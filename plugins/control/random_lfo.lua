-- Random LFO
-- Sample-and-hold random LFO with optional smoothing.

return {
    type    = "control",
    name    = "Random LFO",
    version = 1,

    inlets  = {
        { id = "rate",  kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="rate",   label="Rate (Hz)", min=0.01, max=40,  default=1,   type="float" },
        { id="depth",  label="Depth",     min=0,    max=1,   default=1.0, type="float" },
        { id="offset", label="Offset",    min=0,    max=1,   default=0,   type="float" },
        { id="smooth", label="Smooth",    min=0,    max=1,   default=0,   type="float" },
        { id="seed",   label="Seed",      min=0,    max=999, default=0,   type="int"   },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local rate   = 1
        local depth  = 1.0
        local offset = 0
        local smooth = 0
        local seed   = 0

        local phase   = 0.0
        local current = 0.0
        local target  = 0.0

        local function pick_target()
            target = math.random() * depth*2 - depth
        end

        function inst:init(sample_rate)
            sr = sample_rate
            phase = 0.0; current = 0.0; target = 0.0
            if seed > 0 then math.randomseed(seed) end
            pick_target()
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "depth"  then depth  = value
            elseif id == "offset" then offset = value
            elseif id == "smooth" then smooth = value
            elseif id == "seed"   then
                seed = math.floor(value)
                if seed > 0 then math.randomseed(seed) end
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "rate" and msg.type == "float" then
                rate = msg.v
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                phase = 0.0
                if seed > 0 then math.randomseed(seed) end
                pick_target()
                current = target
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]

            local phase_inc = rate / sr
            phase = phase + phase_inc * n

            while phase >= 1.0 do
                phase = phase - 1.0
                pick_target()
            end

            -- Smooth toward target
            if smooth <= 0 then
                current = target
            else
                local step = rate / sr / math.max(smooth, 0.001)
                local diff = target - current
                local move = math.min(math.abs(diff), step * n)
                current = current + (diff >= 0 and move or -move)
            end

            if ctl then
                table.insert(ctl, {type="float", v=current + offset})
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            phase = 0.0; current = 0.0; target = 0.0
            if seed > 0 then math.randomseed(seed) end
            pick_target()
        end

        function inst:destroy() end

        return inst
    end,
}
