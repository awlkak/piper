-- Song Arranger View
--
-- Layout:
--   [Toolbar row 1]  [New Pat] [Dup Pat] [Del Pat]
--   [Toolbar row 2]  [Insert] [Append] [Remove] [Copy] [Paste] [◄] [►]
--   [Pattern list sidebar]  |  [Order timeline grid]
--
-- Pattern list (left):
--   All patterns in the song; click to select/rename.
--   Selected pattern is shown in the pattern editor.
--
-- Order timeline (right):
--   Columns = order positions (song slots).
--   Rows    = channels.
--   Each cell shows the machine assigned to that channel at that position.
--   Click a cell to assign the currently selected pattern + open machine picker.
--   Right-click a slot column header for slot operations.
--   Drag a slot column to reorder.
--
-- Keyboard (when focused):
--   Left/Right   = move selected slot
--   [ / ]        = previous / next pattern
--   Ins / I      = insert slot after selected
--   Del          = remove selected slot
--   Ctrl+C       = copy selected slot
--   Ctrl+V       = paste slot after selected
--   Ctrl+N       = new pattern
--   Ctrl+D       = duplicate selected pattern
--
-- Right-click a slot: "Assign selected pattern" to change what pattern plays in that slot

local Theme    = require("src.ui.theme")
local Widgets  = require("src.ui.widgets")
local Pattern  = require("src.sequencer.pattern")
local Registry = require("src.machine.registry")

local SongArranger = {}
SongArranger.__index = SongArranger

local TOOLBAR_ROW_H = 28
local TOOLBAR_H     = TOOLBAR_ROW_H * 2   -- two-row toolbar
local LIST_W        = 130   -- pattern list sidebar
local SLOT_W      = 72
local SLOT_H      = 26
local ORDER_HDR_H = 22
local CH_LABEL_W  = 44
local SCROLLBAR_H = 10

local PAT_COLORS = {
    {0.20, 0.40, 0.70, 1},
    {0.60, 0.22, 0.22, 1},
    {0.22, 0.52, 0.28, 1},
    {0.55, 0.38, 0.08, 1},
    {0.38, 0.18, 0.58, 1},
    {0.12, 0.48, 0.52, 1},
    {0.48, 0.48, 0.12, 1},
    {0.52, 0.20, 0.40, 1},
}

function SongArranger.new()
    return setmetatable({
        song           = nil,
        selected_pat   = nil,   -- selected pattern id (shown in editor)
        selected_slot  = nil,   -- selected order position (1-based)
        scroll_x       = 0,
        list_scroll    = 0,
        play_pos       = nil,
        focused        = false,
        -- Clipboard
        clipboard_slot = nil,   -- copy of {pattern_id, machine_map}
        -- Context menu
        ctx            = nil,
        -- Drag reorder
        drag_slot      = nil,
        drag_screen_x  = 0,
        -- Rename
        rename_pat     = nil,   -- pat id being renamed
        rename_str     = "",
        -- Machine picker (assign machine to channel)
        mach_pick      = nil,   -- { slot_i, ch, x, y, items }
        -- Callbacks
        on_select_pat  = nil,   -- fn(pat_id, pat) -- called when user picks a pattern
    }, SongArranger)
end

function SongArranger:set_song(song)
    self.song = song
    -- Auto-select first pattern
    if song then
        for id in pairs(song.patterns) do
            self.selected_pat = id
            break
        end
    end
end

function SongArranger:set_playhead(order_pos)
    self.play_pos = order_pos
end

function SongArranger:set_on_select(fn)
    self.on_select_pat = fn
end

-- -------------------------
-- Pattern operations
-- -------------------------

local function new_pat_id(song)
    local n = 1
    while song.patterns["pat" .. n] do n = n + 1 end
    return "pat" .. n
end

local pat_color_cache = {}   -- id -> color table (stable across frames)

