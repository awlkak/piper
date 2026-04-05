-- UI Root
-- Manages layout, view switching (mobile tabs / desktop split),
-- and dispatches input events to the active views.

local Theme        = require("src.ui.theme")
local Widgets      = require("src.ui.widgets")
local Input        = require("src.ui.input")
local PatternEditor = require("src.ui.views.pattern_editor")
local PatchGraph   = require("src.ui.views.patch_graph")
local SongArranger = require("src.ui.views.song_arranger")

local HAS_CURSOR = love.mouse ~= nil and love.mouse.getSystemCursor ~= nil

local UI = {}

-- Views
local views = {}
local layout = {}
local is_mobile = false
local active_tab = 1   -- 1=pattern, 2=graph, 3=song
local TABS = { "Pattern", "Graph", "Song" }

-- Resizable layout: stored as fractions [0..1]
local split = {
    graph_w  = 0.28,   -- fraction of total width for patch graph
    arr_h    = 0.28,   -- fraction of (h - tb_h) for song arranger
}
local DIVIDER_W = 6   -- hit target width for dividers

-- Divider drag state
local divider_drag = nil  -- { which="v"|"h", start_x, start_y, start_frac }

-- Transport bar (top)
local transport = {
    playing      = false,
    loop_pattern = false,
    bpm          = 120,
    speed        = 6,
    order_pos    = 1,
    row          = 0,
    song         = nil,
    -- Jump-to input state
    jump_open    = false,
    jump_str     = "",
}

-- Callbacks injected by app.lua
local on_play         = nil
local on_stop         = nil
local on_save         = nil
local on_new          = nil
local on_open         = nil
local on_restart      = nil
local on_loop_toggle  = nil
local on_seek         = nil

function UI.set_callbacks(play_fn, stop_fn, save_fn, new_fn, open_fn,
                          restart_fn, loop_fn, seek_fn)
    on_play        = play_fn
    on_stop        = stop_fn
    on_save        = save_fn
    on_new         = new_fn
    on_open        = open_fn
    on_restart     = restart_fn
    on_loop_toggle = loop_fn
    on_seek        = seek_fn
end

-- Project file picker modal state
local fp = {
    open      = false,
    mode      = nil,   -- "open" or "save"
    files     = {},
    scroll    = 0,
    selected  = nil,
    filename  = "",
    typing    = false,
}
local FP_W, FP_H, FP_ROW = 400, 300, 22

local function fp_scan()
    fp.files = {}
    local seen = {}
    local function scan(dir, prefix)
        local items = love.filesystem.getDirectoryItems(dir) or {}
        for _, name in ipairs(items) do
            if name:match("%.piper$") then
                local full = prefix ~= "" and (prefix .. "/" .. name) or name
                if not seen[full] then
                    seen[full] = true
                    table.insert(fp.files, full)
                end
            end
        end
    end
    scan("", "")          -- save dir root
    scan("songs", "songs") -- songs/ subdir (save dir and source dir both searched by Love2D)
    table.sort(fp.files)
end

local function fp_open(mode, default_name)
    fp.open     = true
    fp.mode     = mode
    fp.scroll   = 0
    fp.selected = nil
    fp.filename = (mode == "save") and (default_name or "untitled.piper") or ""
    fp.typing   = (mode == "save")  -- auto-focus filename field on save
    fp_scan()
end

local function fp_close()
    fp.open = false
end

function UI.set_graph_callbacks(on_add, on_del, on_add_edge, on_del_edge)
    if views.graph then
        views.graph:set_callbacks(on_add, on_del, on_add_edge, on_del_edge)
    end
end

function UI.load()
    Theme.load()
    views.pattern  = PatternEditor.new()
    views.graph    = PatchGraph.new()
    views.arranger = SongArranger.new()
end

function UI.set_song(song)
    transport.song = song
    transport.bpm  = song.bpm
    transport.speed = song.speed
    views.pattern:set_pattern(
        song:pattern_at(1), song, 1)
    views.arranger:set_song(song)
    views.arranger:set_on_select(function(id, pat, order_pos)
        views.pattern:set_pattern(pat, song, order_pos or 1)
    end)
end

function UI.set_playing(playing)
    transport.playing = playing
end

