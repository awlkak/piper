-- Formant Filter
-- Three parallel bandpass filters morphing between vowel formants.

return {
    type    = "effect",
    name    = "Formant Filter",
    version = 1,

    inlets  = {
        { id = "in",    kind = "signal"  },
        { id = "morph", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="morph", label="Morph",  min=0, max=4, default=0,   type="float" },
        { id="gain",  label="Gain",   min=0, max=2, default=1.0, type="float" },
        { id="mix",   label="Mix",    min=0, max=1, default=1.0, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local morph = 0
        local gain  = 1.0
        local mix   = 1.0

        -- Vowel formant tables: F1, F2, F3 Hz, Q1, Q2, Q3
        local VOWELS = {
            [0] = {800,  1200, 2800, 8, 8, 8},  -- A
            [1] = {400,  2200, 2600, 8, 8, 8},  -- E
            [2] = {350,  2400, 3000, 8, 8, 8},  -- I
            [3] = {500,  1000, 2800, 8, 8, 8},  -- O
            [4] = {350,  800,  2250, 8, 8, 8},  -- U
        }

        -- 3 BP filters × 2 channels × 2 state vars (x1, x2)
        -- States: bpXL[f], bpXR[f] where f=1,2,3
        local x1L = {0,0,0}; local x2L = {0,0,0}
        local x1R = {0,0,0}; local x2R = {0,0,0}

        local function bp_coeffs(cutoff, Q, sr_)
            local w0    = 2*math.pi*cutoff/sr_
            local alpha = math.sin(w0)/(2*Q)
            local a0    = 1+alpha
            return alpha/a0, 0, -alpha/a0, -2*math.cos(w0)/a0, (1-alpha)/a0
        end

        local function biquad(b0, b1, b2, a1, a2, x, xn1, xn2)
            -- transposed direct form II
            local y = b0*x + xn1
            xn1 = b1*x - a1*y + xn2
            xn2 = b2*x - a2*y
            return y, xn1, xn2
        end

        -- Cache coefficients
        local coeffs = {{0,0,0,0,0},{0,0,0,0,0},{0,0,0,0,0}}

        local function update_coeffs()
            local vi = math.floor(morph)
            local vf = morph - vi
            vi = math.min(vi, 4)
            local vi2 = math.min(vi+1, 4)
            local v1 = VOWELS[vi]; local v2 = VOWELS[vi2]
            for f = 1, 3 do
                local freq = v1[f]*(1-vf) + v2[f]*vf
                local q    = v1[f+3]*(1-vf) + v2[f+3]*vf
                freq = piper.clamp(freq, 20, sr*0.49)
                local b0,b1,b2,a1,a2 = bp_coeffs(freq, q, sr)
                coeffs[f] = {b0,b1,b2,a1,a2}
            end
        end

        function inst:init(sample_rate)
            sr = sample_rate
            x1L={0,0,0}; x2L={0,0,0}; x1R={0,0,0}; x2R={0,0,0}
            update_coeffs()
        end

        function inst:set_param(id, value)
            if     id == "morph" then morph = value; update_coeffs()
            elseif id == "gain"  then gain  = value
            elseif id == "mix"   then mix   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "morph" and msg.type == "float" then
                morph = msg.v
                update_coeffs()
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local xL = src[i*2+1]
                local xR = src[i*2+2]
                local sumL, sumR = 0, 0

                for f = 1, 3 do
                    local c = coeffs[f]
                    local yL, yR
                    yL, x1L[f], x2L[f] = biquad(c[1],c[2],c[3],c[4],c[5], xL, x1L[f], x2L[f])
                    yR, x1R[f], x2R[f] = biquad(c[1],c[2],c[3],c[4],c[5], xR, x1R[f], x2R[f])
                    sumL = sumL + yL
                    sumR = sumR + yR
                end

                dst[i*2+1] = xL*dry + sumL*gain*mix
                dst[i*2+2] = xR*dry + sumR*gain*mix
            end
        end

        function inst:reset()
            x1L={0,0,0}; x2L={0,0,0}; x1R={0,0,0}; x2R={0,0,0}
        end

        function inst:destroy() end

        return inst
    end,
}
