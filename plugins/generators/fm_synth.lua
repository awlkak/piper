-- FM Synthesizer
-- Two-operator FM: carrier modulated by modulator.
-- carrier_freq = note_hz * carrier_ratio
-- modulator_freq = note_hz * mod_ratio
-- output = sin(carrier_phase + mod_index * sin(mod_phase))

return {
    type    = "generator",
    name    = "FM Synth",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "mod",  kind = "control" },  -- modulation index override (float)
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",        label="Amplitude",    min=0,   max=1,    default=0.5,  type="float" },
        { id="pan",        label="Pan",          min=-1,  max=1,    default=0,    type="float" },
        { id="car_ratio",  label="Carrier Ratio",min=0.5, max=8,    default=1,    type="float" },
        { id="mod_ratio",  label="Mod Ratio",    min=0.5, max=8,    default=2,    type="float" },
        { id="mod_index",  label="Mod Index",    min=0,   max=20,   default=3,    type="float" },
        { id="attack",     label="Attack (s)",   min=0,   max=2,    default=0.01, type="float" },
        { id="decay",      label="Decay (s)",    min=0,   max=2,    default=0.1,  type="float" },
        { id="sustain",    label="Sustain",      min=0,   max=1,    default=0.7,  type="float" },
        { id="release",    label="Release (s)",  min=0,   max=4,    default=0.3,  type="float" },
        { id="tune",       label="Tune (semi)",  min=-24, max=24,   default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local amp       = 0.5
        local pan       = 0.0
        local car_ratio = 1.0
        local mod_ratio = 2.0
        local mod_index = 3.0
        local attack    = 0.01
        local decay     = 0.1
        local sustain   = 0.7
        local release   = 0.3
        local tune      = 0.0

        local car_phase = 0.0
        local mod_phase = 0.0
        local note_hz   = 440.0
        local vel       = 1.0

        -- Envelope
        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "amp"       then amp       = value
            elseif id == "pan"       then pan       = value
            elseif id == "car_ratio" then car_ratio = value
            elseif id == "mod_ratio" then mod_ratio = value
            elseif id == "mod_index" then mod_index = value
            elseif id == "attack"    then attack    = math.max(0.001, value)
            elseif id == "decay"     then decay     = math.max(0.001, value)
            elseif id == "sustain"   then sustain   = value
            elseif id == "release"   then release   = math.max(0.001, value)
            elseif id == "tune"      then tune      = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    note_hz   = piper.note_to_hz(msg.note + tune)
                    vel       = msg.vel or 1.0
                    car_phase = 0.0
                    mod_phase = 0.0
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then
                        env_state = ENV_RELEASE
                    end
                end
            elseif inlet_id == "mod" and msg.type == "float" then
                mod_index = msg.v
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if env_state == ENV_OFF then
                piper.buf_fill(buf, 0.0, n)
                return
            end

            local pan_l, pan_r = piper.pan_gains(pan)
            local att_inc = 1.0 / (attack  * sr)
            local dec_inc = 1.0 / (decay   * sr)
            local rel_inc = 1.0 / (release * sr)

            for i = 0, n - 1 do
                -- Envelope
                if env_state == ENV_ATTACK then
                    env_val = env_val + att_inc
                    if env_val >= 1.0 then env_val = 1.0; env_state = ENV_DECAY end
                elseif env_state == ENV_DECAY then
                    env_val = env_val - dec_inc * (1.0 - sustain)
                    if env_val <= sustain then env_val = sustain; env_state = ENV_SUSTAIN end
                elseif env_state == ENV_RELEASE then
                    env_val = env_val - rel_inc
                    if env_val <= 0.0 then env_val = 0.0; env_state = ENV_OFF end
                end

                local mod_hz = note_hz * mod_ratio
                local car_hz = note_hz * car_ratio
                local mod_out = math.sin(mod_phase) * mod_index
                local s = math.sin(car_phase + mod_out) * amp * vel * env_val

                buf[i * 2 + 1] = s * pan_l
                buf[i * 2 + 2] = s * pan_r

                car_phase = car_phase + TAU * car_hz / sr
                mod_phase = mod_phase + TAU * mod_hz / sr
                if car_phase > TAU * 1000 then car_phase = car_phase % TAU end
                if mod_phase > TAU * 1000 then mod_phase = mod_phase % TAU end
            end
        end

        function inst:reset()
            env_state = ENV_OFF
            env_val   = 0.0
            car_phase = 0.0
            mod_phase = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
