-- Pattern Editor View
--
-- Layout (top to bottom):
--   [Toolbar]  pattern name | rows | channels | BPM | SPD  [New Pat] [Clear]
--   [Headers]  row# | Ch0 (machine) | Ch1 | ...
--   [Grid]     cells with note / vol / fx columns
--   [Status]   octave indicator | step | keyboard map hint | playhead info
--
-- Note entry (when grid is focused):
--   QWERTY piano layout (two rows):
--     White keys: Z X C V B N M , .      = C D E F G A B C D  (from current octave)
--     Black keys: S D   G H J             = C# D# F# G# A#
--   [1]         = insert NOTE OFF
--   [Delete]    = clear cell, advance cursor
--   Arrow keys  = move cursor
--   F5 / F6     = octave down / up  (or shown buttons in toolbar)
--   F1–F4       = step size 1 / 2 / 4 / 8
--   Page Up/Dn  = jump 16 rows
--   Tab         = next channel
--   Shift+Tab   = prev channel
--
-- Click a cell to move cursor there.
-- Double-click or press Enter on a cell to start editing its note (type MIDI note number).
-- Right-click a cell for a context menu (clear, set note off, set volume).

local Theme    = require("src.ui.theme")
local Widgets  = require("src.ui.widgets")
local Event    = require("src.sequencer.event")
local Pattern  = require("src.sequencer.pattern")
local Registry = require("src.machine.registry")
local DAG      = require("src.machine.dag")

local PatternEditor = {}
PatternEditor.__index = PatternEditor

-- QWERTY -> semitone offset (C = 0).  Two-octave span.
local KEY_NOTES = {
    z=0,  s=1,  x=2,  d=3,  c=4,  v=5,  g=6,
    b=7,  h=8,  n=9,  j=10, m=11,
    [","]=12, l=13, ["."]=14,
}

-- Note name table
local NOTE_NAMES = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}

local function midi_to_str(note)
    if note == Event.NOTE_OFF then return "---" end
    if not note then return "..." end
    local name = NOTE_NAMES[(note % 12) + 1]
    local oct  = math.floor(note / 12) - 1
    return string.format("%-3s%d", name, oct)
end

local TOOLBAR_H = 28
local HEADER_H  = 34
local STATUS_H  = 36   -- taller status bar with keyboard map
local ROW_NUM_W = 36
local CELL_W    = 120  -- per channel: "C#4 .. 0A00"
local SCROLLBAR = 10

-- Column layout within a cell (in characters / sub-pixels):
--   note(4) vol(2) fx1_cmd(2) fx1_val(2)  = roughly 10 chars
local SUB = { note=0, vol=52, fx1=72, fx2=96 }  -- x offsets within cell

-- Which sub-column the cursor is in
local SUBCOLS = {"note", "vol", "fx1", "fx2"}

function PatternEditor.new()
    return setmetatable({
        scroll_row   = 0,
        scroll_col   = 0,
        cursor_row   = 0,
        cursor_col   = 0,
        cursor_sub   = 1,      -- index into SUBCOLS
        octave       = 4,
        step         = 1,
        pattern      = nil,
        song         = nil,
        order_pos    = 1,
        play_row     = nil,
        play_order   = nil,
        focused      = false,
        -- Context menu
        ctx          = nil,    -- { x, y, row, col, items }
        -- Inline value editing (for vol/fx fields)
        edit_cell    = nil,    -- { row, col, sub, value_str }
        -- Toolbar edit state
        edit_field   = nil,    -- "rows" | "channels" | "bpm" | "speed" | nil
        -- Machine picker for column headers
        mach_pick    = nil,    -- { ch, x, y, items={label,id} }
        edit_str     = "",
        -- Automation mode
        auto_mode    = false,  -- true = show automation lanes instead of note grid
        auto_lane    = {},     -- ch -> param_id currently shown for that channel
        auto_pick    = nil,    -- { ch, x, y, items={label,id} } param picker dropdown
        auto_edit    = nil,    -- { row, ch, param_id, value_str } inline value editor
    }, PatternEditor)
end

function PatternEditor:set_pattern(pat, song, order_pos)
    self.pattern   = pat
    self.song      = song
    self.order_pos = order_pos or 1
end

function PatternEditor:set_playhead(order_pos, row)
    self.play_order = order_pos
    self.play_row   = row
end

-- -------------------------
-- Drawing
-- -------------------------

function PatternEditor:draw(rect)
    Theme.set(Theme.bg)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, rect.h)

    self:_draw_toolbar(rect)

    if not self.pattern then
        Widgets.label("No pattern — press [N] to create one",
            rect.x, rect.y + rect.h * 0.5 - 10, rect.w, 20,
            Theme.text_dim, Theme.font_medium, "center")
        return
    end

    local top = rect.y + TOOLBAR_H
    local bot = rect.y + rect.h - STATUS_H
    local grid_h = bot - top - HEADER_H

    self:_draw_headers(rect.x, top, rect.w, HEADER_H)
    if self.auto_mode then
        self:_draw_auto_grid(rect.x, top + HEADER_H, rect.w, grid_h)
    else
        self:_draw_grid(rect.x, top + HEADER_H, rect.w, grid_h)
    end
    self:_draw_status(rect.x, bot, rect.w, STATUS_H)

    -- Context menu on top
    if self.ctx then self:_draw_ctx() end

    -- Machine picker (floats above everything)
    if self.mach_pick then self:_draw_mach_pick() end

    -- Auto param picker
    if self.auto_pick then self:_draw_auto_pick() end

    -- Auto inline value editor
    if self.auto_edit then self:_draw_auto_edit() end
end

