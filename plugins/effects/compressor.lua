-- Compressor
-- RMS-detecting feed-forward compressor with soft knee.

return {
    type    = "effect",
    name    = "Compressor",
    version = 1,

    inlets  = {
        { id = "in",  kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="threshold", label="Threshold (dB)", min=-60, max=0,   default=-12,  type="float" },
        { id="ratio",     label="Ratio",          min=1,   max=20,  default=4,    type="float" },
        { id="attack",    label="Attack (ms)",    min=0.1, max=200, default=10,   type="float" },
        { id="release",   label="Release (ms)",   min=1,   max=2000,default=100,  type="float" },
        { id="knee",      label="Knee (dB)",      min=0,   max=12,  default=3,    type="float" },
        { id="makeup",    label="Makeup (dB)",    min=0,   max=24,  default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local threshold = piper.db_to_amp(-12)
        local ratio     = 4.0
        local attack_c  = 0.0
        local release_c = 0.0
        local knee_db   = 3.0
        local makeup    = 1.0
        local thr_db    = -12.0

        local env_db    = -100.0  -- current detector level in dB

        local function update_time_constants()
            -- Coefficient for one-pole IIR: c = exp(-1 / (time_s * sr))
            local att_s = (attack_c  > 0) and (attack_c  / 1000.0) or 0.00001
            local rel_s = (release_c > 0) and (release_c / 1000.0) or 0.001
            attack_c  = math.exp(-1.0 / (att_s * sr))
            release_c = math.exp(-1.0 / (rel_s * sr))
        end

        -- Store raw ms values separately
        local att_ms  = 10.0
        local rel_ms  = 100.0

        local function recompute()
            local att_s = att_ms  / 1000.0
            local rel_s = rel_ms  / 1000.0
            attack_c  = math.exp(-1.0 / (math.max(0.0001, att_s)  * sr))
            release_c = math.exp(-1.0 / (math.max(0.001,  rel_s)  * sr))
        end

        function inst:init(sample_rate)
            sr = sample_rate
            recompute()
        end

        function inst:set_param(id, value)
            if id == "threshold" then
                thr_db    = value
            elseif id == "ratio" then
                ratio = math.max(1.001, value)
            elseif id == "attack" then
                att_ms = value; recompute()
            elseif id == "release" then
                rel_ms = value; recompute()
            elseif id == "knee" then
                knee_db = value
            elseif id == "makeup" then
                makeup = piper.db_to_amp(value)
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local half_knee = knee_db * 0.5

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Peak detection (max of L/R)
                local peak = math.max(math.abs(inL), math.abs(inR))
                local peak_db = peak > 1e-6 and (20.0 * math.log(peak) / math.log(10)) or -100.0

                -- Smooth envelope follower
                if peak_db > env_db then
                    env_db = attack_c  * env_db + (1.0 - attack_c)  * peak_db
                else
                    env_db = release_c * env_db + (1.0 - release_c) * peak_db
                end

                -- Gain computation with soft knee
                local gain_db
                local over = env_db - thr_db
                if over <= -half_knee then
                    gain_db = 0.0
                elseif over >= half_knee then
                    gain_db = (1.0 - 1.0/ratio) * (-over)
                else
                    -- Soft knee
                    local t = (over + half_knee) / knee_db
                    gain_db = (1.0 - 1.0/ratio) * (-t * t * half_knee)
                end

                local gain = piper.db_to_amp(gain_db) * makeup
                dst[i * 2 + 1] = inL * gain
                dst[i * 2 + 2] = inR * gain
            end
        end

        function inst:reset() env_db = -100.0 end
        function inst:destroy() end

        return inst
    end,
}
