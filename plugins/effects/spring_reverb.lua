-- Spring Reverb
-- Spring reverb simulation with comb resonator and boing transient.

return {
    type    = "effect",
    name    = "Spring Reverb",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="tension", label="Tension", min=0, max=1,    default=0.5,  type="float" },
        { id="length",  label="Length",  min=0, max=1,    default=0.4,  type="float" },
        { id="damp",    label="Damp",    min=0, max=1,    default=0.5,  type="float" },
        { id="mix",     label="Mix",     min=0, max=1,    default=0.35, type="float" },
        { id="drip",    label="Drip",    min=0, max=1,    default=0.3,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr      = piper.SAMPLE_RATE
        local tension = self.params[1].default
        local length  = self.params[2].default
        local damp    = self.params[3].default
        local mix     = self.params[4].default
        local drip    = self.params[5].default

        local MAX_COMB = math.ceil(sr * 0.22) + 1
        local comb_buf = {}
        local comb_pos = 1
        local comb_lp  = 0.0

        local function alloc(sample_rate)
            sr = sample_rate
            MAX_COMB = math.ceil(sr * 0.22) + 1
            comb_buf = {}
            for i = 1, MAX_COMB do comb_buf[i] = 0.0 end
            comb_pos = 1
            comb_lp  = 0.0
        end

        alloc(sr)

        -- Boing transient state
        local peak_env  = 0.0
        local prev_mono = 0.0
        local boing_env = 0.0

        -- Inline bandpass state
        local bp_x1 = 0.0; local bp_x2 = 0.0
        local bp_y1 = 0.0; local bp_y2 = 0.0
        local bp_b0 = 0.0; local bp_b2 = 0.0
        local bp_a1 = 0.0; local bp_a2 = 0.0

        local function bp_compute(cutoff, Q)
            local w0 = 2 * math.pi * cutoff / sr
            local alpha = math.sin(w0) / (2 * Q)
            local a0 = 1 + alpha
            bp_b0 =  alpha / a0
            bp_b2 = -alpha / a0
            bp_a1 = -2 * math.cos(w0) / a0
            bp_a2 = (1 - alpha) / a0
        end

        bp_compute(500, 1.5)

        function inst:init(sample_rate)
            alloc(sample_rate)
            peak_env = 0.0; prev_mono = 0.0; boing_env = 0.0
            bp_x1 = 0.0; bp_x2 = 0.0; bp_y1 = 0.0; bp_y2 = 0.0
            bp_compute(500, 1.5)
        end

        function inst:set_param(id, value)
            if     id == "tension" then tension = value
            elseif id == "length"  then length  = value
            elseif id == "damp"    then damp    = value
            elseif id == "mix"     then mix     = value
            elseif id == "drip"    then drip    = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local delay_samp = piper.clamp(math.floor((20 + length * 180) / 1000 * sr), 1, MAX_COMB - 1)
            local comb_fb    = 0.5 + tension * 0.45
            local damp_c     = piper.clamp(1 - damp, 0, 1)

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]
                local mono = (inL + inR) * 0.5

                -- Comb resonator
                local rp = ((comb_pos - delay_samp - 1) % MAX_COMB) + 1
                local y  = comb_buf[rp]
                comb_lp = comb_lp + damp_c * (y - comb_lp)
                comb_buf[comb_pos] = mono + comb_lp * comb_fb
                comb_pos = (comb_pos % MAX_COMB) + 1
                local comb_out = comb_lp

                -- Boing transient
                peak_env = peak_env * 0.995 + math.abs(mono) * 0.005
                if mono - prev_mono > 0.01 then
                    boing_env = 1.0
                end
                prev_mono = mono

                boing_env = boing_env * 0.9995

                local boing_hz = 500 + 2500 * boing_env
                bp_compute(boing_hz, 1.5)

                local bx = mono
                local by = bp_b0*bx + bp_b2*bp_x2 - bp_a1*bp_y1 - bp_a2*bp_y2
                bp_x2 = bp_x1; bp_x1 = bx
                bp_y2 = bp_y1; bp_y1 = by

                local boing_out = by * boing_env * drip

                local wet_out = comb_out * 0.7 + boing_out * 0.3

                dst[i*2+1] = inL * (1 - mix) + wet_out * mix
                dst[i*2+2] = inR * (1 - mix) + wet_out * mix
            end
        end

        function inst:reset()
            for i = 1, MAX_COMB do comb_buf[i] = 0.0 end
            comb_pos = 1; comb_lp = 0.0
            peak_env = 0.0; prev_mono = 0.0; boing_env = 0.0
            bp_x1 = 0.0; bp_x2 = 0.0; bp_y1 = 0.0; bp_y2 = 0.0
        end

        function inst:destroy()
            comb_buf = {}
        end

        return inst
    end,
}