function UI.set_playhead(order_pos, row)
    transport.order_pos = order_pos
    transport.row       = row
    views.pattern:set_playhead(order_pos, row)
    views.arranger:set_playhead(order_pos)
end

function UI.set_loop_pattern(enabled)
    transport.loop_pattern = enabled
end

function UI.resize(w, h)
    is_mobile = (w < 800)
    Theme.apply_dpi(w, h)
    UI._compute_layout(w, h)
end

function UI._compute_layout(w, h)
    local tb_h  = 32
    local tab_h = Theme.tab_bar_h

    if is_mobile then
        layout.transport   = { x=0, y=0, w=w, h=tb_h }
        layout.tab_bar     = { x=0, y=h - tab_h, w=w, h=tab_h }
        local content_h    = h - tb_h - tab_h
        layout.pattern     = { x=0, y=tb_h, w=w, h=content_h }
        layout.graph       = { x=0, y=tb_h, w=w, h=content_h }
        layout.arranger    = { x=0, y=tb_h, w=w, h=content_h }
        layout.div_v       = nil
        layout.div_h       = nil
    else
        local graph_w = math.floor(w * math.max(0.15, math.min(0.6, split.graph_w)))
        local right_w = w - graph_w
        local avail_h = h - tb_h
        local arr_h   = math.floor(avail_h * math.max(0.1, math.min(0.6, split.arr_h)))
        local pat_h   = avail_h - arr_h

        layout.transport = { x=0,       y=0,          w=w,       h=tb_h   }
        layout.graph     = { x=0,       y=tb_h,       w=graph_w, h=avail_h}
        layout.pattern   = { x=graph_w, y=tb_h,       w=right_w, h=pat_h  }
        layout.arranger  = { x=graph_w, y=tb_h+pat_h, w=right_w, h=arr_h  }
        layout.tab_bar   = nil
        -- Divider rects (used for hit testing and drawing)
        layout.div_v = { x=graph_w - DIVIDER_W/2, y=tb_h, w=DIVIDER_W, h=avail_h }
        layout.div_h = { x=graph_w, y=tb_h+pat_h - DIVIDER_W/2, w=right_w, h=DIVIDER_W }
    end
end

function UI.draw()
    local w, h = love.graphics.getDimensions()
    if not layout.transport then UI._compute_layout(w, h) end

    -- Transport bar
    UI._draw_transport(layout.transport)

    -- Views
    if is_mobile then
        if active_tab == 1 then views.pattern:draw(layout.pattern)
        elseif active_tab == 2 then views.graph:draw(layout.graph)
        elseif active_tab == 3 then views.arranger:draw(layout.arranger)
        end
        if layout.tab_bar then
            UI._draw_tab_bar(layout.tab_bar)
        end
    else
        views.graph:draw(layout.graph)
        views.pattern:draw(layout.pattern)
        views.arranger:draw(layout.arranger)
        -- Panel dividers
        UI._draw_dividers()
    end

    -- Patch graph overlays (param editor floats above all panels)
    if views.graph then views.graph:draw_overlay() end

    -- File picker modal (drawn on top of everything)
    UI._draw_file_picker()
end

function UI._draw_dividers()
    if not layout.div_v then return end
    local mx, my = love.mouse.getPosition()

    -- Vertical divider (between graph and right panels)
    local dv = layout.div_v
    local hov_v = Widgets.hit(mx, my, dv.x, dv.y, dv.w, dv.h)
        or (divider_drag and divider_drag.which == "v")
    love.graphics.setColor(hov_v and 0.45 or 0.2, hov_v and 0.55 or 0.25, hov_v and 0.45 or 0.2, 1)
    love.graphics.rectangle("fill", dv.x, dv.y, dv.w, dv.h)
    -- Grip dots
    love.graphics.setColor(0.6, 0.7, 0.6, 0.7)
    local mid_y = dv.y + dv.h * 0.5
    for i = -2, 2 do
        love.graphics.circle("fill", dv.x + dv.w * 0.5, mid_y + i * 5, 1.5)
    end

    -- Horizontal divider (between pattern and arranger)
    local dh = layout.div_h
    local hov_h = Widgets.hit(mx, my, dh.x, dh.y, dh.w, dh.h)
        or (divider_drag and divider_drag.which == "h")
    love.graphics.setColor(hov_h and 0.45 or 0.2, hov_h and 0.55 or 0.25, hov_h and 0.45 or 0.2, 1)
    love.graphics.rectangle("fill", dh.x, dh.y, dh.w, dh.h)
    local mid_x = dh.x + dh.w * 0.5
    love.graphics.setColor(0.6, 0.7, 0.6, 0.7)
    for i = -2, 2 do
        love.graphics.circle("fill", mid_x + i * 5, dh.y + dh.h * 0.5, 1.5)
    end

    -- Set resize cursor when hovering dividers
    if HAS_CURSOR then
        if hov_v then
            love.mouse.setCursor(love.mouse.getSystemCursor("sizewe"))
        elseif hov_h then
            love.mouse.setCursor(love.mouse.getSystemCursor("sizens"))
        elseif not divider_drag then
            love.mouse.setCursor(love.mouse.getSystemCursor("arrow"))
        end
    end
