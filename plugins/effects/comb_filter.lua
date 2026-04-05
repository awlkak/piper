-- Comb Filter
-- Feedback comb filter with one-pole damping.

return {
    type    = "effect",
    name    = "Comb Filter",
    version = 1,

    inlets  = {
        { id = "in",       kind = "signal"  },
        { id = "time",     kind = "control" },
        { id = "feedback", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="time",     label="Time (ms)", min=0.1, max=50,   default=5,   type="float" },
        { id="feedback", label="Feedback",  min=-0.98, max=0.98, default=0.5, type="float" },
        { id="damp",     label="Damp",      min=0,   max=1,    default=0.3, type="float" },
        { id="mix",      label="Mix",       min=0,   max=1,    default=0.5, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr       = piper.SAMPLE_RATE
        local time_ms  = self.params[1].default
        local feedback = self.params[2].default
        local damp     = self.params[3].default
        local mix      = self.params[4].default

        local MAX_DELAY = math.floor(sr * 2) + 1
        local buf_l = {}
        local buf_r = {}
        local write_pos = 1
        local lp_l = 0.0
        local lp_r = 0.0

        local function alloc(sample_rate)
            sr = sample_rate
            MAX_DELAY = math.floor(sr * 2) + 1
            buf_l = {}; buf_r = {}
            for i = 1, MAX_DELAY do buf_l[i] = 0.0; buf_r[i] = 0.0 end
            write_pos = 1; lp_l = 0.0; lp_r = 0.0
        end

        alloc(sr)

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "time"     then time_ms  = value
            elseif id == "feedback" then feedback = value
            elseif id == "damp"     then damp     = value
            elseif id == "mix"      then mix      = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if     inlet_id == "time"     then time_ms  = msg.v
                elseif inlet_id == "feedback" then feedback = msg.v
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local delay_samp = piper.clamp(math.max(1, math.floor(time_ms / 1000 * sr)), 1, MAX_DELAY - 1)
            local damp_c = piper.clamp(1 - damp, 0, 1)

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                local rp = ((write_pos - delay_samp - 1) % MAX_DELAY) + 1

                local y_del_l = buf_l[rp]
                local y_del_r = buf_r[rp]

                lp_l = lp_l + damp_c * (y_del_l - lp_l)
                lp_r = lp_r + damp_c * (y_del_r - lp_r)

                local y_l = inL + feedback * lp_l
                local y_r = inR + feedback * lp_r

                buf_l[write_pos] = y_l
                buf_r[write_pos] = y_r
                write_pos = (write_pos % MAX_DELAY) + 1

                dst[i*2+1] = inL * (1 - mix) + y_l * mix
                dst[i*2+2] = inR * (1 - mix) + y_r * mix
            end
        end

        function inst:reset()
            for i = 1, MAX_DELAY do buf_l[i] = 0.0; buf_r[i] = 0.0 end
            write_pos = 1; lp_l = 0.0; lp_r = 0.0
        end

        function inst:destroy()
            buf_l = {}; buf_r = {}
        end

        return inst
    end,
}
