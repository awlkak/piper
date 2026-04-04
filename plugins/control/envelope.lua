-- ADSR Envelope
-- Triggered by note/bang on "trig" inlet.
-- Outputs control-rate float messages (amplitude 0..1) on "out".
-- Also has a signal output "out~" for modulating audio-rate parameters.

return {
    type    = "control",
    name    = "ADSR Envelope",
    version = 1,

    inlets  = {
        { id = "trig",   kind = "control" },
    },
    outlets = {
        { id = "out",  kind = "control" },
        { id = "out~", kind = "signal"  },
    },

    params = {
        { id="attack",  label="Attack  (s)", min=0.001, max=10, default=0.01,  type="float" },
        { id="decay",   label="Decay   (s)", min=0.001, max=10, default=0.1,   type="float" },
        { id="sustain", label="Sustain",     min=0,     max=1,  default=0.7,   type="float" },
        { id="release", label="Release (s)", min=0.001, max=10, default=0.3,   type="float" },
    },

    new = function(self, args)
        local inst     = {}
        local sr       = piper.SAMPLE_RATE
        local bs       = piper.BLOCK_SIZE
        local attack   = self.params[1].default
        local decay    = self.params[2].default
        local sustain  = self.params[3].default
        local release  = self.params[4].default

        local IDLE     = 0
        local ATTACK   = 1
        local DECAY    = 2
        local SUSTAIN  = 3
        local RELEASE  = 4

        local state    = IDLE
        local env_val  = 0.0
        local sample   = 0   -- sample counter within state

        local function samples_for(t)
            return math.max(1, math.floor(t * sr))
        end

        function inst:init(sample_rate)
            sr = sample_rate
            env_val = 0.0
            state   = IDLE
        end

        function inst:set_param(id, value)
            if     id == "attack"  then attack  = value
            elseif id == "decay"   then decay   = value
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" or msg.type == "bang" then
                    state  = ATTACK
                    sample = 0
                elseif msg.type == "note_off" then
                    if state ~= IDLE then
                        state  = RELEASE
                        sample = 0
                    end
                end
            end
        end

        -- Compute next envelope sample value
        local function tick_env()
            if state == IDLE then
                env_val = 0.0
            elseif state == ATTACK then
                local total = samples_for(attack)
                env_val = sample / total
                sample = sample + 1
                if sample >= total then
                    state  = DECAY
                    sample = 0
                    env_val = 1.0
                end
            elseif state == DECAY then
                local total = samples_for(decay)
                env_val = 1.0 - (1.0 - sustain) * (sample / total)
                sample = sample + 1
                if sample >= total then
                    state   = SUSTAIN
                    sample  = 0
                    env_val = sustain
                end
            elseif state == SUSTAIN then
                env_val = sustain
            elseif state == RELEASE then
                local total = samples_for(release)
                local start = env_val  -- capture at note-off
                -- Use exponential release from current value
                if sample == 0 then start = env_val end
                env_val = sustain * (1.0 - sample / total)
                sample = sample + 1
                if sample >= total or env_val < 0.0001 then
                    state   = IDLE
                    env_val = 0.0
                end
            end
            return env_val
        end

        function inst:process(in_bufs, out_bufs, n)
            -- Compute one block worth of envelope, output average as control msg
            -- and fill signal output buffer
            local sig_buf = out_bufs["out~"]
            local ctl_out = out_bufs["out"]

            local sum = 0.0
            for i = 0, n - 1 do
                local v = tick_env()
                sum = sum + v
                if sig_buf then
                    sig_buf[i * 2 + 1] = v
                    sig_buf[i * 2 + 2] = v
                end
            end

            if ctl_out then
                table.insert(ctl_out, { type = "float", v = sum / n })
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            state   = IDLE
            env_val = 0.0
            sample  = 0
        end

        function inst:destroy() end

        return inst
    end,
}
