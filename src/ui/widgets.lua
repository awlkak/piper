-- UI Widgets: reusable drawing primitives
-- All draw functions take explicit x,y,w,h to avoid global state.

local Theme = require("src.ui.theme")

local W = {}

-- Draw a filled + outlined rectangle
function W.rect(x, y, w, h, fill_color, border_color, radius)
    radius = radius or 0
    if fill_color then
        Theme.set(fill_color)
        if radius > 0 then
            love.graphics.rectangle("fill", x, y, w, h, radius, radius)
        else
            love.graphics.rectangle("fill", x, y, w, h)
        end
    end
    if border_color then
        Theme.set(border_color)
        if radius > 0 then
            love.graphics.rectangle("line", x, y, w, h, radius, radius)
        else
            love.graphics.rectangle("line", x, y, w, h)
        end
    end
end

-- Draw text clipped to a rectangle (no actual scissor; just truncate)
function W.label(text, x, y, w, h, color, font, align)
    font  = font  or Theme.font_medium
    color = color or Theme.text
    align = align or "left"
    love.graphics.setFont(font)
    Theme.set(color)
    love.graphics.printf(text, x + 2, y + (h - (font:getHeight())) * 0.5, w - 4, align)
end

-- Draw a button; returns true if clicked this frame.
-- hovered and pressed are booleans passed in from the input state.
function W.button(text, x, y, w, h, hovered, pressed, font)
    local bg = pressed and Theme.btn_active
               or (hovered and Theme.btn_hover or Theme.btn_bg)
    W.rect(x, y, w, h, bg, Theme.border, 3)
    W.label(text, x, y, w, h, Theme.btn_text, font or Theme.font_medium, "center")
end

-- Draw a horizontal slider; returns the new value if dragged.
-- value is in [min, max].
function W.slider(x, y, w, h, value, min_val, max_val, hovered)
    local t = (value - min_val) / (max_val - min_val)
    W.rect(x, y, w, h, Theme.bg_panel, Theme.border)
    local fill_w = math.floor(t * (w - 4))
    if fill_w > 0 then
        local c = hovered and Theme.accent2 or Theme.accent
        W.rect(x + 2, y + 2, fill_w, h - 4, c, nil)
    end
    -- Thumb
    local tx = x + 2 + fill_w - 4
    W.rect(tx, y + 1, 8, h - 2, Theme.btn_text, nil, 2)
end

-- Draw a knob (circular representation)
function W.knob(x, y, r, value, min_val, max_val, label_text, hovered)
    local t    = (value - min_val) / (max_val - min_val)
    local start = math.pi * 0.75
    local range = math.pi * 1.5
    local angle = start + t * range

    -- Background circle
    Theme.set(Theme.bg_panel)
    love.graphics.circle("fill", x, y, r)
    Theme.set(hovered and Theme.border_focus or Theme.border)
    love.graphics.circle("line", x, y, r)

    -- Arc fill
    local steps = 20
    local prev_x, prev_y = x + r * math.cos(start), y + r * math.sin(start)
    Theme.set(Theme.accent)
    love.graphics.setLineWidth(2)
    for i = 1, steps do
        local a = start + (i / steps) * (angle - start)
        local nx = x + r * math.cos(a)
        local ny = y + r * math.sin(a)
        love.graphics.line(prev_x, prev_y, nx, ny)
        prev_x, prev_y = nx, ny
    end
    love.graphics.setLineWidth(1)

    -- Pointer line
    Theme.set(Theme.text)
    local px = x + (r - 3) * math.cos(angle)
    local py = y + (r - 3) * math.sin(angle)
    love.graphics.line(x, y, px, py)

    if label_text then
        W.label(label_text, x - r, y + r + 1, r * 2, 12,
                Theme.text_dim, Theme.font_small, "center")
    end
end

-- Draw a vertical scrollbar; returns the new scroll offset if dragged.
-- content_h > view_h triggers scrolling.
function W.scrollbar(x, y, w, h, scroll_offset, content_h, view_h)
    if content_h <= view_h then return scroll_offset end
    W.rect(x, y, w, h, Theme.scrollbar_bg, nil)
    local ratio  = view_h / content_h
    local thumb_h = math.max(20, math.floor(h * ratio))
    local max_off = content_h - view_h
    local thumb_y = y + math.floor((scroll_offset / max_off) * (h - thumb_h))
    W.rect(x + 1, thumb_y, w - 2, thumb_h, Theme.scrollbar_thumb, nil, 2)
    return scroll_offset
end

-- Hit test: returns true if (px, py) is inside rectangle
function W.hit(px, py, x, y, w, h)
    return px >= x and px < x + w and py >= y and py < y + h
end

-- Draw a tab bar; returns the index of the selected tab.
-- tabs = list of label strings
function W.tab_bar(x, y, w, h, tabs, active_idx)
    W.rect(x, y, w, h, Theme.tab_bg, nil)
    local tw = math.floor(w / #tabs)
    for i, label in ipairs(tabs) do
        local tx = x + (i - 1) * tw
        local is_active = (i == active_idx)
        W.rect(tx, y, tw, h,
               is_active and Theme.tab_active or nil,
               is_active and Theme.border_focus or Theme.border)
        W.label(label, tx, y, tw, h,
                is_active and Theme.tab_active_text or Theme.tab_text,
                Theme.font_medium, "center")
    end
    return active_idx
end

-- Draw a text input field (no actual editing logic; just display)
function W.text_field(x, y, w, h, text, focused)
    W.rect(x, y, w, h, Theme.bg_panel, focused and Theme.border_focus or Theme.border, 2)
    W.label(text, x + 2, y, w - 4, h, Theme.text, Theme.font_mono)
    if focused then
        -- Cursor blink
        local cx = x + 4 + (Theme.font_mono and Theme.font_mono:getWidth(text) or 0)
        if math.floor(love.timer.getTime() * 2) % 2 == 0 then
            Theme.set(Theme.text)
            love.graphics.rectangle("fill", cx, y + 3, 1, h - 6)
        end
    end
end

return W
