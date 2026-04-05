-- Transient Shaper
-- Dual envelope follower transient shaper.

return {
    type    = "effect",
    name    = "Transient Shaper",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="attack",  label="Attack (dB)",  min=-12, max=12, default=0,   type="float" },
        { id="sustain", label="Sustain (dB)", min=-12, max=12, default=0,   type="float" },
        { id="speed",   label="Speed",        min=0,   max=1,  default=0.5, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr        = piper.SAMPLE_RATE
        local attack_db = self.params[1].default
        local sustain_db= self.params[2].default
        local speed     = self.params[3].default

        local fast = 0.0
        local slow = 0.0

        function inst:init(sample_rate)
            sr = sample_rate
            fast = 0.0; slow = 0.0
        end

        function inst:set_param(id, value)
            if     id == "attack"  then attack_db  = value
            elseif id == "sustain" then sustain_db = value
            elseif id == "speed"   then speed      = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            -- Fast envelope: attack based on 0.5ms*(1-speed*0.8), release 30ms
            local fatk_ms = 0.5 * (1 - speed * 0.8)
            local frel_ms = 30
            local satk_ms = 50
            local srel_ms = 300

            local fatk = 1 - math.exp(-1 / (math.max(fatk_ms, 0.01) / 1000 * sr))
            local frel = 1 - math.exp(-1 / (frel_ms / 1000 * sr))
            local satk = 1 - math.exp(-1 / (satk_ms / 1000 * sr))
            local srel = 1 - math.exp(-1 / (srel_ms / 1000 * sr))

            local atk_lin = 2^(attack_db / 6)
            local sus_lin = 2^(sustain_db / 6)

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                local level = math.max(math.abs(inL), math.abs(inR))

                local fc = level > fast and fatk or frel
                fast = fast + fc * (level - fast)

                local sc = level > slow and satk or srel
                slow = slow + sc * (level - slow)

                local transient = math.max(0, fast - slow)
                local sustain_v = slow
                local denom = math.max(0.0001, fast)
                local t_norm = transient / denom
                local s_norm = sustain_v / denom

                local gain = 1.0 + (atk_lin - 1) * t_norm + (sus_lin - 1) * s_norm
                gain = piper.clamp(gain, 0.0, 8.0)

                dst[i*2+1] = inL * gain
                dst[i*2+2] = inR * gain
            end
        end

        function inst:reset()
            fast = 0.0; slow = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
