-- Wavefolder
-- Iterative fold distortion with DC blocking.

return {
    type    = "effect",
    name    = "Wavefolder",
    version = 1,

    inlets  = {
        { id = "in",    kind = "signal"  },
        { id = "drive", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="drive",  label="Drive",  min=1,  max=20, default=3.0, type="float" },
        { id="stages", label="Stages", min=1,  max=4,  default=1,   type="int"   },
        { id="mix",    label="Mix",    min=0,  max=1,  default=1.0, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local drive  = 3.0
        local stages = 1
        local mix    = 1.0

        -- DC block state per channel
        local dcL, dcR     = 0, 0
        local prevL, prevR = 0, 0

        local function fold(x)
            x = x * drive
            for _ = 1, 8 do
                if     x >  1 then x =  2 - x
                elseif x < -1 then x = -2 - x
                else break end
            end
            return x
        end

        function inst:init(sample_rate)
            sr = sample_rate
            dcL, dcR = 0, 0; prevL, prevR = 0, 0
        end

        function inst:set_param(id, value)
            if     id == "drive"  then drive  = value
            elseif id == "stages" then stages = math.floor(value)
            elseif id == "mix"    then mix    = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "drive" and msg.type == "float" then
                drive = msg.v
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local xL = src[i*2+1]
                local xR = src[i*2+2]

                local fL = fold(xL)
                local fR = fold(xR)
                for _ = 2, stages do
                    fL = fold(fL / drive)  -- normalize back before re-folding
                    fR = fold(fR / drive)
                end

                -- DC block
                dcL  = dcL*0.995 + fL - prevL; prevL = fL
                dcR  = dcR*0.995 + fR - prevR; prevR = fR

                dst[i*2+1] = xL*dry + dcL*mix
                dst[i*2+2] = xR*dry + dcR*mix
            end
        end

        function inst:reset()
            dcL, dcR = 0, 0; prevL, prevR = 0, 0
        end

        function inst:destroy() end

        return inst
    end,
}
