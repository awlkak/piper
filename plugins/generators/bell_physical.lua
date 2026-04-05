-- Bell Physical Model
-- Inharmonic additive synthesis using real bell partial ratios.
-- Each partial decays independently; higher partials decay faster.

return {
    type    = "generator",
    name    = "Bell Physical",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",          label="Amplitude",    min=0,   max=1,   default=0.6,  type="float" },
        { id="pan",          label="Pan",          min=-1,  max=1,   default=0,    type="float" },
        { id="tune",         label="Tune (semi)",  min=-24, max=24,  default=0,    type="float" },
        { id="decay",        label="Decay",        min=0.1, max=10,  default=3.0,  type="float" },
        { id="brightness",   label="Brightness",   min=0,   max=1,   default=0.5,  type="float" },
        { id="shimmer",      label="Shimmer",      min=0,   max=1,   default=0.2,  type="float" },
        { id="num_partials", label="Num Partials", min=2,   max=6,   default=6,    type="int"   },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local NUM_MAX = 6
        local RATIOS   = { 1.0, 2.756, 5.404, 8.933, 13.34, 18.64 }
        local INIT_AMP = { 1.0, 0.67,  0.45,  0.3,   0.2,   0.13  }

        local amp          = self.params[1].default
        local pan          = self.params[2].default
        local tune         = self.params[3].default
        local decay        = self.params[4].default
        local brightness   = self.params[5].default
        local shimmer      = self.params[6].default
        local num_partials = math.floor(self.params[7].default)

        local base_hz = 440.0
        local vel     = 1.0

        local phases = {}
        local envs   = {}
        local decay_coeffs = {}

        for i = 1, NUM_MAX do
            phases[i]       = 0.0
            envs[i]         = 0.0
            decay_coeffs[i] = 0.0
        end

        local function recompute_decay_coeffs()
            for n = 1, NUM_MAX do
                local t = math.max(0.001, decay) * sr / (1.0 + (n-1) * 0.5)
                decay_coeffs[n] = math.exp(-1.0 / t)
            end
        end

        recompute_decay_coeffs()

        function inst:init(sample_rate)
            sr = sample_rate
            for i = 1, NUM_MAX do
                phases[i] = 0.0
                envs[i]   = 0.0
            end
            recompute_decay_coeffs()
        end

        function inst:set_param(id, value)
            if     id == "amp"          then amp          = value
            elseif id == "pan"          then pan          = value
            elseif id == "tune"         then tune         = value
            elseif id == "decay"        then decay = value; recompute_decay_coeffs()
            elseif id == "brightness"   then brightness   = value
            elseif id == "shimmer"      then shimmer      = value
            elseif id == "num_partials" then num_partials = math.max(2, math.floor(value))
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_hz = piper.note_to_hz(msg.note) * 2^(tune/12)
                    vel     = msg.vel or 1.0

                    -- Reset phases and set initial envelope amplitudes
                    local bpow = 1.0
                    for n = 1, NUM_MAX do
                        phases[n] = 0.0
                        envs[n]   = INIT_AMP[n] * bpow * vel
                        bpow = bpow * brightness
                    end
                    recompute_decay_coeffs()
                end
                -- note_off has no effect — bell decays naturally
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local np = math.min(num_partials, NUM_MAX)
            local pan_l, pan_r = piper.pan_gains(pan)

            -- Precompute frequency increments
            local incs = {}
            for k = 1, np do
                incs[k] = TAU * base_hz * RATIOS[k] / sr
            end

            for i = 0, n-1 do
                local sum = 0.0

                -- Main partial sum
                for k = 1, np do
                    sum = sum + math.sin(phases[k]) * envs[k]
                    envs[k]   = envs[k] * decay_coeffs[k]
                    phases[k] = phases[k] + incs[k]
                    if phases[k] > TAU * 1000 then phases[k] = phases[k] % TAU end
                end

                -- Shimmer: ring mod between adjacent partials
                local shim = 0.0
                for k = 1, np-1 do
                    shim = shim + math.sin(phases[k]) * math.sin(phases[k+1]) * shimmer * 0.1
                end

                local s = (sum + shim) * amp
                buf[i*2+1] = s * pan_l
                buf[i*2+2] = s * pan_r
            end
        end

        function inst:reset()
            for i = 1, NUM_MAX do
                phases[i] = 0.0
                envs[i]   = 0.0
            end
        end

        function inst:destroy() end

        return inst
    end,
}