end

function UI._draw_transport(r)
    Theme.set(Theme.bg_header)
    love.graphics.rectangle("fill", r.x, r.y, r.w, r.h)
    Theme.set(Theme.border)
    love.graphics.line(r.x, r.y + r.h, r.x + r.w, r.y + r.h)

    local x  = r.x + 6
    local bh = r.h - 8
    local by = r.y + 4

    -- Play/Stop
    Widgets.button(transport.playing and "■" or "▶",
                   x, by, 30, bh, false, transport.playing, Theme.font_small)
    x = x + 34

    -- Restart (|◀)
    Widgets.button("|◀", x, by, 26, bh, false, false, Theme.font_small)
    x = x + 30

    -- Loop pattern toggle
    Widgets.button("⟳", x, by, 26, bh, false, transport.loop_pattern, Theme.font_small)
    x = x + 30

    -- Separator
    love.graphics.setColor(0.3, 0.3, 0.3, 1)
    love.graphics.line(x + 3, by, x + 3, by + bh)
    x = x + 10

    -- Position display: "slot/total row" — clickable to open jump input
    local pos_str
    if transport.jump_open then
        pos_str = "▸" .. transport.jump_str .. "|"
    else
        local total = transport.song and #transport.song.order or 0
        pos_str = string.format("%d/%d r%d", transport.order_pos, total, transport.row)
    end
    local pos_col = transport.jump_open and Theme.accent or Theme.text
    Widgets.button(pos_str, x, by, 72, bh, false, transport.jump_open, Theme.font_small)
    x = x + 76

    -- Separator
    love.graphics.setColor(0.3, 0.3, 0.3, 1)
    love.graphics.line(x + 3, by, x + 3, by + bh)
    x = x + 10

    -- BPM / Speed (read live from song so edits reflect immediately)
    local disp_bpm   = transport.song and transport.song.bpm   or transport.bpm
    local disp_speed = transport.song and transport.song.speed or transport.speed
    Widgets.label(string.format("BPM:%d  SPD:%d", disp_bpm, disp_speed),
                  x, r.y, 100, r.h, Theme.text_dim, Theme.font_small)
    x = x + 104

    -- Title
    Widgets.label("PIPER", x, r.y, 46, r.h, Theme.accent, Theme.font_medium, "left")
    x = x + 50

    -- File buttons
    Widgets.button("NEW",  x,      by, 36, bh, false, false, Theme.font_small)
    Widgets.button("OPEN", x + 40, by, 40, bh, false, false, Theme.font_small)
    Widgets.button("SAVE", x + 84, by, 40, bh, false, false, Theme.font_small)
end

