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

local function node_height(def)
    if not def then return HDR_H end
    local n = def.params and #def.params or 0
    return HDR_H + n * PARAM_H + 6
end

-- Pin world positions for a node
local function inlet_pos(node, pin_idx, n_inlets)
    local nh = node_height(node.def)
    return node.x, node.y + HDR_H + (pin_idx / (n_inlets + 1)) * (nh - HDR_H)
end

local function outlet_pos(node, pin_idx, n_outlets)
    local nh = node_height(node.def)
    return node.x + NODE_W, node.y + HDR_H + (pin_idx / (n_outlets + 1)) * (nh - HDR_H)
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
    return wx >= node.x and wx < node.x + NODE_W
       and wy >= node.y and wy < node.y + nh
end

-- Hit-test node header only
local function hit_header(node, wx, wy)
    return wx >= node.x and wx < node.x + NODE_W
       and wy >= node.y and wy < node.y + HDR_H
end

-- Hit-test a specific param row; returns param index or nil
local function hit_param(node, wx, wy)
    if not node.def or not node.def.params then return nil end
    local params = node.def.params
    for i = 1, #params do
        local py = node.y + HDR_H + (i - 1) * PARAM_H
        if wx >= node.x and wx < node.x + NODE_W
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

    -- Nodes
    for id, node in pairs(nodes) do
        self:_draw_node(id, node, z, ox, oy)
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

function PatchGraph:_draw_node(id, node, z, ox, oy)
    local nx, ny = node.x * z + ox, node.y * z + oy
    local nw     = NODE_W * z
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
    local name = is_master and "MASTER" or (node.def and node.def.name or id)
    Widgets.label(name, nx + 6, ny, nw - 28, hdr_h, Theme.text, Theme.font_small)

    -- Delete button in header (×) — only on non-master
    if not is_master and (is_sel or is_hov) then
        local bx = nx + nw - 20 * z
        local bw = 18 * z
        Theme.set({0.6, 0.2, 0.2, 0.8})
        love.graphics.rectangle("fill", bx, ny + 3 * z, bw, hdr_h - 6 * z, 3, 3)
        Theme.set(Theme.text)
        love.graphics.setFont(Theme.font_small)
        love.graphics.printf("×", bx, ny + (hdr_h - (Theme.font_small:getHeight())) * 0.5, bw, "center")
    end

    -- Params
    if node.def and node.def.params then
        for i, p in ipairs(node.def.params) do
            local py    = ny + hdr_h + (i - 1) * PARAM_H * z
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

    -- Value display
    local disp = ep.value_str .. (ep.typing and "_" or "")
    love.graphics.setColor(Theme.accent[1], Theme.accent[2], Theme.accent[3], 1)
    love.graphics.setFont(Theme.font_medium)
    love.graphics.printf(disp, px + 4, py + PE_HDR_H + 4, PE_W - 8, "center")

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

-- Scan for audio files in LÖVE save dir and source dir
local function scan_audio_files()
    local files = {}
    local exts  = { wav=true, ogg=true, mp3=true, flac=true }
    local function scan_dir(dir)
        local ok, items = pcall(love.filesystem.getDirectoryItems, dir)
        if not ok then return end
        for _, name in ipairs(items) do
            local ext = name:match("%.(%w+)$")
            if ext and exts[ext:lower()] then
                table.insert(files, (dir ~= "" and dir .. "/" or "") .. name)
            end
        end
    end
    scan_dir("")          -- save dir root
    scan_dir("samples")   -- common samples subfolder
    scan_dir("audio")
    scan_dir("sounds")
    -- Also source dir via love.filesystem (mounted automatically)
    return files
end

function PatchGraph:_open_file_picker(node_id, param_idx, current_val)
    local files = scan_audio_files()
    self.file_picker = {
        node_id   = node_id,
        param_idx = param_idx,
        path_str  = tostring(current_val or ""),
        files     = files,
        scroll    = 0,
    }
    self.edit_param = nil   -- close numeric editor if open
end

local FP_W, FP_H = 380, 280
local FP_ROW_H   = 22

