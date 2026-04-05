-- Math Node
-- Algebraic operations on control-rate float messages.

return {
    type    = "control",
    name    = "Math Node",
    version = 1,

    inlets  = {
        { id = "in_a", kind = "control" },
        { id = "in_b", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="op",    label="Op",    min=-100, max=100,  default=2,   type="int"   },
        { id="a",     label="A",     min=-100, max=100,  default=1.0, type="float" },
        { id="b",     label="B",     min=-100, max=100,  default=0.0, type="float" },
        { id="const", label="Const", min=-100, max=100,  default=0,   type="float" },
    },

    new = function(self, args)
        local inst = {}

        local op     = 2
        local a_p    = 1.0
        local b_p    = 0.0
        local const  = 0.0

        local val_a  = 0.0
        local val_b  = 0.0
        local got_msg = false

        local function compute()
            local x = val_a
            local y = val_b ~= nil and val_b or const
            if op == 0 then return x + y
            elseif op == 1 then return x - y
            elseif op == 2 then return x * y
            elseif op == 3 then return y ~= 0 and x/y or 0
            elseif op == 4 then return math.min(x, y)
            elseif op == 5 then return math.max(x, y)
            elseif op == 6 then return math.abs(x)
            elseif op == 7 then return 1 - x
            elseif op == 8 then return a_p * x + b_p
            else return x end
        end

        function inst:init(sample_rate) end

        function inst:set_param(id, value)
            if     id == "op"    then op    = math.floor(value)
            elseif id == "a"     then a_p   = value
            elseif id == "b"     then b_p   = value
            elseif id == "const" then const = value; val_b = value
            end
        end

        -- Store pending outputs to emit in process
        local pending = {}

        function inst:on_message(inlet_id, msg)
            if msg.type == "float" then
                if inlet_id == "in_a" then val_a = msg.v
                elseif inlet_id == "in_b" then val_b = msg.v
                end
                got_msg = true
                table.insert(pending, compute())
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]
            if ctl then
                for _, v in ipairs(pending) do
                    table.insert(ctl, {type="float", v=v})
                end
            end
            pending = {}
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            val_a = 0; val_b = const; got_msg = false; pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
