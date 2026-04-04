-- Phaser
-- 4-stage all-pass phaser with LFO sweep and feedback.

return {
    type    = "effect",
    name    = "Phaser",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="rate",     label="Rate (Hz)",   min=0.01, max=5,   default=0.4,  type="float" },
        { id="depth",    label="Depth",       min=0,    max=1,   default=0.8,  type="float" },
        { id="center",   label="Center (Hz)", min=200,  max=4000,default=1000, type="float" },
        { id="feedback", label="Feedback",    min=0,    max=0.95,default=0.5,  type="float" },
        { id="mix",      label="Wet Mix",     min=0,    max=1,   default=0.5,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local rate     = 0.4
        local depth    = 0.8
        local center   = 1000.0
        local feedback = 0.5
        local mix      = 0.5

        -- 4 all-pass stages (stereo)
        local N = 4
        local apL = {}; local apR = {}
        for i = 1, N do apL[i] = 0.0; apR[i] = 0.0 end
        local fbL = 0.0; local fbR = 0.0
        local lfo_phase = 0.0

        -- All-pass coefficient: a = (1 - tan(pi*fc/sr)) / (1 + tan(pi*fc/sr))
        local function ap_coef(fc)
            local t = math.tan(math.pi * fc / sr)
            return (1.0 - t) / (1.0 + t)
        end

        local function allpass(x, state, a)
            local y = a * x + state
            state = x - a * y
            return y, state
        end

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "rate"     then rate     = value
            elseif id == "depth"    then depth    = value
            elseif id == "center"   then center   = value
            elseif id == "feedback" then feedback = value
            elseif id == "mix"      then mix      = value
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local dry = 1.0 - mix
            local oct = math.log(center) / math.log(2)

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- LFO sweeps center frequency up/down by 'depth' octaves
                local lfo   = math.sin(lfo_phase)
                local fc    = 2.0 ^ (oct + lfo * depth * 2.0)
                fc = piper.clamp(fc, 20, sr * 0.49)
                local a = ap_coef(fc)

                -- 4 all-pass stages with feedback
                local xL = inL + fbL * feedback
                local xR = inR + fbR * feedback

                for s = 1, N do
                    xL, apL[s] = allpass(xL, apL[s], a)
                    xR, apR[s] = allpass(xR, apR[s], a)
                end

                fbL = xL; fbR = xR

                dst[i * 2 + 1] = inL * dry + xL * mix
                dst[i * 2 + 2] = inR * dry + xR * mix

                lfo_phase = lfo_phase + TAU * rate / sr
                if lfo_phase > TAU * 1000 then lfo_phase = lfo_phase % TAU end
            end
        end

        function inst:reset()
            for i = 1, N do apL[i] = 0.0; apR[i] = 0.0 end
            fbL = 0.0; fbR = 0.0; lfo_phase = 0.0
        end
        function inst:destroy() end

        return inst
    end,
}
