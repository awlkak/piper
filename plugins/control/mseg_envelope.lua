-- MSEG Envelope
-- Multi-segment envelope with up to 8 breakpoints.

local DEFAULT_LEVELS = {1, 1, 0.8, 0.8, 0.6, 0.3, 0}
local DEFAULT_TIMES  = {0.01, 0.1, 0, 0.2, 0, 0.1, 0.3}

local params_list = {
    { id="loop_start", label="Loop Start", min=0, max=6, default=3, type="int"  },
    { id="loop_end",   label="Loop End",   min=0, max=6, default=5, type="int"  },
    { id="loop",       label="Loop",       min=0, max=1, default=0, type="bool" },
}
for i = 1, 7 do
    table.insert(params_list, {id="l"..i, label="Level "..i, min=0, max=1, default=DEFAULT_LEVELS[i], type="float"})
end
for i = 1, 7 do
    table.insert(params_list, {id="t"..i, label="Time "..i,  min=0, max=10, default=DEFAULT_TIMES[i],  type="float"})
end

return {
    type    = "control",
    name    = "MSEG Envelope",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out",  kind = "control" },
        { id = "out~", kind = "signal"  },
    },

    params = params_list,

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local loop_start = 3
        local loop_end   = 5
        local loop_on    = false

        local levels = {}; local times = {}
        for i = 1, 7 do levels[i] = DEFAULT_LEVELS[i] end
        for i = 1, 7 do times[i]  = DEFAULT_TIMES[i]  end

        local IDLE    = 0
        local RUNNING = 1
        local SUSTAIN = 2

        local state   = IDLE
        local seg     = 1     -- current segment (1..7)
        local pos     = 0.0   -- position within segment (0..1)
        local env_val = 0.0
        local note_held = false

        local function seg_start_level(s)
            return s == 1 and 0 or levels[s-1]
        end

        local function seg_end_level(s)
            return levels[s]
        end

        local function advance(dt)
            -- dt in samples
            if state == IDLE then return end

            local remaining = dt
            while remaining > 0 and state ~= IDLE do
                local seg_dur = times[seg] * sr
                if seg_dur <= 0 then
                    -- Zero-duration segment: jump immediately
                    env_val = seg_end_level(seg)
                    pos = 1.0
                else
                    local step = 1.0 / seg_dur
                    pos = pos + remaining * step
                    remaining = 0
                    if pos >= 1.0 then
                        pos = 1.0
                        env_val = seg_end_level(seg)
                        -- Move to next segment
                        if state == SUSTAIN and loop_on and seg >= loop_end then
                            seg = loop_start + 1  -- loop back
                            pos = 0.0
                        elseif seg >= 7 then
                            state = IDLE
                        else
                            seg = seg + 1
                            pos = 0.0
                            if state == RUNNING and note_held and loop_on and seg > loop_end then
                                state = SUSTAIN
                            end
                        end
                        remaining = 0
                    end
                end
            end

            if state ~= IDLE then
                local sl = seg_start_level(seg)
                local el = seg_end_level(seg)
                env_val = sl + (el - sl) * pos
            end
        end

        function inst:init(sample_rate)
            sr = sample_rate
            state = IDLE; seg = 1; pos = 0.0; env_val = 0.0; note_held = false
        end

        function inst:set_param(id, value)
            if     id == "loop_start" then loop_start = math.floor(value)
            elseif id == "loop_end"   then loop_end   = math.floor(value)
            elseif id == "loop"       then loop_on    = value >= 0.5
            else
                for i = 1, 7 do
                    if id == "l"..i then levels[i] = value; return end
                    if id == "t"..i then times[i]  = value; return end
                end
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" or msg.type == "bang" then
                    note_held = true
                    state = RUNNING; seg = 1; pos = 0.0
                elseif msg.type == "note_off" then
                    note_held = false
                    if state == SUSTAIN then
                        state = RUNNING  -- continue past loop
                    end
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]
            local sig = out_bufs["out~"]

            local sum = 0.0
            for i = 0, n - 1 do
                advance(1)
                sum = sum + env_val
                if sig then
                    sig[i*2+1] = env_val
                    sig[i*2+2] = env_val
                end
            end

            if ctl then
                table.insert(ctl, {type="float", v=sum/n})
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            state = IDLE; seg = 1; pos = 0.0; env_val = 0.0; note_held = false
        end

        function inst:destroy() end

        return inst
    end,
}
