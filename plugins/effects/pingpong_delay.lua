-- Ping-Pong Delay
-- Stereo ping-pong delay: L feeds R and R feeds L.

return {
    type    = "effect",
    name    = "Ping-Pong Delay",
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
        { id="time",     label="Time (ms)",  min=1,   max=2000, default=375, type="float" },
        { id="feedback", label="Feedback",   min=0,   max=0.98, default=0.5, type="float" },
        { id="offset",   label="Offset",     min=0.5, max=2.0,  default=1.0, type="float" },
        { id="damp",     label="Damp",       min=0,   max=1,    default=0.4, type="float" },
        { id="wet",      label="Wet",        min=0,   max=1,    default=0.4, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr       = piper.SAMPLE_RATE
        local time_ms  = self.params[1].default
        local feedback = self.params[2].default
        local offset   = self.params[3].default
        local damp     = self.params[4].default
        local wet      = self.params[5].default

        local MAX_DELAY = math.ceil(sr * 2.0) + 1
        local buf_l = {}
        local buf_r = {}
        local write_pos = 1
        local lp_l = 0.0
        local lp_r = 0.0

        local function alloc(sample_rate)
            sr = sample_rate
            MAX_DELAY = math.ceil(sr * 2.0) + 1
            buf_l = {}
            buf_r = {}
            for i = 1, MAX_DELAY do buf_l[i] = 0.0; buf_r[i] = 0.0 end
            write_pos = 1
            lp_l = 0.0
            lp_r = 0.0
        end

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "time"     then time_ms  = value
            elseif id == "feedback" then feedback = value
            elseif id == "offset"   then offset   = value
            elseif id == "damp"     then damp     = value
            elseif id == "wet"      then wet      = value
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

            local delay_L = piper.clamp(math.floor(time_ms / 1000 * sr), 1, MAX_DELAY - 1)
            local delay_R = piper.clamp(math.floor(time_ms / 1000 * sr * offset), 1, MAX_DELAY - 1)
            local damp_c  = piper.clamp(damp, 0, 1)

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                local rp_l = ((write_pos - delay_L - 1) % MAX_DELAY) + 1
                local rp_r = ((write_pos - delay_R - 1) % MAX_DELAY) + 1

                local read_l = buf_l[rp_l]
                local read_r = buf_r[rp_r]

                lp_l = lp_l + damp_c * (read_l - lp_l)
                lp_r = lp_r + damp_c * (read_r - lp_r)

                local mono = (inL + inR) * 0.5
                buf_l[write_pos] = mono + lp_r * feedback
                buf_r[write_pos] = mono + lp_l * feedback

                write_pos = (write_pos % MAX_DELAY) + 1

                dst[i*2+1] = inL * (1 - wet) + lp_l * wet
                dst[i*2+2] = inR * (1 - wet) + lp_r * wet
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