function PatchGraph:_draw_file_picker(rect)
    local fp = self.file_picker
    -- Center the picker in the view
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

    -- Path input row
    local input_y = py + 26
    Widgets.label("Path:", px + 4, input_y, 34, FP_ROW_H, Theme.text_dim, Theme.font_small)
    -- Text field background
    Theme.set({0.08, 0.08, 0.11, 1})
    love.graphics.rectangle("fill", px + 40, input_y + 2, FP_W - 88, FP_ROW_H - 4, 2, 2)
    Theme.set(Theme.border_focus)
    love.graphics.rectangle("line", px + 40, input_y + 2, FP_W - 88, FP_ROW_H - 4, 2, 2)
    Widgets.label(fp.path_str .. "_", px + 42, input_y, FP_W - 90, FP_ROW_H,
                  Theme.text, Theme.font_small)
    -- OK button
    Widgets.button("OK", px + FP_W - 44, input_y + 2, 40, FP_ROW_H - 4, false, false, Theme.font_small)

    -- File list
    local list_y  = input_y + FP_ROW_H + 4
    local list_h  = FP_H - (list_y - py) - 28
    love.graphics.setScissor(px, list_y, FP_W - 12, list_h)

    if #fp.files == 0 then
        Widgets.label("No audio files found in save directory.", px + 8, list_y + 8,
                      FP_W - 16, FP_ROW_H, Theme.text_dim, Theme.font_small)
    else
        local cy = list_y - fp.scroll
        for _, path in ipairs(fp.files) do
            if cy + FP_ROW_H >= list_y and cy < list_y + list_h then
                local is_sel = (fp.path_str == path)
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
                -- Show just the filename, full path on hover
                local display = path:match("[^/]+$") or path
                Widgets.label(display, px + 6, cy, FP_W - 20, FP_ROW_H,
                              is_sel and Theme.text or Theme.text_dim, Theme.font_small)
                if hov then
                    Widgets.label(path, px + 6, cy + FP_ROW_H, FP_W - 20, FP_ROW_H,
                                  Theme.accent, Theme.font_small)
                end
            end
            cy = cy + FP_ROW_H
        end
    end
    love.graphics.setScissor()

    -- Scrollbar
    local total_h = #fp.files * FP_ROW_H
    if total_h > list_h then
        Widgets.scrollbar(px + FP_W - 12, list_y, 10, list_h, fp.scroll, total_h, list_h)
    end

    -- Cancel button at bottom
    local bot_y = py + FP_H - 26
    Theme.set(Theme.border)
    love.graphics.line(px, bot_y, px + FP_W, bot_y)
    Widgets.label("Tip: place .wav/.ogg files in the app save directory",
                  px + 4, bot_y + 2, FP_W - 90, 22, Theme.text_dim, Theme.font_small)
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
        local input_y = py + 26
        local list_y  = input_y + FP_ROW_H + 4
        local list_h  = FP_H - (list_y - py) - 28
        local bot_y   = py + FP_H - 26

        if ev.type == "text" then
            fp.path_str = fp.path_str .. ev.text
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "backspace" then
                fp.path_str = fp.path_str:sub(1, #fp.path_str - 1)
            elseif k == "return" or k == "kpenter" then
                self:_commit_file_picker()
            elseif k == "escape" then
                self.file_picker = nil
            elseif k == "up" then
                -- Navigate file list
                for i, path in ipairs(fp.files) do
                    if path == fp.path_str and i > 1 then
                        fp.path_str = fp.files[i - 1]; break
                    end
                end
            elseif k == "down" then
                for i, path in ipairs(fp.files) do
                    if path == fp.path_str and i < #fp.files then
                        fp.path_str = fp.files[i + 1]; break
                    end
                end
            end
            return true
        elseif ev.type == "pointer_down" then
            -- OK button
            if Widgets.hit(ex, ey, px + FP_W - 44, input_y + 2, 40, FP_ROW_H - 4) then
                self:_commit_file_picker(); return true
            end
            -- Cancel button
            if Widgets.hit(ex, ey, px + FP_W - 66, bot_y + 3, 62, 20) then
                self.file_picker = nil; return true
            end
            -- File list clicks
            if Widgets.hit(ex, ey, px + 2, list_y, FP_W - 16, list_h) then
                local cy = list_y - fp.scroll
                for _, path in ipairs(fp.files) do
                    if Widgets.hit(ex, ey, px + 2, cy, FP_W - 16, FP_ROW_H) then
                        fp.path_str = path
                        -- Double-click or single-click confirm
                        if self._fp_last_click == path then
                            self:_commit_file_picker()
                        end
                        self._fp_last_click = path
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
            local total_h = #fp.files * FP_ROW_H
            fp.scroll = math.max(0, math.min(math.max(0, total_h - list_h),
                                             fp.scroll - ev.dy * FP_ROW_H * 3))
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
            -- Then node
            for id, node in pairs(nodes) do
                if hit_node(node, wx, wy) then
                    self:_open_node_ctx(id, ex, ey)
                    return true
                end
            end
            -- Right-click on background: open background context menu
            self:_open_bg_ctx(ex, ey, wx, wy)
            return true
        end

        -- Left-click: outlet pin drag to start wire
        for id, node in pairs(nodes) do
            if id ~= DAG.master_id() then
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

        -- Left-click: delete (×) button on node header
        for id, node in pairs(nodes) do
            if id ~= DAG.master_id() and hit_header(node, wx, wy) then
                -- Check × button hit (right 20px of header)
                if wx >= node.x + NODE_W - 20 then
                    self:_delete_node(id)
                    return true
                end
            end
        end

        -- Left-click: param row -> start editing
        for id, node in pairs(nodes) do
            local pi = hit_param(node, wx, wy)
            if pi then
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

        -- Left-click: node header -> drag
        for id, node in pairs(nodes) do
            if hit_node(node, wx, wy) then
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

        -- Check pin hover
        local found_pin = false
        for id, node in pairs(nodes) do
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

        if not found_pin then
            -- Check wire hover
            local ei = hit_wire(edges, nodes, wx, wy, self.zoom, self.offset_x, self.offset_y)
            if ei then
                self.hov_edge = ei
            else
                -- Check node hover
                for id, node in pairs(nodes) do
                    if hit_node(node, wx, wy) then
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

            for id, node in pairs(nodes) do
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

return PatchGraph
