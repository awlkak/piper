-- Auto Pan
-- LFO-driven stereo panning with multiple shapes.

return {
    type    = "effect",
    name    = "Auto Pan",
    version = 1,

    inlets  = {
        { id = "in",   kind = "signal"  },
        { id = "rate", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="rate",   label="Rate (Hz)", min=0.01, max=20, default=1,   type="float" },
        { id="width",  label="Width",     min=0,    max=1,  default=0.8, type="float" },
        { id="center", label="Center",    min=-1,   max=1,  default=0,   type="float" },
        { id="shape",  label="Shape",     min=0,    max=2,  default=0,   type="int"   },
        { id="phase",  label="Phase",     min=0,    max=1,  default=0,   type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local rate   = self.params[1].default
        local width  = self.params[2].default
        local center = self.params[3].default
        local shape  = self.params[4].default
        local phase0 = self.params[5].default

        local lfo_phase = phase0 * TAU

        local function lfo_val(ph)
            if shape == 0 then
                return math.sin(ph)
            elseif shape == 1 then
                if ph < math.pi then
                    return ph / math.pi * 2.0 - 1.0
                else
                    return 3.0 - ph / math.pi * 2.0
                end
            else
                return (ph < math.pi) and 1.0 or -1.0
            end
        end

        function inst:init(sample_rate)
            sr = sample_rate
            lfo_phase = phase0 * TAU
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "width"  then width  = value
            elseif id == "center" then center = value
            elseif id == "shape"  then shape  = math.floor(value + 0.5)
            elseif id == "phase"  then phase0 = value; lfo_phase = value * TAU
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "rate" and msg.type == "float" then
                rate = msg.v
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local inc = TAU * rate / sr

            for i = 0, n - 1 do
                local lv   = lfo_val(lfo_phase)
                local pan_pos = piper.clamp(center + width * lv, -1.0, 1.0)
                local gl, gr = piper.pan_gains(pan_pos)

                -- mono mix from stereo input then repan
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]
                local mono = (inL + inR) * 0.5

                dst[i * 2 + 1] = mono * gl
                dst[i * 2 + 2] = mono * gr

                lfo_phase = lfo_phase + inc
                if lfo_phase >= TAU then lfo_phase = lfo_phase - TAU end
            end
        end

        function inst:reset()
            lfo_phase = phase0 * TAU
        end

        function inst:destroy() end

        return inst
    end,
}
