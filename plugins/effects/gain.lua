-- Gain / Pan
-- Simple stereo gain and pan effect.

return {
    type    = "effect",
    name    = "Gain",
    version = 1,

    inlets  = {
        { id = "in",  kind = "signal"  },
        { id = "gain",kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="gain", label="Gain (dB)", min=-60, max=12, default=0,  type="float" },
        { id="pan",  label="Pan",       min=-1,  max=1,  default=0,  type="float" },
    },

    new = function(self, args)
        local inst  = {}
        local gain  = 1.0   -- linear
        local pan   = 0.0

        function inst:init(_sr) end

        function inst:set_param(id, value)
            if id == "gain" then
                gain = piper.db_to_amp(value)
            elseif id == "pan" then
                pan = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "gain" and msg.type == "float" then
                gain = piper.db_to_amp(msg.v)
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end
            local pan_l, pan_r = piper.pan_gains(pan)
            for i = 0, n - 1 do
                dst[i * 2 + 1] = src[i * 2 + 1] * gain * pan_l
                dst[i * 2 + 2] = src[i * 2 + 2] * gain * pan_r
            end
        end

        function inst:reset() end
        function inst:destroy() end

        return inst
    end,
}