function PatternEditor:_draw_toolbar(rect)
    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", rect.x, rect.y, rect.w, TOOLBAR_H)
    Theme.set(Theme.border)
    love.graphics.line(rect.x, rect.y + TOOLBAR_H, rect.x + rect.w, rect.y + TOOLBAR_H)

    local x = rect.x + 6
    local y = rect.y
    local bh = TOOLBAR_H - 6
    local by = rect.y + 3

    local pat = self.pattern
    local song = self.song

    -- Pattern name
    local name = pat and (pat.label ~= "" and pat.label or pat.id) or "—"
    Widgets.label("Pattern: " .. name:sub(1,12), x, y, 130, TOOLBAR_H,
                  Theme.text, Theme.font_medium)
    x = x + 135

    -- Editable: Rows
    local rows_str = pat and tostring(pat.rows) or "—"
    if self.edit_field == "rows" then rows_str = self.edit_str .. "_" end
    Widgets.label("Rows:", x, y, 36, TOOLBAR_H, Theme.text_dim, Theme.font_small)
    Widgets.rect(x + 36, by, 36, bh,
        self.edit_field == "rows" and Theme.bg_panel or Theme.bg,
        self.edit_field == "rows" and Theme.border_focus or Theme.border, 2)
    Widgets.label(rows_str, x + 38, by, 32, bh, Theme.text, Theme.font_mono, "center")
    x = x + 80

    -- Editable: Channels
    local ch_str = pat and tostring(pat.channels) or "—"
    if self.edit_field == "channels" then ch_str = self.edit_str .. "_" end
    Widgets.label("Ch:", x, y, 24, TOOLBAR_H, Theme.text_dim, Theme.font_small)
    Widgets.rect(x + 24, by, 28, bh,
        self.edit_field == "channels" and Theme.bg_panel or Theme.bg,
        self.edit_field == "channels" and Theme.border_focus or Theme.border, 2)
    Widgets.label(ch_str, x + 26, by, 24, bh, Theme.text, Theme.font_mono, "center")
    x = x + 60

    -- BPM / Speed (from song)
    if song then
        local bpm_str = tostring(song.bpm)
        if self.edit_field == "bpm" then bpm_str = self.edit_str .. "_" end
        Widgets.label("BPM:", x, y, 32, TOOLBAR_H, Theme.text_dim, Theme.font_small)
        Widgets.rect(x + 32, by, 36, bh,
            self.edit_field == "bpm" and Theme.bg_panel or Theme.bg,
            self.edit_field == "bpm" and Theme.border_focus or Theme.border, 2)
        Widgets.label(bpm_str, x + 34, by, 32, bh, Theme.text, Theme.font_mono, "center")
        x = x + 76

        local spd_str = tostring(song.speed)
        if self.edit_field == "speed" then spd_str = self.edit_str .. "_" end
        Widgets.label("Spd:", x, y, 28, TOOLBAR_H, Theme.text_dim, Theme.font_small)
        Widgets.rect(x + 28, by, 24, bh,
            self.edit_field == "speed" and Theme.bg_panel or Theme.bg,
            self.edit_field == "speed" and Theme.border_focus or Theme.border, 2)
        Widgets.label(spd_str, x + 30, by, 20, bh, Theme.text, Theme.font_mono, "center")
        x = x + 60
    end

    -- Oct buttons (right-aligned; total width = 56+22+4+22 = 104)
    local oct_x = rect.x + rect.w - 240

    -- NOTE / AUTO mode toggle (just left of oct buttons)
    local mode_x = oct_x - 106
    Widgets.button("NOTE", mode_x,      by, 46, bh, false, not self.auto_mode, Theme.font_small)
    Widgets.button("AUTO", mode_x + 48, by, 46, bh, false, self.auto_mode,     Theme.font_small)
    Widgets.label(string.format("Oct: %d", self.octave),
                  oct_x, y, 56, TOOLBAR_H, Theme.accent, Theme.font_medium)
    Widgets.button("▼", oct_x + 56, by, 22, bh, false, false, Theme.font_small)
    Widgets.button("▲", oct_x + 80, by, 22, bh, false, false, Theme.font_small)

    -- Step buttons (34 label + 4×22 buttons = 122px)
    local stp_x = oct_x + 108
    Widgets.label("Step:", stp_x, y, 34, TOOLBAR_H, Theme.text_dim, Theme.font_small)
    for i, s in ipairs({1,2,4,8}) do
        local active = (self.step == s)
        Widgets.button(tostring(s), stp_x + 34 + (i-1)*22, by, 20, bh,
                       false, active, Theme.font_small)
    end
end

function PatternEditor:_draw_headers(x, y, w, h)
    local pat = self.pattern
    if not pat then return end

    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", x, y, w, h)
    Theme.set(Theme.border)
    love.graphics.line(x, y + h, x + w, y + h)

    -- Row number gutter
    Widgets.label("#", x, y, ROW_NUM_W, h, Theme.text_dim, Theme.font_small, "center")

    local entry    = self.song and self.song.order[self.order_pos]
    local view_w   = w - ROW_NUM_W - SCROLLBAR
    local vis_cols = math.ceil(view_w / CELL_W) + 1
    local top_h    = math.floor(h * 0.55)  -- upper band: machine assignment
    local bot_y    = y + top_h             -- lower band: sub-column labels

    for c = self.scroll_col, math.min(self.scroll_col + vis_cols, pat.channels - 1) do
        local cx  = x + ROW_NUM_W + (c - self.scroll_col) * CELL_W
        local mid = entry and entry.machine_map and entry.machine_map[c]

        -- Column background: tinted green when assigned, normal otherwise
        if c == self.cursor_col and self.focused then
            Theme.set({0.18, 0.20, 0.28, 1})
            love.graphics.rectangle("fill", cx, y, CELL_W - 1, h)
        end
        if mid then
            love.graphics.setColor(0.15, 0.35, 0.15, 0.7)
            love.graphics.rectangle("fill", cx + 1, y + 1, CELL_W - 2, top_h - 2, 2, 2)
        else
            love.graphics.setColor(0.22, 0.22, 0.22, 0.6)
            love.graphics.rectangle("fill", cx + 1, y + 1, CELL_W - 2, top_h - 2, 2, 2)
        end

        -- Machine label or "click to assign" hint
        if mid then
            -- Show machine name + a small "▾" dropdown indicator
            local name = mid:sub(1, 14)
            love.graphics.setFont(Theme.font_small)
            love.graphics.setColor(0.6, 1.0, 0.6, 1)
            love.graphics.printf(name .. " ▾", cx + 3, y + (top_h - Theme.font_small:getHeight()) * 0.5,
                CELL_W - 6, "left")
        else
            love.graphics.setFont(Theme.font_small)
            love.graphics.setColor(0.55, 0.55, 0.55, 1)
            love.graphics.printf("Ch"..(c+1).." — assign ▾", cx + 3,
                y + (top_h - Theme.font_small:getHeight()) * 0.5, CELL_W - 6, "left")
        end

        -- Sub-column labels in lower band
        love.graphics.setFont(Theme.font_mono)
        Theme.set(Theme.text_dim)
        if self.auto_mode then
            local pid = self.auto_lane[c]
            local label = pid and (pid .. " ▾") or "— param ▾"
            love.graphics.setFont(Theme.font_small)
            love.graphics.setColor(0.7, 0.9, 1.0, 1)
            love.graphics.printf(label, cx + 3, bot_y + 1, CELL_W - 6, "left")
        else
            love.graphics.print("note", cx + SUB.note, bot_y + 1)
            love.graphics.print("vol",  cx + SUB.vol,  bot_y + 1)
            love.graphics.print("fx1",  cx + SUB.fx1,  bot_y + 1)
            love.graphics.print("fx2",  cx + SUB.fx2,  bot_y + 1)
        end

        -- Separator
        Theme.set(Theme.border)
        love.graphics.line(cx + CELL_W - 1, y, cx + CELL_W - 1, y + h)
    end
