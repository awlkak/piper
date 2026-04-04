-- Delay
-- Stereo feedback delay line.
-- Time in milliseconds, feedback 0-1, wet/dry mix.

return {
    type    = "effect",
    name    = "Delay",
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
        { id="time",     label="Time (ms)",  min=1,   max=2000, default=375,  type="float" },
        { id="feedback", label="Feedback",   min=0,   max=0.98, default=0.4,  type="float" },
        { id="wet",      label="Wet",        min=0,   max=1,    default=0.4,  type="float" },
    },

    new = function(self, args)
        local inst     = {}
        local sr       = piper.SAMPLE_RATE
        local time_ms  = self.params[1].default
        local fb       = self.params[2].default
        local wet      = self.params[3].default

        local MAX_DELAY_FRAMES = math.ceil(sr * 2.0)  -- 2 second max
        local delay_L = {}
        local delay_R = {}
        local write_pos = 0

        local function init_buffers(sample_rate)
            sr = sample_rate
            MAX_DELAY_FRAMES = math.ceil(sr * 2.0)
            delay_L = {}
            delay_R = {}
            for i = 1, MAX_DELAY_FRAMES do
                delay_L[i] = 0.0
                delay_R[i] = 0.0
            end
            write_pos = 0
        end

        local function delay_frames()
            return math.floor(time_ms * sr / 1000.0)
        end

        function inst:init(sample_rate)
            init_buffers(sample_rate)
        end

        function inst:set_param(id, value)
            if     id == "time"     then time_ms = value
            elseif id == "feedback" then fb      = value
            elseif id == "wet"      then wet     = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if     inlet_id == "time"     then time_ms = msg.v
                elseif inlet_id == "feedback" then fb      = msg.v
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst or #delay_L == 0 then return end

            local df = piper.clamp(delay_frames(), 1, MAX_DELAY_FRAMES - 1)

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Read from delay buffer
                local read_pos = ((write_pos - df - 1) % MAX_DELAY_FRAMES) + 1
                local dL = delay_L[read_pos]
                local dR = delay_R[read_pos]

                -- Write to delay buffer (input + feedback)
                local wp = (write_pos % MAX_DELAY_FRAMES) + 1
                delay_L[wp] = inL + dL * fb
                delay_R[wp] = inR + dR * fb
                write_pos = write_pos + 1

                -- Mix dry + wet
                dst[i * 2 + 1] = inL * (1.0 - wet) + dL * wet
                dst[i * 2 + 2] = inR * (1.0 - wet) + dR * wet
            end
        end

        function inst:reset()
            if #delay_L > 0 then
                for i = 1, #delay_L do delay_L[i] = 0.0 end
                for i = 1, #delay_R do delay_R[i] = 0.0 end
            end
            write_pos = 0
        end

        function inst:destroy()
            delay_L = {}
            delay_R = {}
        end

        return inst
    end,
}
