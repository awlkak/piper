-- Tape Saturation
-- Tape saturation with pre/de-emphasis.

return {
    type    = "effect",
    name    = "Tape Saturation",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="drive", label="Drive",  min=1, max=10, default=2.0, type="float" },
        { id="bias",  label="Bias",   min=0, max=1,  default=0,   type="float" },
        { id="tone",  label="Tone",   min=0, max=1,  default=0.5, type="float" },
        { id="mix",   label="Mix",    min=0, max=1,  default=1.0, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr    = piper.SAMPLE_RATE
        local drive = self.params[1].default
        local bias  = self.params[2].default
        local tone  = self.params[3].default
        local mix   = self.params[4].default

        -- Per-channel state: L and R
        local hp_out_l = 0.0; local hp_prev_l = 0.0; local lp_out_l = 0.0
        local hp_out_r = 0.0; local hp_prev_r = 0.0; local lp_out_r = 0.0

        local function tanh(x)
            if x > 4 then return 1 elseif x < -4 then return -1 end
            local e = math.exp(2 * x); return (e - 1) / (e + 1)
        end

        function inst:init(sample_rate)
            sr = sample_rate
            hp_out_l = 0.0; hp_prev_l = 0.0; lp_out_l = 0.0
            hp_out_r = 0.0; hp_prev_r = 0.0; lp_out_r = 0.0
        end

        function inst:set_param(id, value)
            if     id == "drive" then drive = value
            elseif id == "bias"  then bias  = value
            elseif id == "tone"  then tone  = value
            elseif id == "mix"   then mix   = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local hp_alpha = math.max(0, 1 - 2 * math.pi * 200 / sr)
            local lp_coeff = 1 - hp_alpha

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                -- Left channel
                hp_out_l = hp_alpha * (hp_out_l + inL - hp_prev_l)
                hp_prev_l = inL
                local x_pre_l = inL + hp_out_l * tone
                local x_b_l   = x_pre_l + bias * 0.3
                local x_sat_l = tanh(x_b_l * drive)
                lp_out_l = lp_out_l + lp_coeff * (x_sat_l - lp_out_l)
                local x_de_l  = x_sat_l - lp_out_l * tone
                local outL    = inL * (1 - mix) + x_de_l * mix

                -- Right channel
                hp_out_r = hp_alpha * (hp_out_r + inR - hp_prev_r)
                hp_prev_r = inR
                local x_pre_r = inR + hp_out_r * tone
                local x_b_r   = x_pre_r + bias * 0.3
                local x_sat_r = tanh(x_b_r * drive)
                lp_out_r = lp_out_r + lp_coeff * (x_sat_r - lp_out_r)
                local x_de_r  = x_sat_r - lp_out_r * tone
                local outR    = inR * (1 - mix) + x_de_r * mix

                dst[i*2+1] = outL
                dst[i*2+2] = outR
            end
        end

        function inst:reset()
            hp_out_l = 0.0; hp_prev_l = 0.0; lp_out_l = 0.0
            hp_out_r = 0.0; hp_prev_r = 0.0; lp_out_r = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
