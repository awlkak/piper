-- Patch Graph View
--
-- Interactions:
--   Left-drag header    : move node
--   Left-drag outlet pin: start wire; release on inlet pin to connect
--   Left-click empty    : deselect / pan (hold and drag)
--   Right-click node    : context menu (delete, disconnect, edit params)
--   Right-click wire    : delete wire
--   Scroll              : zoom
--   Pinch               : zoom (touch)
--   [A] key or "+" button: open plugin browser to add a machine
--   [Delete] key        : delete selected node
--
-- Plugin browser sidebar (toggled):
--   Lists all discovered plugins by category.
--   Click an entry to spawn it at the center of the view.

local Theme     = require("src.ui.theme")
local Widgets   = require("src.ui.widgets")
local DAG       = require("src.machine.dag")
local Registry  = require("src.machine.registry")
local Loader    = require("src.machine.loader")
local Discovery = require("src.project.discovery")
local Engine    = require("src.audio.engine")
local Preset    = require("src.machine.preset")

local PatchGraph = {}
PatchGraph.__index = PatchGraph

-- Layout constants
local NODE_W      = 150
local HDR_H       = 24
local PARAM_H     = 18
local PIN_R       = 6      -- pin circle radius (world units)
local PIN_HIT_R   = 10     -- hit radius (world units)
local BROWSER_W   = 180    -- plugin browser panel width (screen px)
local CTX_W       = 160    -- context menu width
local CTX_ROW_H   = 22
local PE_W        = 220    -- param editor panel width
local PE_H        = 112    -- param editor panel height
local PE_HDR_H    = 20     -- param editor title bar height

local MAX_CUSTOM_W = 400   -- cap on gui.width override

local function node_height(def)
    if not def then return HDR_H end
    local n     = def.params and #def.params or 0
    local gui_h = def.gui and def.gui.height or 0
    return HDR_H + gui_h + n * PARAM_H + 6
end

local function node_width(def)
    if def and def.gui and def.gui.width then
        return math.min(def.gui.width, MAX_CUSTOM_W)
    end
    return NODE_W
end

-- Bring a node to the front of the z-order (call on any interaction)
local function bring_to_front(node_order, id)
    for i = #node_order, 1, -1 do
        if node_order[i] == id then
            table.remove(node_order, i)
            break
        end
    end
    table.insert(node_order, id)
end

-- Pin world positions for a node
local function inlet_pos(node, pin_idx, n_inlets)
    local nh = node_height(node.def)
    return node.x, node.y + HDR_H + (pin_idx / (n_inlets + 1)) * (nh - HDR_H)
end

local function outlet_pos(node, pin_idx, n_outlets)
    local nh = node_height(node.def)
    return node.x + node_width(node.def), node.y + HDR_H + (pin_idx / (n_outlets + 1)) * (nh - HDR_H)
end

