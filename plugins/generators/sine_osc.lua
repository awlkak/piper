-- Sine Oscillator
-- Single-voice generator. Outputs a sine wave at the triggered MIDI note frequency.

return {
    type    = "generator",
    name    = "Sine Oscillator",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },    -- note on/off messages
        { id = "freq", kind = "control" },    -- override frequency (float msg)
        { id = "amp",  kind = "control" },    -- override amplitude (float msg)
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="freq",  label="Frequency",  min=20,  max=20000, default=440,  type="float" },
        { id="amp",   label="Amplitude",  min=0,   max=1,     default=0.5,  type="float" },
        { id="pan",   label="Pan",        min=-1,  max=1,     default=0,    type="float" },
        { id="tune",  label="Tune (semi)",min=-24, max=24,    default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr    = piper.SAMPLE_RATE
        local TAU   = 2.0 * math.pi

        local phase  = 0.0
        local freq   = self.params[1].default
        local amp    = self.params[2].default
        local pan    = self.params[3].default
        local tune   = self.params[4].default
        local active = false
        local base_note_hz = freq

        local function recalc_freq(hz)
            freq = hz * piper.note_to_hz(69 + tune) / 440.0
        end

        function inst:init(sample_rate)
            sr = sample_rate
            phase = 0.0
        end

        function inst:set_param(id, value)
            if id == "freq" then
                base_note_hz = value
                recalc_freq(value)
            elseif id == "amp"  then amp  = value
            elseif id == "pan"  then pan  = value
            elseif id == "tune" then
                tune = value
                recalc_freq(base_note_hz)
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_note_hz = piper.note_to_hz(msg.note)
                    recalc_freq(base_note_hz)
                    amp    = msg.vel or amp
                    active = true
                    phase  = 0.0
                elseif msg.type == "note_off" then
                    active = false
                end
            elseif inlet_id == "freq" and msg.type == "float" then
                base_note_hz = msg.v
                recalc_freq(msg.v)
            elseif inlet_id == "amp" and msg.type == "float" then
                amp = piper.clamp(msg.v, 0.0, 1.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if not active then
                piper.buf_fill(buf, 0.0, n)
                return
            end
            local inc    = TAU * freq / sr
            local pan_l, pan_r = piper.pan_gains(pan)
            for i = 0, n - 1 do
                local s = math.sin(phase) * amp
                phase   = phase + inc
                buf[i * 2 + 1] = s * pan_l
                buf[i * 2 + 2] = s * pan_r
            end
            -- Wrap to prevent float drift
            if phase > TAU * 1000 then phase = phase % TAU end
        end

        function inst:reset()
            phase  = 0.0
            active = false
        end

        function inst:destroy() end

        return inst
    end,
}
