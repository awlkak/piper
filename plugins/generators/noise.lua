-- Noise Generator
-- White noise and pink noise (Paul Kellett's method).

return {
    type    = "generator",
    name    = "Noise",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "amp",  kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="amp",   label="Amplitude", min=0,  max=1,   default=0.5,  type="float" },
        { id="color", label="Color",     min=0,  max=1,   default=0,    type="float" },
        -- color: 0 = white, 1 = pink
        { id="pan",   label="Pan",       min=-1, max=1,   default=0,    type="float" },
    },

    new = function(self, args)
        local inst   = {}
        local sr     = piper.SAMPLE_RATE
        local amp    = self.params[1].default
        local color  = self.params[2].default
        local pan    = self.params[3].default
        local active = false

        -- Pink noise state (Paul Kellett 3-pole)
        local b0, b1, b2 = 0, 0, 0
        local b3, b4, b5, b6 = 0, 0, 0, 0

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "amp"   then amp   = value
            elseif id == "color" then color = value
            elseif id == "pan"   then pan   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" or msg.type == "bang" then
                    amp    = msg.vel or amp
                    active = true
                elseif msg.type == "note_off" then
                    active = false
                end
            elseif inlet_id == "amp" and msg.type == "float" then
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
            local pan_l, pan_r = piper.pan_gains(pan)

            for i = 0, n - 1 do
                local white = math.random() * 2.0 - 1.0
                local s
                if color < 0.5 then
                    s = white
                else
                    -- Pink noise via Paul Kellett approximation
                    b0 = 0.99886 * b0 + white * 0.0555179
                    b1 = 0.99332 * b1 + white * 0.0750759
                    b2 = 0.96900 * b2 + white * 0.1538520
                    b3 = 0.86650 * b3 + white * 0.3104856
                    b4 = 0.55000 * b4 + white * 0.5329522
                    b5 = -0.7616 * b5 - white * 0.0168980
                    local pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
                    b6 = white * 0.115926
                    s = piper.clamp(pink * 0.11, -1.0, 1.0)
                end
                s = s * amp
                buf[i * 2 + 1] = s * pan_l
                buf[i * 2 + 2] = s * pan_r
            end
        end

        function inst:reset()
            active = false
            b0,b1,b2,b3,b4,b5,b6 = 0,0,0,0,0,0,0
        end

        function inst:destroy() end

        return inst
    end,
}
