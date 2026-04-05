-- Stereo Widener
-- Mid-side width control with optional bass mono.

return {
    type    = "effect",
    name    = "Stereo Widener",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="width",     label="Width",         min=0,  max=2,   default=1.0, type="float" },
        { id="bass_mono", label="Bass Mono",      min=0,  max=1,   default=0,   type="int"   },
        { id="bass_freq", label="Bass Freq (Hz)", min=20, max=500, default=200, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local width     = self.params[1].default
        local bass_mono = self.params[2].default
        local bass_freq = self.params[3].default

        -- One-pole highpass state for side channel
        local hp_prev_L = 0.0
        local hp_out_L  = 0.0
        local hp_prev_R = 0.0
        local hp_out_R  = 0.0

        local function hp_alpha()
            return piper.clamp(1.0 - (2.0 * math.pi * bass_freq / sr), 0.0, 0.9999)
        end

        function inst:init(sample_rate)
            sr = sample_rate
            hp_prev_L, hp_out_L = 0.0, 0.0
            hp_prev_R, hp_out_R = 0.0, 0.0
        end

        function inst:set_param(id, value)
            if     id == "width"     then width     = value
            elseif id == "bass_mono" then bass_mono = math.floor(value + 0.5)
            elseif id == "bass_freq" then bass_freq = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local alpha = hp_alpha()

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                local M = (inL + inR) * 0.5
                local S = (inL - inR) * 0.5

                local Sw
                if bass_mono > 0.5 then
                    -- One-pole highpass on S to pass only highs into widening
                    hp_out_L = alpha * (hp_out_L + S - hp_prev_L)
                    hp_prev_L = S
                    Sw = hp_out_L * width
                else
                    Sw = S * width
                end

                dst[i * 2 + 1] = M + Sw
                dst[i * 2 + 2] = M - Sw
            end
        end

        function inst:reset()
            hp_prev_L, hp_out_L = 0.0, 0.0
            hp_prev_R, hp_out_R = 0.0, 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
