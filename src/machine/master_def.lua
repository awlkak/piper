-- Master output node definition.
-- Provides a GUI with oscilloscope and stereo level meters.
-- Not loaded via the plugin browser; attached directly to the master DAG node at init.

return {
    type = "master",
    name = "Master",

    gui = {
        height = 80,
        width  = 160,

        draw = function(ctx, state)
            local samples = state.scope_samples or {}
            local peak_l  = state.peak_l      or 0
            local peak_r  = state.peak_r      or 0
            local hold_l  = state.peak_hold_l or 0
            local hold_r  = state.peak_hold_r or 0
            local T       = ctx.theme

            -- Background
            ctx.rect(0, 0, ctx.w, ctx.h, {0.07, 0.06, 0.04, 1}, nil)

            local pad     = 4
            local scope_w = math.floor(ctx.w * 0.56)
            local meter_x = scope_w + 4
            local meter_w = ctx.w - meter_x - pad

            -- ── Oscilloscope ─────────────────────────────────────────
            ctx.rect(0, 0, scope_w, ctx.h, {0.05, 0.05, 0.05, 1},
                     {0.18, 0.14, 0.06, 0.5})
            -- Zero line
            ctx.line(1, ctx.h * 0.5, scope_w - 1, ctx.h * 0.5,
                     {0.22, 0.20, 0.12, 0.5}, 1)
            -- Waveform
            if #samples >= 2 then
                local pts = {}
                local n   = #samples
                for i, v in ipairs(samples) do
                    pts[#pts + 1] = (i - 1) / (n - 1) * (scope_w - 2) + 1
                    pts[#pts + 1] = ctx.h * 0.5 - v * (ctx.h * 0.44)
                end
                ctx.plot(pts, {0.40, 1.00, 0.40, 0.90}, 1)
            end

            -- ── Stereo level meters ───────────────────────────────────
            local bar_w = math.floor((meter_w - 3) / 2)
            local bar_h = ctx.h - pad * 2

            local function draw_meter(bx, peak, hold, label)
                -- Trough
                ctx.rect(bx, pad, bar_w, bar_h,
                         {0.10, 0.10, 0.10, 1}, {0.22, 0.18, 0.10, 0.6})
                -- Fill bar (bottom-anchored)
                local frac   = math.max(0, math.min(1, peak))
                local fill_h = math.floor(bar_h * frac)
                if fill_h > 0 then
                    local r = math.min(1, frac * 2)
                    local g = math.min(1, 2 - frac * 2)
                    ctx.rect(bx + 1, pad + bar_h - fill_h,
                             bar_w - 2, fill_h, {r, g, 0.05, 1}, nil)
                end
                -- Peak-hold tick
                local hy = pad + bar_h - math.floor(bar_h * math.min(1, hold))
                ctx.line(bx + 1, hy, bx + bar_w - 2, hy, {1, 0.80, 0.20, 0.85}, 1)
                -- Label
                ctx.label(label, bx, ctx.h - 10, bar_w, 10,
                          T.text_dim, T.font_small, "center")
            end

            draw_meter(meter_x,             peak_l, hold_l, "L")
            draw_meter(meter_x + bar_w + 3, peak_r, hold_r, "R")
        end,
    },
}
