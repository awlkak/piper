-- Multi LFO
-- Single LFO with 4 phase-offset outputs.

return {
    type    = "control",
    name    = "Multi LFO",
    version = 1,

    inlets  = {
        { id = "rate",  kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out1", kind = "control" },
        { id = "out2", kind = "control" },
        { id = "out3", kind = "control" },
        { id = "out4", kind = "control" },
    },

    params = {
        { id="rate",   label="Rate (Hz)", min=0.01, max=40,  default=1,    type="float" },
        { id="depth",  label="Depth",     min=0,    max=1,   default=1.0,  type="float" },
        { id="shape",  label="Shape",     min=0,    max=3,   default=0,    type="int"   },
        { id="phase2", label="Phase 2",   min=0,    max=1,   default=0.25, type="float" },
        { id="phase3", label="Phase 3",   min=0,    max=1,   default=0.5,  type="float" },
        { id="phase4", label="Phase 4",   min=0,    max=1,   default=0.75, type="float" },
        { id="offset", label="Offset",    min=-1,   max=1,   default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local rate   = 1
        local depth  = 1.0
        local shape  = 0
        local phase2 = 0.25
        local phase3 = 0.5
        local phase4 = 0.75
        local offset = 0

        local phase = 0.0

        local function lfo_val(ph)
            ph = math.fmod(ph, 1.0)
            if ph < 0 then ph = ph + 1.0 end
            local v
            if shape == 0 then
                v = math.sin(ph * 2*math.pi)
            elseif shape == 1 then
                v = ph < 0.5 and (ph*4-1) or (3-ph*4)
            elseif shape == 2 then
                v = ph < 0.5 and 1.0 or -1.0
            else
                v = ph*2 - 1.0
            end
            return v*depth + offset
        end

        function inst:init(sample_rate)
            sr = sample_rate; phase = 0.0
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "depth"  then depth  = value
            elseif id == "shape"  then shape  = math.floor(value)
            elseif id == "phase2" then phase2 = value
            elseif id == "phase3" then phase3 = value
            elseif id == "phase4" then phase4 = value
            elseif id == "offset" then offset = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "rate" and msg.type == "float" then
                rate = msg.v
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                phase = 0.0
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            phase = math.fmod(phase + rate/sr*n, 1.0)

            local ids = {"out1","out2","out3","out4"}
            local offsets = {0, phase2, phase3, phase4}
            for k = 1, 4 do
                local lst = out_bufs[ids[k]]
                if lst then
                    table.insert(lst, {type="float", v=lfo_val(phase + offsets[k])})
                end
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
