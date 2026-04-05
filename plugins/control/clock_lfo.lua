-- Clock LFO
-- LFO that syncs to incoming clock pulses.

return {
    type    = "control",
    name    = "Clock LFO",
    version = 1,

    inlets  = {
        { id = "clock", kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="period_beats", label="Period (beats)", min=0.25, max=16, default=1,   type="float" },
        { id="depth",        label="Depth",          min=0,    max=1,  default=1.0, type="float" },
        { id="shape",        label="Shape",          min=0,    max=3,  default=0,   type="int"   },
        { id="offset",       label="Offset",         min=-1,   max=1,  default=0,   type="float" },
        { id="phase_offset", label="Phase Offset",   min=0,    max=1,  default=0,   type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local period_beats = 1
        local depth        = 1.0
        local shape        = 0
        local offset       = 0
        local phase_offset = 0

        local phase             = 0.0
        local clock_period      = sr   -- samples between clocks (default 1 beat = 1s at 60bpm)
        local sample_count      = 0
        local prev_clock_sample = -1
        local last_clock_sample = 0

        local function lfo_val(ph)
            ph = math.fmod(ph + phase_offset, 1.0)
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
            sr = sample_rate
            phase = 0.0; sample_count = 0
            prev_clock_sample = -1; last_clock_sample = 0
            clock_period = sr
        end

        function inst:set_param(id, value)
            if     id == "period_beats" then period_beats = value
            elseif id == "depth"        then depth        = value
            elseif id == "shape"        then shape        = math.floor(value)
            elseif id == "offset"       then offset       = value
            elseif id == "phase_offset" then phase_offset = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "clock" and (msg.type == "bang" or msg.type == "float") then
                if prev_clock_sample >= 0 then
                    local new_period = sample_count - prev_clock_sample
                    if new_period > 0 then clock_period = new_period end
                end
                prev_clock_sample = sample_count
                -- Advance phase by 1/period_beats per clock beat
                phase = math.fmod(phase + 1.0/period_beats, 1.0)
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                phase = 0.0
                prev_clock_sample = -1
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            -- Interpolate phase advancement between clocks
            local phase_inc = n / (clock_period * period_beats)
            phase = math.fmod(phase + phase_inc, 1.0)
            sample_count = sample_count + n

            local ctl = out_bufs["out"]
            if ctl then
                table.insert(ctl, {type="float", v=lfo_val(phase)})
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            phase = 0.0; sample_count = 0
            prev_clock_sample = -1; clock_period = sr
        end

        function inst:destroy() end

        return inst
    end,
}
