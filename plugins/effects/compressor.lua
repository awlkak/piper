-- Compressor
-- RMS-detecting feed-forward compressor with soft knee.

return {
    type    = "effect",
    name    = "Compressor",
    version = 1,

    inlets  = {
        { id = "in",  kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="threshold", label="Threshold (dB)", min=-60, max=0,   default=-12,  type="float" },
        { id="ratio",     label="Ratio",          min=1,   max=20,  default=4,    type="float" },
        { id="attack",    label="Attack (ms)",    min=0.1, max=200, default=10,   type="float" },
        { id="release",   label="Release (ms)",   min=1,   max=2000,default=100,  type="float" },
        { id="knee",      label="Knee (dB)",      min=0,   max=12,  default=3,    type="float" },
        { id="makeup",    label="Makeup (dB)",    min=0,   max=24,  default=0,    type="float" },
    },

    gui = {
        height = 60,
        draw = function(ctx, state)
            local thr    = state.threshold or -12
            local ratio  = state.ratio     or 4
            local makeup = state.makeup    or 0
            local gr     = state.gr_db     or 0   -- current gain reduction (negative dB)
            local T      = ctx.theme

            ctx.rect(0, 0, ctx.w, ctx.h, {0.07,0.07,0.10,1}, nil)

            -- Left 65%: transfer curve
            local tc_w = math.floor(ctx.w * 0.65)
            local tc_h = ctx.h
            local pad  = 6

            -- dB range shown: -60 to 0
            local db_min, db_max = -60, 0
            local function db_to_x(db) return pad + (db - db_min) / (db_max - db_min) * (tc_w - pad*2) end
            local function db_to_y(db) return tc_h - pad - (db - db_min) / (db_max - db_min) * (tc_h - pad*2) end

            -- 1:1 reference line (gray)
            ctx.line(db_to_x(db_min), db_to_y(db_min),
                     db_to_x(db_max), db_to_y(db_max),
                     {0.25,0.25,0.30,1}, 1)

            -- Compressed transfer curve
            local N   = math.max(2, math.floor(tc_w - pad*2))
            local pts = {}
            for i = 0, N do
                local in_db  = db_min + i / N * (db_max - db_min)
                local out_db
                if in_db <= thr then
                    out_db = in_db
                else
                    out_db = thr + (in_db - thr) / ratio
                end
                out_db = out_db + makeup
                out_db = math.max(db_min, math.min(db_max, out_db))
                pts[#pts+1] = db_to_x(in_db)
                pts[#pts+1] = db_to_y(out_db)
            end
            ctx.plot(pts, T.accent, 1.5)

            -- Threshold vertical marker
            ctx.line(db_to_x(thr), pad, db_to_x(thr), tc_h - pad, {0.60,0.40,0.10,0.6}, 1)

            -- Axis labels
            ctx.label(tostring(thr).."dB", db_to_x(thr)-12, tc_h-12, 28, 10,
                      {0.60,0.40,0.10,0.8}, T.font_small, "center")

            -- Right 35%: GR meter
            local mr_x = tc_w + 4
            local mr_w = ctx.w - mr_x - pad
            local mr_h = tc_h - pad*2

            ctx.rect(mr_x, pad, mr_w, mr_h, {0.10,0.10,0.13,1}, {0.20,0.20,0.25,1})
            ctx.label("GR", mr_x, pad-1, mr_w, 9, T.text_dim, T.font_small, "center")

            -- GR bar: gr is negative (e.g. -6 dB), bar fills from top
            local gr_range = 20  -- show 0 to -20 dB
            local gr_frac  = math.max(0, math.min(1, (-gr) / gr_range))
            local bar_h    = math.floor(mr_h * gr_frac)
            if bar_h > 0 then
                -- Color: green for low GR, yellow for medium, red for heavy
                local r2 = math.min(1, gr_frac * 2)
                local g2 = math.min(1, 2 - gr_frac * 2)
                ctx.rect(mr_x + 2, pad + 1, mr_w - 4, bar_h, {r2, g2, 0.1, 1}, nil)
            end

            -- GR value label
            local gr_str = string.format("%.1f", gr)
            ctx.label(gr_str, mr_x, pad + mr_h - 10, mr_w, 10, T.text, T.font_small, "center")
        end,
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local threshold = piper.db_to_amp(-12)
        local ratio     = 4.0
        local attack_c  = 0.0
        local release_c = 0.0
        local knee_db   = 3.0
        local makeup    = 1.0
        local thr_db    = -12.0

        local env_db    = -100.0  -- current detector level in dB
        local gr_db     = 0.0    -- current gain reduction in dB (updated each process block)
        local makeup_db = 0.0    -- makeup gain in dB (mirrored from set_param)

        local function update_time_constants()
            -- Coefficient for one-pole IIR: c = exp(-1 / (time_s * sr))
            local att_s = (attack_c  > 0) and (attack_c  / 1000.0) or 0.00001
            local rel_s = (release_c > 0) and (release_c / 1000.0) or 0.001
            attack_c  = math.exp(-1.0 / (att_s * sr))
            release_c = math.exp(-1.0 / (rel_s * sr))
        end

        -- Store raw ms values separately
        local att_ms  = 10.0
        local rel_ms  = 100.0

        local function recompute()
            local att_s = att_ms  / 1000.0
            local rel_s = rel_ms  / 1000.0
            attack_c  = math.exp(-1.0 / (math.max(0.0001, att_s)  * sr))
            release_c = math.exp(-1.0 / (math.max(0.001,  rel_s)  * sr))
        end

        function inst:init(sample_rate)
            sr = sample_rate
            recompute()
        end

        function inst:set_param(id, value)
            if id == "threshold" then
                thr_db    = value
            elseif id == "ratio" then
                ratio = math.max(1.001, value)
            elseif id == "attack" then
                att_ms = value; recompute()
            elseif id == "release" then
                rel_ms = value; recompute()
            elseif id == "knee" then
                knee_db = value
            elseif id == "makeup" then
                makeup_db = value
                makeup = piper.db_to_amp(value)
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local half_knee = knee_db * 0.5
            local last_gain_db = 0.0

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Peak detection (max of L/R)
                local peak = math.max(math.abs(inL), math.abs(inR))
                local peak_db = peak > 1e-6 and (20.0 * math.log(peak) / math.log(10)) or -100.0

                -- Smooth envelope follower
                if peak_db > env_db then
                    env_db = attack_c  * env_db + (1.0 - attack_c)  * peak_db
                else
                    env_db = release_c * env_db + (1.0 - release_c) * peak_db
                end

                -- Gain computation with soft knee
                local gain_db
                local over = env_db - thr_db
                if over <= -half_knee then
                    gain_db = 0.0
                elseif over >= half_knee then
                    gain_db = (1.0 - 1.0/ratio) * (-over)
                else
                    -- Soft knee
                    local t = (over + half_knee) / knee_db
                    gain_db = (1.0 - 1.0/ratio) * (-t * t * half_knee)
                end

                last_gain_db = gain_db
                local gain = piper.db_to_amp(gain_db) * makeup
                dst[i * 2 + 1] = inL * gain
                dst[i * 2 + 2] = inR * gain
            end
            -- Update GR display (smoothed)
            gr_db = gr_db * 0.9 + last_gain_db * 0.1
        end

        function inst:reset() env_db = -100.0 end
        function inst:destroy() end

        function inst:get_ui_state()
            return {
                threshold = thr_db,
                ratio     = ratio,
                makeup    = makeup_db,
                gr_db     = gr_db,
            }
        end

        return inst
    end,
}
