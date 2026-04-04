-- Send / Receive primitives
-- These are two separate plugin definitions in one file.
-- Use require("plugins.control.send_receive") to get both.
-- Alternatively, each is its own plugin file conceptually;
-- this file returns the "send" plugin. The receive plugin is in receive.lua.

-- SEND: takes control messages on "in" and broadcasts to a named bus channel.
return {
    type    = "control",
    name    = "Send",
    version = 1,

    inlets  = {
        { id = "in", kind = "control" },
    },
    outlets = {},

    params = {
        { id="channel", label="Channel", min=0, max=0, default=0, type="enum" },
    },

    new = function(self, args)
        local inst    = {}
        local channel = args and args[1] or "send1"

        function inst:init(_sr) end

        function inst:set_param(id, value)
            if id == "channel" then channel = value end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "in" then
                -- Bus is accessed via the global piper.bus (set by app)
                -- Since the sandbox doesn't expose the bus directly,
                -- the loader sets a bus_send helper on instantiation.
                if inst._bus_send then
                    inst._bus_send(channel, msg)
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local msgs = in_bufs["in"]
            if msgs then
                for _, msg in ipairs(msgs) do
                    self:on_message("in", msg)
                end
            end
        end

        function inst:render(out_bufs, n) end
        function inst:reset() end
        function inst:destroy() end

        return inst
    end,
}
