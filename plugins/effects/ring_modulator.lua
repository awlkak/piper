-- Ring Modulator
-- Multiply input by internal carrier oscillator (sine/saw/square).

return {
    type    = "effect",
    name    = "Ring Modulator",
    version = 1,

    inlets  = {
        { id = "in",   kind = "signal"  },
        { id = "freq", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="freq",  label="Freq (Hz)", min=1,   max=5000, default=440, type="float" },
        { id="shape", label="Shape",     min=0,   max=2,    default=0,   type="int"   },
        { id="depth", label="Depth",     min=0,   max=1,    default=1.0, type="float" },
        { id="mode",  label="Mode",      min=0,   max=1,    default=0,   type="int"   },
        { id="mix",   label="Mix",       min=0,   max=1,    default=1.0, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local freq  = 440
        local shape = 0
        local depth = 1.0
        local mode  = 0
        local mix   = 1.0

        local car_phase = 0.0

        function inst:init(sample_rate)
            sr = sample_rate
            car_phase = 0.0
        end

        function inst:set_param(id, value)
            if     id == "freq"  then freq  = value
            elseif id == "shape" then shape = math.floor(value)
            elseif id == "depth" then depth = value
            elseif id == "mode"  then mode  = math.floor(value)
            elseif id == "mix"   then mix   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "freq" and msg.type == "float" then
                freq = msg.v
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local phase_inc = freq / sr
            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local xL = src[i*2+1]
                local xR = src[i*2+2]

                -- Carrier
                local carrier
                if shape == 0 then
                    carrier = math.sin(car_phase * TAU)
                elseif shape == 1 then
                    carrier = car_phase * 2 - 1
                else
                    carrier = car_phase < 0.5 and 1 or -1
                end

                local outL, outR
                if mode == 0 then
                    -- AM: (1 + carrier*depth) * 0.5
                    local am = (1 + carrier*depth) * 0.5
                    outL = xL * am
                    outR = xR * am
                else
                    -- RM: blend ring-mod and dry
                    outL = xL * carrier * depth + xL*(1-depth)
                    outR = xR * carrier * depth + xR*(1-depth)
                end

                dst[i*2+1] = xL*dry + outL*mix
                dst[i*2+2] = xR*dry + outR*mix

                car_phase = car_phase + phase_inc
                if car_phase >= 1.0 then car_phase = car_phase - 1.0 end
            end
        end

        function inst:reset()
            car_phase = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
