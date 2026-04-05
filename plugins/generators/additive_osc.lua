-- Additive Oscillator
-- 8 harmonic partial sines summed together with independent amplitude control.

return {
    type    = "generator",
    name    = "Additive Oscillator",
    version = 1,

    inlets  = {
        { id = "trig",       kind = "control" },
        { id = "brightness", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",        label="Amplitude",   min=0,   max=1,    default=0.5,  type="float" },
        { id="pan",        label="Pan",         min=-1,  max=1,    default=0,    type="float" },
        { id="tune",       label="Tune (semi)", min=-24, max=24,   default=0,    type="float" },
        { id="h1",         label="Partial 1",   min=0,   max=1,    default=1.0,  type="float" },
        { id="h2",         label="Partial 2",   min=0,   max=1,    default=0.5,  type="float" },
        { id="h3",         label="Partial 3",   min=0,   max=1,    default=0.33, type="float" },
        { id="h4",         label="Partial 4",   min=0,   max=1,    default=0.25, type="float" },
        { id="h5",         label="Partial 5",   min=0,   max=1,    default=0.2,  type="float" },
        { id="h6",         label="Partial 6",   min=0,   max=1,    default=0.16, type="float" },
        { id="h7",         label="Partial 7",   min=0,   max=1,    default=0.14, type="float" },
        { id="h8",         label="Partial 8",   min=0,   max=1,    default=0.12, type="float" },
        { id="brightness", label="Brightness",  min=0,   max=1,    default=0.7,  type="float" },
        { id="attack",     label="Attack",      min=0,   max=2,    default=0.02, type="float" },
        { id="decay",      label="Decay",       min=0,   max=2,    default=0.1,  type="float" },
        { id="sustain",    label="Sustain",     min=0,   max=1,    default=0.8,  type="float" },
        { id="release",    label="Release",     min=0,   max=4,    default=0.4,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local amp        = self.params[1].default
        local pan        = self.params[2].default
        local tune       = self.params[3].default
        local h          = { self.params[4].default, self.params[5].default, self.params[6].default,
                             self.params[7].default, self.params[8].default, self.params[9].default,
                             self.params[10].default, self.params[11].default }
        local brightness = self.params[12].default
        local attack     = self.params[13].default
        local decay      = self.params[14].default
        local sustain    = self.params[15].default
        local release    = self.params[16].default

        local base_hz = 440.0
        local vel     = 1.0
        local phases  = { 0,0,0,0,0,0,0,0 }

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local param_ids = { "h1","h2","h3","h4","h5","h6","h7","h8" }

        function inst:init(sample_rate)
            sr = sample_rate
            for i = 1, 8 do phases[i] = 0.0 end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "amp"        then amp        = value
            elseif id == "pan"        then pan        = value
            elseif id == "tune"       then tune       = value
            elseif id == "brightness" then brightness = value
            elseif id == "attack"     then attack     = value
            elseif id == "decay"      then decay      = value
            elseif id == "sustain"    then sustain    = value
            elseif id == "release"    then release    = value
            else
                for n = 1, 8 do
                    if id == param_ids[n] then h[n] = value; break end
                end
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_hz = piper.note_to_hz(msg.note) * 2^(tune/12)
                    vel     = msg.vel or 1.0
                    for i = 1, 8 do phases[i] = 0.0 end
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            elseif inlet_id == "brightness" and msg.type == "float" then
                brightness = piper.clamp(msg.v, 0.0, 1.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local pan_l, pan_r = piper.pan_gains(pan)
            local note_hz = base_hz

            -- Precompute frequency increments per partial
            local incs = {}
            for k = 1, 8 do
                incs[k] = TAU * note_hz * k / sr
            end

            for i = 0, n-1 do
                -- Envelope
                if env_state == ENV_ATTACK then
                    env_val = env_val + 1.0 / (math.max(0.001, attack) * sr)
                    if env_val >= 1.0 then env_val = 1.0; env_state = ENV_DECAY end
                elseif env_state == ENV_DECAY then
                    env_val = env_val - (1.0 - sustain) / (math.max(0.001, decay) * sr)
                    if env_val <= sustain then env_val = sustain; env_state = ENV_SUSTAIN end
                elseif env_state == ENV_RELEASE then
                    env_val = env_val - env_val / (math.max(0.001, release) * sr)
                    if env_val < 0.0001 then env_val = 0.0; env_state = ENV_OFF end
                end

                local sum = 0.0
                local bpow = 1.0  -- brightness^(n-1), n=1 -> bpow=1
                for k = 1, 8 do
                    sum = sum + h[k] * bpow * math.sin(phases[k])
                    phases[k] = phases[k] + incs[k]
                    if phases[k] > TAU * 1000 then phases[k] = phases[k] % TAU end
                    bpow = bpow * brightness
                end

                local s = (sum / 8.0) * amp * vel * env_val
                buf[i*2+1] = s * pan_l
                buf[i*2+2] = s * pan_r
            end
        end

        function inst:reset()
            for i = 1, 8 do phases[i] = 0.0 end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
