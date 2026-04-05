-- Triangle Oscillator
-- Bandlimited triangle via PolyBLEP. Full ADSR envelope.

return {
    type    = "generator",
    name    = "Triangle Oscillator",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "freq", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="freq",    label="Frequency",    min=20,  max=20000, default=440,  type="float" },
        { id="amp",     label="Amplitude",    min=0,   max=1,     default=0.5,  type="float" },
        { id="pan",     label="Pan",          min=-1,  max=1,     default=0,    type="float" },
        { id="tune",    label="Tune (semi)",  min=-24, max=24,    default=0,    type="float" },
        { id="attack",  label="Attack (s)",   min=0,   max=2,     default=0.01, type="float" },
        { id="decay",   label="Decay (s)",    min=0,   max=2,     default=0.1,  type="float" },
        { id="sustain", label="Sustain",      min=0,   max=1,     default=0.7,  type="float" },
        { id="release", label="Release (s)",  min=0,   max=4,     default=0.3,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local freq    = self.params[1].default
        local amp     = self.params[2].default
        local pan     = self.params[3].default
        local tune    = self.params[4].default
        local attack  = self.params[5].default
        local decay   = self.params[6].default
        local sustain = self.params[7].default
        local release = self.params[8].default

        local phase_norm   = 0.0
        local note_hz      = freq
        local base_note_hz = freq

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local function polyblep(t, dt)
            if t < dt then
                t = t/dt; return t+t - t*t - 1.0
            elseif t > 1.0-dt then
                t = (t-1.0)/dt; return t*t + t+t + 1.0
            end
            return 0.0
        end

        local function recalc_freq(hz)
            note_hz = hz * piper.note_to_hz(69 + tune) / 440.0
        end

        function inst:init(sample_rate)
            sr = sample_rate
            phase_norm = 0.0
        end

        function inst:set_param(id, value)
            if     id == "freq"    then base_note_hz = value; recalc_freq(value)
            elseif id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value; recalc_freq(base_note_hz)
            elseif id == "attack"  then attack  = math.max(value, 0.0001)
            elseif id == "decay"   then decay   = math.max(value, 0.0001)
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = math.max(value, 0.0001)
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_note_hz = piper.note_to_hz(msg.note)
                    recalc_freq(base_note_hz)
                    amp        = msg.vel or amp
                    phase_norm = 0.0
                    env_state  = ENV_ATTACK
                    env_val    = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then
                        env_state = ENV_RELEASE
                    end
                end
            elseif inlet_id == "freq" and msg.type == "float" then
                base_note_hz = msg.v
                recalc_freq(msg.v)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if env_state == ENV_OFF then
                piper.buf_fill(buf, 0.0, n)
                return
            end

            local dt = note_hz / sr
            local pan_l, pan_r = piper.pan_gains(pan)
            local att = math.max(attack, 0.0001)
            local dec = math.max(decay,  0.0001)
            local rel = math.max(release, 0.0001)

            for i = 0, n - 1 do
                -- Envelope
                if env_state == ENV_ATTACK then
                    env_val = env_val + 1.0 / (att * sr)
                    if env_val >= 1.0 then env_val = 1.0; env_state = ENV_DECAY end
                elseif env_state == ENV_DECAY then
                    env_val = env_val - (1.0 - sustain) / (dec * sr)
                    if env_val <= sustain then env_val = sustain; env_state = ENV_SUSTAIN end
                elseif env_state == ENV_RELEASE then
                    env_val = env_val - env_val / (rel * sr)
                    if env_val < 0.0001 then env_val = 0.0; env_state = ENV_OFF end
                end

                -- Naive triangle
                local v
                if phase_norm < 0.5 then
                    v = phase_norm * 4.0 - 1.0
                else
                    v = 3.0 - phase_norm * 4.0
                end

                -- PolyBLEP corrections at both inflection points
                v = v + 2.0 * dt * polyblep(phase_norm, dt)
                v = v - 2.0 * dt * polyblep(math.fmod(phase_norm + 0.5, 1.0), dt)

                local s = v * amp * env_val
                buf[i * 2 + 1] = s * pan_l
                buf[i * 2 + 2] = s * pan_r

                phase_norm = phase_norm + dt
                if phase_norm >= 1.0 then phase_norm = phase_norm - 1.0 end
            end
        end

        function inst:reset()
            phase_norm = 0.0
            env_state  = ENV_OFF
            env_val    = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