-- Hit-test a pin; returns pin index and kind, or nil
local function hit_inlet(node, wx, wy)
    if not node.def then return nil end
    local inlets = node.def.inlets or {}
    for i, pin in ipairs(inlets) do
        local px, py = inlet_pos(node, i, #inlets)
        local dx, dy = wx - px, wy - py
        if dx*dx + dy*dy <= PIN_HIT_R * PIN_HIT_R then
            return i, pin
        end
    end
    -- Master node has a single "in" inlet at mid-left
    if node.id == DAG.master_id() then
        local nh = node_height(node.def)
        local px, py = node.x, node.y + nh * 0.5
        local dx, dy = wx - px, wy - py
        if dx*dx + dy*dy <= PIN_HIT_R * PIN_HIT_R then
            return 1, { id="in", kind="signal" }
        end
    end
    return nil
end

local function hit_outlet(node, wx, wy)
    if not node.def then return nil end
    local outlets = node.def.outlets or {}
    for i, pin in ipairs(outlets) do
        local px, py = outlet_pos(node, i, #outlets)
        local dx, dy = wx - px, wy - py
        if dx*dx + dy*dy <= PIN_HIT_R * PIN_HIT_R then
            return i, pin
        end
    end
    return nil
end

-- Hit-test a node body (world coords)
local function hit_node(node, wx, wy)
    local nh = node_height(node.def)
    return wx >= node.x and wx < node.x + node_width(node.def)
       and wy >= node.y and wy < node.y + nh
end

-- Hit-test node header only
local function hit_header(node, wx, wy)
    return wx >= node.x and wx < node.x + node_width(node.def)
       and wy >= node.y and wy < node.y + HDR_H
end

-- Hit-test a specific param row; returns param index or nil
local function hit_param(node, wx, wy)
    if not node.def or not node.def.params then return nil end
    local params = node.def.params
    local gui_h  = (node.def.gui and node.def.gui.height or 0)
    for i = 1, #params do
        local py = node.y + HDR_H + gui_h + (i - 1) * PARAM_H
        if wx >= node.x and wx < node.x + node_width(node.def)
        and wy >= py    and wy < py + PARAM_H then
            return i
        end
    end
    return nil
end

-- Hit-test a wire (screen coords, returns edge index or nil)
local function hit_wire(edges, nodes, wx, wy, zoom, ox, oy)
    local THRESH = 6 / zoom
    for i, e in ipairs(edges) do
        local fn = nodes[e.from_id]
        local tn = nodes[e.to_id]
        if fn and tn then
            local outlets = fn.def and fn.def.outlets or {}
            local inlets  = tn.def and tn.def.inlets  or {}
            local oi, ii = 1, 1
            for j, p in ipairs(outlets) do if p.id == e.from_pin then oi = j end end
            for j, p in ipairs(inlets)  do if p.id == e.to_pin   then ii = j end end
            local x1, y1 = outlet_pos(fn, oi, #outlets)
            local x2, y2
            if e.to_id == DAG.master_id() then
                x2 = nodes[e.to_id].x
                y2 = nodes[e.to_id].y + node_height(nodes[e.to_id].def) * 0.5
            else
                x2, y2 = inlet_pos(tn, ii, #inlets)
            end
            -- Point-to-segment distance
            local lx, ly = x2 - x1, y2 - y1
            local len2 = lx*lx + ly*ly
            if len2 > 0 then
                local t = ((wx - x1)*lx + (wy - y1)*ly) / len2
                t = math.max(0, math.min(1, t))
                local cx2 = x1 + t*lx - wx
                local cy2 = y1 + t*ly - wy
                if cx2*cx2 + cy2*cy2 <= THRESH*THRESH then
                    return i
                end
            end
        end
    end
    return nil
end

-- -------------------------
-- Constructor
-- -------------------------

function PatchGraph.new()
    return setmetatable({
        offset_x     = 50,
        offset_y     = 50,
        zoom         = 1.0,

        -- Dragging
        drag_node    = nil,   -- node id being moved
        drag_ox      = 0,
        drag_oy      = 0,
        panning      = false,
        pan_sx       = 0,     -- screen coords at pan start
        pan_sy       = 0,
        pan_ox       = 0,     -- offset at pan start
        pan_oy       = 0,

        -- Wire drawing
        wire_from    = nil,   -- { node_id, pin_id, kind, wx, wy } outlet being dragged
        wire_mx      = 0,     -- current mouse world x
        wire_my      = 0,

        -- Selection
        selected     = nil,   -- node id

        -- Context menu
        ctx          = nil,   -- { x, y, items={label,fn}, target_id, target_edge }

        -- Param editing
        edit_param   = nil,   -- { node_id, param_idx, value_str, px, py, dragging, drag_ox, drag_oy }

        -- File picker (for "file" type params)
        file_picker  = nil,   -- { node_id, param_idx, path_str, files={}, scroll }

        -- Preset picker
        preset_picker = nil,  -- { node_id, filter, scroll, presets, selected, saved_params, saving, save_name }

        -- spawn_pos: world coords to place next spawned machine (from bg right-click)
        spawn_wx     = nil,
        spawn_wy     = nil,

        -- Plugin browser
        browser_open = false,
        browser_scroll = 0,
        browser_plugins = nil,  -- cached discovery results

        -- Hover state
        hov_node     = nil,
        hov_pin      = nil,   -- { node_id, is_inlet, pin_id }
        hov_edge     = nil,

        focused      = false,
        error_msg    = nil,   -- short error string shown in graph (cleared on next spawn)

        -- Custom GUI panel state keyed by node id
        node_gui_state = {},

        -- Z-order: list of node IDs in draw order (last = on top)
        node_order = {},

        -- Callback: called when a new machine is added (for app-level wiring)
        on_add_machine = nil,
        on_del_machine = nil,
        on_add_edge    = nil,
        on_del_edge    = nil,
    }, PatchGraph)
end

function PatchGraph:set_callbacks(on_add, on_del, on_add_edge, on_del_edge)
    self.on_add_machine = on_add
    self.on_del_machine = on_del
    self.on_add_edge    = on_add_edge
    self.on_del_edge    = on_del_edge
end

-- World <-> screen
function PatchGraph:w2s(x, y)
    return x * self.zoom + self.offset_x, y * self.zoom + self.offset_y
end
function PatchGraph:s2w(x, y)
    return (x - self.offset_x) / self.zoom, (y - self.offset_y) / self.zoom
end

-- -------------------------
-- Drawing
-- -------------------------

function PatchGraph:draw(rect)
    local z  = self.zoom
    local ox = self.offset_x
    local oy = self.offset_y

    -- Background + grid
    Theme.set(Theme.bg)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)

    Theme.set({0.12, 0.12, 0.15, 1})
    local gs = math.floor(40 * z)
    if gs >= 6 then
        -- Anchor grid origin to world (0,0) mapped through offset
        local start_x = rect.x + ((ox % gs) + gs) % gs - gs
        local start_y = rect.y + ((oy % gs) + gs) % gs - gs
        for gx = start_x, rect.x + rect.w, gs do
            if gx >= rect.x then
                love.graphics.line(gx, rect.y, gx, rect.y + rect.h)
            end
        end
        for gy = start_y, rect.y + rect.h, gs do
            if gy >= rect.y then
                love.graphics.line(rect.x, gy, rect.x + rect.w, gy)
            end
        end
    end

    love.graphics.setScissor(rect.x, rect.y, rect.w, rect.h)

    local nodes = DAG.get_nodes()
    local edges = DAG.get_edges()

    -- Wires
    self:_draw_wires(nodes, edges, z, ox, oy)

    -- In-progress wire
    if self.wire_from then
        local wf = self.wire_from
        local sx1, sy1 = self:w2s(wf.wx, wf.wy)
        local sx2, sy2 = self:w2s(self.wire_mx, self.wire_my)
        local c = wf.kind == "control" and Theme.wire_control or Theme.wire_signal
        Theme.set(c)
        love.graphics.setLineWidth(2)
        self:_draw_bezier(sx1, sy1, sx2, sy2)
        love.graphics.setLineWidth(1)
    end

    -- Sync node_order: add any nodes not yet tracked (e.g. loaded from project)
    local ordered_set = {}
    for _, id in ipairs(self.node_order) do ordered_set[id] = true end
    for id in pairs(nodes) do
        if not ordered_set[id] then
            table.insert(self.node_order, id)
        end
    end
    -- Remove stale IDs from node_order
    for i = #self.node_order, 1, -1 do
        if not nodes[self.node_order[i]] then
            table.remove(self.node_order, i)
        end
    end

    -- Nodes (draw in z-order; last = on top)
    for _, id in ipairs(self.node_order) do
        local node = nodes[id]
        if node then self:_draw_node(id, node, z, ox, oy, rect) end
    end

    love.graphics.setScissor()

    -- Plugin browser panel
    local graph_w = self.browser_open and (rect.w - BROWSER_W) or rect.w
    if self.browser_open then
        self:_draw_browser(rect.x + graph_w, rect.y, BROWSER_W, rect.h)
    end

    -- Context menu (drawn on top, no scissor; reset color state first)
    if self.ctx then
        love.graphics.setColor(1, 1, 1, 1)
        self:_draw_ctx_menu()
    end

    -- File picker overlay
    if self.file_picker then
        love.graphics.setColor(1, 1, 1, 1)
        self:_draw_file_picker(rect)
    end

    -- Preset picker overlay
    if self.preset_picker then
        love.graphics.setColor(1, 1, 1, 1)
        self:_draw_preset_picker(rect)
    end

    -- Toolbar: "+" button and hint
    self:_draw_toolbar(rect)

    -- Error toast
    if self.error_msg then
        local tw = rect.w - 20
        local tx = rect.x + 10
        local ty = rect.y + rect.h - 48
        love.graphics.setColor(0.7, 0.1, 0.1, 0.92)
        love.graphics.rectangle("fill", tx, ty, tw, 34, 4, 4)
        love.graphics.setColor(1, 0.9, 0.9, 1)
        love.graphics.setFont(Theme.font_medium)
        love.graphics.printf(self.error_msg, tx + 8, ty + 9, tw - 16, "left")
    end
end

-- Called by ui.lua after all views so param editor floats above everything
function PatchGraph:draw_overlay()
    if self.edit_param then
        self:_draw_param_editor()
    end
end

-- Called by ui.lua BEFORE view routing — handles overlay events globally
-- Returns true if the event was consumed
function PatchGraph:handle_overlay_event(ev)
    if not self.edit_param then return false end
    local ep = self.edit_param
    local ex, ey = ev.x or 0, ev.y or 0

    -- Keyboard and text always go to param editor while open
    if ev.type == "text" or ev.type == "key_down" then
        return self:handle_event(ev, nil)  -- nil rect: skips rect checks
    end

    -- Pointer move: handle drag and slider drag regardless of position
    if ev.type == "pointer_move" then
        if ep.dragging then
            local sw2, sh2 = love.graphics.getDimensions()
            ep.px = math.max(4, math.min(sw2 - PE_W - 4, ex - ep.drag_ox))
            ep.py = math.max(4, math.min(sh2 - PE_H - 4, ey - ep.drag_oy))
            return true
        elseif ep.slider_drag then
            local node = DAG.get_nodes()[ep.node_id]
            local p    = node and node.def and node.def.params[ep.param_idx]
            if p then
                local sl_x = ep.px + 8
                local sl_w = PE_W - 16
                local t = math.max(0, math.min(1, (ex - sl_x) / sl_w))
                local v = p.min + t * (p.max - p.min)
                ep.value_str = string.format("%g", v)
                ep.typing = false
                DAG.set_param(ep.node_id, p.id, v)
                local nd = DAG.get_nodes()[ep.node_id]
                if nd then nd.params[p.id] = v end
            end
            return true
        end
    end

    if ev.type == "pointer_up" then
        if ep.dragging or ep.slider_drag then
            ep.dragging    = false
            ep.slider_drag = false
            return true
        end
    end

    -- pointer_down on the panel itself: always consume regardless of which view owns the rect
    if ev.type == "pointer_down" then
        if Widgets.hit(ex, ey, ep.px, ep.py, PE_W, PE_H) then
            return self:handle_event(ev, nil)
        end
    end

    return false
end

function PatchGraph:_draw_wires(nodes, edges, z, ox, oy)
    love.graphics.setLineWidth(2)
    for i, e in ipairs(edges) do
        local fn = nodes[e.from_id]
        local tn = nodes[e.to_id]
        if not fn or not tn then goto next end

        local outlets = fn.def and fn.def.outlets or {}
        local inlets  = tn.def and tn.def.inlets  or {}
        local oi, kind = 1, "signal"
        for j, p in ipairs(outlets) do
            if p.id == e.from_pin then oi = j; kind = p.kind end
        end
        local ii = 1
        for j, p in ipairs(inlets) do if p.id == e.to_pin then ii = j end end

        local wx1, wy1 = outlet_pos(fn, oi, #outlets)
        local wx2, wy2
        if e.to_id == DAG.master_id() then
            wx2 = tn.x
            wy2 = tn.y + node_height(tn.def) * 0.5
        else
            wx2, wy2 = inlet_pos(tn, ii, #inlets)
        end
        local sx1, sy1 = wx1 * z + ox, wy1 * z + oy
        local sx2, sy2 = wx2 * z + ox, wy2 * z + oy

        local hov = (self.hov_edge == i)
        local c = kind == "control" and Theme.wire_control or Theme.wire_signal
        if hov then
            love.graphics.setLineWidth(4)
            Theme.set({1, 0.3, 0.3, 0.7})
            self:_draw_bezier(sx1, sy1, sx2, sy2)
            love.graphics.setLineWidth(2)
        end
        Theme.set(c)
        self:_draw_bezier(sx1, sy1, sx2, sy2)
        ::next::
    end
    love.graphics.setLineWidth(1)
end

function PatchGraph:_draw_bezier(x1, y1, x2, y2)
    -- Control-point spread: proportional to horizontal distance, clamped so
    -- short wires don't overshoot and long wires don't balloon.
    local dx = math.max(30, math.min(200, math.abs(x2 - x1) * 0.45))
    love.graphics.line(
        x1, y1,
        x1 + dx, y1,
        x2 - dx, y2,
        x2, y2)
end

local function build_gui_ctx(bsx, bsy, bsw, bsh, z, mx, my)
    local Theme   = require("src.ui.theme")
    local Widgets = require("src.ui.widgets")
    local ox, oy = bsx, bsy
    local ctx = {
        w       = bsw,
        h       = bsh,
        z       = z,
        mouse_x = mx - bsx,
        mouse_y = my - bsy,
        theme   = Theme,
    }
    function ctx.rect(x, y, w, h, fill, border, radius)
        Widgets.rect(ox+x, oy+y, w, h, fill, border, radius)
    end
    function ctx.label(text, x, y, w, h, color, font, align)
        Widgets.label(text, ox+x, oy+y, w, h, color, font, align)
    end
    function ctx.line(x1, y1, x2, y2, color, width)
        if color then Theme.set(color) end
        love.graphics.setLineWidth(width or 1)
        love.graphics.line(ox+x1, oy+y1, ox+x2, oy+y2)
        love.graphics.setLineWidth(1)
    end
    function ctx.circle(x, y, r, mode, color)
        if color then Theme.set(color) end
        love.graphics.circle(mode or "fill", ox+x, oy+y, r)
    end
    function ctx.plot(points, color, width)
        if #points < 4 then return end
        if color then Theme.set(color) end
        love.graphics.setLineWidth(width or 1)
        local pts = {}
        for i = 1, #points, 2 do
            pts[#pts+1] = ox + points[i]
            pts[#pts+1] = oy + points[i+1]
        end
        love.graphics.line(pts)
        love.graphics.setLineWidth(1)
    end
    function ctx.button(text, x, y, w, h, hovered, pressed)
        Widgets.button(text, ox+x, oy+y, w, h, hovered, pressed)
    end
    function ctx.slider(x, y, w, h, value, min_val, max_val, hovered)
        Widgets.slider(ox+x, oy+y, w, h, value, min_val, max_val, hovered)
    end
    function ctx.scrollbar(x, y, w, h, offset, content_h, view_h)
        return Widgets.scrollbar(ox+x, oy+y, w, h, offset, content_h, view_h)
    end
    return ctx
end

function PatchGraph:_draw_node(id, node, z, ox, oy, rect)
    local nx, ny = node.x * z + ox, node.y * z + oy
    local nw     = node_width(node.def) * z
    local nh     = node_height(node.def) * z
    local is_sel    = (id == self.selected)
    local is_master = (id == DAG.master_id())
    local is_hov    = (self.hov_node == id)

    -- Shadow
    Theme.set({0, 0, 0, 0.4})
    love.graphics.rectangle("fill", nx + 3, ny + 3, nw, nh, 5 * z, 5 * z)

    -- Body
    local bg = is_master and {0.18, 0.14, 0.06, 1} or Theme.node_bg
    Widgets.rect(nx, ny, nw, nh, bg,
        is_sel and Theme.node_selected or (is_hov and Theme.accent2 or Theme.node_border),
        5 * z)

    -- Header
    local hdr_h = HDR_H * z
    local hdr_c
    if is_master then
        hdr_c = {0.30, 0.22, 0.05, 1}
    elseif node.def then
        local t = node.def.type
        hdr_c = t == "generator" and {0.10, 0.18, 0.28, 1}
             or t == "effect"    and {0.10, 0.22, 0.12, 1}
             or t == "control"   and {0.25, 0.15, 0.08, 1}
             or {0.12, 0.12, 0.20, 1}
    else
        hdr_c = {0.12, 0.12, 0.20, 1}
    end
    Widgets.rect(nx, ny, nw, hdr_h, hdr_c, nil, 5 * z)

    -- Node name + type badge
    -- Reserve 16px on right for ▾ preset button (shrink name area, don't change NODE_W)
    local name = is_master and "MASTER" or (node.def and node.def.name or id)
    Widgets.label(name, nx + 6, ny, nw - 44, hdr_h, Theme.text, Theme.font_small)

    -- ▾ preset picker button (right edge of header, always visible)
    do
        local pbw = 16 * z
        local pbx = nx + nw - pbw
        -- Slightly lighter than header color
        local pb_c = {
            math.min(1, hdr_c[1] + 0.08),
            math.min(1, hdr_c[2] + 0.08),
            math.min(1, hdr_c[3] + 0.08),
            1,
        }
        Theme.set(pb_c)
        love.graphics.rectangle("fill", pbx, ny, pbw, hdr_h)
        Theme.set(Theme.text_dim)
        love.graphics.setFont(Theme.font_small)
        love.graphics.printf("\xe2\x96\xbe", pbx, ny + (hdr_h - Theme.font_small:getHeight()) * 0.5, pbw, "center")
    end

    -- Delete button in header (×) — only on non-master
    if not is_master and (is_sel or is_hov) then
        local bx = nx + nw - 20 * z
        local bw = 18 * z
        Theme.set({0.6, 0.2, 0.2, 0.8})
        love.graphics.rectangle("fill", bx, ny + 3 * z, bw, hdr_h - 6 * z, 3, 3)
        Theme.set(Theme.text)
        love.graphics.setFont(Theme.font_small)
        love.graphics.printf("\xc3\x97", bx, ny + (hdr_h - (Theme.font_small:getHeight())) * 0.5, bw, "center")
    end

    -- Custom GUI panel (drawn above param rows, clipped to panel bounds)
    if node.def and node.def.gui then
        local gui_h  = node.def.gui.height
        local panel_sx = nx
        local panel_sy = ny + hdr_h
        local panel_sw = nw
        local panel_sh = gui_h * z

        love.graphics.setScissor(panel_sx, panel_sy, panel_sw, panel_sh)

        local gui_state = self.node_gui_state[id] or {}
        self.node_gui_state[id] = gui_state

        -- Let the instance push live data into gui_state
        local nd2 = DAG.get_nodes()[id]
        if nd2 and nd2.instance and type(nd2.instance.get_ui_state) == "function" then
            local ok2, ui_data = pcall(nd2.instance.get_ui_state, nd2.instance)
            if ok2 and type(ui_data) == "table" then
                for k, v in pairs(ui_data) do gui_state[k] = v end
            end
        end

        local mx2, my2 = love.mouse.getPosition()
        local gctx = build_gui_ctx(panel_sx, panel_sy, panel_sw, panel_sh, z, mx2, my2)
        pcall(node.def.gui.draw, gctx, gui_state)

        -- Restore the view-level scissor
        love.graphics.setScissor(rect.x, rect.y, rect.w, rect.h)
    end

    -- Params
    if node.def and node.def.params then
        local gui_h_px = (node.def.gui and node.def.gui.height or 0) * z
        for i, p in ipairs(node.def.params) do
            local py    = ny + hdr_h + gui_h_px + (i - 1) * PARAM_H * z
            local val   = node.params and node.params[p.id]
            if val == nil then val = p.default end
            local is_editing = self.edit_param
                            and self.edit_param.node_id == id
                            and self.edit_param.param_idx == i

            -- Row background on hover
            if is_editing then
                Theme.set({0.22, 0.30, 0.22, 1})
                love.graphics.rectangle("fill", nx + 2, py, nw - 4, PARAM_H * z)
            end

            local val_str
            if p.type == "file" then
                -- Show just filename
                val_str = tostring(val)
                val_str = val_str:match("[^/]+$") or val_str
                if val_str == "" then val_str = "(click to browse)" end
            elseif is_editing then
                val_str = self.edit_param.value_str .. (self.edit_param.typing and "_" or "")
            else
                val_str = string.format("%g", val)
            end
            local lbl = string.format("%-9s", p.label:sub(1, 9))
            Widgets.label(lbl,     nx + 4, py, (nw - 8) * 0.55, PARAM_H * z, Theme.text_dim, Theme.font_small)
            Widgets.label(val_str, nx + 4 + (nw - 8) * 0.55, py, (nw - 8) * 0.45, PARAM_H * z,
                          is_editing and Theme.accent or Theme.text, Theme.font_small)
        end
    end

    -- Inlet pins (left side)
    local inlets = (node.def and node.def.inlets) or {}
    if is_master then inlets = { { id="in", kind="signal" } } end
    for i, pin in ipairs(inlets) do
        local wx, wy
        if is_master then
            wx, wy = node.x, node.y + node_height(node.def) * 0.5
        else
            wx, wy = inlet_pos(node, i, #inlets)
        end
        local sx, sy = wx * z + ox, wy * z + oy
        local hov = self.hov_pin and self.hov_pin.node_id == id
                 and self.hov_pin.is_inlet and self.hov_pin.pin_id == pin.id
        local c = pin.kind == "control" and Theme.pin_control or Theme.pin_signal
        Theme.set(c)
        love.graphics.circle("fill", sx, sy, PIN_R * z * (hov and 1.5 or 1))
        Theme.set(hov and Theme.text or Theme.border)
        love.graphics.circle("line", sx, sy, PIN_R * z * (hov and 1.5 or 1))
        if hov then
            Widgets.label(pin.id, sx + 8, sy - 8, 80, 14, Theme.text, Theme.font_small)
        end
    end

    -- Outlet pins (right side)
    local outlets = node.def and node.def.outlets or {}
    for i, pin in ipairs(outlets) do
        local wx, wy = outlet_pos(node, i, #outlets)
        local sx, sy = wx * z + ox, wy * z + oy
        local hov = self.hov_pin and self.hov_pin.node_id == id
                 and not self.hov_pin.is_inlet and self.hov_pin.pin_id == pin.id
        local c = pin.kind == "control" and Theme.pin_control or Theme.pin_signal
        Theme.set(c)
        love.graphics.circle("fill", sx, sy, PIN_R * z * (hov and 1.5 or 1))
        Theme.set(hov and Theme.text or Theme.border)
        love.graphics.circle("line", sx, sy, PIN_R * z * (hov and 1.5 or 1))
        if hov then
            Widgets.label(pin.id, sx - 80, sy - 8, 78, 14, Theme.text, Theme.font_small, "right")
        end
    end
end

function PatchGraph:_draw_toolbar(rect)
    local bw, bh = 28, 22
    local bx = rect.x + 6
    local by = rect.y + rect.h - bh - 4

    -- "+" add machine button
    local hov = self.browser_open
    Widgets.button(self.browser_open and "×" or "+", bx, by, bw, bh,
                   false, hov, Theme.font_large)

    -- Hint text
    local hint = "[A] add   [Del] delete   right-click for options   drag pin→pin to connect"
    Widgets.label(hint, bx + bw + 8, by, rect.w - bw - 20, bh,
                  Theme.text_dim, Theme.font_small)
end

function PatchGraph:_draw_browser(x, y, w, h)
    -- Panel background
    Widgets.rect(x, y, w, h, Theme.bg_panel, Theme.border)
    Widgets.label("ADD MACHINE", x, y + 2, w, 20, Theme.accent, Theme.font_small, "center")
    Theme.set(Theme.border)
    love.graphics.line(x, y + 22, x + w, y + 22)

    if not self.browser_plugins then
        self.browser_plugins = Discovery.scan()
    end

    local CATS = { "generators", "effects", "control", "abstractions" }
    local CAT_LABELS = { generators="Generators", effects="Effects",
                         control="Control", abstractions="Abstractions" }

    local row_h = 20
    local cy = y + 24 - self.browser_scroll
    love.graphics.setScissor(x, y + 22, w, h - 22)

    for _, cat in ipairs(CATS) do
        local paths = self.browser_plugins[cat] or {}
        if #paths > 0 then
            -- Category header
            if cy >= y + 22 and cy < y + h then
                Theme.set(Theme.bg_header)
                love.graphics.rectangle("fill", x, cy, w, row_h)
                Widgets.label(CAT_LABELS[cat], x + 6, cy, w - 8, row_h,
                              Theme.text_header, Theme.font_small)
            end
            cy = cy + row_h

            for _, path in ipairs(paths) do
                if cy >= y + 22 and cy < y + h then
                    local name = Discovery.display_name(path)
                    local hov = Widgets.hit(
                        love.mouse.getX(), love.mouse.getY(), x, cy, w, row_h)
                    if hov then
                        Theme.set(Theme.btn_hover)
                        love.graphics.rectangle("fill", x + 2, cy, w - 4, row_h)
                    end
                    Widgets.label("  " .. name, x, cy, w, row_h,
                                  Theme.text, Theme.font_small)
                end
                cy = cy + row_h
            end
        end
    end

    love.graphics.setScissor()

    -- Scroll hint if content overflows
    local total_h = cy - (y + 24 - self.browser_scroll)
    if total_h > h - 22 then
        Widgets.label("▼ scroll", x, y + h - 14, w, 14, Theme.text_dim, Theme.font_small, "center")
    end
end

function PatchGraph:_draw_ctx_menu()
    local ctx = self.ctx
    local mw  = CTX_W
    local mh  = #ctx.items * CTX_ROW_H + 4
    local mx  = ctx.x
    local my  = ctx.y

    Widgets.rect(mx, my, mw, mh, Theme.bg_panel, Theme.border, 4)

    for i, item in ipairs(ctx.items) do
        local iy = my + 2 + (i - 1) * CTX_ROW_H
        local hov = Widgets.hit(love.mouse.getX(), love.mouse.getY(),
                                mx, iy, mw, CTX_ROW_H)
        if hov then
            Theme.set(Theme.btn_hover)
            love.graphics.rectangle("fill", mx + 1, iy, mw - 2, CTX_ROW_H)
        end
        local c = item.danger and {0.9, 0.3, 0.3, 1} or Theme.text
        Widgets.label(item.label, mx + 8, iy, mw - 12, CTX_ROW_H, c, Theme.font_medium)
    end
end

function PatchGraph:_draw_param_editor()
    local ep   = self.edit_param
    local node = DAG.get_nodes()[ep.node_id]
    if not node or not node.def then return end
    local p    = node.def.params[ep.param_idx]
    if not p then return end

    local px, py = ep.px, ep.py

    -- Shadow
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", px + 3, py + 3, PE_W, PE_H, 4, 4)

    -- Title bar (draggable)
    local node_name = node.def.name or ep.node_id
    love.graphics.setColor(Theme.bg_header[1], Theme.bg_header[2], Theme.bg_header[3], 1)
    love.graphics.rectangle("fill", px, py, PE_W, PE_HDR_H, 4, 4)
    love.graphics.rectangle("fill", px, py + PE_HDR_H - 4, PE_W, 4)  -- square bottom corners
    love.graphics.setColor(Theme.border_focus[1], Theme.border_focus[2], Theme.border_focus[3], 1)
    love.graphics.rectangle("line", px, py, PE_W, PE_HDR_H)
    love.graphics.setColor(Theme.text_dim[1], Theme.text_dim[2], Theme.text_dim[3], 1)
    love.graphics.setFont(Theme.font_small)
    love.graphics.print(node_name .. " / " .. p.label, px + 6, py + 3)
    Widgets.button("×", px + PE_W - 20, py + 2, 16, 14, false, false, Theme.font_small)

    -- Panel body
    Widgets.rect(px, py + PE_HDR_H, PE_W, PE_H - PE_HDR_H, Theme.bg_panel, Theme.border_focus, 4)
    love.graphics.rectangle("fill", px, py + PE_HDR_H, PE_W, 4)  -- square top corners on body

    -- Value display (tappable text field)
    local val_y = py + PE_HDR_H + 4
    local val_h = 22
    local field_bg     = ep.typing and {0.10,0.12,0.18,1} or {0.09,0.09,0.13,1}
    local field_border = ep.typing and Theme.border_focus or Theme.border
    Widgets.rect(px + 8, val_y, PE_W - 16, val_h, field_bg, field_border, 3)
    local disp = ep.value_str .. (ep.typing and "_" or "")
    Widgets.label(disp, px + 8, val_y, PE_W - 16, val_h,
                  ep.typing and Theme.accent or Theme.text, Theme.font_medium, "center")

    -- Slider track
    local cur_val = tonumber(ep.value_str) or 0
    local sl_x, sl_y = px + 8, py + PE_HDR_H + 26
    local sl_w, sl_h = PE_W - 16, 16
    local range = p.max - p.min
    local t     = range > 0 and (cur_val - p.min) / range or 0
    t = math.max(0, math.min(1, t))

    love.graphics.setColor(0.10, 0.10, 0.14, 1)
    love.graphics.rectangle("fill", sl_x, sl_y + sl_h * 0.4, sl_w, sl_h * 0.2, 3, 3)
    Theme.set(Theme.accent)
    love.graphics.rectangle("fill", sl_x, sl_y + sl_h * 0.4, sl_w * t, sl_h * 0.2, 3, 3)
    local thumb_x = sl_x + sl_w * t
    love.graphics.circle("fill", thumb_x, sl_y + sl_h * 0.5, sl_h * 0.4)
    Theme.set(Theme.text)
    love.graphics.circle("line", thumb_x, sl_y + sl_h * 0.5, sl_h * 0.4)

    -- Range labels
    Widgets.label(string.format("%g", p.min), sl_x, sl_y + sl_h + 1,
                  50, 11, Theme.text_dim, Theme.font_small, "left")
    Widgets.label(string.format("%g", p.max), sl_x + sl_w - 50, sl_y + sl_h + 1,
                  50, 11, Theme.text_dim, Theme.font_small, "right")

    -- Stepper buttons: −− − + ++
    local btn_y = py + PE_H - 26
    local btn_h = 22
    local btn_w = math.floor((PE_W - 10) / 4) - 2
    Widgets.button("−−", px + 4,               btn_y, btn_w, btn_h, false, false, Theme.font_small)
    Widgets.button("−",  px + 4 + (btn_w+2),   btn_y, btn_w, btn_h, false, false, Theme.font_small)
    Widgets.button("+",  px + 4 + (btn_w+2)*2, btn_y, btn_w, btn_h, false, false, Theme.font_small)
    Widgets.button("++", px + 4 + (btn_w+2)*3, btn_y, btn_w, btn_h, false, false, Theme.font_small)
end

local AUDIO_EXTS = { wav=true, ogg=true, mp3=true, flac=true, aif=true, aiff=true }

local function scan_dir_entries(dir)
    local dirs  = {}
    local files = {}
    local ok, items = pcall(love.filesystem.getDirectoryItems, dir)
    if not ok or not items then return {} end
    for _, name in ipairs(items) do
        if name:sub(1,1) ~= "." then
            local full = dir ~= "" and (dir .. "/" .. name) or name
            local info = love.filesystem.getInfo(full)
            if info then
                if info.type == "directory" then
                    table.insert(dirs, { name=name, is_dir=true, path=full })
                else
                    local ext = name:match("%.(%w+)$")
                    if ext and AUDIO_EXTS[ext:lower()] then
                        table.insert(files, { name=name, is_dir=false, path=full })
                    end
                end
            end
        end
    end
    table.sort(dirs,  function(a,b) return a.name < b.name end)
    table.sort(files, function(a,b) return a.name < b.name end)
    local entries = {}
    for _, e in ipairs(dirs)  do table.insert(entries, e) end
    for _, e in ipairs(files) do table.insert(entries, e) end
    return entries
end

function PatchGraph:_open_file_picker(node_id, param_idx, current_val)
    local cur = tostring(current_val or "")
    local cwd = cur ~= "" and (cur:match("^(.*)/[^/]+$") or "") or ""
    self.file_picker = {
        node_id   = node_id,
        param_idx = param_idx,
        path_str  = cur,
        cwd       = cwd,
        entries   = scan_dir_entries(cwd),
        scroll    = 0,
    }
    self.edit_param = nil
end

local FP_W, FP_H = 380, 280
local FP_ROW_H   = 22

local PP_W, PP_H = 380, 300
local PP_ROW_H   = 22

function PatchGraph:_draw_file_picker(rect)
    local fp = self.file_picker
    local px = rect.x + math.floor((rect.w - FP_W) * 0.5)
    local py = rect.y + math.floor((rect.h - FP_H) * 0.5)

    -- Dim overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)

    -- Panel
    Widgets.rect(px, py, FP_W, FP_H, Theme.bg_panel, Theme.border_focus, 4)

    -- Title
    Widgets.label("SELECT AUDIO FILE", px + 4, py + 2, FP_W - 8, 20,
                  Theme.accent, Theme.font_small, "center")
    Theme.set(Theme.border)
    love.graphics.line(px, py + 22, px + FP_W, py + 22)

    -- Breadcrumb (current directory)
    local cwd_display = fp.cwd == "" and "(root)" or fp.cwd
    Widgets.label("\xe2\x96\xb8 " .. cwd_display, px + 4, py + 24, FP_W - 8, FP_ROW_H,
                  Theme.text_dim, Theme.font_small)
    Theme.set(Theme.border)
    love.graphics.line(px, py + 24 + FP_ROW_H, px + FP_W, py + 24 + FP_ROW_H)

    -- Selected file field
    local input_y = py + 24 + FP_ROW_H + 2
    Widgets.label("File:", px + 4, input_y, 30, FP_ROW_H, Theme.text_dim, Theme.font_small)
    Theme.set({0.08, 0.08, 0.11, 1})
    love.graphics.rectangle("fill", px + 36, input_y + 2, FP_W - 84, FP_ROW_H - 4, 2, 2)
    Theme.set(fp.path_str ~= "" and Theme.border_focus or Theme.border)
    love.graphics.rectangle("line", px + 36, input_y + 2, FP_W - 84, FP_ROW_H - 4, 2, 2)
    local disp = fp.path_str ~= "" and (fp.path_str:match("[^/]+$") or fp.path_str) or "(none)"
    Widgets.label(disp, px + 38, input_y, FP_W - 86, FP_ROW_H,
                  fp.path_str ~= "" and Theme.text or Theme.text_dim, Theme.font_small)
    Widgets.button("OK", px + FP_W - 44, input_y + 2, 40, FP_ROW_H - 4, false, false, Theme.font_small)

    -- Directory listing
    local list_y = input_y + FP_ROW_H + 4
    local bot_y  = py + FP_H - 26
    local list_h = bot_y - list_y - 2
    love.graphics.setScissor(px, list_y, FP_W - 12, list_h)

    -- Build display list: ".." entry first if not at root, then entries
    local all_entries = {}
    if fp.cwd ~= "" then
        table.insert(all_entries, { name="..", is_dir=true, path=".." })
    end
    for _, e in ipairs(fp.entries) do table.insert(all_entries, e) end

    if #all_entries == 0 then
        Widgets.label("(empty)", px + 8, list_y + 8, FP_W - 16, FP_ROW_H,
                      Theme.text_dim, Theme.font_small)
    else
        local cy = list_y - fp.scroll
        for _, entry in ipairs(all_entries) do
            if cy + FP_ROW_H >= list_y and cy < list_y + list_h then
                local is_sel = not entry.is_dir and fp.path_str == entry.path
                if is_sel then
                    Theme.set({0.20, 0.35, 0.55, 1})
                    love.graphics.rectangle("fill", px + 2, cy, FP_W - 16, FP_ROW_H)
                end
                local hov = Widgets.hit(love.mouse.getX(), love.mouse.getY(),
                                        px + 2, cy, FP_W - 16, FP_ROW_H)
                if hov and not is_sel then
                    Theme.set(Theme.btn_hover)
                    love.graphics.rectangle("fill", px + 2, cy, FP_W - 16, FP_ROW_H)
                end
                local lbl, col
                if entry.path == ".." then
                    lbl = "\xe2\x86\x90  .."
                    col = Theme.text_dim
                elseif entry.is_dir then
                    lbl = "\xe2\x96\xb8 " .. entry.name .. "/"
                    col = Theme.accent2
                else
                    lbl = entry.name
                    col = is_sel and Theme.text or Theme.text_dim
                end
                Widgets.label(lbl, px + 8, cy, FP_W - 20, FP_ROW_H, col, Theme.font_small)
            end
            cy = cy + FP_ROW_H
        end
    end
    love.graphics.setScissor()

    -- Scrollbar
    local n_all = #fp.entries + (fp.cwd ~= "" and 1 or 0)
    local total_h = n_all * FP_ROW_H
    if total_h > list_h then
        Widgets.scrollbar(px + FP_W - 12, list_y, 10, list_h, fp.scroll, total_h, list_h)
    end

    -- Bottom bar
    Theme.set(Theme.border)
    love.graphics.line(px, bot_y, px + FP_W, bot_y)
    local can_open = fp.path_str ~= ""
    Widgets.button("Open", px + FP_W - 132, bot_y + 3, 62, 20, can_open, false, Theme.font_small)
    Widgets.button("Cancel", px + FP_W - 66, bot_y + 3, 62, 20, false, false, Theme.font_small)
end

function PatchGraph:_commit_file_picker()
    local fp   = self.file_picker
    local path = fp.path_str
    if path ~= "" then
        DAG.set_param(fp.node_id, "file", path)
        local node = DAG.get_nodes()[fp.node_id]
        if node then node.params["file"] = path end
    end
    self.file_picker = nil
end

-- -------------------------
-- Machine management helpers
-- -------------------------

function PatchGraph:_do_spawn(plugin_path, wx, wy)
    self.error_msg = nil
    local ok, def = pcall(Loader.load, plugin_path, Engine.SAMPLE_RATE, Engine.BLOCK_SIZE)
    if not ok then
        local msg = tostring(def)
        print("[PatchGraph] could not load plugin: " .. msg)
        self.error_msg = "Load error: " .. (msg:match("[^\n]+") or msg)
        return
    end
    local ok2, inst = pcall(Loader.instantiate, def, {}, Engine.SAMPLE_RATE)
    if not ok2 then
        local msg = tostring(inst)
        print("[PatchGraph] could not instantiate: " .. msg)
        self.error_msg = "Instantiate error: " .. (msg:match("[^\n]+") or msg)
        return
    end

    local base = plugin_path:match("([^/]+)%.lua$") or "machine"
    local id   = base
    local n    = 1
    while DAG.get_nodes()[id] do
        n  = n + 1
        id = base .. n
    end

    local params = {}
    for _, p in ipairs(def.params or {}) do
        params[p.id] = p.default
    end

    DAG.add_node(id, def, inst, params, wx, wy)
    Registry.register(id, def, inst, params)

    if self.on_add_machine then
        self.on_add_machine(id, def, inst, params)
    end

    self.selected     = id
    self.browser_open = false
    table.insert(self.node_order, id)
    return id
end

function PatchGraph:_spawn_machine(plugin_path, rect)
    local cx = rect and (rect.x + rect.w * 0.5) or 400
    local cy = rect and (rect.y + rect.h * 0.5) or 300
    local wx, wy = self:s2w(cx, cy)
    wx = wx + math.random(-20, 20)
    wy = wy + math.random(-20, 20)
    return self:_do_spawn(plugin_path, wx, wy)
end

function PatchGraph:_spawn_machine_at(plugin_path, wx, wy)
    return self:_do_spawn(plugin_path, wx, wy)
end

function PatchGraph:_delete_node(id)
    if id == DAG.master_id() then return end
    -- Remove all edges connected to this node first
    local edges = DAG.get_edges()
    for i = #edges, 1, -1 do
        local e = edges[i]
        if e.from_id == id or e.to_id == id then
            if self.on_del_edge then self.on_del_edge(i, e) end
            DAG.remove_edge(e.from_id, e.from_pin, e.to_id, e.to_pin)
        end
    end
    if self.on_del_machine then self.on_del_machine(id) end
    Registry.unregister(id)
    DAG.remove_node(id)
    if self.selected == id then self.selected = nil end
    for i = #self.node_order, 1, -1 do
        if self.node_order[i] == id then
            table.remove(self.node_order, i)
            break
        end
    end
end

function PatchGraph:_delete_edge(idx)
    local edges = DAG.get_edges()
    local e = edges[idx]
    if not e then return end
    if self.on_del_edge then self.on_del_edge(idx, e) end
    DAG.remove_edge(e.from_id, e.from_pin, e.to_id, e.to_pin)
end

function PatchGraph:_disconnect_all(id)
    local edges = DAG.get_edges()
    for i = #edges, 1, -1 do
        local e = edges[i]
        if e.from_id == id or e.to_id == id then
            DAG.remove_edge(e.from_id, e.from_pin, e.to_id, e.to_pin)
        end
    end
end

-- -------------------------
-- Context menu builders
-- -------------------------

function PatchGraph:_open_node_ctx(id, sx, sy)
    local is_master = (id == DAG.master_id())
    local items = {}

    if not is_master then
        table.insert(items, {
            label = "Delete machine",
            danger = true,
            fn = function() self:_delete_node(id) end,
        })
        table.insert(items, {
            label = "Disconnect all",
            fn = function() self:_disconnect_all(id) end,
        })
    end
    table.insert(items, {
        label = "Connect to Master →",
        fn = function()
            local node = DAG.get_nodes()[id]
            if not node or not node.def then return end
            local outlets = node.def.outlets or {}
            for _, pin in ipairs(outlets) do
                if pin.kind == "signal" then
                    local ok = pcall(DAG.add_edge, id, pin.id, DAG.master_id(), "in")
                    if ok and self.on_add_edge then
                        self.on_add_edge(id, pin.id, DAG.master_id(), "in")
                    end
                    break
                end
            end
        end,
    })
    table.insert(items, {
        label = "Load Preset\xe2\x80\xa6",
        fn = function() self:_open_preset_picker(id, false) end,
    })
    table.insert(items, {
        label = "Save as Preset\xe2\x80\xa6",
        fn = function() self:_open_preset_picker(id, true) end,
    })
    table.insert(items, {
        label = "Cancel",
        fn = function() end,
    })

    self.ctx = { x = sx, y = sy, items = items, target_id = id }
end

function PatchGraph:_open_edge_ctx(edge_idx, sx, sy)
    local e = DAG.get_edges()[edge_idx]
    if not e then return end
    self.ctx = {
        x = sx, y = sy,
        target_edge = edge_idx,
        items = {
            {
                label  = "Delete wire",
                danger = true,
                fn = function() self:_delete_edge(edge_idx) end,
            },
            { label = "Cancel", fn = function() end },
        },
    }
end

function PatchGraph:_open_bg_ctx(sx, sy, wx, wy)
    if not self.browser_plugins then
        self.browser_plugins = Discovery.scan()
    end
    local bp = self.browser_plugins

    -- Build "Add Machine" sub-items from discovered plugins
    local CATS = { "generators", "effects", "control", "abstractions" }
    local CAT_LABELS = { generators="Generator", effects="Effect",
                         control="Control", abstractions="Abstraction" }
    local add_items = {}
    for _, cat in ipairs(CATS) do
        local paths = bp[cat] or {}
        for _, path in ipairs(paths) do
            local name = Discovery.display_name(path)
            table.insert(add_items, {
                label = CAT_LABELS[cat] .. ": " .. name,
                fn = function()
                    self.spawn_wx = wx
                    self.spawn_wy = wy
                    self:_spawn_machine_at(path, wx, wy)
                end,
            })
        end
    end

    local items = {}
    -- Flatten add_items directly into the menu (no sub-menus in this simple UI)
    for _, item in ipairs(add_items) do
        table.insert(items, item)
    end
    table.insert(items, { label = "Open Machine Browser", fn = function()
        self.browser_open = true
        self.browser_plugins = Discovery.scan()
    end })
    table.insert(items, { label = "Cancel", fn = function() end })

    self.ctx = { x = sx, y = sy, items = items }
end

-- -------------------------
-- Event handling
-- -------------------------

function PatchGraph:handle_event(ev, rect)
    -- rect may be nil when called from handle_overlay_event (overlay-only path)
    local graph_rect = rect and {
        x = rect.x,
        y = rect.y,
        w = self.browser_open and (rect.w - BROWSER_W) or rect.w,
        h = rect.h,
    } or { x=0, y=0, w=0, h=0 }

    local ex, ey = ev.x or 0, ev.y or 0

    -- File picker eats all input when open
    if self.file_picker then
        local fp = self.file_picker
        local px = rect.x + math.floor((rect.w - FP_W) * 0.5)
        local py = rect.y + math.floor((rect.h - FP_H) * 0.5)
        local input_y = py + 24 + FP_ROW_H + 2
        local list_y  = input_y + FP_ROW_H + 4
        local bot_y   = py + FP_H - 26
        local list_h  = bot_y - list_y - 2

        local function nav_up()
            if fp.cwd ~= "" then
                fp.cwd     = fp.cwd:match("^(.*)/[^/]+$") or ""
                fp.entries = scan_dir_entries(fp.cwd)
                fp.scroll  = 0
            end
        end

        if ev.type == "key_down" then
            local k = ev.key
            if k == "escape" then
                self.file_picker = nil
            elseif k == "return" or k == "kpenter" then
                self:_commit_file_picker()
            elseif k == "backspace" then
                nav_up()
            end
            return true
        elseif ev.type == "pointer_down" then
            -- OK button (in file field bar)
            if Widgets.hit(ex, ey, px + FP_W - 44, input_y + 2, 40, FP_ROW_H - 4) then
                self:_commit_file_picker(); return true
            end
            -- Open button (bottom bar)
            if Widgets.hit(ex, ey, px + FP_W - 132, bot_y + 3, 62, 20) then
                if fp.path_str ~= "" then self:_commit_file_picker() end
                return true
            end
            -- Cancel button
            if Widgets.hit(ex, ey, px + FP_W - 66, bot_y + 3, 62, 20) then
                self.file_picker = nil; return true
            end
            -- Directory listing clicks
            if Widgets.hit(ex, ey, px + 2, list_y, FP_W - 16, list_h) then
                local all_entries = {}
                if fp.cwd ~= "" then
                    table.insert(all_entries, { name="..", is_dir=true, path=".." })
                end
                for _, e in ipairs(fp.entries) do table.insert(all_entries, e) end
                local cy = list_y - fp.scroll
                local now = love.timer.getTime()
                for _, entry in ipairs(all_entries) do
                    if Widgets.hit(ex, ey, px + 2, cy, FP_W - 16, FP_ROW_H) then
                        if entry.is_dir then
                            if entry.path == ".." then
                                nav_up()
                            else
                                fp.cwd     = entry.path
                                fp.entries = scan_dir_entries(fp.cwd)
                                fp.scroll  = 0
                            end
                            fp._last_click_path = nil
                        else
                            -- Single click: select; double-click: select + commit
                            local is_dbl = fp._last_click_path == entry.path
                                       and fp._last_click_time
                                       and (now - fp._last_click_time) < 0.4
                            fp.path_str = entry.path
                            fp._last_click_path = entry.path
                            fp._last_click_time = now
                            if is_dbl then
                                self:_commit_file_picker()
                            end
                        end
                        return true
                    end
                    cy = cy + FP_ROW_H
                end
                return true
            end
            -- Click outside panel: cancel
            if not Widgets.hit(ex, ey, px, py, FP_W, FP_H) then
                self.file_picker = nil
            end
            return true
        elseif ev.type == "wheel" then
            local n_all = #fp.entries + (fp.cwd ~= "" and 1 or 0)
            local total_h = n_all * FP_ROW_H
            fp.scroll = math.max(0, math.min(math.max(0, total_h - list_h),
                                             fp.scroll - ev.dy * FP_ROW_H * 3))
            return true
        end
        return true
    end

    -- Preset picker eats all input when open
    if self.preset_picker then
        local pp = self.preset_picker
        local px = rect.x + math.floor((rect.w - PP_W) * 0.5)
        local py = rect.y + math.floor((rect.h - PP_H) * 0.5)
        local bot_y = py + PP_H - 26

        local function revert_params()
            local node = DAG.get_nodes()[pp.node_id]
            if node and pp.saved_params then
                for k, v in pairs(pp.saved_params) do
                    DAG.set_param(pp.node_id, k, v)
                    if node.params then node.params[k] = v end
                end
            end
        end

        if ev.type == "text" then
            if pp.saving then
                pp.save_name = pp.save_name .. ev.text
            else
                pp.filter = pp.filter .. ev.text
                pp.scroll = 0
            end
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "escape" then
                if not pp.saving then revert_params() end
                self.preset_picker = nil
            elseif k == "backspace" then
                if pp.saving then
                    pp.save_name = pp.save_name:sub(1, #pp.save_name - 1)
                else
                    pp.filter = pp.filter:sub(1, #pp.filter - 1)
                    pp.scroll = 0
                end
            elseif k == "return" or k == "kpenter" then
                if pp.saving then
                    if pp.save_name ~= "" then
                        local save_node = DAG.get_nodes()[pp.node_id]
                        if save_node and save_node.def and pp.save_name ~= "" then
                            local _ppath = save_node.def._path or ""
                            local _pparams = save_node.params or {}
                            local _ok_s, _err_s = pcall(Preset.save, _ppath, pp.save_name, _pparams)
                            if not _ok_s then
                                print("[PatchGraph] preset save failed: " .. tostring(_err_s))
                            end
                            self.preset_picker = nil
                        end
                    end
                end
            end
            return true
        elseif ev.type == "pointer_down" then
            if pp.saving then
                -- Save button
                local input_y = py + 30
                if Widgets.hit(ex, ey, px + PP_W - 44, input_y + 2, 40, PP_ROW_H - 4) then
                    if pp.save_name ~= "" then
                        local save_node = DAG.get_nodes()[pp.node_id]
                        if save_node and save_node.def and pp.save_name ~= "" then
                            local _ppath = save_node.def._path or ""
                            local _pparams = save_node.params or {}
                            local _ok_s, _err_s = pcall(Preset.save, _ppath, pp.save_name, _pparams)
                            if not _ok_s then
                                print("[PatchGraph] preset save failed: " .. tostring(_err_s))
                            end
                            self.preset_picker = nil
                        end
                    end
                    return true
                end
                -- Cancel button
                if Widgets.hit(ex, ey, px + PP_W - 66, bot_y + 3, 62, 20) then
                    self.preset_picker = nil
                    return true
                end
            else
                -- Load button
                if Widgets.hit(ex, ey, px + PP_W - 132, bot_y + 3, 62, 20) then
                    if pp.selected then self.preset_picker = nil end
                    return true
                end
                -- Cancel button
                if Widgets.hit(ex, ey, px + PP_W - 66, bot_y + 3, 62, 20) then
                    revert_params()
                    self.preset_picker = nil
                    return true
                end

                -- Preset list clicks
                local input_y = py + 26
                local list_y  = input_y + PP_ROW_H + 4
                local list_h  = bot_y - list_y - 2
                if Widgets.hit(ex, ey, px + 2, list_y, PP_W - 16, list_h) then
                    local filter_lc = pp.filter:lower()
                    local factory_entries, user_entries = {}, {}
                    for _, entry in ipairs(pp.presets) do
                        local name_lc = entry.name:lower()
                        if filter_lc == "" or name_lc:find(filter_lc, 1, true) then
                            if entry.factory then
                                factory_entries[#factory_entries + 1] = entry
                            else
                                user_entries[#user_entries + 1] = entry
                            end
                        end
                    end
                    local cy = list_y - pp.scroll
                    local now = love.timer.getTime()
                    local function check_section(entries)
                        cy = cy + PP_ROW_H  -- skip header row
                        for _, entry in ipairs(entries) do
                            if Widgets.hit(ex, ey, px + 2, cy, PP_W - 16, PP_ROW_H) then
                                local is_dbl = pp.selected == entry.path
                                           and pp._last_click_time
                                           and (now - pp._last_click_time) < 0.4
                                pp.selected = entry.path
                                pp._last_click_time = now
                                local ok, data = pcall(Preset.load, entry.path)
                                if ok and data then
                                    Preset.apply(pp.node_id, data)
                                end
                                if is_dbl then
                                    self.preset_picker = nil
                                end
                                return true
                            end
                            cy = cy + PP_ROW_H
                        end
                        return false
                    end
                    if #factory_entries > 0 then check_section(factory_entries) end
                    if #user_entries > 0 then check_section(user_entries) end
                    return true
                end
            end
            -- Click outside panel: cancel (revert if loading)
            if not Widgets.hit(ex, ey, px, py, PP_W, PP_H) then
                if not pp.saving then revert_params() end
                self.preset_picker = nil
            end
            return true
        elseif ev.type == "wheel" then
            if not pp.saving then
                local filter_lc = pp.filter:lower()
                local count = 0
                for _, entry in ipairs(pp.presets) do
                    local name_lc = entry.name:lower()
                    if filter_lc == "" or name_lc:find(filter_lc, 1, true) then
                        count = count + 1
                    end
                end
                local input_y = py + 26
                local list_y  = input_y + PP_ROW_H + 4
                local list_h  = bot_y - list_y - 2
                local total_h = count * PP_ROW_H
                pp.scroll = math.max(0, math.min(math.max(0, total_h - list_h),
                                                 pp.scroll - ev.dy * PP_ROW_H * 3))
            end
            return true
        end
        return true
    end

    -- Context menu eats all clicks
    if self.ctx then
        if ev.type == "pointer_down" then
            local ctx = self.ctx
            for i, item in ipairs(ctx.items) do
                local iy = ctx.y + 2 + (i - 1) * CTX_ROW_H
                if Widgets.hit(ex, ey, ctx.x, iy, CTX_W, CTX_ROW_H) then
                    item.fn()
                    self.ctx = nil
                    return true
                end
            end
            self.ctx = nil  -- clicked outside: close
            return true
        end
        return true
    end

    -- Param editor panel: eats input and provides slider + stepper buttons
    if self.edit_param then
        local ep   = self.edit_param
        local node = DAG.get_nodes()[ep.node_id]
        local p    = node and node.def and node.def.params[ep.param_idx]

        local function commit_ep()
            local v = tonumber(ep.value_str)
            if v and p then
                v = math.max(p.min, math.min(p.max, v))
                if p.type == "int" or p.type == "bool" then
                    v = math.floor(v + 0.5)
                end
                ep.value_str = string.format("%g", v)
                DAG.set_param(ep.node_id, p.id, v)
                local nd = DAG.get_nodes()[ep.node_id]
                if nd then nd.params[p.id] = v end
            end
        end

        local function step_ep(delta)
            local v = (tonumber(ep.value_str) or 0) + delta
            if p then v = math.max(p.min, math.min(p.max, v)) end
            ep.value_str = string.format("%g", v)
            commit_ep()
        end

        if ev.type == "text" then
            if not ep.typing then ep.value_str = ""; ep.typing = true end
            local ch = ev.text
            if ch:match("[%d%.%-]") then ep.value_str = ep.value_str .. ch end
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "backspace" then
                ep.typing = true
                ep.value_str = ep.value_str:sub(1, #ep.value_str - 1)
            elseif k == "return" or k == "kpenter" then
                commit_ep(); self.edit_param = nil
            elseif k == "escape" then
                self.edit_param = nil
            elseif k == "up" then
                step_ep(ep.fine_step or ((p and (p.max-p.min)/100 or 1)))
            elseif k == "down" then
                step_ep(-(ep.fine_step or ((p and (p.max-p.min)/100 or 1))))
            end
            return true
        elseif ev.type == "pointer_down" then
            if not p then self.edit_param = nil; return false end

            local px2, py2 = ep.px, ep.py

            -- × close button
            if Widgets.hit(ex, ey, px2 + PE_W - 20, py2 + 2, 16, 14) then
                commit_ep(); self.edit_param = nil; return true
            end

            -- Title bar drag
            if Widgets.hit(ex, ey, px2, py2, PE_W - 20, PE_HDR_H) then
                ep.dragging = true
                ep.drag_ox  = ex - px2
                ep.drag_oy  = ey - py2
                return true
            end

            -- Value field: click to enter text
            local val_y2 = py2 + PE_HDR_H + 4
            if Widgets.hit(ex, ey, px2 + 8, val_y2, PE_W - 16, 22) then
                ep.typing    = true
                ep.value_str = string.format("%g", tonumber(ep.value_str) or 0)
                return true
            end

            -- Slider interaction
            local sl_x, sl_y = px2 + 8, py2 + PE_HDR_H + 26
            local sl_w, sl_h = PE_W - 16, 16
            if Widgets.hit(ex, ey, sl_x - sl_h, sl_y, sl_w + sl_h * 2, sl_h) then
                local t = math.max(0, math.min(1, (ex - sl_x) / sl_w))
                local v = p.min + t * (p.max - p.min)
                ep.value_str = string.format("%g", v)
                ep.slider_drag = true
                ep.typing = false
                commit_ep()
                return true
            end

            -- Stepper buttons
            local fine   = ep.fine_step or ((p.max - p.min) / 100)
            local coarse = fine * 10
            local btn_y2 = py2 + PE_H - 26
            local btn_w2 = math.floor((PE_W - 10) / 4) - 2
            local btn_h2 = 22
            if Widgets.hit(ex, ey, px2 + 4,               btn_y2, btn_w2, btn_h2) then step_ep(-coarse); return true end
            if Widgets.hit(ex, ey, px2 + 4 + (btn_w2+2),  btn_y2, btn_w2, btn_h2) then step_ep(-fine);   return true end
            if Widgets.hit(ex, ey, px2 + 4 + (btn_w2+2)*2,btn_y2, btn_w2, btn_h2) then step_ep(fine);    return true end
            if Widgets.hit(ex, ey, px2 + 4 + (btn_w2+2)*3,btn_y2, btn_w2, btn_h2) then step_ep(coarse);  return true end

            -- Click inside panel body: absorb
            if Widgets.hit(ex, ey, px2, py2, PE_W, PE_H) then
                return true
            end

            -- Click outside: commit and close
            commit_ep(); self.edit_param = nil
            -- Fall through
        elseif ev.type == "pointer_move" then
            if ep.dragging then
                local sw2, sh2 = love.graphics.getDimensions()
                ep.px = math.max(4, math.min(sw2 - PE_W - 4, ex - ep.drag_ox))
                ep.py = math.max(4, math.min(sh2 - PE_H - 4, ey - ep.drag_oy))
                return true
            elseif ep.slider_drag then
                local sl_x = ep.px + 8
                local sl_w = PE_W - 16
                local t = math.max(0, math.min(1, (ex - sl_x) / sl_w))
                local v = p.min + t * (p.max - p.min)
                ep.value_str = string.format("%g", v)
                ep.typing = false
                commit_ep()
                return true
            end
        elseif ev.type == "pointer_up" then
            ep.slider_drag = false
            ep.dragging    = false
        end
    end

    -- Browser panel (only when rect is valid)
    if self.browser_open and rect then
        local bx = rect.x + graph_rect.w
        if Widgets.hit(ex, ey, bx, rect.y, BROWSER_W, rect.h) then
            if ev.type == "pointer_down" then
                -- Find clicked plugin
                local CATS = { "generators", "effects", "control", "abstractions" }
                local row_h = 20
                local cy = rect.y + 24 - self.browser_scroll
                for _, cat in ipairs(CATS) do
                    local paths = self.browser_plugins and self.browser_plugins[cat] or {}
                    if #paths > 0 then
                        cy = cy + row_h  -- category header
                        for _, path in ipairs(paths) do
                            if Widgets.hit(ex, ey, bx, cy, BROWSER_W, row_h) then
                                self:_spawn_machine(path, graph_rect)
                                return true
                            end
                            cy = cy + row_h
                        end
                    end
                end
            elseif ev.type == "wheel" then
                self.browser_scroll = math.max(0, self.browser_scroll - ev.dy * 20)
            end
            return true
        end
    end

    -- Toolbar "+" button
    if ev.type == "pointer_down" then
        local bw, bh = 28, 22
        local bx = rect.x + 6
        local by = rect.y + rect.h - bh - 4
        if Widgets.hit(ex, ey, bx, by, bw, bh) then
            self.browser_open = not self.browser_open
            if self.browser_open then
                self.browser_plugins = Discovery.scan()
            end
            return true
        end
    end

    -- Outside graph area (keyboard events have no x/y, skip bounds check for them)
    local is_pointer_ev = (ev.type == "pointer_down" or ev.type == "pointer_up"
                        or ev.type == "pointer_move" or ev.type == "wheel")
    if rect and is_pointer_ev and not Widgets.hit(ex, ey, graph_rect.x, graph_rect.y, graph_rect.w, graph_rect.h) then
        if ev.type == "pointer_down" then
            self.focused = false
            self.edit_param = nil
        end
        return false
    end
    if rect and is_pointer_ev then self.focused = true end

    local nodes = DAG.get_nodes()
    local edges = DAG.get_edges()

    if ev.type == "pointer_down" then
        local wx, wy = self:s2w(ex, ey)
        local button  = ev.button or 1

        -- Right-click: context menus
        if button == 2 then
            -- Check wire hit first
            local ei = hit_wire(edges, nodes, wx, wy, self.zoom, self.offset_x, self.offset_y)
            if ei then
                self:_open_edge_ctx(ei, ex, ey)
                return true
            end
            -- Then node (top-most first)
            for i = #self.node_order, 1, -1 do
                local id = self.node_order[i]
                local node = nodes[id]
                if node and hit_node(node, wx, wy) then
                    self:_open_node_ctx(id, ex, ey)
                    return true
                end
            end
            -- Right-click on background: open background context menu
            self:_open_bg_ctx(ex, ey, wx, wy)
            return true
        end

        -- Left-click: outlet pin drag to start wire (top-most first)
        for i = #self.node_order, 1, -1 do
            local id = self.node_order[i]
            local node = nodes[id]
            if node and id ~= DAG.master_id() then
                local pi, pin = hit_outlet(node, wx, wy)
                if pi then
                    local wx2, wy2 = outlet_pos(node, pi, #(node.def.outlets or {}))
                    self.wire_from = {
                        node_id = id,
                        pin_id  = pin.id,
                        kind    = pin.kind,
                        wx = wx2, wy = wy2,
                    }
                    self.wire_mx = wx
                    self.wire_my = wy
                    self.drag_node = nil
                    return true
                end
            end
        end

        -- Left-click: delete (×) button on node header (top-most first)
        for i = #self.node_order, 1, -1 do
            local id = self.node_order[i]
            local node = nodes[id]
            if node and id ~= DAG.master_id() and hit_header(node, wx, wy) then
                -- Check × button hit (right 20px of header)
                if wx >= node.x + node_width(node.def) - 20 then
                    self:_delete_node(id)
                    return true
                end
            end
        end

        -- Left-click: custom GUI panel event routing (top-most first)
        for i = #self.node_order, 1, -1 do
            local id2 = self.node_order[i]
            local node2 = nodes[id2]
            if node2 and node2.def and node2.def.gui then
                local nw2    = node_width(node2.def)
                local gui_h2 = node2.def.gui.height
                local bx = node2.x
                local by = node2.y + HDR_H
                if wx >= bx and wx < bx + nw2 and wy >= by and wy < by + gui_h2 then
                    bring_to_front(self.node_order, id2)
                    -- Pointer is in the gui panel area
                    if node2.def.gui.on_event then
                        local gui_state = self.node_gui_state[id2] or {}
                        self.node_gui_state[id2] = gui_state
                        local panel_sx2 = node2.x * self.zoom + self.offset_x
                        local panel_sy2 = (node2.y + HDR_H) * self.zoom + self.offset_y
                        local panel_sw2 = nw2 * self.zoom
                        local panel_sh2 = gui_h2 * self.zoom
                        local rel_x = (wx - node2.x) * self.zoom
                        local rel_y = (wy - node2.y - HDR_H) * self.zoom
                        local gev = { type = ev.type, x = rel_x, y = rel_y,
                                      button = ev.button, key = ev.key, dy = ev.dy }
                        local mx3, my3 = love.mouse.getPosition()
                        local gctx = build_gui_ctx(panel_sx2, panel_sy2, panel_sw2, panel_sh2, self.zoom, mx3, my3)
                        local ok3, consumed = pcall(node2.def.gui.on_event, gctx, gui_state, gev)
                        if ok3 and consumed then return true end
                    end
                    -- Even without on_event, absorb clicks in the gui area
                    -- so they don't fall through to param editing
                    return true
                end
            end
        end

        -- Left-click: param row -> start editing (top-most first)
        for i = #self.node_order, 1, -1 do
            local id = self.node_order[i]
            local node = nodes[id]
            if node then
                local pi = hit_param(node, wx, wy)
                if pi then
                    bring_to_front(self.node_order, id)
                    local p   = node.def.params[pi]
                    local val = node.params and node.params[p.id]
                    if val == nil then val = p.default end
                    if p.type == "file" then
                        self:_open_file_picker(id, pi, val)
                    else
                        local fine = (p.max - p.min) / 100
                        if p.type == "int" or p.type == "bool" then fine = 1 end
                        -- Initial position: right of the node, clamped to screen
                        local sw0, sh0 = love.graphics.getDimensions()
                        local init_px = math.max(4, math.min(sw0 - PE_W - 4, ex + 12))
                        local init_py = math.max(4, math.min(sh0 - PE_H - 4, ey - PE_HDR_H / 2))
                        self.edit_param = {
                            node_id   = id,
                            param_idx = pi,
                            value_str = string.format("%g", val),
                            fine_step = fine,
                            typing    = false,
                            slider_drag = false,
                            px        = init_px,
                            py        = init_py,
                            dragging  = false,
                            drag_ox   = 0,
                            drag_oy   = 0,
                        }
                    end
                    return true
                end
            end
        end

        -- Left-click: node body -> drag (top-most first)
        for i = #self.node_order, 1, -1 do
            local id = self.node_order[i]
            local node = nodes[id]
            if node and hit_node(node, wx, wy) then
                bring_to_front(self.node_order, id)
                self.selected  = id
                self.drag_node = id
                self.drag_ox   = wx - node.x
                self.drag_oy   = wy - node.y
                self.panning   = false
                return true
            end
        end

        -- Left-click: empty space -> pan
        self.selected  = nil
        self.drag_node = nil
        self.panning   = true
        self.pan_sx    = ex
        self.pan_sy    = ey
        self.pan_ox    = self.offset_x
        self.pan_oy    = self.offset_y
        return true

    elseif ev.type == "pointer_move" then
        local wx, wy = self:s2w(ex, ey)

        -- Update hover state
        self.hov_node = nil
        self.hov_pin  = nil
        self.hov_edge = nil

        -- Check pin hover (top-most first)
        local found_pin = false
        for i = #self.node_order, 1, -1 do
            local id = self.node_order[i]
            local node = nodes[id]
            if node then
                local pi, pin = hit_outlet(node, wx, wy)
                if pi then
                    self.hov_pin = { node_id=id, is_inlet=false, pin_id=pin.id }
                    found_pin = true; break
                end
                pi, pin = hit_inlet(node, wx, wy)
                if pi then
                    self.hov_pin = { node_id=id, is_inlet=true, pin_id=pin.id }
                    found_pin = true; break
                end
            end
        end

        if not found_pin then
            -- Check wire hover
            local ei = hit_wire(edges, nodes, wx, wy, self.zoom, self.offset_x, self.offset_y)
            if ei then
                self.hov_edge = ei
            else
                -- Check node hover (top-most first)
                for i = #self.node_order, 1, -1 do
                    local id = self.node_order[i]
                    local node = nodes[id]
                    if node and hit_node(node, wx, wy) then
                        self.hov_node = id; break
                    end
                end
            end
        end

        -- Update wire drag endpoint
        if self.wire_from then
            self.wire_mx = wx
            self.wire_my = wy
            return true
        end

        -- Drag node
        if self.drag_node then
            local node = nodes[self.drag_node]
            if node then
                DAG.set_position(self.drag_node, wx - self.drag_ox, wy - self.drag_oy)
            end
            return true
        end

        -- Pan
        if self.panning then
            self.offset_x = self.pan_ox + (ex - self.pan_sx)
            self.offset_y = self.pan_oy + (ey - self.pan_sy)
            return true
        end

        return false

    elseif ev.type == "pointer_up" then
        -- Complete wire connection
        if self.wire_from then
            local wx, wy = self:s2w(ex, ey)
            local wf = self.wire_from
            self.wire_from = nil

            for i = #self.node_order, 1, -1 do
                local id = self.node_order[i]
                local node = nodes[id]
                if node then
                    local pi, pin = hit_inlet(node, wx, wy)
                    if pi and id ~= wf.node_id then
                        -- Attempt connection
                        local ok, err = pcall(DAG.add_edge,
                            wf.node_id, wf.pin_id, id, pin.id)
                        if ok then
                            if self.on_add_edge then
                                self.on_add_edge(wf.node_id, wf.pin_id, id, pin.id)
                            end
                        else
                            print("[PatchGraph] edge error: " .. tostring(err))
                        end
                        break
                    end
                end
            end
            return true
        end

        self.drag_node = nil
        self.panning   = false
        return false

    elseif ev.type == "wheel" then
        local factor = ev.dy > 0 and 1.12 or (1 / 1.12)
        local wx, wy = self:s2w(ex, ey)
        self.zoom     = math.max(0.15, math.min(4.0, self.zoom * factor))
        self.offset_x = ex - wx * self.zoom
        self.offset_y = ey - wy * self.zoom
        return true

    elseif ev.type == "pinch" then
        local wx, wy = self:s2w(ev.cx, ev.cy)
        self.zoom     = math.max(0.15, math.min(4.0, self.zoom * ev.scale))
        self.offset_x = ev.cx - wx * self.zoom
        self.offset_y = ev.cy - wy * self.zoom
        return true

    elseif ev.type == "key_down" and self.focused then
        local k = ev.key
        if k == "delete" or k == "backspace" then
            if self.selected and self.selected ~= DAG.master_id() then
                self:_delete_node(self.selected)
                return true   -- only consume if we actually deleted something
            end
            return false  -- let other views handle delete when nothing selected
        elseif k == "a" then
            self.browser_open = not self.browser_open
            if self.browser_open then
                self.browser_plugins = Discovery.scan()
            end
            return true
        elseif k == "escape" then
            self.browser_open = false
            self.ctx = nil
            self.edit_param = nil
            return true
        end
    end

    return false
end

-- -------------------------
-- Preset picker
-- -------------------------

function PatchGraph:_open_preset_picker(node_id, saving)
    local node = DAG.get_nodes()[node_id]
    if not node or not node.def then return end
    local presets = Preset.list(node.def._path or "")
    -- Save current params so we can revert on cancel
    local saved = {}
    if node.params then
        for k, v in pairs(node.params) do saved[k] = v end
    end
    self.preset_picker = {
        node_id      = node_id,
        plugin_path  = node.def._path or "",
        filter       = "",
        scroll       = 0,
        presets      = presets,
        selected     = nil,
        saved_params = saved,
        saving       = saving,
        save_name    = "",
    }
    self.ctx = nil
end

function PatchGraph:_draw_preset_picker(rect)
    local pp = self.preset_picker
    local px = rect.x + math.floor((rect.w - PP_W) * 0.5)
    local py = rect.y + math.floor((rect.h - PP_H) * 0.5)

    -- Dim overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)

    -- Panel
    Widgets.rect(px, py, PP_W, PP_H, Theme.bg_panel, Theme.border_focus, 4)

    -- Title
    local _slug = (pp.plugin_path or ""):match("([^/]+)%.lua$") or ""
    local title = pp.saving and ("SAVE  \xe2\x80\x94  " .. _slug) or ("LOAD  \xe2\x80\x94  " .. _slug)
    Widgets.label(title, px + 4, py + 2, PP_W - 8, 20,
                  Theme.accent, Theme.font_small, "center")
    Theme.set(Theme.border)
    love.graphics.line(px, py + 22, px + PP_W, py + 22)

    local bot_y = py + PP_H - 26
    Theme.set(Theme.border)
    love.graphics.line(px, bot_y, px + PP_W, bot_y)

    if pp.saving then
        -- Save name input
        local input_y = py + 30
        Widgets.label("Name:", px + 4, input_y, 38, PP_ROW_H, Theme.text_dim, Theme.font_small)
        Theme.set({0.08, 0.08, 0.11, 1})
        love.graphics.rectangle("fill", px + 44, input_y + 2, PP_W - 92, PP_ROW_H - 4, 2, 2)
        Theme.set(Theme.border_focus)
        love.graphics.rectangle("line", px + 44, input_y + 2, PP_W - 92, PP_ROW_H - 4, 2, 2)
        Widgets.label(pp.save_name .. "_", px + 46, input_y, PP_W - 94, PP_ROW_H,
                      Theme.text, Theme.font_small)

        -- Save button
        Widgets.button("Save", px + PP_W - 44, input_y + 2, 40, PP_ROW_H - 4, false, false, Theme.font_small)

        -- Cancel button
        Widgets.button("Cancel", px + PP_W - 66, bot_y + 3, 62, 20, false, false, Theme.font_small)
    else
        -- Filter input
        local input_y = py + 26
        Widgets.label("Filter:", px + 4, input_y, 42, PP_ROW_H, Theme.text_dim, Theme.font_small)
        Theme.set({0.08, 0.08, 0.11, 1})
        love.graphics.rectangle("fill", px + 48, input_y + 2, PP_W - 56, PP_ROW_H - 4, 2, 2)
        Theme.set(Theme.border_focus)
        love.graphics.rectangle("line", px + 48, input_y + 2, PP_W - 56, PP_ROW_H - 4, 2, 2)
        Widgets.label(pp.filter .. "_", px + 50, input_y, PP_W - 58, PP_ROW_H,
                      Theme.text, Theme.font_small)

        -- Preset list
        local list_y = input_y + PP_ROW_H + 4
        local list_h = bot_y - list_y - 2
        love.graphics.setScissor(px, list_y, PP_W - 12, list_h)

        local filter_lc = pp.filter:lower()

        -- Build display list with section headers
        local factory_entries = {}
        local user_entries    = {}
        for _, entry in ipairs(pp.presets) do
            local name_lc = entry.name:lower()
            if filter_lc == "" or name_lc:find(filter_lc, 1, true) then
                if entry.factory then
                    factory_entries[#factory_entries + 1] = entry
                else
                    user_entries[#user_entries + 1] = entry
                end
            end
        end

        local cy = list_y - pp.scroll
        local function draw_section(label_str, entries)
            -- Section header
            if cy + PP_ROW_H >= list_y and cy < list_y + list_h then
                Theme.set({0.12, 0.14, 0.18, 1})
                love.graphics.rectangle("fill", px + 2, cy, PP_W - 16, PP_ROW_H)
                Widgets.label(label_str, px + 6, cy, PP_W - 20, PP_ROW_H,
                              Theme.text_dim, Theme.font_small)
            end
            cy = cy + PP_ROW_H
            for _, entry in ipairs(entries) do
                if cy + PP_ROW_H >= list_y and cy < list_y + list_h then
                    local is_sel = (pp.selected == entry.path)
                    if is_sel then
                        Theme.set({0.20, 0.35, 0.55, 1})
                        love.graphics.rectangle("fill", px + 2, cy, PP_W - 16, PP_ROW_H)
                    end
                    local hov = Widgets.hit(love.mouse.getX(), love.mouse.getY(),
                                            px + 2, cy, PP_W - 16, PP_ROW_H)
                    if hov and not is_sel then
                        Theme.set(Theme.btn_hover)
                        love.graphics.rectangle("fill", px + 2, cy, PP_W - 16, PP_ROW_H)
                    end
                    Widgets.label(entry.name, px + 14, cy, PP_W - 28, PP_ROW_H,
                                  is_sel and Theme.text or Theme.text_dim, Theme.font_small)
                end
                cy = cy + PP_ROW_H
            end
        end

        if #factory_entries > 0 then
            draw_section("[Factory]", factory_entries)
        end
        if #user_entries > 0 then
            draw_section("[User]", user_entries)
        end
        if #factory_entries == 0 and #user_entries == 0 then
            Widgets.label("No presets found.", px + 8, list_y + 8,
                          PP_W - 16, PP_ROW_H, Theme.text_dim, Theme.font_small)
        end

        love.graphics.setScissor()

        -- Scrollbar
        local n_headers = (#factory_entries > 0 and 1 or 0) + (#user_entries > 0 and 1 or 0)
        local total_rows = #factory_entries + #user_entries + n_headers
        local total_h = total_rows * PP_ROW_H
        if total_h > list_h then
            Widgets.scrollbar(px + PP_W - 12, list_y, 10, list_h, pp.scroll, total_h, list_h)
        end

        local can_load = pp.selected ~= nil
        Widgets.button("Load", px + PP_W - 132, bot_y + 3, 62, 20, can_load, false, Theme.font_small)
        Widgets.button("Cancel", px + PP_W - 66, bot_y + 3, 62, 20, false, false, Theme.font_small)
    end
end

return PatchGraph
