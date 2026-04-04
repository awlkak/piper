-- Chorus
-- Two-voice chorus with LFO-modulated delay lines.

return {
    type    = "effect",
    name    = "Chorus",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="rate",  label="Rate (Hz)",  min=0.1, max=5,   default=0.5, type="float" },
        { id="depth", label="Depth (ms)", min=0,   max=20,  default=7,   type="float" },
        { id="delay", label="Delay (ms)", min=1,   max=30,  default=12,  type="float" },
        { id="mix",   label="Wet Mix",   min=0,   max=1,   default=0.5, type="float" },
        { id="spread",label="Spread",    min=0,   max=1,   default=0.7, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local rate  = 0.5
        local depth = 7.0
        local delay = 12.0
        local mix   = 0.5
        local spread = 0.7

        -- Delay buffer (stereo interleaved, max 50ms)
        local MAX_DELAY_S = 0.05
        local buf_size = 0
        local bufL = {}
        local bufR = {}
        local write_pos = 0
        local lfo_phase = 0.0

        local function init_buffers()
            buf_size = math.floor(MAX_DELAY_S * sr) + 4
            bufL = {}; bufR = {}
            for i = 1, buf_size do bufL[i] = 0.0; bufR[i] = 0.0 end
            write_pos = 1
        end

        local function read_interp(buf, pos, sz)
            local fi  = math.floor(pos)
            local fr  = pos - fi
            local i0  = ((fi - 1) % sz) + 1
            local i1  = (fi % sz) + 1
            return buf[i0] + (buf[i1] - buf[i0]) * fr
        end

        function inst:init(sample_rate)
            sr = sample_rate
            init_buffers()
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "depth"  then depth  = value
            elseif id == "delay"  then delay  = value
            elseif id == "mix"    then mix    = value
            elseif id == "spread" then spread = value
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local base_d = delay / 1000.0 * sr
            local depth_s = depth / 1000.0 * sr
            local dry = 1.0 - mix

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Two LFOs 90° apart
                local lfo1 = math.sin(lfo_phase)
                local lfo2 = math.sin(lfo_phase + math.pi * 0.5)

                local d1 = base_d + depth_s * lfo1
                local d2 = base_d + depth_s * lfo2

                local rpos1 = write_pos - d1
                local rpos2 = write_pos - d2
                if rpos1 < 1 then rpos1 = rpos1 + buf_size end
                if rpos2 < 1 then rpos2 = rpos2 + buf_size end

                local wetL = read_interp(bufL, rpos1, buf_size)
                local wetR = read_interp(bufR, rpos2, buf_size)

                -- Spread: swap some wet L/R
                local outL = inL * dry + (wetL * (1-spread*0.5) + wetR * spread*0.5) * mix
                local outR = inR * dry + (wetR * (1-spread*0.5) + wetL * spread*0.5) * mix

                dst[i * 2 + 1] = outL
                dst[i * 2 + 2] = outR

                bufL[write_pos] = inL
                bufR[write_pos] = inR
                write_pos = (write_pos % buf_size) + 1

                lfo_phase = lfo_phase + TAU * rate / sr
                if lfo_phase > TAU * 1000 then lfo_phase = lfo_phase % TAU end
            end
        end

        function inst:reset()
            for i = 1, buf_size do bufL[i] = 0.0; bufR[i] = 0.0 end
            write_pos = 1
            lfo_phase = 0.0
        end

        function inst:destroy() bufL = {}; bufR = {} end

        return inst
    end,
}
