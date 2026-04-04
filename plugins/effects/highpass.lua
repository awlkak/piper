-- Biquad Highpass Filter
-- Cutoff and resonance parameters.

return {
    type    = "effect",
    name    = "Highpass",
    version = 1,

    inlets  = {
        { id = "in",     kind = "signal"  },
        { id = "cutoff", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="cutoff", label="Cutoff (Hz)", min=20,  max=20000, default=500, type="float" },
        { id="res",    label="Resonance",   min=0.5, max=10,    default=0.7, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local cutoff = 500.0
        local res    = 0.7

        local b0, b1, b2, a1, a2 = 1, 0, 0, 0, 0
        local x1L, x2L, y1L, y2L = 0, 0, 0, 0
        local x1R, x2R, y1R, y2R = 0, 0, 0, 0

        local function update_coefs()
            b0, b1, b2, a1, a2 = piper.biquad_highpass(
                piper.clamp(cutoff, 20, sr * 0.49), res, sr)
        end

        function inst:init(sample_rate)
            sr = sample_rate
            update_coefs()
        end

        function inst:set_param(id, value)
            if     id == "cutoff" then cutoff = value; update_coefs()
            elseif id == "res"    then res    = value; update_coefs()
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "cutoff" and msg.type == "float" then
                cutoff = piper.clamp(msg.v, 20, 20000)
                update_coefs()
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end
            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]
                local yL  = b0*inL + b1*x1L + b2*x2L - a1*y1L - a2*y2L
                local yR  = b0*inR + b1*x1R + b2*x2R - a1*y1R - a2*y2R
                x2L=x1L; x1L=inL; y2L=y1L; y1L=yL
                x2R=x1R; x1R=inR; y2R=y1R; y1R=yR
                dst[i * 2 + 1] = yL
                dst[i * 2 + 2] = yR
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
