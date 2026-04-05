-- Tremolo
-- Amplitude modulation via internal LFO with multiple shapes and stereo mode.

return {
    type    = "effect",
    name    = "Tremolo",
    version = 1,

    inlets  = {
        { id = "in",    kind = "signal"  },
        { id = "rate",  kind = "control" },
        { id = "depth", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="rate",         label="Rate (Hz)",      min=0.1, max=20,  default=4,    type="float" },
        { id="depth",        label="Depth",          min=0,   max=1,   default=0.7,  type="float" },
        { id="shape",        label="Shape",          min=0,   max=3,   default=0,    type="int"   },
        { id="stereo",       label="Stereo",         min=0,   max=1,   default=0,    type="int"   },
        { id="phase_offset", label="Phase Offset",   min=0,   max=1,   default=0.25, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local rate         = self.params[1].default
        local depth        = self.params[2].default
        local shape        = self.params[3].default
        local stereo       = self.params[4].default
        local phase_offset = self.params[5].default

        local lfo_phase   = 0.0
        local sh_value    = 0.0  -- S&H held value
        local sh_prev_cyc = false -- was phase previously in "late" portion

        local function lfo_out(ph)
            if shape == 0 then
                return math.sin(ph)
            elseif shape == 1 then
                -- triangle
                if ph < math.pi then
                    return ph / math.pi * 2.0 - 1.0
                else
                    return 3.0 - ph / math.pi * 2.0
                end
            elseif shape == 2 then
                return (ph < math.pi) and 1.0 or -1.0
            else
                -- S&H: value held per cycle, updated by caller
                return sh_value
            end
        end

        function inst:init(sample_rate)
            sr = sample_rate
            lfo_phase = 0.0
        end

        function inst:set_param(id, value)
            if     id == "rate"         then rate         = value
            elseif id == "depth"        then depth        = value
            elseif id == "shape"        then shape        = math.floor(value + 0.5)
            elseif id == "stereo"       then stereo       = math.floor(value + 0.5)
            elseif id == "phase_offset" then phase_offset = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if     inlet_id == "rate"  then rate  = msg.v
                elseif inlet_id == "depth" then depth = msg.v
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local inc = TAU * rate / sr

            for i = 0, n - 1 do
                -- S&H: detect cycle reset
                if shape == 3 then
                    local prev_late = lfo_phase > TAU * 0.9
                    local curr_late = (lfo_phase + inc) > TAU
                    if not prev_late and curr_late then
                        sh_value = math.random() * 2.0 - 1.0
                    end
                end

                local lL = lfo_out(lfo_phase)
                local gainL = 1.0 - depth * (0.5 - lL * 0.5)

                local gainR
                if stereo == 1 then
                    local ph_r = math.fmod(lfo_phase + phase_offset * TAU, TAU)
                    local lR = lfo_out(ph_r)
                    gainR = 1.0 - depth * (0.5 - lR * 0.5)
                else
                    gainR = gainL
                end

                dst[i * 2 + 1] = src[i * 2 + 1] * gainL
                dst[i * 2 + 2] = src[i * 2 + 2] * gainR

                lfo_phase = lfo_phase + inc
                if lfo_phase >= TAU then lfo_phase = lfo_phase - TAU end
            end
        end

        function inst:reset()
            lfo_phase = 0.0
            sh_value  = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
