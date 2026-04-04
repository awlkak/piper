-- Low Pass Filter
-- Biquad lowpass with cutoff and resonance.
-- Coefficients recomputed when parameters change.

return {
    type    = "effect",
    name    = "Low Pass Filter",
    version = 1,

    inlets  = {
        { id = "in",     kind = "signal"  },
        { id = "cutoff", kind = "control" },
        { id = "res",    kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="cutoff", label="Cutoff (Hz)", min=20,   max=20000, default=2000, type="float" },
        { id="res",    label="Resonance",   min=0.1,  max=10,    default=0.7,  type="float" },
    },

    new = function(self, args)
        local inst    = {}
        local sr      = piper.SAMPLE_RATE
        local cutoff  = self.params[1].default
        local res     = self.params[2].default

        -- Biquad coefficients (stereo, two independent filter states)
        local b0, b1, b2, a1, a2 = 1, 0, 0, 0, 0
        local x1L, x2L, y1L, y2L = 0, 0, 0, 0
        local x1R, x2R, y1R, y2R = 0, 0, 0, 0
        local dirty = true

        local function recompute()
            b0, b1, b2, a1, a2 = piper.biquad_lowpass(
                piper.clamp(cutoff, 20, sr * 0.499),
                piper.clamp(res, 0.1, 40),
                sr)
            dirty = false
        end

        function inst:init(sample_rate)
            sr = sample_rate
            dirty = true
        end

        function inst:set_param(id, value)
            if id == "cutoff" then cutoff = value; dirty = true
            elseif id == "res" then res   = value; dirty = true
            end
        end

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if inlet_id == "cutoff" then cutoff = msg.v; dirty = true
                elseif inlet_id == "res" then res   = msg.v; dirty = true
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end
            if dirty then recompute() end

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]
                local outL = b0*inL + b1*x1L + b2*x2L - a1*y1L - a2*y2L
                local outR = b0*inR + b1*x1R + b2*x2R - a1*y1R - a2*y2R
                x2L, x1L = x1L, inL
                y2L, y1L = y1L, outL
                x2R, x1R = x1R, inR
                y2R, y1R = y1R, outR
                dst[i * 2 + 1] = outL
                dst[i * 2 + 2] = outR
            end
        end

        function inst:reset()
            x1L,x2L,y1L,y2L = 0,0,0,0
            x1R,x2R,y1R,y2R = 0,0,0,0
        end

        function inst:destroy() end

        return inst
    end,
}
