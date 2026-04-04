-- Multi Oscillator
-- Three detuned oscillators (sine, saw, square selectable) with ADSR envelope.
-- Oscillator shapes: 0=sine, 1=saw, 2=square, 3=triangle

return {
    type    = "generator",
    name    = "Multi Osc",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "amp",  kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",     label="Amplitude",   min=0,   max=1,   default=0.4,  type="float" },
        { id="pan",     label="Pan",         min=-1,  max=1,   default=0,    type="float" },
        { id="shape",   label="Shape",       min=0,   max=3,   default=1,    type="int"   },
        { id="detune",  label="Detune (ct)", min=0,   max=50,  default=8,    type="float" },
        { id="spread",  label="Spread",      min=0,   max=1,   default=0.5,  type="float" },
        { id="attack",  label="Attack (s)",  min=0,   max=2,   default=0.01, type="float" },
        { id="decay",   label="Decay (s)",   min=0,   max=2,   default=0.15, type="float" },
        { id="sustain", label="Sustain",     min=0,   max=1,   default=0.6,  type="float" },
        { id="release", label="Release (s)", min=0,   max=4,   default=0.3,  type="float" },
        { id="tune",    label="Tune (semi)", min=-24, max=24,  default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local amp     = 0.4
        local pan     = 0.0
        local shape   = 1
        local detune  = 8.0    -- cents
        local spread  = 0.5
        local attack  = 0.01
        local decay   = 0.15
        local sustain = 0.6
        local release = 0.3
        local tune    = 0.0

        local phases = {0.0, 0.0, 0.0}
        local note_hz = 440.0
        local vel     = 1.0

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local function osc(ph, sh)
            local p = ph % TAU
            if sh == 0 then
                return math.sin(p)
            elseif sh == 1 then
                return 2.0 * (p / TAU) - 1.0
            elseif sh == 2 then
                return p < math.pi and 1.0 or -1.0
            else  -- triangle
                local t = p / TAU
                return t < 0.5 and (4*t - 1) or (3 - 4*t)
            end
        end

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "shape"   then shape   = math.floor(value)
            elseif id == "detune"  then detune  = value
            elseif id == "spread"  then spread  = value
            elseif id == "attack"  then attack  = math.max(0.001, value)
            elseif id == "decay"   then decay   = math.max(0.001, value)
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = math.max(0.001, value)
            elseif id == "tune"    then tune    = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    note_hz     = piper.note_to_hz(msg.note + tune)
                    vel         = msg.vel or 1.0
                    phases[1]   = 0.0
                    phases[2]   = 0.0
                    phases[3]   = 0.0
                    env_state   = ENV_ATTACK
                    env_val     = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            elseif inlet_id == "amp" and msg.type == "float" then
                amp = msg.v
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if env_state == ENV_OFF then piper.buf_fill(buf, 0.0, n); return end

            -- Detune ratios: center, up, down (in cents -> ratio)
            local dt = detune / 1200.0  -- semitones -> octave fraction
            local hz0 = note_hz
            local hz1 = note_hz * (2 ^ dt)
            local hz2 = note_hz * (2 ^ (-dt))

            local att_inc = 1.0 / (attack  * sr)
            local dec_inc = 1.0 / (decay   * sr)
            local rel_inc = 1.0 / (release * sr)

            -- Spread: osc1=L, osc2=C, osc3=R
            local sp = spread
            local l1, r1 = 0.5 + sp*0.5, 0.5 - sp*0.5   -- left osc
            local l2, r2 = 0.5, 0.5                        -- center
            local l3, r3 = 0.5 - sp*0.5, 0.5 + sp*0.5   -- right osc
            local base_pan_l, base_pan_r = piper.pan_gains(pan)

            for i = 0, n - 1 do
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

                local s0 = osc(phases[1], shape)
                local s1 = osc(phases[2], shape)
                local s2 = osc(phases[3], shape)

                local scale = amp * vel * env_val / 3.0
                local sL = (s0 * l1 + s1 * l2 + s2 * l3) * 2.0 * scale
                local sR = (s0 * r1 + s1 * r2 + s2 * r3) * 2.0 * scale

                buf[i * 2 + 1] = sL * base_pan_l
                buf[i * 2 + 2] = sR * base_pan_r

                phases[1] = phases[1] + TAU * hz0 / sr
                phases[2] = phases[2] + TAU * hz1 / sr
                phases[3] = phases[3] + TAU * hz2 / sr
            end
        end

        function inst:reset()
            env_state = ENV_OFF
            env_val   = 0.0
            phases    = {0.0, 0.0, 0.0}
        end

        function inst:destroy() end

        return inst
    end,
}
