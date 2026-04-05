-- Pad Generator
-- 12 detuned sine oscillators for lush pad sounds with Gaussian amplitude window.

return {
    type    = "generator",
    name    = "Pad Generator",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",     label="Amplitude",   min=0,    max=1,    default=0.4,  type="float" },
        { id="pan",     label="Pan",         min=-1,   max=1,    default=0,    type="float" },
        { id="tune",    label="Tune (semi)", min=-24,  max=24,   default=0,    type="float" },
        { id="voices",  label="Voices",      min=2,    max=12,   default=8,    type="int"   },
        { id="detune",  label="Detune",      min=0,    max=200,  default=30,   type="float" },
        { id="spread",  label="Spread",      min=0,    max=1,    default=0.9,  type="float" },
        { id="attack",  label="Attack",      min=0.1,  max=10,   default=2.0,  type="float" },
        { id="decay",   label="Decay",       min=0,    max=4,    default=0.5,  type="float" },
        { id="sustain", label="Sustain",     min=0,    max=1,    default=0.8,  type="float" },
        { id="release", label="Release",     min=0.1,  max=20,   default=4.0,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local MAX_VOICES = 12

        local amp     = self.params[1].default
        local pan     = self.params[2].default
        local tune    = self.params[3].default
        local voices  = math.floor(self.params[4].default)
        local detune  = self.params[5].default
        local spread  = self.params[6].default
        local attack  = self.params[7].default
        local decay   = self.params[8].default
        local sustain = self.params[9].default
        local release = self.params[10].default

        local base_hz = 440.0
        local vel     = 1.0
        local phases  = {}
        for i = 1, MAX_VOICES do phases[i] = 0.0 end

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        function inst:init(sample_rate)
            sr = sample_rate
            for i = 1, MAX_VOICES do phases[i] = 0.0 end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value
            elseif id == "voices"  then voices  = math.max(2, math.floor(value))
            elseif id == "detune"  then detune  = value
            elseif id == "spread"  then spread  = value
            elseif id == "attack"  then attack  = value
            elseif id == "decay"   then decay   = value
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_hz = piper.note_to_hz(msg.note) * 2^(tune/12)
                    vel = msg.vel or 1.0
                    for i = 1, MAX_VOICES do phases[i] = 0.0 end
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local nv = voices
            local center = (nv - 1) / 2.0
            local sigma2 = (nv / 2.0)^2

            -- Precompute voice parameters
            local voice_hz   = {}
            local voice_amp  = {}
            local voice_l    = {}
            local voice_r    = {}
            local amp_sum    = 0.0

            for iv = 0, nv-1 do
                -- Detune offset in cents
                local offset_cents = (nv > 1) and ((iv - center) * detune / math.max(1, nv-1)) or 0.0
                voice_hz[iv+1] = base_hz * 2^(offset_cents / 1200.0)

                -- Gaussian amplitude window
                local diff = iv - center
                local ga   = math.exp(-(diff * diff) / sigma2)
                voice_amp[iv+1] = ga
                amp_sum = amp_sum + ga

                -- Pan per voice
                local pan_pos = (nv > 1) and ((iv / (nv-1)) * 2.0 - 1.0) or 0.0
                local vp = piper.clamp(pan_pos * spread + pan, -1.0, 1.0)
                local vl, vr = piper.pan_gains(vp)
                voice_l[iv+1] = vl
                voice_r[iv+1] = vr
            end

            -- Normalize amplitudes
            if amp_sum > 0 then
                for iv = 1, nv do
                    voice_amp[iv] = voice_amp[iv] / amp_sum
                end
            end

            -- Precompute increments
            local incs = {}
            for iv = 1, nv do
                incs[iv] = TAU * voice_hz[iv] / sr
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
                for iv = 1, nv do
                    local s = math.sin(phases[iv]) * voice_amp[iv]
                    out_l = out_l + s * voice_l[iv]
                    out_r = out_r + s * voice_r[iv]
                    phases[iv] = phases[iv] + incs[iv]
                    if phases[iv] > TAU * 1000 then phases[iv] = phases[iv] % TAU end
                end

                local scale = amp * vel * env_val
                buf[i*2+1] = out_l * scale
                buf[i*2+2] = out_r * scale
            end
        end

        function inst:reset()
            for i = 1, MAX_VOICES do phases[i] = 0.0 end
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