end

function PatternEditor:_open_mach_pick(ch, sx, sy)
    local items = { { label = "(none — unassign)", id = "__none__" } }
    local all = Registry.all()
    local ids = {}
    for id in pairs(all) do table.insert(ids, id) end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local e    = all[id]
        local name = (e.def and e.def.name) and (e.def.name .. "  [" .. id .. "]") or id
        table.insert(items, { label = name, id = id })
    end
    local sw, sh   = love.graphics.getDimensions()
    local mw, rh   = 220, 22
    local mh       = #items * rh + 4
    local mx = math.min(sx, sw - mw - 4)
    local my = math.min(sy, sh - mh - 4)
    self.mach_pick = { ch = ch, x = mx, y = my, items = items }
end

function PatternEditor:_draw_mach_pick()
    local mp   = self.mach_pick
    local mw   = 220
    local rh   = 22
    local mh   = #mp.items * rh + 4
    local mx, my = love.mouse.getPosition()
    -- Header
    love.graphics.setColor(0.1, 0.1, 0.12, 0.97)
    love.graphics.rectangle("fill", mp.x, mp.y, mw, mh, 4, 4)
    love.graphics.setColor(0.3, 0.5, 0.3, 1)
    love.graphics.rectangle("line", mp.x, mp.y, mw, mh, 4, 4)
    for idx, item in ipairs(mp.items) do
        local iy  = mp.y + 2 + (idx - 1) * rh
        local hov = Widgets.hit(mx, my, mp.x, iy, mw, rh)
        if hov then
            love.graphics.setColor(0.2, 0.45, 0.2, 1)
            love.graphics.rectangle("fill", mp.x + 1, iy, mw - 2, rh)
        end
        local tc = (item.id == "__none__") and {0.6, 0.4, 0.4, 1} or {0.85, 0.95, 0.85, 1}
        love.graphics.setColor(tc[1], tc[2], tc[3], tc[4])
        love.graphics.setFont(Theme.font_small)
        love.graphics.print(item.label, mp.x + 8, iy + (rh - Theme.font_small:getHeight()) * 0.5)
    end
end

-- Auto-mode: draw automation lane grid (one value column per channel)
local AUTO_CELL_W = 120  -- same visual width as note cells

function PatternEditor:_draw_auto_grid(x, y, w, h)
    local pat = self.pattern
    if not pat then return end

    local cell_h = Theme.cell_h
    local view_w = w - ROW_NUM_W - SCROLLBAR
    local vis_rows = math.ceil(h / cell_h) + 1
    local vis_cols = math.ceil(view_w / AUTO_CELL_W) + 1

    love.graphics.setScissor(x, y, w, h)
    love.graphics.setFont(Theme.font_mono)

    local entry = self.song and self.song.order[self.order_pos]

    for r = self.scroll_row, math.min(self.scroll_row + vis_rows, pat.rows - 1) do
        local ry = y + (r - self.scroll_row) * cell_h

        -- Row number gutter
        local row_c
        if r % 16 == 0 then row_c = Theme.accent
        elseif r % 4 == 0 then row_c = Theme.text
        else row_c = Theme.text_dim
        end
        Theme.set(r % 2 == 0 and Theme.bg_header or Theme.bg)
        love.graphics.rectangle("fill", x, ry, ROW_NUM_W, cell_h)
        Theme.set(row_c)
        love.graphics.printf(string.format("%03d", r), x, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5, ROW_NUM_W, "center")

        for c = self.scroll_col, math.min(self.scroll_col + vis_cols, pat.channels - 1) do
            local cx = x + ROW_NUM_W + (c - self.scroll_col) * AUTO_CELL_W

            local is_cursor   = (r == self.cursor_row and c == self.cursor_col and self.focused)
            local is_playhead = (r == self.play_row and self.play_order == self.order_pos)
            local bg
            if is_cursor then bg = Theme.cell_cursor
            elseif is_playhead then bg = Theme.cell_playhead
            elseif r % 2 == 0 then bg = (c % 2 == 0) and Theme.cell_empty or Theme.cell_empty_alt
            else bg = (c % 2 == 0) and Theme.cell_empty_alt or Theme.cell_empty
            end
            Theme.set(bg)
            love.graphics.rectangle("fill", cx, ry, AUTO_CELL_W - 1, cell_h - 1)

            -- Show value if a param is assigned and there's data
            local param_id = self.auto_lane[c]
            local auto_slot = pat:get_auto(r, c)
            local value = auto_slot and param_id and auto_slot[param_id]
            local ty = ry + (cell_h - Theme.font_mono:getHeight()) * 0.5

            if value ~= nil then
                -- Check if we're currently inline-editing this cell
                local ae = self.auto_edit
                if ae and ae.row == r and ae.ch == c and ae.param_id == param_id then
                    -- Show edit cursor
                    love.graphics.setColor(0.3, 0.8, 1.0, 1)
                    love.graphics.print(ae.value_str .. "_", cx + 4, ty)
                else
                    love.graphics.setColor(0.4, 0.9, 1.0, 1)
                    love.graphics.print(string.format("%.4g", value), cx + 4, ty)
                end
            else
                -- Show editing cursor for empty cell if cursor is here
                local ae = self.auto_edit
                if ae and ae.row == r and ae.ch == c then
                    love.graphics.setColor(0.3, 0.8, 1.0, 1)
                    love.graphics.print(ae.value_str .. "_", cx + 4, ty)
                else
                    Theme.set(Theme.text_dim)
                    love.graphics.print("·····", cx + 4, ty)
                end
            end

            -- Separator
            Theme.set(Theme.border)
            love.graphics.line(cx + AUTO_CELL_W - 1, ry, cx + AUTO_CELL_W - 1, ry + cell_h)
        end
    end

    love.graphics.setScissor()

    -- Vertical scrollbar
    local total_h = pat.rows * cell_h
    Widgets.scrollbar(x + w - SCROLLBAR, y, SCROLLBAR, h,
        self.scroll_row * cell_h, total_h, h)
