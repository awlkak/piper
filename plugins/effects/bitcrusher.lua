-- Bitcrusher
-- Reduces bit depth and sample rate for lo-fi digital distortion.

return {
    type    = "effect",
    name    = "Bitcrusher",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="bits",    label="Bit Depth",    min=1,   max=16,  default=8,   type="int"   },
        { id="rate",    label="Rate Crush",   min=1,   max=64,  default=1,   type="int"   },
        { id="mix",     label="Wet Mix",      min=0,   max=1,   default=1.0, type="float" },
    },

    new = function(self, args)
        local inst = {}

        local bits  = 8
        local rate  = 1
        local mix   = 1.0

        local hold_L = 0.0
        local hold_R = 0.0
        local count  = 0

        function inst:init(_sr) end

        function inst:set_param(id, value)
            if     id == "bits" then bits = math.max(1, math.floor(value))
            elseif id == "rate" then rate = math.max(1, math.floor(value))
            elseif id == "mix"  then mix  = value
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local levels = 2.0 ^ bits
            local dry    = 1.0 - mix

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Rate reduction: hold sample for 'rate' output samples
                count = count + 1
                if count >= rate then
                    count = 0
                    -- Quantize
                    hold_L = math.floor(inL * levels + 0.5) / levels
                    hold_R = math.floor(inR * levels + 0.5) / levels
                end

                dst[i * 2 + 1] = inL * dry + hold_L * mix
                dst[i * 2 + 2] = inR * dry + hold_R * mix
            end
        end

        function inst:reset() hold_L=0; hold_R=0; count=0 end
        function inst:destroy() end

        return inst
    end,
}
