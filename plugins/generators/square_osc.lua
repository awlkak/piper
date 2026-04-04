-- Square Oscillator
-- Bandlimited via additive harmonics (odd partials only, up to Nyquist).

return {
    type    = "generator",
    name    = "Square Oscillator",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "freq", kind = "control" },
        { id = "amp",  kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="freq",  label="Frequency",   min=20,  max=20000, default=440, type="float" },
        { id="amp",   label="Amplitude",   min=0,   max=1,     default=0.5, type="float" },
        { id="pan",   label="Pan",         min=-1,  max=1,     default=0,   type="float" },
        { id="duty",  label="Duty Cycle",  min=0.01,max=0.99,  default=0.5, type="float" },
    },

    new = function(self, args)
        local inst   = {}
        local sr     = piper.SAMPLE_RATE
        local TAU    = 2.0 * math.pi

        local phase  = 0.0
        local freq   = self.params[1].default
        local amp    = self.params[2].default
        local pan    = self.params[3].default
        local duty   = self.params[4].default
        local active = false

        -- Precompute max harmonics count
        local function max_harmonics(f)
            -- Odd harmonics up to Nyquist
            local n = 1
            while f * (2 * n + 1) < sr * 0.45 do n = n + 1 end
            return n
        end

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "freq" then freq  = value
            elseif id == "amp"  then amp   = value
            elseif id == "pan"  then pan   = value
            elseif id == "duty" then duty  = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    freq   = piper.note_to_hz(msg.note)
                    amp    = msg.vel or amp
                    active = true
                    phase  = 0.0
                elseif msg.type == "note_off" then
                    active = false
                end
            elseif inlet_id == "freq" and msg.type == "float" then
                freq = msg.v
            elseif inlet_id == "amp"  and msg.type == "float" then
                amp = msg.v
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if not active then
                piper.buf_fill(buf, 0.0, n)
                return
            end

            local inc   = TAU * freq / sr
            local nh    = max_harmonics(freq)
            local norm  = amp * (4.0 / math.pi)
            local pan_l, pan_r = piper.pan_gains(pan)

            for i = 0, n - 1 do
                local s = 0.0
                for k = 1, nh do
                    local h = 2 * k - 1
                    s = s + math.sin(phase * h) / h
                end
                s = s * norm
                s = piper.softclip(s)
                buf[i * 2 + 1] = s * pan_l
                buf[i * 2 + 2] = s * pan_r
                phase = phase + inc
            end
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
