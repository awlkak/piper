-- Envelope Follower
-- Signal amplitude detection → control float output.

return {
    type    = "control",
    name    = "Envelope Follower",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out",  kind = "control" },
        { id = "gate", kind = "control" },
    },

    params = {
        { id="attack",    label="Attack (ms)",    min=0.1,  max=200,  default=10,   type="float" },
        { id="release",   label="Release (ms)",   min=1,    max=2000, default=100,  type="float" },
        { id="mode",      label="Mode",           min=0,    max=1,    default=0,    type="int"   },
        { id="gain",      label="Gain",           min=1,    max=100,  default=1.0,  type="float" },
        { id="threshold", label="Threshold",      min=0,    max=1,    default=0.5,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local attack    = 10
        local release   = 100
        local mode      = 0
        local gain      = 1.0
        local threshold = 0.5

        local env       = 0.0
        local gate_open = false

        local function make_coeff(ms)
            return 1.0 - math.exp(-1.0 / (ms * 0.001 * sr))
        end

        function inst:init(sample_rate)
            sr = sample_rate
            env = 0.0; gate_open = false
        end

        function inst:set_param(id, value)
            if     id == "attack"    then attack    = value
            elseif id == "release"   then release   = value
            elseif id == "mode"      then mode      = math.floor(value)
            elseif id == "gain"      then gain      = value
            elseif id == "threshold" then threshold = value
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src  = in_bufs["in"]
            local ctl  = out_bufs["out"]
            local gate = out_bufs["gate"]

            local atk_c = make_coeff(attack)
            local rel_c = make_coeff(release)
            local sum   = 0.0
            local sq    = 0.0

            for i = 0, n - 1 do
                local inL = src and src[i*2+1] or 0
                local inR = src and src[i*2+2] or 0
                local level

                if mode == 0 then
                    level = math.max(math.abs(inL), math.abs(inR))
                else
                    sq = sq + inL*inL + inR*inR
                    level = 0  -- computed after loop
                end

                if mode == 0 then
                    local c = level > env and atk_c or rel_c
                    env = env + c*(level-env)
                end
                sum = sum + env
            end

            if mode == 1 then
                local rms = math.sqrt(sq / (n*2))
                local c = rms > env and atk_c or rel_c
                env = env + c*(rms - env)
                sum = env * n
            end

            local out_v = piper.clamp(env * gain, 0, 1)
            if ctl then
                table.insert(ctl, {type="float", v=out_v})
            end

            -- Gate: bang on rising edge above threshold
            if gate then
                local above = out_v >= threshold
                if above and not gate_open then
                    table.insert(gate, {type="bang"})
                end
                gate_open = above
            end
        end

        function inst:reset()
            env = 0.0; gate_open = false
        end

        function inst:destroy() end

        return inst
    end,
}
