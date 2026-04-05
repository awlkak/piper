-- Attenuverter
-- Scale and offset a control signal. Negative amount inverts.

return {
    type    = "control",
    name    = "Attenuverter",
    version = 1,

    inlets  = {
        { id = "in", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="amount",    label="Amount",    min=-1,    max=1,   default=1.0,  type="float" },
        { id="offset",    label="Offset",    min=-1,    max=1,   default=0,    type="float" },
        { id="range_min", label="Range Min", min=-100,  max=100, default=-1,   type="float" },
        { id="range_max", label="Range Max", min=-100,  max=100, default=1,    type="float" },
    },

    new = function(self, args)
        local inst = {}

        local amount    = 1.0
        local offset    = 0.0
        local range_min = -1.0
        local range_max = 1.0

        local last_v   = 0.0
        local pending  = {}

        function inst:init(sample_rate) end

        function inst:set_param(id, value)
            if     id == "amount"    then amount    = value
            elseif id == "offset"    then offset    = value
            elseif id == "range_min" then range_min = value
            elseif id == "range_max" then range_max = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "in" and msg.type == "float" then
                last_v = msg.v
                local out_v = piper.clamp(msg.v * amount + offset, range_min, range_max)
                table.insert(pending, out_v)
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]
            if ctl then
                for _, v in ipairs(pending) do
                    table.insert(ctl, {type="float", v=v})
                end
                -- Also emit once per block with last value
                local out_v = piper.clamp(last_v * amount + offset, range_min, range_max)
                table.insert(ctl, {type="float", v=out_v})
            end
            pending = {}
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            last_v = 0; pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