end

function PatternEditor:_open_auto_pick(ch, sx, sy)
    local entry = self.song and self.song.order[self.order_pos]
    local machine_id = entry and entry.machine_map and entry.machine_map[ch]
    local items = {}
    table.insert(items, { label = "(none — clear lane)", id = "__none__" })
    if machine_id then
        local reg_entry = Registry.all()[machine_id]
        local def = reg_entry and reg_entry.def
        if def and def.params then
            for _, p in ipairs(def.params) do
                if p.type == "float" or p.type == "int" then
                    local range = string.format("  [%.4g–%.4g]", p.min or 0, p.max or 1)
                    table.insert(items, { label = p.label .. range, id = p.id })
                end
            end
        end
    end
    if #items == 1 then
        -- No float/int params — add a note
        table.insert(items, { label = "(no automatable params on this channel)", id = "__none__" })
    end
    local sw, sh = love.graphics.getDimensions()
    local mw, rh = 260, 22
    local mh = #items * rh + 4
    local mx = math.min(sx, sw - mw - 4)
    local my = math.min(sy, sh - mh - 4)
    self.auto_pick = { ch = ch, x = mx, y = my, items = items }
end

function PatternEditor:_draw_auto_pick()
    local ap = self.auto_pick
    local mw, rh = 260, 22
    local mh = #ap.items * rh + 4
    local mx, my = love.mouse.getPosition()
    love.graphics.setColor(0.08, 0.10, 0.14, 0.97)
    love.graphics.rectangle("fill", ap.x, ap.y, mw, mh, 4, 4)
    love.graphics.setColor(0.2, 0.45, 0.6, 1)
    love.graphics.rectangle("line", ap.x, ap.y, mw, mh, 4, 4)
    for idx, item in ipairs(ap.items) do
        local iy = ap.y + 2 + (idx - 1) * rh
        local hov = Widgets.hit(mx, my, ap.x, iy, mw, rh)
        if hov then
            love.graphics.setColor(0.15, 0.35, 0.5, 1)
            love.graphics.rectangle("fill", ap.x + 1, iy, mw - 2, rh)
        end
        local tc = (item.id == "__none__") and {0.5, 0.4, 0.4, 1} or {0.7, 0.92, 1.0, 1}
        love.graphics.setColor(tc[1], tc[2], tc[3], tc[4])
        love.graphics.setFont(Theme.font_small)
        love.graphics.print(item.label, ap.x + 8, iy + (rh - Theme.font_small:getHeight()) * 0.5)
    end
end

function PatternEditor:_draw_auto_edit()
    -- inline edit is shown inside the grid cell, nothing extra needed here
end