function UI._draw_file_picker()
    if not fp.open then return end
    local sw, sh = love.graphics.getDimensions()
    -- Dim overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, sw, sh)

    local rx = math.floor((sw - FP_W) / 2)
    local ry = math.floor((sh - FP_H) / 2)

    -- Panel background
    love.graphics.setColor(Theme.bg_panel[1], Theme.bg_panel[2],
                           Theme.bg_panel[3], 1)
    love.graphics.rectangle("fill", rx, ry, FP_W, FP_H, 4, 4)
    love.graphics.setColor(Theme.border[1], Theme.border[2], Theme.border[3], 1)
    love.graphics.rectangle("line", rx, ry, FP_W, FP_H, 4, 4)

    -- Title
    love.graphics.setColor(Theme.text[1], Theme.text[2], Theme.text[3], 1)
    love.graphics.setFont(Theme.font_medium)
    local title = fp.mode == "save" and "Save Project" or "Open Project"
    love.graphics.print(title, rx + 8, ry + 8)

    -- Close button
    Widgets.button("X", rx + FP_W - 28, ry + 6, 22, 18, false, false, Theme.font_small)

    -- File list area
    local list_y  = ry + 32
    local list_h  = FP_H - 32 - 60
    local visible = math.floor(list_h / FP_ROW)
    love.graphics.setScissor(rx + 2, list_y, FP_W - 4, list_h)
    for i, name in ipairs(fp.files) do
        local fy = list_y + (i - 1 - fp.scroll) * FP_ROW
        if fy >= list_y - FP_ROW and fy < list_y + list_h then
            local sel = (fp.selected == i)
            if sel then
                love.graphics.setColor(Theme.accent[1], Theme.accent[2],
                                       Theme.accent[3], 0.3)
                love.graphics.rectangle("fill", rx + 2, fy, FP_W - 4, FP_ROW)
            end
            love.graphics.setColor(sel and Theme.accent or Theme.text)
            love.graphics.setFont(Theme.font_mono)
            love.graphics.print(name, rx + 6, fy + 3)
        end
    end
    love.graphics.setScissor()

    -- Filename input (save mode)
    local bot_y = ry + FP_H - 56
    if fp.mode == "save" then
        love.graphics.setColor(Theme.text_dim[1], Theme.text_dim[2],
                               Theme.text_dim[3], 1)
        love.graphics.setFont(Theme.font_small)
        love.graphics.print("Filename:", rx + 8, bot_y + 4)
        -- text box
        love.graphics.setColor(Theme.bg[1], Theme.bg[2], Theme.bg[3], 1)
        love.graphics.rectangle("fill", rx + 70, bot_y, FP_W - 78, 22, 2, 2)
        love.graphics.setColor(fp.typing and Theme.accent or Theme.border)
        love.graphics.rectangle("line", rx + 70, bot_y, FP_W - 78, 22, 2, 2)
        love.graphics.setColor(Theme.text[1], Theme.text[2], Theme.text[3], 1)
        love.graphics.setFont(Theme.font_mono)
        local display = fp.filename .. (fp.typing and "|" or "")
        love.graphics.print(display, rx + 74, bot_y + 3)
    end

    -- OK / Cancel buttons
    local btn_y = ry + FP_H - 28
    Widgets.button(fp.mode == "save" and "Save" or "Open",
                   rx + FP_W - 120, btn_y, 52, 22, false, false, Theme.font_small)
    Widgets.button("Cancel", rx + FP_W - 62, btn_y, 56, 22, false, false, Theme.font_small)
end

function UI._draw_tab_bar(r)
    Widgets.tab_bar(r.x, r.y, r.w, r.h, TABS, active_tab)
end

-- Commit the file picker action
local function fp_commit()
    if fp.mode == "open" and fp.selected then
        local path = fp.files[fp.selected]
        fp_close()
        if on_open then on_open(path) end
    elseif fp.mode == "save" then
        local name = fp.filename
        if name == "" then name = "untitled.piper" end
        if not name:match("%.piper$") then name = name .. ".piper" end
        -- Save into songs/ unless the user typed an explicit path
        if not name:match("/") then name = "songs/" .. name end
        fp_close()
        if on_save then on_save(name) end
    end
end

