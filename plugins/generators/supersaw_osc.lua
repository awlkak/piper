-- Supersaw Oscillator
-- 7 detuned naive sawtooth oscillators (Roland JP-8000 style).

return {
    type    = "generator",
    name    = "Supersaw Oscillator",
    version = 1,

    inlets  = {
        { id = "trig",   kind = "control" },
        { id = "detune", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="freq",    label="Frequency",  min=20,  max=20000, default=440,  type="float" },
        { id="amp",     label="Amplitude",  min=0,   max=1,     default=0.5,  type="float" },
        { id="pan",     label="Pan",        min=-1,  max=1,     default=0,    type="float" },
        { id="tune",    label="Tune (semi)",min=-24, max=24,    default=0,    type="float" },
        { id="detune",  label="Detune",     min=0,   max=100,   default=25,   type="float" },
        { id="spread",  label="Spread",     min=0,   max=1,     default=0.8,  type="float" },
        { id="mix",     label="Mix",        min=0,   max=1,     default=0.5,  type="float" },
        { id="attack",  label="Attack",     min=0,   max=2,     default=0.02, type="float" },
        { id="decay",   label="Decay",      min=0,   max=2,     default=0.2,  type="float" },
        { id="sustain", label="Sustain",    min=0,   max=1,     default=0.6,  type="float" },
        { id="release", label="Release",    min=0,   max=4,     default=0.5,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local NUM_VOICES = 7
        -- Fixed stereo pan positions per voice
        local VOICE_PANS = { -1.0, -0.67, -0.33, 0.0, 0.33, 0.67, 1.0 }

        local freq    = 440
        local amp     = 0.5
        local pan     = 0.0
        local tune    = 0.0
        local detune  = 25.0
        local spread  = 0.8
        local mix     = 0.5
        local attack  = 0.02
        local decay   = 0.2
        local sustain = 0.6
        local release = 0.5

        local base_note_hz = freq
        local vel = 1.0

        local phases = {}
        for i = 1, NUM_VOICES do phases[i] = (i-1) * TAU / NUM_VOICES end

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local function get_note_hz()
            return base_note_hz * 2^(tune/12)
        end

        function inst:init(sample_rate)
            sr = sample_rate
            for i = 1, NUM_VOICES do phases[i] = (i-1) * TAU / NUM_VOICES end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "freq"    then base_note_hz = value
            elseif id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value
            elseif id == "detune"  then detune  = value
            elseif id == "spread"  then spread  = value
            elseif id == "mix"     then mix     = value
            elseif id == "attack"  then attack  = value
            elseif id == "decay"   then decay   = value
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_note_hz = piper.note_to_hz(msg.note)
                    vel = msg.vel or 1.0
                    for i = 1, NUM_VOICES do phases[i] = (i-1) * TAU / NUM_VOICES end
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            elseif inlet_id == "detune" and msg.type == "float" then
                detune = piper.clamp(msg.v, 0.0, 100.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local note_hz = get_note_hz()
            -- Detune offsets in semitones (detune param is in cents)
            local det_semi = detune / 100.0
            local offsets = {
                -det_semi,
                -det_semi * 2.0/3.0,
                -det_semi * 1.0/3.0,
                0.0,
                det_semi * 1.0/3.0,
                det_semi * 2.0/3.0,
                det_semi,
            }

            -- Voice frequencies
            local voice_hz = {}
            for i = 1, NUM_VOICES do
                voice_hz[i] = note_hz * 2^(offsets[i]/12)
            end

            -- Voice amplitudes: mix blends between center-only and equal
            -- center is voice 4 (index 4)
            local voice_amp = {}
            for i = 1, NUM_VOICES do
                if i == 4 then
                    voice_amp[i] = (1.0 - mix) + mix / NUM_VOICES
                else
                    voice_amp[i] = mix / NUM_VOICES
                end
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

                local out_l, out_r = 0.0, 0.0

                for v = 1, NUM_VOICES do
                    local inc   = TAU * voice_hz[v] / sr
                    -- Sawtooth: phase 0→TAU maps to -1→+1
                    local s     = phases[v] / TAU * 2.0 - 1.0
                    local va    = voice_amp[v]

                    -- Pan for this voice
                    local vp   = piper.clamp(VOICE_PANS[v] * spread + pan, -1.0, 1.0)
                    local vl, vr = piper.pan_gains(vp)

                    out_l = out_l + s * va * vl
                    out_r = out_r + s * va * vr

                    phases[v] = (phases[v] + inc) % TAU
                end

                local scale = amp * vel * env_val
                buf[i*2+1] = out_l * scale
                buf[i*2+2] = out_r * scale
            end
        end

        function inst:reset()
            for i = 1, NUM_VOICES do phases[i] = (i-1) * TAU / NUM_VOICES end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
