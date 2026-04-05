-- Chaos Oscillator
-- Mode 0: logistic map driven oscillator. Mode 1: rich sine fold.

return {
    type    = "generator",
    name    = "Chaos Oscillator",
    version = 1,

    inlets  = {
        { id = "trig",  kind = "control" },
        { id = "chaos", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",     label="Amplitude",   min=0,   max=1,   default=0.5,  type="float" },
        { id="pan",     label="Pan",         min=-1,  max=1,   default=0,    type="float" },
        { id="tune",    label="Tune (semi)", min=-24, max=24,  default=0,    type="float" },
        { id="chaos",   label="Chaos",       min=0,   max=1,   default=0.8,  type="float" },
        { id="mode",    label="Mode",        min=0,   max=1,   default=0,    type="int"   },
        { id="attack",  label="Attack",      min=0,   max=2,   default=0.01, type="float" },
        { id="release", label="Release",     min=0,   max=4,   default=0.5,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local amp     = self.params[1].default
        local pan     = self.params[2].default
        local tune    = self.params[3].default
        local chaos   = self.params[4].default
        local mode    = self.params[5].default
        local attack  = self.params[6].default
        local release = self.params[7].default

        local base_hz = 440.0
        local vel     = 1.0
        local phase   = 0.0
        local accum   = 0.0
        local x       = 0.5   -- logistic map state

        local ENV_OFF, ENV_ATTACK, ENV_RELEASE = 0,1,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        function inst:init(sample_rate)
            sr    = sample_rate
            phase = 0.0
            accum = 0.0
            x     = 0.5
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value
            elseif id == "chaos"   then chaos   = value
            elseif id == "mode"    then mode    = math.floor(value)
            elseif id == "attack"  then attack  = value
            elseif id == "release" then release = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_hz = piper.note_to_hz(msg.note) * 2^(tune/12)
                    vel     = msg.vel or 1.0
                    phase   = 0.0
                    accum   = 0.0
                    x       = 0.5
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            elseif inlet_id == "chaos" and msg.type == "float" then
                chaos = piper.clamp(msg.v, 0.0, 1.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local pan_l, pan_r = piper.pan_gains(pan)
            local hz = base_hz
            local inc = TAU * hz / sr

            for i = 0, n-1 do
                -- Envelope
                if env_state == ENV_ATTACK then
                    env_val = env_val + 1.0 / (math.max(0.001, attack) * sr)
                    if env_val >= 1.0 then env_val = 1.0; env_state = ENV_RELEASE end
                elseif env_state == ENV_RELEASE then
                    env_val = env_val - env_val / (math.max(0.001, release) * sr)
                    if env_val < 0.0001 then env_val = 0.0; env_state = ENV_OFF end
                end

                local s
                if mode == 0 then
                    -- Logistic map mode
                    local r = 2.8 + chaos * 1.2
                    accum = accum + hz / sr
                    while accum >= 1.0 do
                        accum = accum - 1.0
                        x = r * x * (1.0 - x)
                    end
                    s = x * 2.0 - 1.0
                else
                    -- Rich sine mode
                    s = math.sin(phase + chaos * 4.0 * math.sin(phase * (1.0 + chaos * 3.0)))
                    phase = phase + inc
                    if phase > TAU * 1000 then phase = phase % TAU end
                end

                local out_s = s * amp * vel * env_val
                buf[i*2+1] = out_s * pan_l
                buf[i*2+2] = out_s * pan_r
            end
        end

        function inst:reset()
            phase     = 0.0
            accum     = 0.0
            x         = 0.5
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