function PatternEditor:_draw_grid(x, y, w, h)
    local pat = self.pattern
    if not pat then return end

    local cell_h = Theme.cell_h
    local view_h = h
    local view_w = w - ROW_NUM_W - SCROLLBAR
    local vis_rows = math.ceil(view_h / cell_h) + 1
    local vis_cols = math.ceil(view_w / CELL_W) + 1

    love.graphics.setScissor(x, y, w, h)
    love.graphics.setFont(Theme.font_mono)

    for r = self.scroll_row, math.min(self.scroll_row + vis_rows, pat.rows - 1) do
        local ry = y + (r - self.scroll_row) * cell_h

        -- Row number gutter
        local row_c
        if r % 16 == 0 then row_c = Theme.accent
        elseif r % 4 == 0 then row_c = Theme.text
        else row_c = Theme.text_dim
        end
        Theme.set(r % 2 == 0 and Theme.bg_header or Theme.bg)
        love.graphics.rectangle("fill", x, ry, ROW_NUM_W, cell_h)
        Theme.set(row_c)
        love.graphics.printf(string.format("%03d", r), x, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5, ROW_NUM_W, "center")

        for c = self.scroll_col, math.min(self.scroll_col + vis_cols, pat.channels - 1) do
            local cx = x + ROW_NUM_W + (c - self.scroll_col) * CELL_W
            local cell = pat:get_cell(r, c)

            -- Cell background
            local is_cursor  = (r == self.cursor_row and c == self.cursor_col and self.focused)
            local is_playhead = (r == self.play_row and self.play_order == self.order_pos)
            local bg
            if is_cursor then
                bg = Theme.cell_cursor
            elseif is_playhead then
                bg = Theme.cell_playhead
            elseif r % 2 == 0 then
                bg = (c % 2 == 0) and Theme.cell_empty or Theme.cell_empty_alt
            else
                bg = (c % 2 == 0) and Theme.cell_empty_alt or Theme.cell_empty
            end
            Theme.set(bg)
            love.graphics.rectangle("fill", cx, ry, CELL_W - 1, cell_h - 1)

            -- Sub-column cursor highlight
            if is_cursor then
                local sub_x = cx + SUB[SUBCOLS[self.cursor_sub]]
                local sub_w = (self.cursor_sub < #SUBCOLS)
                    and (SUB[SUBCOLS[self.cursor_sub + 1]] - SUB[SUBCOLS[self.cursor_sub]])
                    or (CELL_W - SUB[SUBCOLS[self.cursor_sub]] - 4)
                Theme.set({1, 1, 1, 0.15})
                love.graphics.rectangle("fill", sub_x, ry, sub_w, cell_h - 1)
            end

            -- Cell text
            if cell then
                -- Note
                local note_str, note_c
                if cell.note == Event.NOTE_OFF then
                    note_str = "---"; note_c = Theme.cell_note_off
                elseif cell.note then
                    note_str = midi_to_str(cell.note)
                    note_c   = Theme.cell_note
                else
                    note_str = "···"; note_c = Theme.text_dim
                end
                Theme.set(note_c)
                love.graphics.print(note_str, cx + SUB.note + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)

                -- Volume
                local vol_str = (cell.vol and cell.vol < 255) and string.format("%02X", cell.vol) or ".."
                Theme.set(cell.vol and cell.vol < 255 and Theme.accent2 or Theme.text_dim)
                love.graphics.print(vol_str, cx + SUB.vol + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)

                -- FX1
                if cell.fx1_cmd and cell.fx1_cmd ~= 0 then
                    Theme.set(Theme.cell_fx)
                    love.graphics.print(
                        string.format("%02X%02X", cell.fx1_cmd, cell.fx1_val or 0),
                        cx + SUB.fx1 + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)
                else
                    Theme.set(Theme.text_dim)
                    love.graphics.print("....", cx + SUB.fx1 + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)
                end

                -- FX2
                if cell.fx2_cmd and cell.fx2_cmd ~= 0 then
                    Theme.set(Theme.cell_fx)
                    love.graphics.print(
                        string.format("%02X%02X", cell.fx2_cmd, cell.fx2_val or 0),
                        cx + SUB.fx2 + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)
                else
                    Theme.set(Theme.text_dim)
                    love.graphics.print("....", cx + SUB.fx2 + 1, ry + (cell_h - Theme.font_mono:getHeight()) * 0.5)
                end
            else
                -- Empty row — print each sub-column separately so they align with header
                local ty = ry + (cell_h - Theme.font_mono:getHeight()) * 0.5
                Theme.set(Theme.text_dim)
                love.graphics.print("···", cx + SUB.note + 1, ty)
                love.graphics.print("..", cx + SUB.vol  + 1, ty)
                love.graphics.print("....", cx + SUB.fx1  + 1, ty)
                love.graphics.print("....", cx + SUB.fx2  + 1, ty)
            end
        end
    end

    love.graphics.setScissor()

    -- Vertical scrollbar
    local total_h = pat.rows * cell_h
    Widgets.scrollbar(x + w - SCROLLBAR, y, SCROLLBAR, h,
        self.scroll_row * cell_h, total_h, h)
end

function PatternEditor:_draw_status(x, y, w, h)
    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", x, y, w, h)
    Theme.set(Theme.border)
    love.graphics.line(x, y, x + w, y)

    -- Octave piano diagram
    local oct = self.octave
    local keys = {
        {k="Z", note=0}, {k="X", note=2}, {k="C", note=4}, {k="V", note=5},
        {k="B", note=7}, {k="N", note=9}, {k="M", note=11}, {k=",", note=12},
    }
    local black = {
        {k="S", note=1}, {k="D", note=3}, {k="G", note=6},
        {k="H", note=8}, {k="J", note=10},
    }
    local kw, kh = 14, h - 8
    local kx = x + 6
    love.graphics.setFont(Theme.font_small)
    for i, entry in ipairs(keys) do
        local note_abs = (oct + 1) * 12 + entry.note
        Theme.set({0.85, 0.85, 0.90, 1})
        love.graphics.rectangle("fill", kx, y + 4, kw, kh)
        Theme.set(Theme.border)
        love.graphics.rectangle("line", kx, y + 4, kw, kh)
        Theme.set({0.1, 0.1, 0.15, 1})
        love.graphics.printf(entry.k, kx, y + kh - 10, kw, "center")
        kx = kx + kw + 1
    end
    -- Black keys (overlaid roughly)
    local bk_offsets = {1, 2, 4, 5, 6}  -- gaps corresponding to white key positions
    local bk_keys = black
    kx = x + 6
    local bkw, bkh = 10, math.floor(kh * 0.55)
    for i, entry in ipairs(black) do
        local bx2 = x + 6 + (bk_offsets[i] * (kw + 1)) - math.floor(bkw / 2)
        Theme.set({0.15, 0.15, 0.20, 1})
        love.graphics.rectangle("fill", bx2, y + 4, bkw, bkh)
        Theme.set(Theme.border)
        love.graphics.rectangle("line", bx2, y + 4, bkw, bkh)
        Theme.set({0.7, 0.7, 0.8, 1})
        love.graphics.printf(entry.k, bx2, y + 4, bkw, "center")
    end

    -- Info text
    local info_x = x + 6 + 8 * (kw + 1) + 10
    local pat = self.pattern
    local row_str = pat and string.format("Row %d/%d", self.cursor_row + 1, pat.rows) or ""
    local ch_str  = pat and string.format("Ch %d/%d", self.cursor_col + 1, pat.channels) or ""

    Widgets.label(row_str, info_x, y + 2, 80, 14, Theme.text, Theme.font_small)
    Widgets.label(ch_str,  info_x, y + 16, 80, 14, Theme.text, Theme.font_small)

    -- Step / octave reminders
    local hint_x = info_x + 85
    if self.auto_mode then
        Widgets.label(string.format("AUTO mode   F1-F4 = step %d   [Enter] = edit value   [Del] = clear",
                      self.step), hint_x, y + 2, w - hint_x - 8, 14, Theme.text_dim, Theme.font_small)
        Widgets.label("Tab = next ch   arrows = move   click lower header = set param   right-click = clear   NOTE button = exit",
                      hint_x, y + 16, w - hint_x - 8, 14, Theme.text_dim, Theme.font_small)
    else
        Widgets.label(string.format("F5/F6 = oct ▼▲   F1-F4 = step %d   [1] = note-off   [Del] = clear",
                      self.step), hint_x, y + 2, w - hint_x - 8, 14, Theme.text_dim, Theme.font_small)
        Widgets.label("Tab = next ch   arrows = move   click column header = assign machine   right-click cell = options",
                      hint_x, y + 16, w - hint_x - 8, 14, Theme.text_dim, Theme.font_small)
    end

    -- Focus indicator
    if not self.focused then
        Widgets.label("[ click grid to focus ]", x + w - 140, y + 2, 134, 14,
                      Theme.text_dim, Theme.font_small, "right")
    end
end

function PatternEditor:_draw_ctx()
    local ctx = self.ctx
    local mw = 160
    local mh = #ctx.items * 22 + 4
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

-- -------------------------
-- Event handling
-- -------------------------

function PatternEditor:handle_event(ev, rect)
    local ex, ey = ev.x or 0, ev.y or 0

    -- Machine picker eats clicks
    if self.mach_pick then
        if ev.type == "pointer_down" then
            local mp = self.mach_pick
            local mw, rh = 220, 22
            for idx, item in ipairs(mp.items) do
                local iy = mp.y + 2 + (idx - 1) * rh
                if Widgets.hit(ex, ey, mp.x, iy, mw, rh) then
                    local entry = self.song and self.song.order[self.order_pos]
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

    -- Auto param picker eats clicks
    if self.auto_pick then
        if ev.type == "pointer_down" then
            local ap = self.auto_pick
            local mw, rh = 260, 22
            for idx, item in ipairs(ap.items) do
                local iy = ap.y + 2 + (idx - 1) * rh
                if Widgets.hit(ex, ey, ap.x, iy, mw, rh) then
                    if item.id == "__none__" then
                        self.auto_lane[ap.ch] = nil
                    else
                        self.auto_lane[ap.ch] = item.id
                    end
                    self.auto_pick = nil
                    return true
                end
            end
            self.auto_pick = nil
        end
        return true
    end

    -- Auto inline edit eats text/key events
    if self.auto_edit then
        if ev.type == "text" then
            local t = ev.text
            if t:match("[0-9%.%-]") then
                self.auto_edit.value_str = self.auto_edit.value_str .. t
            end
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "backspace" then
                local s = self.auto_edit.value_str
                self.auto_edit.value_str = s:sub(1, #s - 1)
                return true
            elseif k == "return" or k == "kpenter" or k == "tab" then
                local v = tonumber(self.auto_edit.value_str)
                if v then
                    local pat = self.pattern
                    if pat then
                        pat:set_auto(self.auto_edit.row, self.auto_edit.ch,
                                     self.auto_edit.param_id, v)
                        -- Live-apply to machine
                        local entry = self.song and self.song.order[self.order_pos]
                        local mid = entry and entry.machine_map and entry.machine_map[self.auto_edit.ch]
                        if mid then pcall(DAG.set_param, mid, self.auto_edit.param_id, v) end
                    end
                end
                local advance = (k == "tab") and 0 or self.step
                self.auto_edit = nil
                if advance > 0 then self:_move(advance, 0) end
                return true
            elseif k == "escape" then
                self.auto_edit = nil
                return true
            end
        elseif ev.type == "pointer_down" then
            -- click outside cancels edit
            self.auto_edit = nil
        end
    end

    -- Context menu eats clicks
    if self.ctx then
        if ev.type == "pointer_down" then
            local ctx = self.ctx
            local mw = 160
            for i, item in ipairs(ctx.items) do
                local iy = ctx.y + 2 + (i - 1) * 22
                if Widgets.hit(ex, ey, ctx.x, iy, mw, 22) then
                    item.fn()
                    self.ctx = nil
                    return true
                end
            end
            self.ctx = nil
        end
        return true
    end

    -- Toolbar field editing: text + enter/escape
    if self.edit_field then
        if ev.type == "text" then
            if ev.text:match("%d") then
                self.edit_str = self.edit_str .. ev.text
            end
            return true
        elseif ev.type == "key_down" then
            local k = ev.key
            if k == "backspace" then
                self.edit_str = self.edit_str:sub(1, #self.edit_str - 1)
                return true
            elseif k == "return" or k == "kpenter" then
                self:_commit_toolbar_field()
                return true
            elseif k == "escape" then
                self.edit_field = nil
                self.edit_str   = ""
                return true
            end
        end
    end

    local pat = self.pattern
    local song = self.song

    -- Toolbar click detection
    if ev.type == "pointer_down" and Widgets.hit(ex, ey, rect.x, rect.y, rect.w, TOOLBAR_H) then
        self:_handle_toolbar_click(ex, ey, rect)
        return true
    end

    -- Keyboard events have no meaningful x/y; only pointer events need bounds check
    local is_pointer = (ev.type == "pointer_down" or ev.type == "pointer_up"
                     or ev.type == "pointer_move" or ev.type == "wheel")
    if is_pointer and not Widgets.hit(ex, ey, rect.x, rect.y, rect.w, rect.h) then
        if ev.type == "pointer_down" then
            self.focused = false
            self.edit_field = nil
        end
        return false
    end

    -- Header row click: open machine picker or auto param picker
    local header_y = rect.y + TOOLBAR_H
    if ev.type == "pointer_down" and pat
    and Widgets.hit(ex, ey, rect.x + ROW_NUM_W, header_y, rect.w - ROW_NUM_W - SCROLLBAR, HEADER_H) then
        local col = self.scroll_col + math.floor((ex - rect.x - ROW_NUM_W) / CELL_W)
        col = math.max(0, math.min(pat.channels - 1, col))
        local top_h = math.floor(HEADER_H * 0.55)
        if ey < header_y + top_h then
            -- Upper band: machine assignment (both modes)
            self:_open_mach_pick(col, ex, header_y + HEADER_H)
        elseif self.auto_mode then
            -- Lower band in auto mode: param picker
            self:_open_auto_pick(col, ex, header_y + HEADER_H)
        end
        return true
    end

    -- Grid area bounds
    local grid_y = rect.y + TOOLBAR_H + HEADER_H
    local grid_h = rect.h - TOOLBAR_H - HEADER_H - STATUS_H

    if ev.type == "pointer_down" and Widgets.hit(ex, ey, rect.x, grid_y, rect.w, grid_h) then
        self.focused = true
        self.edit_field = nil
        if pat then
            local cell_h = Theme.cell_h
            local col = self.scroll_col + math.floor((ex - rect.x - ROW_NUM_W) / CELL_W)
            local row = self.scroll_row + math.floor((ey - grid_y) / cell_h)
            col = math.max(0, math.min(pat.channels - 1, col))
            row = math.max(0, math.min(pat.rows - 1, row))

            self.cursor_row = row
            self.cursor_col = col

            if self.auto_mode then
                -- Auto mode: click opens inline value editor for the assigned param
                local param_id = self.auto_lane[col]
                if param_id and ev.button ~= 2 then
                    local auto_slot = pat:get_auto(row, col)
                    local cur_val   = auto_slot and auto_slot[param_id]
                    self.auto_edit = {
                        row       = row,
                        ch        = col,
                        param_id  = param_id,
                        value_str = cur_val and tostring(cur_val) or "",
                    }
                elseif ev.button == 2 then
                    -- Right-click: clear auto value for this cell/param
                    local param_id2 = self.auto_lane[col]
                    if param_id2 then
                        pat:clear_auto(row, col, param_id2)
                    end
                end
            else
                -- Note mode: determine sub-column from x offset within cell
                local cell_x_off = (ex - rect.x - ROW_NUM_W) % CELL_W
                local sub = 1
                for si = #SUBCOLS, 1, -1 do
                    if cell_x_off >= SUB[SUBCOLS[si]] then
                        sub = si; break
                    end
                end
                self.cursor_sub = sub

                if ev.button == 2 then
                    self:_open_cell_ctx(row, col, ex, ey)
                end
            end
        end
        return true
    end

    if ev.type == "pointer_down" then
        self.focused = true
        return true
    end

    if ev.type == "wheel" and pat then
        if Widgets.hit(ex, ey, rect.x, grid_y, rect.w, grid_h) then
            local cell_h = Theme.cell_h
            local vis = math.floor(grid_h / cell_h)
            if love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift") then
                self.scroll_col = math.max(0, math.min(pat.channels - 1,
                    self.scroll_col - math.floor(ev.dy)))
            else
                self.scroll_row = math.max(0, math.min(
                    math.max(0, pat.rows - vis),
                    self.scroll_row - math.floor(ev.dy * 3)))
            end
            return true
        end
    end

    if ev.type == "key_down" and self.focused then
        return self:_handle_key(ev.key, ev.isrepeat, rect)
    end

    return false
end

function PatternEditor:_handle_toolbar_click(ex, ey, rect)
    local pat  = self.pattern
    local song = self.song
    local by   = rect.y + 3
    local bh   = TOOLBAR_H - 6
    local x    = rect.x + 6

    x = x + 135  -- skip "Pattern: ..."

    -- Rows field
    if pat and Widgets.hit(ex, ey, x + 36, by, 36, bh) then
        self.edit_field = "rows"
        self.edit_str   = tostring(pat.rows)
        return
    end
    x = x + 80

    -- Channels field
    if pat and Widgets.hit(ex, ey, x + 24, by, 28, bh) then
        self.edit_field = "channels"
        self.edit_str   = tostring(pat.channels)
        return
    end
    x = x + 60

    -- BPM / Speed
    if song then
        if Widgets.hit(ex, ey, x + 32, by, 36, bh) then
            self.edit_field = "bpm"
            self.edit_str   = tostring(song.bpm)
            return
        end
        x = x + 76
        if Widgets.hit(ex, ey, x + 28, by, 24, bh) then
            self.edit_field = "speed"
            self.edit_str   = tostring(song.speed)
            return
        end
        x = x + 60
    end

    -- NOTE / AUTO toggle buttons
    local oct_x = rect.x + rect.w - 240
    local mode_x = oct_x - 106
    if Widgets.hit(ex, ey, mode_x, by, 46, bh) then
        self.auto_mode = false; self.auto_edit = nil; return
    end
    if Widgets.hit(ex, ey, mode_x + 48, by, 46, bh) then
        self.auto_mode = true; self.auto_edit = nil; return
    end

    -- Oct buttons
    if Widgets.hit(ex, ey, oct_x + 56, by, 22, bh) then
        self.octave = math.max(0, self.octave - 1); return
    end
    if Widgets.hit(ex, ey, oct_x + 80, by, 22, bh) then
        self.octave = math.min(9, self.octave + 1); return
    end

    -- Step buttons
    local stp_x = oct_x + 108
    for i, s in ipairs({1,2,4,8}) do
        if Widgets.hit(ex, ey, stp_x + 34 + (i-1)*22, by, 20, bh) then
            self.step = s; return
        end
    end
end

function PatternEditor:_commit_toolbar_field()
    local v = tonumber(self.edit_str)
    local pat  = self.pattern
    local song = self.song
    if v then
        if self.edit_field == "rows" and pat then
            pat:resize(math.max(1, math.min(256, math.floor(v))), pat.channels)
        elseif self.edit_field == "channels" and pat then
            pat:resize(pat.rows, math.max(1, math.min(32, math.floor(v))))
        elseif self.edit_field == "bpm" and song then
            song.bpm = math.max(20, math.min(999, math.floor(v)))
            -- Notify sequencer if available
            local ok, Seq = pcall(require, "src.sequencer.sequencer")
            if ok then Seq.recompute_timing() end
        elseif self.edit_field == "speed" and song then
            song.speed = math.max(1, math.min(32, math.floor(v)))
            local ok, Seq = pcall(require, "src.sequencer.sequencer")
            if ok then Seq.recompute_timing() end
        end
    end
    self.edit_field = nil
    self.edit_str   = ""
end

function PatternEditor:_open_cell_ctx(row, col, sx, sy)
    local pat  = self.pattern
    local cell = pat and pat:get_cell(row, col)
    self.ctx = {
        x = sx, y = sy,
        row = row, col = col,
        items = {
            {
                label = "Clear cell",
                fn = function()
                    if pat then pat:set_cell(row, col, nil) end
                end,
            },
            {
                label = "Note OFF",
                fn = function()
                    if pat then pat:set_note(row, col, Event.NOTE_OFF) end
                end,
            },
            {
                label = cell and cell.note and ("Note: " .. midi_to_str(cell.note)) or "No note",
                fn = function() end,
            },
            {
                label = "Set volume (hex)…",
                fn = function()
                    -- Would open inline editor; for now toggle default
                    if pat then
                        local c2 = pat:get_cell(row, col) or {}
                        c2.vol = (c2.vol and c2.vol < 255) and 255 or 200
                        pat:set_cell(row, col, c2)
                    end
                end,
            },
            { label = "Cancel", fn = function() end },
        },
    }
end

function PatternEditor:_handle_key(key, isrepeat, rect)
    local pat = self.pattern
    if not pat then
        return false
    end

    -- Auto mode keyboard shortcuts
    if self.auto_mode then
        -- Navigation same as note mode
        if key == "up"    then self:_move(-(self.step), 0); return true end
        if key == "down"  then self:_move(  self.step,  0); return true end
        if key == "left"  then self:_move(0, -1); return true end
        if key == "right" then self:_move(0,  1); return true end
        if key == "tab" then
            if love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift") then
                self:_move(0, -1)
            else
                self:_move(0, 1)
            end
            return true
        end
        if key == "pageup"   then self:_move(-16, 0); return true end
        if key == "pagedown" then self:_move( 16, 0); return true end
        if key == "home"     then self.cursor_row = 0; self:_clamp_scroll(rect); return true end
        if key == "end"      then self.cursor_row = pat.rows - 1; self:_clamp_scroll(rect); return true end
        if key == "f1" then self.step = 1; return true end
        if key == "f2" then self.step = 2; return true end
        if key == "f3" then self.step = 4; return true end
        if key == "f4" then self.step = 8; return true end
        -- Delete: clear auto value at cursor for the assigned param
        if key == "delete" or key == "backspace" then
            local pid = self.auto_lane[self.cursor_col]
            if pid then
                pat:clear_auto(self.cursor_row, self.cursor_col, pid)
            end
            self:_move(self.step, 0)
            return true
        end
        -- Enter / Return: open inline editor for cursor cell
        if key == "return" or key == "kpenter" then
            local pid = self.auto_lane[self.cursor_col]
            if pid then
                local auto_slot = pat:get_auto(self.cursor_row, self.cursor_col)
                local cur_val   = auto_slot and auto_slot[pid]
                self.auto_edit = {
                    row       = self.cursor_row,
                    ch        = self.cursor_col,
                    param_id  = pid,
                    value_str = cur_val and tostring(cur_val) or "",
                }
            end
            return true
        end
        return false
    end

    -- Navigation
    if key == "up"    then self:_move(-(self.step), 0);  return true end
    if key == "down"  then self:_move( self.step, 0);   return true end
    if key == "left"  then
        if self.cursor_sub > 1 then self.cursor_sub = self.cursor_sub - 1
        else self:_move(0, -1); self.cursor_sub = #SUBCOLS end
        return true
    end
    if key == "right" then
        if self.cursor_sub < #SUBCOLS then self.cursor_sub = self.cursor_sub + 1
        else self:_move(0, 1); self.cursor_sub = 1 end
        return true
    end
    if key == "tab" then
        if love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift") then
            self:_move(0, -1)
        else
            self:_move(0, 1)
        end
        self.cursor_sub = 1
        return true
    end
    if key == "pageup"   then self:_move(-16, 0); return true end
    if key == "pagedown" then self:_move( 16, 0); return true end
    if key == "home"     then self.cursor_row = 0;  self:_clamp_scroll(rect); return true end
    if key == "end"      then self.cursor_row = pat.rows - 1; self:_clamp_scroll(rect); return true end

    -- Octave
    if key == "f5" then self.octave = math.max(0, self.octave - 1); return true end
    if key == "f6" then self.octave = math.min(9, self.octave + 1); return true end

    -- Step
    if key == "f1" then self.step = 1; return true end
    if key == "f2" then self.step = 2; return true end
    if key == "f3" then self.step = 4; return true end
    if key == "f4" then self.step = 8; return true end

    -- Delete / clear
    if key == "delete" or key == "backspace" then
        if self.cursor_sub == 1 then
            pat:set_cell(self.cursor_row, self.cursor_col, nil)
        else
            -- Clear just the active sub-field
            local cell = pat:get_cell(self.cursor_row, self.cursor_col)
            if cell then
                local sub = SUBCOLS[self.cursor_sub]
                if sub == "vol" then cell.vol = 255
                elseif sub == "fx1" then cell.fx1_cmd = 0; cell.fx1_val = 0
                elseif sub == "fx2" then cell.fx2_cmd = 0; cell.fx2_val = 0
                end
            end
        end
        self:_move(self.step, 0)
        return true
    end

    -- Note OFF
    if key == "1" then
        pat:set_note(self.cursor_row, self.cursor_col, Event.NOTE_OFF)
        self:_move(self.step, 0)
        return true
    end

    -- Note entry via QWERTY piano
    if self.cursor_sub == 1 then
        local semi = KEY_NOTES[key]
        if semi then
            local midi = (self.octave + 1) * 12 + semi
            midi = math.max(0, math.min(127, midi))
            pat:set_note(self.cursor_row, self.cursor_col, midi, nil, 255)
            self:_move(self.step, 0)
            return true
        end
    end

    return false
end

function PatternEditor:_move(dr, dc)
    local pat = self.pattern
    if not pat then return end
    self.cursor_row = (self.cursor_row + dr) % pat.rows
    self.cursor_col = (self.cursor_col + dc + pat.channels) % pat.channels
    self:_clamp_scroll(nil)
end

function PatternEditor:_clamp_scroll(rect)
    local pat = self.pattern
    if not pat then return end
    -- Estimate visible rows/cols
    local vis_rows = 24
    local vis_cols = 4
    if rect then
        local grid_h = rect.h - TOOLBAR_H - HEADER_H - STATUS_H
        vis_rows = math.max(1, math.floor(grid_h / Theme.cell_h))
        vis_cols = math.max(1, math.floor((rect.w - ROW_NUM_W - SCROLLBAR) / CELL_W))
    end

    if self.cursor_row < self.scroll_row then
        self.scroll_row = self.cursor_row
    elseif self.cursor_row >= self.scroll_row + vis_rows then
        self.scroll_row = self.cursor_row - vis_rows + 1
    end
    if self.cursor_col < self.scroll_col then
        self.scroll_col = self.cursor_col
    elseif self.cursor_col >= self.scroll_col + vis_cols then
        self.scroll_col = self.cursor_col - vis_cols + 1
    end
    self.scroll_row = math.max(0, self.scroll_row)
    self.scroll_col = math.max(0, self.scroll_col)
end

return PatternEditor
