-- Flanger
-- Short LFO-modulated delay with feedback, producing comb-filter sweeping.

return {
    type    = "effect",
    name    = "Flanger",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="rate",     label="Rate (Hz)",    min=0.01, max=5,  default=0.3,  type="float" },
        { id="depth",    label="Depth (ms)",   min=0,    max=5,  default=2.5,  type="float" },
        { id="delay",    label="Min Delay(ms)",min=0.1,  max=10, default=0.5,  type="float" },
        { id="feedback", label="Feedback",     min=-0.95,max=0.95,default=0.6, type="float" },
        { id="mix",      label="Wet Mix",      min=0,    max=1,  default=0.5,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local rate     = 0.3
        local depth    = 2.5
        local delay_ms = 0.5
        local feedback = 0.6
        local mix      = 0.5

        local MAX_S  = 0.015
        local buf_size = 0
        local bufL = {}
        local bufR = {}
        local write_pos = 1
        local lfo_phase = 0.0

        local function init_buf()
            buf_size = math.floor(MAX_S * sr) + 4
            bufL = {}; bufR = {}
            for i = 1, buf_size do bufL[i] = 0.0; bufR[i] = 0.0 end
        end

        local function read_interp(buf, pos, sz)
            local fi = math.floor(pos)
            local fr = pos - fi
            local i0 = ((fi - 1) % sz) + 1
            local i1 = (fi      % sz) + 1
            return buf[i0] + (buf[i1] - buf[i0]) * fr
        end

        function inst:init(sample_rate)
            sr = sample_rate
            init_buf()
        end

        function inst:set_param(id, value)
            if     id == "rate"     then rate     = value
            elseif id == "depth"    then depth    = value
            elseif id == "delay"    then delay_ms = value
            elseif id == "feedback" then feedback = value
            elseif id == "mix"      then mix      = value
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local base_d  = delay_ms / 1000.0 * sr
            local depth_s = depth    / 1000.0 * sr
            local dry     = 1.0 - mix

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                local lfo = math.sin(lfo_phase)
                local d   = math.max(1, base_d + depth_s * lfo)

                local rpos = write_pos - d
                if rpos < 1 then rpos = rpos + buf_size end

                local wetL = read_interp(bufL, rpos, buf_size)
                local wetR = read_interp(bufR, rpos, buf_size)

                bufL[write_pos] = inL + wetL * feedback
                bufR[write_pos] = inR + wetR * feedback
                write_pos = (write_pos % buf_size) + 1

                dst[i * 2 + 1] = inL * dry + wetL * mix
                dst[i * 2 + 2] = inR * dry + wetR * mix

                lfo_phase = lfo_phase + TAU * rate / sr
                if lfo_phase > TAU * 1000 then lfo_phase = lfo_phase % TAU end
            end
        end

        function inst:reset()
            for i = 1, buf_size do bufL[i] = 0.0; bufR[i] = 0.0 end
            write_pos = 1; lfo_phase = 0.0
        end
        function inst:destroy() bufL = {}; bufR = {} end

        return inst
    end,
}
