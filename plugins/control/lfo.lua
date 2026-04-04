-- LFO (Low Frequency Oscillator)
-- Outputs control-rate float messages each block.
-- Shape: sine, triangle, square, sawtooth.

return {
    type    = "control",
    name    = "LFO",
    version = 1,

    inlets  = {
        { id = "rate",  kind = "control" },
        { id = "depth", kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="rate",  label="Rate (Hz)",  min=0.01, max=40,  default=1.0,  type="float" },
        { id="depth", label="Depth",      min=0,    max=1,   default=1.0,  type="float" },
        { id="shape", label="Shape",      min=0,    max=3,   default=0,    type="int"   },
        -- 0=sine 1=triangle 2=square 3=saw
        { id="offset",label="Offset",     min=-1,   max=1,   default=0,    type="float" },
    },

    new = function(self, args)
        local inst   = {}
        local sr     = piper.SAMPLE_RATE
        local bs     = piper.BLOCK_SIZE
        local rate   = self.params[1].default
        local depth  = self.params[2].default
        local shape  = self.params[3].default
        local offset = self.params[4].default
        local phase  = 0.0   -- 0..1

        function inst:init(sample_rate)
            sr = sample_rate
            phase = 0.0
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "depth"  then depth  = value
            elseif id == "shape"  then shape  = math.floor(value)
            elseif id == "offset" then offset = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "rate"  and msg.type == "float" then rate  = msg.v
            elseif inlet_id == "depth" and msg.type == "float" then depth = msg.v
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                phase = 0.0
            end
        end

        -- LFO is a control machine; process is called each block
        -- It outputs messages on "out" by writing to out_bufs["out"] list
        function inst:process(in_bufs, out_bufs, n)
            -- Advance phase by one block worth
            local phase_inc = rate * bs / sr
            phase = (phase + phase_inc) % 1.0

            -- Compute LFO value
            local v
            local s = shape
            if s == 0 then
                v = math.sin(phase * 2.0 * math.pi)
            elseif s == 1 then
                -- Triangle
                v = phase < 0.5 and (phase * 4.0 - 1.0) or (3.0 - phase * 4.0)
            elseif s == 2 then
                -- Square
                v = phase < 0.5 and 1.0 or -1.0
            else
                -- Sawtooth
                v = phase * 2.0 - 1.0
            end
            v = v * depth + offset

            -- Push float message to outlet
            local out_list = out_bufs["out"]
            if out_list then
                table.insert(out_list, piper and { type="float", v=v } or { type="float", v=v })
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            phase = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
