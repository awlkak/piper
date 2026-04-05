-- Step Sequencer
-- 16-step note sequencer driven by clock.

local DEFAULT_NOTES = {60,62,64,65,67,69,71,72,60,62,64,65,67,69,71,72}

local params_list = {
    { id="steps",     label="Steps",     min=1, max=16,  default=8,   type="int"   },
    { id="direction", label="Direction", min=0, max=2,   default=0,   type="int"   },
    { id="gate_len",  label="Gate Len",  min=0, max=1,   default=0.5, type="float" },
    { id="gate_hold", label="Gate Hold", min=0, max=1,   default=0,   type="float" }, -- placeholder for count
}

-- Add n1..n16
for i = 1, 16 do
    table.insert(params_list, {id="n"..i, label="Note "..i, min=0, max=127, default=DEFAULT_NOTES[i], type="int"})
end
-- Add v1..v16
for i = 1, 16 do
    table.insert(params_list, {id="v"..i, label="Vel "..i, min=0, max=1, default=0.8, type="float"})
end
-- Add g1..g16
for i = 1, 16 do
    table.insert(params_list, {id="g"..i, label="Gate "..i, min=0, max=1, default=1, type="float"})
end

return {
    type    = "control",
    name    = "Step Sequencer",
    version = 1,

    inlets  = {
        { id = "clock", kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "trig",     kind = "control" },
        { id = "step_out", kind = "control" },
    },

    params = params_list,

    gui = {
        height = 112,
        width  = 272,
        draw = function(ctx, state)
            if not state.notes then return end
            local steps   = state.steps or 8
            local cur     = state.current_step or 0
            local notes   = state.notes
            local vels    = state.vels
            local gates   = state.gates
            local T       = ctx.theme

            -- Background
            ctx.rect(0, 0, ctx.w, ctx.h, {0.07, 0.07, 0.10, 1}, nil)

            local cols   = 16
            local cw     = ctx.w / cols
            local row_h  = ctx.h / 3   -- note row, vel row, gate row

            for i = 1, cols do
                local x  = (i-1) * cw
                local active = (i <= steps)
                local is_cur = (i == cur)

                -- Column background
                local bg = active and {0.11, 0.11, 0.15, 1} or {0.08, 0.08, 0.10, 1}
                ctx.rect(x+1, 1, cw-2, ctx.h-2, bg, nil)

                if active then
                    -- Note row (top third): colored by pitch class
                    local note = notes[i] or 60
                    local pc   = note % 12
                    local hue  = pc / 12.0
                    -- Simple hue-to-rgb
                    local r2 = math.max(0, math.min(1, math.abs(hue*6-3)-1))
                    local g2 = math.max(0, math.min(1, 2-math.abs(hue*6-2)))
                    local b2 = math.max(0, math.min(1, 2-math.abs(hue*6-4)))
                    local dim = is_cur and 1.0 or 0.5
                    ctx.rect(x+1, 1, cw-2, row_h-2,
                             {r2*dim, g2*dim, b2*dim, 1}, nil)
                    -- Note name (only if wide enough)
                    if cw > 12 then
                        local names = {"C","C#","D","D#","E","F","F#","G","G#","A","A#","B"}
                        local oct = math.floor(note/12) - 1
                        local nm  = (names[pc+1] or "?") .. tostring(oct)
                        ctx.label(nm, x+1, 1, cw-2, row_h-2,
                                  {1,1,1, is_cur and 1.0 or 0.7},
                                  ctx.theme.font_small, "center")
                    end

                    -- Velocity row (middle third): bar height proportional to vel
                    local vel = vels[i] or 0.8
                    local vh  = math.floor((row_h-4) * vel)
                    ctx.rect(x+2, row_h + (row_h-4-vh), cw-4, vh,
                             is_cur and T.accent or {0.35, 0.60, 0.35, 1}, nil)
                    ctx.rect(x+1, row_h, cw-2, row_h-1,
                             nil, {0.20, 0.20, 0.25, 1})

                    -- Gate row (bottom third): filled = on, outline = off
                    local gate = (gates[i] or 1) > 0.5
                    local gc   = gate and (is_cur and T.accent or {0.30,0.65,0.30,1})
                                      or {0.15, 0.15, 0.20, 1}
                    ctx.rect(x+2, row_h*2+2, cw-4, row_h-4, gc, {0.25,0.25,0.30,1})
                else
                    -- Inactive step: dim placeholder
                    ctx.rect(x+2, 2, cw-4, ctx.h-4, {0.09,0.09,0.11,1}, {0.14,0.14,0.18,1})
                end

                -- Column separator
                ctx.line(x, 0, x, ctx.h, {0.14,0.14,0.18,1}, 1)
            end
            -- Row separators
            ctx.line(0, row_h,   ctx.w, row_h,   {0.18,0.18,0.22,1}, 1)
            ctx.line(0, row_h*2, ctx.w, row_h*2, {0.18,0.18,0.22,1}, 1)
        end,

        on_event = function(ctx, state, ev)
            if ev.type ~= "pointer_down" then return false end
            if not state.notes then return false end
            local steps = state.steps or 8
            local cols  = 16
            local cw    = ctx.w / cols
            local row_h = ctx.h / 3
            local col   = math.floor(ev.x / cw) + 1
            if col < 1 or col > cols then return false end
            -- Gate row click = toggle gate
            if ev.y >= row_h * 2 then
                state._toggle_gate = col
                return true
            end
            return false
        end,
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local steps     = 8
        local direction = 0
        local gate_len  = 0.5

        local notes = {}; local vels = {}; local gates = {}
        for i = 1, 16 do
            notes[i] = DEFAULT_NOTES[i]
            vels[i]  = 0.8
            gates[i] = 1
        end

        local step        = 1
        local ping_dir    = 1   -- for pingpong
        local prev_note   = nil
        local clock_period     = sr  -- estimated samples per clock
        local last_clock_sample = 0
        local sample_count      = 0
        local gate_off_at       = -1  -- sample count when to send note_off

        local pending = {}

        local function send_note_off(n)
            if n then
                table.insert(pending, {outlet="trig", msg={type="note_off", note=n, vel=0}})
            end
        end

        local function advance_step()
            local s = steps
            if direction == 0 then
                step = step % s + 1
            elseif direction == 1 then
                step = step - 1
                if step < 1 then step = s end
            else
                -- pingpong
                step = step + ping_dir
                if step > s then step = s - 1; ping_dir = -1
                elseif step < 1 then step = 2; ping_dir = 1 end
                step = math.max(1, math.min(step, s))
            end
        end

        function inst:init(sample_rate)
            sr = sample_rate
            step = 1; ping_dir = 1; prev_note = nil
            gate_off_at = -1; sample_count = 0
        end

        function inst:set_param(id, value)
            if     id == "steps"     then steps     = math.floor(value)
            elseif id == "direction" then direction = math.floor(value)
            elseif id == "gate_len"  then gate_len  = value
            elseif id == "gate_hold" then -- unused placeholder
            else
                for i = 1, 16 do
                    if id == "n"..i then notes[i] = math.floor(value); return end
                    if id == "v"..i then vels[i]  = value; return end
                    if id == "g"..i then gates[i] = value; return end
                end
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "clock" and (msg.type == "bang" or msg.type == "float" or msg.type == "note") then
                -- Update clock period estimate
                local new_period = sample_count - last_clock_sample
                if new_period > 0 then clock_period = new_period end
                last_clock_sample = sample_count

                advance_step()

                -- Note off previous
                if prev_note then
                    send_note_off(prev_note)
                    prev_note = nil
                end

                if gates[step] >= 0.5 then
                    local n = notes[step]; local v = vels[step]
                    table.insert(pending, {outlet="trig", msg={type="note", note=n, vel=v}})
                    table.insert(pending, {outlet="step_out", msg={type="float", v=step}})
                    prev_note = n
                    gate_off_at = sample_count + math.floor(clock_period * gate_len)
                end

            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                if prev_note then send_note_off(prev_note); prev_note = nil end
                step = 1; ping_dir = 1; gate_off_at = -1
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            -- Check if gate_off should fire during this block
            if gate_off_at >= 0 and gate_off_at <= sample_count + n and prev_note then
                send_note_off(prev_note)
                prev_note = nil
                gate_off_at = -1
            end

            local trig     = out_bufs["trig"]
            local step_out = out_bufs["step_out"]

            for _, p in ipairs(pending) do
                if p.outlet == "trig" and trig then
                    table.insert(trig, p.msg)
                elseif p.outlet == "step_out" and step_out then
                    table.insert(step_out, p.msg)
                end
            end
            pending = {}
            sample_count = sample_count + n
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            step = 1; ping_dir = 1; prev_note = nil
            gate_off_at = -1; sample_count = 0; pending = {}
        end

        function inst:get_ui_state()
            local n, v, g = {}, {}, {}
            for i = 1, 16 do
                n[i] = notes[i] or 60
                v[i] = vels[i]  or 0.8
                g[i] = gates[i] or 1
            end
            return {
                notes        = n,
                vels         = v,
                gates        = g,
                steps        = steps,
                current_step = step,
            }
        end

        function inst:destroy() end

        return inst
    end,
}
