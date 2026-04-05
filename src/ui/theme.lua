-- Theme: colors, fonts, sizing constants
-- All sizes are in logical pixels; scaled by DPI in ui.lua on resize.

local Theme = {}

-- Colors (RGBA, 0..1)
Theme.bg              = {0.08, 0.08, 0.10, 1}
Theme.bg_panel        = {0.11, 0.11, 0.14, 1}
Theme.bg_header       = {0.06, 0.06, 0.08, 1}

Theme.cell_empty      = {0.13, 0.13, 0.17, 1}
Theme.cell_empty_alt  = {0.10, 0.10, 0.14, 1}  -- alternate row
Theme.cell_note       = {0.15, 0.38, 0.65, 1}
Theme.cell_note_off   = {0.55, 0.15, 0.15, 1}
Theme.cell_fx         = {0.15, 0.45, 0.25, 1}
Theme.cell_cursor     = {0.90, 0.65, 0.10, 1}
Theme.cell_playhead   = {0.30, 0.60, 0.30, 0.5}
Theme.cell_selected   = {0.30, 0.30, 0.55, 0.7}

Theme.accent          = {0.90, 0.65, 0.10, 1}
Theme.accent2         = {0.30, 0.70, 0.90, 1}
Theme.text            = {0.90, 0.90, 0.90, 1}
Theme.text_dim        = {0.50, 0.50, 0.55, 1}
Theme.text_header     = {0.70, 0.70, 0.80, 1}

Theme.border          = {0.20, 0.20, 0.25, 1}
Theme.border_focus    = {0.55, 0.45, 0.10, 1}

Theme.node_bg         = {0.14, 0.14, 0.20, 1}
Theme.node_border     = {0.30, 0.30, 0.45, 1}
Theme.node_selected   = {0.55, 0.45, 0.10, 1}
Theme.wire_signal     = {0.30, 0.70, 0.90, 1}
Theme.wire_control    = {0.80, 0.50, 0.20, 1}
Theme.pin_signal      = {0.30, 0.70, 0.90, 1}
Theme.pin_control     = {0.80, 0.50, 0.20, 1}

Theme.btn_bg          = {0.18, 0.18, 0.23, 1}
Theme.btn_hover       = {0.25, 0.25, 0.32, 1}
Theme.btn_active      = {0.35, 0.65, 0.20, 1}
Theme.btn_text        = {0.85, 0.85, 0.90, 1}

Theme.scrollbar_bg    = {0.10, 0.10, 0.13, 1}
Theme.scrollbar_thumb = {0.28, 0.28, 0.38, 1}

-- Tab bar
Theme.tab_bg          = {0.08, 0.08, 0.11, 1}
Theme.tab_active      = {0.18, 0.18, 0.24, 1}
Theme.tab_text        = {0.75, 0.75, 0.80, 1}
Theme.tab_active_text = {0.95, 0.90, 0.70, 1}

-- Desktop cell sizes
Theme.cell_w        = 110
Theme.cell_h        = 20
Theme.header_h      = 22
Theme.row_num_w     = 36
Theme.tab_bar_h     = 36
Theme.scrollbar_w   = 10
Theme.node_min_w    = 130
Theme.node_pin_r    = 5
Theme.node_padding  = 8

-- Mobile overrides (set in Theme.apply_dpi)
Theme.mobile_cell_h  = 34
Theme.mobile_tab_h   = 48

-- Font handles (set during love.load)
Theme.font_small  = nil
Theme.font_medium = nil
Theme.font_large  = nil
Theme.font_mono   = nil

function Theme.load()
    -- Load fonts; fall back to default if custom not found
    local function try_font(size)
        return love.graphics.newFont(size)
    end
    Theme.font_small  = try_font(10)
    Theme.font_medium = try_font(12)
    Theme.font_large  = try_font(15)
    Theme.font_mono   = try_font(11)
end

-- Call on resize to adjust sizes for DPI / mobile screen size
function Theme.apply_dpi(screen_w, screen_h)
    local dpi   = (love.window and love.window.getDPIScale and love.window.getDPIScale()) or 1
    local mobile = screen_w < 800

    if mobile then
        Theme.cell_h    = Theme.mobile_cell_h
        Theme.tab_bar_h = Theme.mobile_tab_h
    else
        Theme.cell_h    = 20
        Theme.tab_bar_h = 36
    end

    -- Scale node sizes by DPI
    Theme.node_pin_r  = math.max(4, math.floor(5 * dpi))
    Theme.node_padding = math.max(6, math.floor(8 * dpi))
end

-- Convenience: set love.graphics color from a theme color table
function Theme.set(color)
    love.graphics.setColor(color[1], color[2], color[3], color[4] or 1)
end

return Theme