-- Handle input events
function UI.handle_events()
    local events = Input.drain()
    for _, ev in ipairs(events) do

        -- File picker eats all input when open
        if fp.open then
            local sw, sh = love.graphics.getDimensions()
            local rx = math.floor((sw - FP_W) / 2)
            local ry = math.floor((sh - FP_H) / 2)

            if ev.type == "key_down" then
                local k = ev.key
                if k == "escape" then
                    fp_close()
                elseif k == "return" or k == "kpenter" then
                    fp_commit()
                elseif fp.mode == "save" and fp.typing then
                    if k == "backspace" then
                        fp.filename = fp.filename:sub(1, -2)
                    end
                end
            elseif ev.type == "text" and fp.mode == "save" and fp.typing then
                fp.filename = fp.filename .. ev.text
            elseif ev.type == "pointer_down" then
                local ex, ey = ev.x, ev.y
                -- Close button
                if Widgets.hit(ex, ey, rx + FP_W - 28, ry + 6, 22, 18) then
                    fp_close()
                    goto next_event
                end
                -- OK button
                local btn_y = ry + FP_H - 28
                if Widgets.hit(ex, ey, rx + FP_W - 120, btn_y, 52, 22) then
                    fp_commit()
                    goto next_event
                end
                -- Cancel button
                if Widgets.hit(ex, ey, rx + FP_W - 62, btn_y, 56, 22) then
                    fp_close()
                    goto next_event
                end
                -- Filename text box (save mode)
                if fp.mode == "save" then
                    local bot_y = ry + FP_H - 56
                    if Widgets.hit(ex, ey, rx + 70, bot_y, FP_W - 78, 22) then
                        fp.typing = true
                        goto next_event
                    else
                        fp.typing = false
                    end
                end
                -- File list
                local list_y = ry + 32
                local list_h = FP_H - 32 - 60
                if Widgets.hit(ex, ey, rx + 2, list_y, FP_W - 4, list_h) then
                    local rel_y = ey - list_y
                    local idx   = math.floor(rel_y / FP_ROW) + 1 + fp.scroll
                    if idx >= 1 and idx <= #fp.files then
                        fp.selected = idx
                        if fp.mode == "save" then
                            -- Populate filename from selection
                            local name = fp.files[idx]
                            name = name:match("([^/]+)$") or name
                            fp.filename = name
                        end
                    end
                    goto next_event
                end
            elseif ev.type == "wheel" then
                local max_scroll = math.max(0, #fp.files - math.floor((FP_H - 32 - 60) / FP_ROW))
                fp.scroll = math.max(0, math.min(max_scroll, fp.scroll - ev.dy))
            end
            goto next_event  -- swallow all events when picker is open
        end

        -- Divider drag: pointer_move and pointer_up are global
        if divider_drag then
            if ev.type == "pointer_move" then
                local w, h = love.graphics.getDimensions()
                local tb_h = 32
                if divider_drag.which == "v" then
                    local new_frac = (ev.x) / w
                    split.graph_w = math.max(0.15, math.min(0.6, new_frac))
                else
                    local new_frac = (ev.y - tb_h) / (h - tb_h)
                    split.arr_h   = math.max(0.1, math.min(0.6, 1.0 - new_frac))
                end
                UI._compute_layout(w, h)
                goto next_event
            elseif ev.type == "pointer_up" then
                divider_drag = nil
                if HAS_CURSOR then
                    love.mouse.setCursor(love.mouse.getSystemCursor("arrow"))
                end
                goto next_event
            end
        end

        -- Divider drag start
        if ev.type == "pointer_down" and not is_mobile then
            if layout.div_v and Widgets.hit(ev.x, ev.y,
                    layout.div_v.x, layout.div_v.y, layout.div_v.w, layout.div_v.h) then
                divider_drag = { which="v" }
                goto next_event
            end
            if layout.div_h and Widgets.hit(ev.x, ev.y,
                    layout.div_h.x, layout.div_h.y, layout.div_h.w, layout.div_h.h) then
                divider_drag = { which="h" }
                goto next_event
            end
        end

        -- Dismiss jump input on click outside transport
        if transport.jump_open and ev.type == "pointer_down" and layout.transport then
            if not Widgets.hit(ev.x, ev.y, layout.transport.x, layout.transport.y,
                               layout.transport.w, layout.transport.h) then
                transport.jump_open = false
                transport.jump_str  = ""
            end
        end

        -- Jump-to input: key handling (text + confirm/cancel)
        if transport.jump_open then
            if ev.type == "key_down" then
                local k = ev.key
                if k == "return" or k == "kpenter" then
                    local n = tonumber(transport.jump_str)
                    local total = transport.song and #transport.song.order or 0
                    if n and n >= 1 and n <= total then
                        if on_seek then on_seek(n) end
                    end
                    transport.jump_open = false
                    transport.jump_str  = ""
                    goto next_event
                elseif k == "escape" then
                    transport.jump_open = false
                    transport.jump_str  = ""
                    goto next_event
                elseif k == "backspace" then
                    transport.jump_str = transport.jump_str:sub(1, -2)
                    goto next_event
                end
            elseif ev.type == "text" then
                if ev.text:match("%d") then
                    transport.jump_str = transport.jump_str .. ev.text
                end
                goto next_event
            end
        end

        -- Transport bar interactions
        if ev.type == "pointer_down" and layout.transport then
            local r = layout.transport
            if Widgets.hit(ev.x, ev.y, r.x, r.y, r.w, r.h) then
                local x  = r.x + 6
                local bh = r.h - 8
                local by = r.y + 4

                -- Play/Stop
                if Widgets.hit(ev.x, ev.y, x, by, 30, bh) then
                    if transport.playing then
                        if on_stop then on_stop() end
                        transport.playing = false
                    else
                        if on_play then on_play() end
                        transport.playing = true
                    end
                    transport.jump_open = false
                    goto next_event
                end
                x = x + 34

                -- Restart
                if Widgets.hit(ev.x, ev.y, x, by, 26, bh) then
                    if on_restart then on_restart() end
                    transport.playing = true
                    transport.jump_open = false
                    goto next_event
                end
                x = x + 30

                -- Loop pattern toggle
                if Widgets.hit(ev.x, ev.y, x, by, 26, bh) then
                    transport.loop_pattern = not transport.loop_pattern
                    if on_loop_toggle then on_loop_toggle(transport.loop_pattern) end
                    goto next_event
                end
                x = x + 30 + 10  -- +separator

                -- Position / jump
                if Widgets.hit(ev.x, ev.y, x, by, 72, bh) then
                    transport.jump_open = not transport.jump_open
                    transport.jump_str  = ""
                    goto next_event
                end
                x = x + 76 + 10  -- +separator + bpmspd(104) + title(50)
                x = x + 104 + 50

                -- NEW / OPEN / SAVE
                if Widgets.hit(ev.x, ev.y, x, by, 36, bh) then
                    transport.jump_open = false
                    if on_new then on_new() end
                    goto next_event
                elseif Widgets.hit(ev.x, ev.y, x + 40, by, 40, bh) then
                    transport.jump_open = false
                    fp_open("open")
                    goto next_event
                elseif Widgets.hit(ev.x, ev.y, x + 84, by, 40, bh) then
                    transport.jump_open = false
                    fp_open("save")
                    goto next_event
                end
            end
        end

        -- Tab bar (mobile)
        if ev.type == "pointer_down" and is_mobile and layout.tab_bar then
            local r = layout.tab_bar
            if Widgets.hit(ev.x, ev.y, r.x, r.y, r.w, r.h) then
                local tw = math.floor(r.w / #TABS)
                for i = 1, #TABS do
                    local tx = r.x + (i - 1) * tw
                    if Widgets.hit(ev.x, ev.y, tx, r.y, tw, r.h) then
                        active_tab = i
                        break
                    end
                end
                goto next_event
            end
        end

        -- Patch graph overlay events (param editor — floats above all views)
        if views.graph and views.graph:handle_overlay_event(ev) then
            goto next_event
        end

        -- Dispatch to views
        if is_mobile then
            if active_tab == 1 then views.pattern:handle_event(ev, layout.pattern)
            elseif active_tab == 2 then views.graph:handle_event(ev, layout.graph)
            elseif active_tab == 3 then views.arranger:handle_event(ev, layout.arranger)
            end
        else
            -- Desktop: arranger modal (mach_pick) gets priority over all other views
            if views.arranger.mach_pick then
                views.arranger:handle_event(ev, layout.arranger)
            elseif not views.graph:handle_event(ev, layout.graph) then
                if not views.pattern:handle_event(ev, layout.pattern) then
                    views.arranger:handle_event(ev, layout.arranger)
                end
            end
        end

        ::next_event::
    end
end

-- Open the save file dialog (callable from app.lua for Ctrl+S / Ctrl+Shift+S)
-- default_name: optional filename to pre-populate (just the basename, no path)
function UI.open_save_dialog(default_name)
    fp_open("save", default_name)
end

-- Expose active pattern editor (for external sync)
function UI.pattern_editor() return views.pattern end
function UI.patch_graph()    return views.graph    end
function UI.song_arranger()  return views.arranger end

return UI
