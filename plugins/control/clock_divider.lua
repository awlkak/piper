-- Clock Divider
-- Divides incoming clock into 4 outputs at configurable ratios.

return {
    type    = "control",
    name    = "Clock Divider",
    version = 1,

    inlets  = {
        { id = "clock", kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out1", kind = "control" },
        { id = "out2", kind = "control" },
        { id = "out3", kind = "control" },
        { id = "out4", kind = "control" },
    },

    params = {
        { id="div1", label="Div 1", min=1, max=32, default=1, type="int" },
        { id="div2", label="Div 2", min=1, max=32, default=2, type="int" },
        { id="div3", label="Div 3", min=1, max=32, default=4, type="int" },
        { id="div4", label="Div 4", min=1, max=32, default=8, type="int" },
    },

    new = function(self, args)
        local inst = {}

        local divs     = {1, 2, 4, 8}
        local counters = {0, 0, 0, 0}

        function inst:init(sample_rate) end

        function inst:set_param(id, value)
            if     id == "div1" then divs[1] = math.floor(value)
            elseif id == "div2" then divs[2] = math.floor(value)
            elseif id == "div3" then divs[3] = math.floor(value)
            elseif id == "div4" then divs[4] = math.floor(value)
            end
        end

        local out_ids = {"out1","out2","out3","out4"}

        function inst:on_message(inlet_id, msg)
            -- handled in process via out_bufs; stash pending bangs
        end

        -- We need on_message to fire bangs, but we don't have out_bufs there.
        -- Use a pending list approach.
        local pending = {}

        function inst:on_message(inlet_id, msg)
            if inlet_id == "clock" and (msg.type == "bang" or msg.type == "float" or msg.type == "note") then
                for k = 1, 4 do
                    counters[k] = counters[k] + 1
                    if counters[k] >= divs[k] then
                        counters[k] = 0
                        table.insert(pending, k)
                    end
                end
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                counters = {0, 0, 0, 0}
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            for _, k in ipairs(pending) do
                local lst = out_bufs[out_ids[k]]
                if lst then table.insert(lst, {type="bang"}) end
            end
            pending = {}
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            counters = {0, 0, 0, 0}; pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
