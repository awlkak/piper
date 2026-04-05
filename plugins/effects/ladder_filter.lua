-- Ladder Filter
-- 4-pole Moog-style ladder filter with tanh clipping and feedback.

return {
    type    = "effect",
    name    = "Ladder Filter",
    version = 1,

    inlets  = {
        { id = "in",        kind = "signal"  },
        { id = "cutoff",    kind = "control" },
        { id = "resonance", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="cutoff",    label="Cutoff",    min=20, max=20000, default=800, type="float" },
        { id="resonance", label="Resonance", min=0,  max=1,     default=0.3, type="float" },
        { id="drive",     label="Drive",     min=1,  max=5,     default=1.0, type="float" },
        { id="mix",       label="Mix",       min=0,  max=1,     default=1.0, type="float" },
    },

    gui = {
        height = 60,
        draw = function(ctx, state)
            local cutoff = state.cutoff    or 800
            local res    = state.resonance or 0.3
            local T      = ctx.theme

            ctx.rect(0, 0, ctx.w, ctx.h, {0.07,0.07,0.10,1}, nil)

            local pad    = 4
            local sr     = 44100
            local db_min = -48
            local db_max = 12
            local f_min  = 20
            local f_max  = 20000

            -- 0dB line
            local zero_y = pad + (db_max / (db_max - db_min)) * (ctx.h - pad*2)
            ctx.line(0, zero_y, ctx.w, zero_y, {0.20,0.20,0.25,1}, 1)

            -- Analytic 4-pole ladder magnitude (approximation):
            -- One-pole response raised to 4th power, with resonance peak near cutoff
            local function magnitude_db(f)
                local wc = 2 * math.pi * cutoff / sr
                local w  = 2 * math.pi * f / sr
                -- One-pole magnitude squared
                local r  = 1 - wc  -- feedback coeff approximation
                local one_pole_mag2 = (1 - r)^2 / ((1 - r*math.cos(w))^2 + (r*math.sin(w))^2)
                -- 4-pole: raise to 4th power → -24dB/oct
                local ladder_mag2 = one_pole_mag2^4
                -- Resonance peak: add boost near cutoff
                local dist = math.abs(math.log(f/math.max(cutoff,1)))
                local peak = res * 8 * math.exp(-dist * 8)
                local total_mag = math.sqrt(ladder_mag2) + peak
                return 20 * math.log(math.max(total_mag, 1e-6)) / math.log(10)
            end

            local N   = math.max(2, math.floor(ctx.w))
            local pts = {}
            for i = 0, N do
                local t  = i / N
                local f  = f_min * (f_max/f_min)^t
                local db = magnitude_db(f)
                db = math.max(db_min, math.min(db_max, db))
                local x  = t * ctx.w
                local y  = pad + (db_max - db) / (db_max - db_min) * (ctx.h - pad*2)
                pts[#pts+1] = x
                pts[#pts+1] = y
            end

            ctx.plot(pts, T.accent, 1.5)

            -- Cutoff marker
            local fc_x = math.log(cutoff/f_min) / math.log(f_max/f_min) * ctx.w
            ctx.line(fc_x, pad, fc_x, ctx.h-pad, {0.50,0.50,0.60,0.4}, 1)

            -- Label
            ctx.label("4-pole LP", pad, pad, 50, 12, T.text_dim, T.font_small, "left")
        end,
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local cutoff    = 800
        local resonance = 0.3
        local drive     = 1.0
        local mix       = 1.0

        -- Per-channel ladder states
        local s1L, s2L, s3L, s4L = 0, 0, 0, 0
        local s1R, s2R, s3R, s4R = 0, 0, 0, 0

        local function tanh(x)
            if x > 4 then return 1 elseif x < -4 then return -1 end
            local e = math.exp(2*x)
            return (e-1)/(e+1)
        end

        function inst:init(sample_rate)
            sr = sample_rate
            s1L, s2L, s3L, s4L = 0, 0, 0, 0
            s1R, s2R, s3R, s4R = 0, 0, 0, 0
        end

        function inst:set_param(id, value)
            if     id == "cutoff"    then cutoff    = value
            elseif id == "resonance" then resonance = value
            elseif id == "drive"     then drive     = value
            elseif id == "mix"       then mix       = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "cutoff" and msg.type == "float" then
                cutoff = msg.v
            elseif inlet_id == "resonance" and msg.type == "float" then
                resonance = msg.v
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local f  = 2 * math.sin(math.pi * piper.clamp(cutoff, 20, sr * 0.499) / sr)
            local fb = resonance * 4.0 * (1.0 - 0.15*f*f)
            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local xL = src[i*2+1]
                local xR = src[i*2+2]

                -- Left channel
                local x_inL = tanh(xL*drive - s4L*fb)
                s1L = s1L + f*(tanh(x_inL) - tanh(s1L))
                s2L = s2L + f*(tanh(s1L)   - tanh(s2L))
                s3L = s3L + f*(tanh(s2L)   - tanh(s3L))
                s4L = s4L + f*(tanh(s3L)   - tanh(s4L))

                -- Right channel
                local x_inR = tanh(xR*drive - s4R*fb)
                s1R = s1R + f*(tanh(x_inR) - tanh(s1R))
                s2R = s2R + f*(tanh(s1R)   - tanh(s2R))
                s3R = s3R + f*(tanh(s2R)   - tanh(s3R))
                s4R = s4R + f*(tanh(s3R)   - tanh(s4R))

                dst[i*2+1] = xL*dry + s4L*mix
                dst[i*2+2] = xR*dry + s4R*mix
            end
        end

        function inst:reset()
            s1L, s2L, s3L, s4L = 0, 0, 0, 0
            s1R, s2R, s3R, s4R = 0, 0, 0, 0
        end

        function inst:destroy() end

        function inst:get_ui_state()
            return {
                cutoff    = cutoff,
                resonance = resonance,
            }
        end

        return inst
    end,
}