local function pat_color(id)
    if not pat_color_cache[id] then
        local n = 0
        for c in id:gmatch(".") do n = n + string.byte(c) end
        pat_color_cache[id] = PAT_COLORS[(n % #PAT_COLORS) + 1]
    end
    return pat_color_cache[id]
end

function SongArranger:_new_pattern()
    local song = self.song
    if not song then return end
    local id  = new_pat_id(song)
    local pat = Pattern.new(id, 32, 8)
    pat.label = id
    song:add_pattern(pat)
    self.selected_pat = id
    if self.on_select_pat then self.on_select_pat(id, pat) end
end

function SongArranger:_duplicate_pattern()
    local song = self.song
    if not song or not self.selected_pat then return end
    local src = song.patterns[self.selected_pat]
    if not src then return end
    local id  = new_pat_id(song)
    -- Deep copy data
    local new_data = {}
    for k, v in pairs(src.data) do
        local cell = {}
        for ck, cv in pairs(v) do cell[ck] = cv end
        new_data[k] = cell
    end
    local pat = Pattern.new(id, src.rows, src.channels)
    pat.label = src.label .. "_copy"
    pat.data  = new_data
    song:add_pattern(pat)
    self.selected_pat = id
    if self.on_select_pat then self.on_select_pat(id, pat) end
end

function SongArranger:_delete_pattern()
    local song = self.song
    if not song or not self.selected_pat then return end
    local id = self.selected_pat
    song:remove_pattern(id)
    pat_color_cache[id] = nil
    -- Select another pattern
    self.selected_pat = nil
    for pid in pairs(song.patterns) do
        self.selected_pat = pid; break
    end
    if self.on_select_pat and self.selected_pat then
        self.on_select_pat(self.selected_pat, song.patterns[self.selected_pat])
    end
end

function SongArranger:_insert_slot()
    local song = self.song
    if not song or not self.selected_pat then return end
    local pos = (self.selected_slot or #song.order) + 1
    song:insert_order(pos, self.selected_pat, {})
    self.selected_slot = pos
end

function SongArranger:_append_slot()
    local song = self.song
    if not song or not self.selected_pat then return end
    song:append_order(self.selected_pat, {})
    self.selected_slot = #song.order
end

function SongArranger:_remove_slot()
    local song = self.song
    if not song or not self.selected_slot then return end
    song:remove_order(self.selected_slot)
    self.selected_slot = math.min(self.selected_slot, #song.order)
    if self.selected_slot == 0 then self.selected_slot = nil end
end

function SongArranger:_copy_slot()
    local song = self.song
    if not song or not self.selected_slot then return end
    local e = song.order[self.selected_slot]
    if not e then return end
    -- Deep copy machine_map
    local mm = {}
    for k, v in pairs(e.machine_map or {}) do mm[k] = v end
    self.clipboard_slot = { pattern_id = e.pattern_id, machine_map = mm }
end

function SongArranger:_paste_slot()
    local song = self.song
    if not song or not self.clipboard_slot then return end
    local pos = (self.selected_slot or #song.order) + 1
    -- Deep copy again so edits don't affect clipboard
    local mm = {}
    for k, v in pairs(self.clipboard_slot.machine_map) do mm[k] = v end
    song:insert_order(pos, self.clipboard_slot.pattern_id, mm)
    self.selected_slot = pos
end

function SongArranger:_move_slot(from, to)
    local song = self.song
    if not song then return end
    to = math.max(1, math.min(#song.order, to))
    if from == to then return end
    song:move_order(from, to)
    self.selected_slot = to
end

-- -------------------------
-- Drawing
-- -------------------------

function SongArranger:draw(rect)
    local song = self.song
    Theme.set(Theme.bg_panel)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)

    self:_draw_toolbar(rect)

    if not song then
        Widgets.label("No song loaded", rect.x, rect.y + rect.h * 0.5,
                      rect.w, 20, Theme.text_dim, Theme.font_medium, "center")
        return
    end

    local top = rect.y + TOOLBAR_H
    local list_rect  = { x=rect.x,            y=top, w=LIST_W,          h=rect.h - TOOLBAR_H }
    local order_rect = { x=rect.x + LIST_W,   y=top, w=rect.w - LIST_W, h=rect.h - TOOLBAR_H }

    -- Divider
    Theme.set(Theme.border)
    love.graphics.line(rect.x + LIST_W, top, rect.x + LIST_W, rect.y + rect.h)

    self:_draw_pattern_list(list_rect)
    self:_draw_order(order_rect)

    if self.ctx       then self:_draw_ctx()       end
    if self.mach_pick then self:_draw_mach_pick() end
end

function SongArranger:_draw_toolbar(rect)
    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, TOOLBAR_H)
    Theme.set(Theme.border)
    love.graphics.line(rect.x, rect.y + TOOLBAR_H, rect.x + rect.w, rect.y + TOOLBAR_H)
    -- Row divider
    love.graphics.line(rect.x, rect.y + TOOLBAR_ROW_H, rect.x + rect.w, rect.y + TOOLBAR_ROW_H)

    local bh = TOOLBAR_ROW_H - 6
    local bw = 64

    -- Row 1: Pattern operations
    local r1y = rect.y
    local x1  = rect.x + 4
    Widgets.label("PATTERNS", x1, r1y, 64, TOOLBAR_ROW_H, Theme.text_header, Theme.font_small, "left")
    x1 = x1 + 66
    Widgets.button("New",       x1, r1y + 3, bw, bh, false, false, Theme.font_small); x1 = x1 + bw + 3
    Widgets.button("Duplicate", x1, r1y + 3, bw, bh, false, false, Theme.font_small); x1 = x1 + bw + 3
    Widgets.button("Delete",    x1, r1y + 3, bw, bh, false, false, Theme.font_small)

    -- Row 2: Slot operations
    local r2y = rect.y + TOOLBAR_ROW_H
    local x2  = rect.x + 4
    Widgets.label("SLOTS", x2, r2y, 40, TOOLBAR_ROW_H, Theme.text_header, Theme.font_small, "left")
    x2 = x2 + 42
    Widgets.button("Insert",  x2, r2y + 3, bw, bh, false, false, Theme.font_small); x2 = x2 + bw + 3
    Widgets.button("Append",  x2, r2y + 3, bw, bh, false, false, Theme.font_small); x2 = x2 + bw + 3
    Widgets.button("Remove",  x2, r2y + 3, bw, bh, false, false, Theme.font_small); x2 = x2 + bw + 3
    local has_cb = self.clipboard_slot ~= nil
    Widgets.button("Copy",    x2, r2y + 3, bw - 8, bh, false, false, Theme.font_small); x2 = x2 + bw - 5
    Widgets.button("Paste",   x2, r2y + 3, bw - 8, bh, false, has_cb, Theme.font_small); x2 = x2 + bw - 5
    -- Nav arrows for slot selection
    Theme.set(Theme.border)
    love.graphics.line(x2 + 2, r2y + 4, x2 + 2, r2y + TOOLBAR_ROW_H - 4)
    x2 = x2 + 8
    Widgets.button("◄", x2, r2y + 3, 28, bh, false, false, Theme.font_small); x2 = x2 + 31
    Widgets.button("►", x2, r2y + 3, 28, bh, false, false, Theme.font_small)
end

function SongArranger:_draw_pattern_list(r)
    local song = self.song

    Theme.set(Theme.bg)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)

    Widgets.label("PATTERNS", r.x, r.y, r.w, 18, Theme.text_header, Theme.font_small, "center")
    Theme.set(Theme.border)
    love.graphics.line(r.x, r.y + 18, r.x + r.w, r.y + 18)

    local row_h = 22
    local cy    = r.y + 20 - self.list_scroll

    love.graphics.setScissor(r.x, r.y + 18, r.w, r.h - 18)

    -- Sort pattern ids for stable display
    local ids = {}
    for id in pairs(song.patterns) do table.insert(ids, id) end
    table.sort(ids)

    for _, id in ipairs(ids) do
        local pat = song.patterns[id]
        if cy + row_h >= r.y + 18 and cy < r.y + r.h then
            local is_sel = (id == self.selected_pat)
            -- Color swatch
            local col = pat_color(id)
            love.graphics.setColor(col[1], col[2], col[3], 1)
            love.graphics.rectangle("fill", r.x + 2, cy + 3, 6, row_h - 6)

            if is_sel then
                Theme.set({0.20, 0.22, 0.30, 1})
                love.graphics.rectangle("fill", r.x + 10, cy, r.w - 10, row_h)
                Theme.set(Theme.border_focus)
                love.graphics.rectangle("line", r.x + 10, cy, r.w - 10, row_h)
            end

            local name = (pat.label ~= "" and pat.label or id):sub(1, 10)
            if self.rename_pat == id then
                name = self.rename_str .. "_"
                Theme.set(Theme.accent)
            else
                Theme.set(is_sel and Theme.text or Theme.text_dim)
            end
            love.graphics.setFont(Theme.font_small)
            love.graphics.print(name, r.x + 12, cy + (row_h - Theme.font_small:getHeight()) * 0.5)

            -- Row count
            Widgets.label(tostring(pat.rows) .. "r",
                r.x + r.w - 28, cy, 26, row_h, Theme.text_dim, Theme.font_small, "right")
        end
        cy = cy + row_h
    end

    love.graphics.setScissor()

    -- Scroll hint
    local total = #ids * row_h
    if total > r.h - 18 then
        Widgets.scrollbar(r.x + r.w - SCROLLBAR_H, r.y + 18,
            SCROLLBAR_H, r.h - 18, self.list_scroll, total, r.h - 18)
    end
end

function SongArranger:_draw_order(r)
    local song = self.song
    if not song then return end

    -- Figure out channel count
    local n_ch = 1
    for _, entry in ipairs(song.order) do
        local pat = song.patterns[entry.pattern_id]
        if pat and pat.channels > n_ch then n_ch = pat.channels end
    end

    local view_x = r.x + CH_LABEL_W
    local view_w = r.w - CH_LABEL_W - SCROLLBAR_H
    self._last_view_w = view_w
    local hdr_y  = r.y
    local grid_y = r.y + ORDER_HDR_H
    local grid_h = r.h - ORDER_HDR_H - SCROLLBAR_H

    -- Background
    Theme.set(Theme.bg)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)

    love.graphics.setScissor(r.x, r.y, r.w, r.h)

    -- Channel labels
    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", r.x, grid_y, CH_LABEL_W, grid_h)
    for ch = 0, n_ch - 1 do
        local sy = grid_y + ch * SLOT_H
        if sy >= grid_y and sy < grid_y + grid_h then
            Widgets.label("Ch" .. (ch + 1), r.x, sy, CH_LABEL_W, SLOT_H,
                          Theme.text_dim, Theme.font_small, "center")
        end
    end

    -- Slot column headers + blocks
    love.graphics.setScissor(view_x, r.y, view_w, r.h)

    for i, entry in ipairs(song.order) do
        local sx = view_x + (i - 1) * SLOT_W - self.scroll_x
        if sx + SLOT_W < view_x or sx > view_x + view_w then goto continue end

        local pat = song.patterns[entry.pattern_id]
        local col = pat_color(entry.pattern_id)
        local is_sel  = (i == self.selected_slot)
        local is_play = (i == self.play_pos)

        -- Column header
        local hdr_bg = is_sel and {0.20, 0.22, 0.30, 1} or Theme.bg_header
        Theme.set(hdr_bg)
        love.graphics.rectangle("fill", sx, hdr_y, SLOT_W, ORDER_HDR_H)
        local num_c = is_play and Theme.accent or (is_sel and Theme.text or Theme.text_dim)
        local pat_lbl = pat and (pat.label ~= "" and pat.label or entry.pattern_id) or "?"
        Widgets.label(string.format("%02d %s", i, pat_lbl:sub(1,4)),
            sx + 2, hdr_y, SLOT_W - 4, ORDER_HDR_H, num_c, Theme.font_small)

        if is_sel then
            Theme.set(Theme.border_focus)
            love.graphics.rectangle("line", sx, hdr_y, SLOT_W, ORDER_HDR_H)
        end

        -- Channel cells
        for ch = 0, n_ch - 1 do
            local sy = grid_y + ch * SLOT_H
            if sy >= grid_y and sy < grid_y + grid_h then
                local mid = entry.machine_map and entry.machine_map[ch]
                if mid then
                    love.graphics.setColor(col[1], col[2], col[3], 0.75)
                    love.graphics.rectangle("fill", sx + 1, sy + 1, SLOT_W - 2, SLOT_H - 2, 2, 2)
                    Theme.set(Theme.text)
                    love.graphics.setFont(Theme.font_small)
                    love.graphics.printf(mid:sub(1, 8), sx + 2, sy + (SLOT_H - Theme.font_small:getHeight()) * 0.5,
                        SLOT_W - 4, "left")
                else
                    Theme.set(Theme.cell_empty)
                    love.graphics.rectangle("fill", sx + 1, sy + 1, SLOT_W - 2, SLOT_H - 2)
                end
                Theme.set(Theme.border)
                love.graphics.rectangle("line", sx, sy, SLOT_W, SLOT_H)
            end
        end

        -- Playhead highlight
        if is_play then
            Theme.set({1, 1, 0, 0.15})
            love.graphics.rectangle("fill", sx, grid_y, SLOT_W, n_ch * SLOT_H)
        end

        -- Drag indicator
        if self.drag_slot == i then
            Theme.set({1, 1, 1, 0.25})
            love.graphics.rectangle("fill", sx, hdr_y, SLOT_W, ORDER_HDR_H + n_ch * SLOT_H)
        end

        ::continue::
    end

    -- "+" add slot button at end
    do
        local sx = view_x + #song.order * SLOT_W - self.scroll_x
        if sx < view_x + view_w then
            Widgets.button("+", sx + 4, hdr_y + 2, ORDER_HDR_H - 4, ORDER_HDR_H - 4,
                           false, false, Theme.font_medium)
        end
    end

    love.graphics.setScissor()

    -- Horizontal scrollbar
    local total_w = (#song.order + 1) * SLOT_W
    Widgets.scrollbar(view_x, r.y + r.h - SCROLLBAR_H, view_w, SCROLLBAR_H,
        self.scroll_x, total_w, view_w)
end

function SongArranger:_draw_ctx()
    local ctx = self.ctx
    local mw  = 170
    local mh  = #ctx.items * 22 + 4
    Widgets.rect(ctx.x, ctx.y, mw, mh, Theme.bg_panel, Theme.border, 4)
    for i, item in ipairs(ctx.items) do
        local iy = ctx.y + 2 + (i - 1) * 22
        local hov = Widgets.hit(love.mouse.getX(), love.mouse.getY(), ctx.x, iy, mw, 22)
        if hov then
            Theme.set(Theme.btn_hover)
            love.graphics.rectangle("fill", ctx.x + 1, iy, mw - 2, 22)
        end
        local c = item.danger and {0.9, 0.3, 0.3, 1} or Theme.text
        Widgets.label(item.label, ctx.x + 8, iy, mw - 12, 22, c, Theme.font_medium)
    end
end

function SongArranger:_open_mach_pick(slot_i, ch, sx, sy)
    local items = { { label = "(none)", id = "__none__" } }
    local all = Registry.all()
    local ids = {}
    for id in pairs(all) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local e = all[id]
        local name = (e.def and e.def.name) and (e.def.name .. "  [" .. id .. "]") or id
        table.insert(items, { label = name, id = id })
    end
    -- Clamp position so menu stays on screen
    local sw, sh = love.graphics.getDimensions()
    local mw, row_h = 180, 22
    local mh = #items * row_h + 4
    local mx = math.min(sx, sw - mw - 4)
    local my = math.min(sy, sh - mh - 4)
    self.mach_pick = { slot_i = slot_i, ch = ch, x = mx, y = my, items = items }
end

function SongArranger:_draw_mach_pick()
    local mp   = self.mach_pick
    local mw   = 180
    local row_h = 22
    local mh   = #mp.items * row_h + 4
    local mx, my = love.mouse.getX(), love.mouse.getY()
    -- Title bar
    love.graphics.setColor(Theme.bg_header[1], Theme.bg_header[2], Theme.bg_header[3], 1)
    love.graphics.rectangle("fill", mp.x, mp.y - 18, mw, 18, 4, 4)
    love.graphics.setColor(Theme.text_dim[1], Theme.text_dim[2], Theme.text_dim[3], 1)
    love.graphics.setFont(Theme.font_small)
    love.graphics.print("Assign ch" .. mp.ch, mp.x + 6, mp.y - 16)
    Widgets.rect(mp.x, mp.y, mw, mh, Theme.bg_panel, Theme.border, 4)
    for idx, item in ipairs(mp.items) do
        local iy  = mp.y + 2 + (idx - 1) * row_h
        local hov = Widgets.hit(mx, my, mp.x, iy, mw, row_h)
        if hov then
            Theme.set(Theme.btn_hover)
            love.graphics.rectangle("fill", mp.x + 1, iy, mw - 2, row_h)
        end
        Widgets.label(item.label, mp.x + 8, iy, mw - 12, row_h, Theme.text, Theme.font_medium)
    end
end

-- -------------------------
-- Event handling
-- -------------------------

function SongArranger:handle_event(ev, rect)
    if not self.song then return false end

    local ex, ey = ev.x or 0, ev.y or 0
    local song   = self.song

    -- Machine picker (assign machine to channel)
    if self.mach_pick then
        local mp = self.mach_pick
        if ev.type == "pointer_down" then
            local mw, row_h = 180, 22
            local mh = #mp.items * row_h + 4
            for idx, item in ipairs(mp.items) do
                local iy = mp.y + 2 + (idx - 1) * row_h
                if Widgets.hit(ex, ey, mp.x, iy, mw, row_h) then
                    local entry = self.song.order[mp.slot_i]
                    if entry then
                        if item.id == "__none__" then
                            entry.machine_map[mp.ch] = nil
                        else
                            entry.machine_map[mp.ch] = item.id
                        end
                    end
                    self.mach_pick = nil
                    return true
                end
            end
            self.mach_pick = nil
        end
        return true
    end

    -- Context menu
    if self.ctx then
        if ev.type == "pointer_down" then
            local mw = 170
            for i, item in ipairs(self.ctx.items) do
                local iy = self.ctx.y + 2 + (i - 1) * 22
                if Widgets.hit(ex, ey, self.ctx.x, iy, mw, 22) then
                    item.fn(); self.ctx = nil; return true
                end
            end
            self.ctx = nil
        end
        return true
    end

    -- Rename field
    if self.rename_pat then
        if ev.type == "text" then
            self.rename_str = self.rename_str .. ev.text
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "backspace" then
                self.rename_str = self.rename_str:sub(1, #self.rename_str - 1)
                return true
            elseif k == "return" or k == "kpenter" then
                local pat = song.patterns[self.rename_pat]
                if pat then pat.label = self.rename_str end
                self.rename_pat = nil
                return true
            elseif k == "escape" then
                self.rename_pat = nil
                return true
            end
            return true
        end
    end

    local is_pointer_ev = (ev.type == "pointer_down" or ev.type == "pointer_up"
                        or ev.type == "pointer_move" or ev.type == "wheel")
    if is_pointer_ev and not Widgets.hit(ex, ey, rect.x, rect.y, rect.w, rect.h) then
        if ev.type == "pointer_down" then self.focused = false end
        return false
    end
    if is_pointer_ev then self.focused = true end

    -- Toolbar clicks
    if ev.type == "pointer_down" and Widgets.hit(ex, ey, rect.x, rect.y, rect.w, TOOLBAR_H) then
        self:_handle_toolbar_click(ex, ey, rect)
        return true
    end

    local top      = rect.y + TOOLBAR_H
    local list_r   = { x=rect.x, y=top, w=LIST_W, h=rect.h - TOOLBAR_H }
    local order_x  = rect.x + LIST_W
    local view_x   = order_x + CH_LABEL_W
    local grid_y   = top + ORDER_HDR_H
    local view_w   = rect.w - LIST_W - CH_LABEL_W - SCROLLBAR_H

    -- Pattern list clicks
    if Widgets.hit(ex, ey, list_r.x, list_r.y, list_r.w, list_r.h) then
        if ev.type == "pointer_down" then
            local ids = {}
            for id in pairs(song.patterns) do table.insert(ids, id) end
            table.sort(ids)
            local row_h = 22
            local cy = list_r.y + 20 - self.list_scroll
            for _, id in ipairs(ids) do
                if Widgets.hit(ex, ey, list_r.x, cy, list_r.w, row_h) then
                    if ev.button == 2 then
                        self:_open_pat_ctx(id, ex, ey)
                    elseif self.selected_pat == id then
                        -- Second click: rename
                        self.rename_pat = id
                        self.rename_str = song.patterns[id].label or id
                    else
                        self.selected_pat = id
                        local pat = song.patterns[id]
                        if self.on_select_pat then self.on_select_pat(id, pat) end
                    end
                    return true
                end
                cy = cy + row_h
            end
        elseif ev.type == "wheel" then
            self.list_scroll = math.max(0, self.list_scroll - ev.dy * 22)
            return true
        end
        return true
    end

    -- Order timeline
    if ev.type == "pointer_down" then
        local i = math.floor((ex - view_x + self.scroll_x) / SLOT_W) + 1

        -- "+" append button
        local append_x = view_x + #song.order * SLOT_W - self.scroll_x
        if Widgets.hit(ex, ey, append_x + 4, top + 2, ORDER_HDR_H - 4, ORDER_HDR_H - 4) then
            self:_append_slot(); return true
        end

        if i >= 1 and i <= #song.order then
            self.selected_slot = i

            if ev.button == 2 then
                self:_open_slot_ctx(i, ex, ey)
            else
                -- Left click on header row: start drag
                if Widgets.hit(ex, ey, view_x, top, view_w, ORDER_HDR_H) then
                    self.drag_slot    = i
                    self.drag_screen_x = ex
                end
                -- Left click on header row or channel cell
                local cell_area_h = rect.h - TOOLBAR_H - ORDER_HDR_H - SCROLLBAR_H
                if Widgets.hit(ex, ey, view_x, top, view_w, ORDER_HDR_H) then
                    -- Slot header click: load that slot's existing pattern into editor
                    local entry = song.order[i]
                    if entry then
                        local pat = song.patterns[entry.pattern_id]
                        if pat and self.on_select_pat then
                            self.on_select_pat(entry.pattern_id, pat, i)
                        end
                    end
                elseif Widgets.hit(ex, ey, view_x, grid_y, view_w, cell_area_h) then
                    local entry = song.order[i]
                    if entry then
                        -- Load this slot's existing pattern into editor
                        local pat = song.patterns[entry.pattern_id]
                        if pat and self.on_select_pat then
                            self.on_select_pat(entry.pattern_id, pat, i)
                        end
                        -- Determine which channel was clicked and open machine picker
                        local rel_y = ey - grid_y
                        local n_ch  = song:pattern_at(i) and song:pattern_at(i).channels or 4
                        local ch    = math.floor(rel_y / SLOT_H)
                        if ch >= 0 and ch < n_ch then
                            self:_open_mach_pick(i, ch, ex, ey)
                        end
                    end
                end
            end
            return true
        end
    end

    if ev.type == "pointer_move" and self.drag_slot then
        local dx   = ex - self.drag_screen_x
        local steps = math.floor(dx / SLOT_W)
        if steps ~= 0 then
            local target = self.drag_slot + steps
            self:_move_slot(self.drag_slot, target)
            self.drag_slot    = target
            self.drag_screen_x = ex
        end
        return true
    end

    if ev.type == "pointer_up" then
        self.drag_slot = nil
        return false
    end

    if ev.type == "wheel" and Widgets.hit(ex, ey, order_x, top, rect.w - LIST_W, rect.h - TOOLBAR_H) then
        local total_w = (#song.order + 1) * SLOT_W
        self.scroll_x = math.max(0, math.min(
            math.max(0, total_w - view_w),
            self.scroll_x - ev.dy * SLOT_W))
        return true
    end

    if ev.type == "key_down" and self.focused then
        return self:_handle_key(ev.key)
    end

    return false
end

function SongArranger:_handle_toolbar_click(ex, ey, rect)
    local bh = TOOLBAR_ROW_H - 6
    local bw = 64

    -- Row 1: Pattern operations
    local r1y = rect.y
    local x1  = rect.x + 4 + 66
    if Widgets.hit(ex, ey, x1, r1y + 3, bw, bh) then self:_new_pattern();       return end; x1 = x1 + bw + 3
    if Widgets.hit(ex, ey, x1, r1y + 3, bw, bh) then self:_duplicate_pattern(); return end; x1 = x1 + bw + 3
    if Widgets.hit(ex, ey, x1, r1y + 3, bw, bh) then self:_delete_pattern();    return end

    -- Row 2: Slot operations
    local r2y = rect.y + TOOLBAR_ROW_H
    local x2  = rect.x + 4 + 42
    if Widgets.hit(ex, ey, x2, r2y + 3, bw, bh) then self:_insert_slot();  return end; x2 = x2 + bw + 3
    if Widgets.hit(ex, ey, x2, r2y + 3, bw, bh) then self:_append_slot();  return end; x2 = x2 + bw + 3
    if Widgets.hit(ex, ey, x2, r2y + 3, bw, bh) then self:_remove_slot();  return end; x2 = x2 + bw + 3
    if Widgets.hit(ex, ey, x2, r2y + 3, bw - 8, bh) then self:_copy_slot();  return end; x2 = x2 + bw - 5
    if Widgets.hit(ex, ey, x2, r2y + 3, bw - 8, bh) then self:_paste_slot(); return end; x2 = x2 + bw - 5
    x2 = x2 + 10  -- divider
    if Widgets.hit(ex, ey, x2, r2y + 3, 28, bh) then
        if self.selected_slot then self.selected_slot = math.max(1, self.selected_slot - 1) end
        self:_ensure_slot_visible()
        return
    end; x2 = x2 + 31
    if Widgets.hit(ex, ey, x2, r2y + 3, 28, bh) then
        if self.selected_slot and self.song then
            self.selected_slot = math.min(#self.song.order, self.selected_slot + 1)
        end
        self:_ensure_slot_visible()
        return
    end
end

function SongArranger:_open_pat_ctx(id, sx, sy)
    self.ctx = {
        x = sx, y = sy,
        items = {
            { label = "Rename…", fn = function()
                self.rename_pat = id
                self.rename_str = self.song.patterns[id].label or id
            end },
            { label = "Duplicate", fn = function()
                self.selected_pat = id
                self:_duplicate_pattern()
            end },
            { label = "Delete", danger = true, fn = function()
                self.selected_pat = id
                self:_delete_pattern()
            end },
            { label = "Cancel", fn = function() end },
        },
    }
end

function SongArranger:_open_slot_ctx(i, sx, sy)
    local song = self.song
    self.ctx = {
        x = sx, y = sy,
        items = {
            { label = "Assign selected pattern", fn = function()
                local entry = song.order[i]
                if entry and self.selected_pat then
                    entry.pattern_id = self.selected_pat
                    local pat = song.patterns[self.selected_pat]
                    if pat and self.on_select_pat then
                        self.on_select_pat(self.selected_pat, pat, i)
                    end
                end
            end },
            { label = "Insert slot before", fn = function()
                self.selected_slot = i - 1
                self:_insert_slot()
            end },
            { label = "Insert slot after", fn = function()
                self.selected_slot = i
                self:_insert_slot()
            end },
            { label = "Copy slot",  fn = function() self.selected_slot = i; self:_copy_slot()  end },
            { label = "Paste after",fn = function() self.selected_slot = i; self:_paste_slot() end },
            { label = "Move left",  fn = function() self:_move_slot(i, i - 1) end },
            { label = "Move right", fn = function() self:_move_slot(i, i + 1) end },
            { label = "Remove slot",danger = true, fn = function()
                self.selected_slot = i; self:_remove_slot()
            end },
            { label = "Cancel", fn = function() end },
        },
    }
end

function SongArranger:_sorted_pat_ids()
    local ids = {}
    for id in pairs(self.song.patterns) do table.insert(ids, id) end
    table.sort(ids)
    return ids
end

function SongArranger:_select_pat_offset(delta)
    local ids = self:_sorted_pat_ids()
    if #ids == 0 then return end
    local cur = 1
    for i, id in ipairs(ids) do
        if id == self.selected_pat then cur = i; break end
    end
    local next_i = ((cur - 1 + delta) % #ids) + 1
    local id = ids[next_i]
    self.selected_pat = id
    local pat = self.song.patterns[id]
    if pat and self.on_select_pat then self.on_select_pat(id, pat) end
end

-- Scroll so the selected slot is visible in the given order view width.
-- view_w is optional; if omitted we use the last stored value.
function SongArranger:_ensure_slot_visible(view_w)
    if not self.selected_slot or not self.song then return end
    view_w = view_w or self._last_view_w or 400
    local slot_left  = (self.selected_slot - 1) * SLOT_W
    local slot_right = slot_left + SLOT_W
    if slot_left < self.scroll_x then
        self.scroll_x = slot_left
    elseif slot_right > self.scroll_x + view_w then
        self.scroll_x = slot_right - view_w
    end
end

function SongArranger:_handle_key(key)
    local song = self.song
    if key == "left"   then
        self.selected_slot = self.selected_slot and math.max(1, self.selected_slot - 1)
        self:_ensure_slot_visible()
        return true
    elseif key == "right" then
        self.selected_slot = self.selected_slot and math.min(#song.order, self.selected_slot + 1)
        self:_ensure_slot_visible()
        return true
    elseif key == "[" then
        self:_select_pat_offset(-1); return true
    elseif key == "]" then
        self:_select_pat_offset(1); return true
    elseif key == "insert" or key == "i" then
        self:_insert_slot(); return true
    elseif key == "delete" then
        self:_remove_slot(); return true
    elseif key == "n" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
        self:_new_pattern(); return true
    elseif key == "d" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
        self:_duplicate_pattern(); return true
    elseif key == "c" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
        self:_copy_slot(); return true
    elseif key == "v" and (love.keyboard.isDown("lctrl") or love.keyboard.isDown("rctrl")) then
        self:_paste_slot(); return true
    end
    return false
end

return SongArranger
