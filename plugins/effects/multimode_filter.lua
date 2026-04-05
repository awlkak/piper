-- Multimode Filter (State-Variable Filter)
-- Simultaneous LP/BP/HP outputs with crossfading mode control.

return {
    type    = "effect",
    name    = "Multimode Filter",
    version = 1,

    inlets  = {
        { id = "in",     kind = "signal"  },
        { id = "cutoff", kind = "control" },
        { id = "mode",   kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
        { id = "lp",  kind = "signal" },
        { id = "bp",  kind = "signal" },
        { id = "hp",  kind = "signal" },
    },

    params = {
        { id="cutoff",    label="Cutoff",    min=20, max=20000, default=1000, type="float" },
        { id="resonance", label="Resonance", min=0,  max=4,     default=0.5,  type="float" },
        { id="mode",      label="Mode",      min=0,  max=2,     default=0,    type="float" },
        { id="mix",       label="Mix",       min=0,  max=1,     default=1.0,  type="float" },
    },

    gui = {
        height = 60,
        draw = function(ctx, state)
            local cutoff = state.cutoff    or 1000
            local res    = state.resonance or 0.5
            local mode   = math.floor(state.mode or 0)
            local T      = ctx.theme

            ctx.rect(0, 0, ctx.w, ctx.h, {0.07,0.07,0.10,1}, nil)

            local pad    = 4
            local sr     = 44100
            local db_min = -30
            local db_max = 12
            local f_min  = 20
            local f_max  = 20000

            -- 0dB line
            local zero_y = pad + (db_max / (db_max - db_min)) * (ctx.h - pad*2)
            ctx.line(0, zero_y, ctx.w, zero_y, {0.20,0.20,0.25,1}, 1)

            -- Compute biquad coefficients for current mode
            local function biquad_coeffs(fc, Q)
                local w0  = 2 * math.pi * fc / sr
                local cw  = math.cos(w0)
                local sw  = math.sin(w0)
                local alp = sw / (2 * Q)
                local b0,b1,b2,a0,a1,a2
                if mode == 0 then       -- lowpass
                    b0=(1-cw)/2; b1=1-cw; b2=(1-cw)/2
                    a0=1+alp;   a1=-2*cw; a2=1-alp
                elseif mode == 1 then   -- bandpass
                    b0=alp; b1=0; b2=-alp
                    a0=1+alp; a1=-2*cw; a2=1-alp
                else                    -- highpass
                    b0=(1+cw)/2; b1=-(1+cw); b2=(1+cw)/2
                    a0=1+alp;    a1=-2*cw;    a2=1-alp
                end
                return b0/a0, b1/a0, b2/a0, a1/a0, a2/a0
            end

            -- Magnitude at frequency f (analytic)
            local function magnitude_db(f, b0,b1,b2,a1,a2)
                local w = 2 * math.pi * f / sr
                -- H(e^jw) magnitude squared
                local re_num = b0 + b1*math.cos(w) + b2*math.cos(2*w)
                local im_num =      b1*math.sin(w) + b2*math.sin(2*w)
                local re_den = 1  + a1*math.cos(w) + a2*math.cos(2*w)
                local im_den =      a1*math.sin(w) + a2*math.sin(2*w)
                local mag2 = (re_num^2 + im_num^2) / math.max(re_den^2 + im_den^2, 1e-30)
                return 10 * math.log(math.max(mag2, 1e-12)) / math.log(10)
            end

            local Q = math.max(0.1, res + 0.5)  -- map resonance param to Q
            local b0,b1,b2,a1,a2 = biquad_coeffs(cutoff, Q)

            local N   = math.max(2, math.floor(ctx.w))
            local pts = {}
            for i = 0, N do
                local t = i / N
                -- Log frequency mapping
                local f = f_min * (f_max/f_min)^t
                local db = magnitude_db(f, b0,b1,b2,a1,a2)
                db = math.max(db_min, math.min(db_max, db))
                local x = t * ctx.w
                local y = pad + (db_max - db) / (db_max - db_min) * (ctx.h - pad*2)
                pts[#pts+1] = x
                pts[#pts+1] = y
            end

            ctx.plot(pts, T.accent2, 1.5)

            -- Mode label
            local mode_names = {"LP", "BP", "HP"}
            ctx.label(mode_names[mode+1] or "?", pad, pad, 20, 12,
                      T.text_dim, T.font_small, "left")

            -- Cutoff marker
            local fc_x = math.log(cutoff/f_min) / math.log(f_max/f_min) * ctx.w
            ctx.line(fc_x, pad, fc_x, ctx.h-pad, {0.50,0.50,0.60,0.4}, 1)
        end,
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local cutoff    = 1000
        local resonance = 0.5
        local mode      = 0
        local mix       = 1.0

        -- SVF state per channel
        local lowL, bandL, lowR, bandR = 0, 0, 0, 0

        function inst:init(sample_rate)
            sr = sample_rate
            lowL, bandL, lowR, bandR = 0, 0, 0, 0
        end

        function inst:set_param(id, value)
            if     id == "cutoff"    then cutoff    = value
            elseif id == "resonance" then resonance = value
            elseif id == "mode"      then mode      = value
            elseif id == "mix"       then mix       = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "cutoff" and msg.type == "float" then
                cutoff = msg.v
            elseif inlet_id == "mode" and msg.type == "float" then
                mode = msg.v
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src   = in_bufs["in"]
            local d_out = out_bufs["out"]
            local d_lp  = out_bufs["lp"]
            local d_bp  = out_bufs["bp"]
            local d_hp  = out_bufs["hp"]
            if not src then return end

            local f = 2 * math.sin(math.pi * piper.clamp(cutoff, 20, sr * 0.49) / sr)
            local q = piper.clamp(resonance, 0.01, 3.99)
            local m1 = piper.clamp(mode, 0, 1)
            local m2 = piper.clamp(mode - 1, 0, 1)
            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local xL = src[i*2+1]
                local xR = src[i*2+2]

                -- Run SVF twice per sample for stability
                local hpL, hpR
                for _ = 1, 2 do
                    hpL    = xL - q*bandL - lowL
                    bandL  = f*hpL + bandL
                    lowL   = f*bandL + lowL
                    hpR    = xR - q*bandR - lowR
                    bandR  = f*hpR + bandR
                    lowR   = f*bandR + lowR
                end

                -- Crossfade LP->BP->HP
                local outL = lowL + (bandL - lowL)*m1
                outL = outL + (hpL - outL)*m2
                local outR = lowR + (bandR - lowR)*m1
                outR = outR + (hpR - outR)*m2

                local mixL = xL*dry + outL*mix
                local mixR = xR*dry + outR*mix

                if d_out then d_out[i*2+1] = mixL; d_out[i*2+2] = mixR end
                if d_lp  then d_lp [i*2+1] = lowL;  d_lp [i*2+2] = lowR  end
                if d_bp  then d_bp [i*2+1] = bandL; d_bp [i*2+2] = bandR end
                if d_hp  then d_hp [i*2+1] = hpL;   d_hp [i*2+2] = hpR   end
            end
        end

        function inst:reset()
            lowL, bandL, lowR, bandR = 0, 0, 0, 0
        end

        function inst:destroy() end

        function inst:get_ui_state()
            return {
                cutoff    = cutoff,
                resonance = resonance,
                mode      = mode,
            }
        end

        return inst
    end,
}
