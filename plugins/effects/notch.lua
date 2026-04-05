-- Notch Filter
-- Biquad notch filter with inline coefficient computation. Stereo, wet/dry mix.

return {
    type    = "effect",
    name    = "Notch Filter",
    version = 1,

    inlets  = {
        { id = "in",     kind = "signal"  },
        { id = "cutoff", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="cutoff", label="Cutoff (Hz)", min=20,  max=20000, default=1000, type="float" },
        { id="q",      label="Q",           min=0.1, max=20,    default=2.0,  type="float" },
        { id="mix",    label="Mix",         min=0,   max=1,     default=1.0,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local cutoff = self.params[1].default
        local q      = self.params[2].default
        local mix    = self.params[3].default

        local b0, b1, b2, a1, a2 = 1, 0, 0, 0, 0
        local x1L, x2L, y1L, y2L = 0, 0, 0, 0
        local x1R, x2R, y1R, y2R = 0, 0, 0, 0
        local dirty = true

        local function compute_notch(c, Q, s)
            local w0    = 2.0 * math.pi * c / s
            local alpha = math.sin(w0) / (2.0 * Q)
            local b0r   =  1.0
            local b1r   = -2.0 * math.cos(w0)
            local b2r   =  1.0
            local a0    =  1.0 + alpha
            local a1r   = -2.0 * math.cos(w0)
            local a2r   =  1.0 - alpha
            return b0r/a0, b1r/a0, b2r/a0, a1r/a0, a2r/a0
        end

        local function recompute()
            local c = piper.clamp(cutoff, 20, sr * 0.499)
            local Q = piper.clamp(q, 0.1, 40)
            b0, b1, b2, a1, a2 = compute_notch(c, Q, sr)
            dirty = false
        end

        function inst:init(sample_rate)
            sr = sample_rate
            dirty = true
        end

        function inst:set_param(id, value)
            if     id == "cutoff" then cutoff = value; dirty = true
            elseif id == "q"      then q      = value; dirty = true
            elseif id == "mix"    then mix    = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if inlet_id == "cutoff" then cutoff = msg.v; dirty = true end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end
            if dirty then recompute() end

            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                local outL = b0*inL + b1*x1L + b2*x2L - a1*y1L - a2*y2L
                local outR = b0*inR + b1*x1R + b2*x2R - a1*y1R - a2*y2R

                x2L, x1L = x1L, inL
                y2L, y1L = y1L, outL
                x2R, x1R = x1R, inR
                y2R, y1R = y1R, outR

                dst[i * 2 + 1] = inL * dry + outL * mix
                dst[i * 2 + 2] = inR * dry + outR * mix
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
