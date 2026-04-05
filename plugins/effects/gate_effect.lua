-- Gate Effect
-- Noise gate with hold time.

return {
    type    = "effect",
    name    = "Gate",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="threshold", label="Threshold (dB)", min=-80, max=0,    default=-40,  type="float" },
        { id="attack",    label="Attack (ms)",    min=0.1, max=200,  default=1,    type="float" },
        { id="hold",      label="Hold (ms)",      min=0,   max=500,  default=50,   type="float" },
        { id="release",   label="Release (ms)",   min=1,   max=2000, default=200,  type="float" },
        { id="range",     label="Range (dB)",     min=-80, max=0,    default=-60,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr        = piper.SAMPLE_RATE
        local thresh_db = self.params[1].default
        local atk_ms    = self.params[2].default
        local hold_ms   = self.params[3].default
        local rel_ms    = self.params[4].default
        local range_db  = self.params[5].default

        local CLOSED = 0; local OPEN = 1; local HOLD = 2
        local state      = CLOSED
        local env        = 0.0
        local gate_gain  = 0.0
        local hold_count = 0

        local function db2lin(db) return 10^(db/20) end

        function inst:init(sample_rate)
            sr = sample_rate
            state = CLOSED; env = 0.0; gate_gain = 0.0; hold_count = 0
        end

        function inst:set_param(id, value)
            if     id == "threshold" then thresh_db = value
            elseif id == "attack"    then atk_ms    = value
            elseif id == "hold"      then hold_ms   = value
            elseif id == "release"   then rel_ms    = value
            elseif id == "range"     then range_db  = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local thresh    = db2lin(thresh_db)
            local range_lin = db2lin(range_db)
            local atk_c     = 1 - math.exp(-1 / (atk_ms / 1000 * sr))
            local rel_c     = 1 - math.exp(-1 / (rel_ms / 1000 * sr))
            local hold_samp = math.floor(hold_ms / 1000 * sr)

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                local level = math.max(math.abs(inL), math.abs(inR))
                local coeff = level > env and atk_c or rel_c
                env = env + coeff * (level - env)

                if state == CLOSED then
                    if env >= thresh then
                        state = OPEN; hold_count = 0
                    end
                elseif state == OPEN then
                    if env < thresh then
                        state = HOLD; hold_count = 0
                    end
                elseif state == HOLD then
                    hold_count = hold_count + 1
                    if hold_count >= hold_samp then
                        state = CLOSED
                    end
                end

                local target = (state == OPEN or state == HOLD) and 1.0 or range_lin
                gate_gain = gate_gain + 0.005 * (target - gate_gain)

                dst[i*2+1] = inL * gate_gain
                dst[i*2+2] = inR * gate_gain
            end
        end

        function inst:reset()
            state = CLOSED; env = 0.0; gate_gain = 0.0; hold_count = 0
        end

        function inst:destroy() end

        return inst
    end,
}
