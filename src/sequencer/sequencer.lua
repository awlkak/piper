-- Sequencer
-- Tick-based timing engine.
--
-- Timing math:
--   ticks_per_minute = BPM * speed          (speed = ticks per row)
--   samples_per_tick = SAMPLE_RATE * 60 / ticks_per_minute
--
-- The sequencer tracks a fractional sample accumulator.
-- Each time Engine calls queue_drain(n_samples), the sequencer
-- checks whether a tick boundary has been crossed and fires note events.
--
-- Note events are delivered to machines via DAG.deliver_message().

local Event = require("src.sequencer.event")
local DAG   = require("src.machine.dag")

local Sequencer = {}

-- State
local song           = nil   -- Song reference (set via Sequencer.set_song)
local sample_rate    = 44100
local playing        = false

local order_pos      = 1     -- 1-based index into song.order
local row            = 0     -- current row within pattern (0-based)
local tick           = 0     -- current tick within row (0..speed-1)

local sample_accum   = 0.0   -- fractional sample counter
local samples_per_tick = 0.0 -- recomputed when BPM/speed changes

-- Channel note state (for portamento etc.)
local ch_state = {}   -- ch -> { note, machine_id }

-- Injected dependency
local deliver_fn = nil  -- function(machine_id, inlet_id, msg)
local fx_state   = {}   -- ch -> active effect state

-- Playback mode flags
local loop_pattern = false  -- when true, repeat current order slot indefinitely

function Sequencer.set_song(s)
    song = s
    Sequencer.recompute_timing()
end

function Sequencer.set_deliver(fn)
    deliver_fn = fn
end

function Sequencer.set_sample_rate(sr)
    sample_rate = sr
    Sequencer.recompute_timing()
end

function Sequencer.recompute_timing()
    if not song then return end
    -- Classic tracker timing: BPM controls tick rate, speed controls ticks per row.
    -- samples_per_tick = sample_rate * 2.5 / BPM  (matches FT2/ProTracker convention:
    --   125 BPM -> 882 samples/tick at 44100Hz; speed=6 -> 6 ticks/row)
    samples_per_tick = sample_rate * 2.5 / song.bpm
end

function Sequencer.play()
    playing = true
end

function Sequencer.restart()
    -- Stop notes, seek to start, begin playing
    for ch, state in pairs(ch_state) do
        if state.machine_id and deliver_fn then
            deliver_fn(state.machine_id, "trig", Event.note_off_msg(state.note))
        end
    end
    ch_state     = {}
    fx_state     = {}
    order_pos    = (song and song.loop_start or 0) + 1
    row          = 0
    tick         = 0
    sample_accum = 0.0
    playing      = true
end

function Sequencer.stop()
    playing = false
    -- Send note-off to all active channels
    for ch, state in pairs(ch_state) do
        if state.machine_id and deliver_fn then
            deliver_fn(state.machine_id, "trig", Event.note_off_msg(state.note))
        end
    end
    ch_state = {}
    fx_state = {}
end

function Sequencer.seek(new_order_pos, new_row)
    -- Silence active notes before jumping
    for ch, state in pairs(ch_state) do
        if state.machine_id and deliver_fn then
            deliver_fn(state.machine_id, "trig", Event.note_off_msg(state.note))
        end
    end
    ch_state     = {}
    fx_state     = {}
    order_pos    = math.max(1, new_order_pos)
    row          = math.max(0, new_row or 0)
    tick         = 0
    sample_accum = 0.0
end

function Sequencer.set_loop_pattern(enabled)
    loop_pattern = enabled
end

function Sequencer.get_loop_pattern()
    return loop_pattern
end

function Sequencer.is_playing() return playing end

function Sequencer.position()
    return { order_pos = order_pos, row = row, tick = tick }
end

-- Called by Engine.update() before each control block render.
-- n_samples: how many samples this block covers.
function Sequencer.queue_drain(n_samples)
    if not playing or not song then return end

    for _ = 1, n_samples do
        sample_accum = sample_accum + 1.0
        if sample_accum >= samples_per_tick then
            sample_accum = sample_accum - samples_per_tick
            Sequencer._advance_tick()
        end
    end
end

function Sequencer._advance_tick()
    if tick == 0 then
        -- Fire row events at the START of each row (tick 0)
        Sequencer._advance_row()
    else
        -- Process per-tick effects on subsequent ticks
        Sequencer._process_tick_effects()
    end

    tick = tick + 1
    if tick >= song.speed then
        tick = 0
    end
end

function Sequencer._advance_row()
    -- Read pattern at current position
    local entry = song.order[order_pos]
    if not entry then
        Sequencer._advance_order()
        return
    end
    local pat = song.patterns[entry.pattern_id]
    if not pat then
        Sequencer._advance_order()
        return
    end

    -- Fire note events and automation for this row
    for ch = 0, pat.channels - 1 do
        local cell = pat:get_cell(row, ch)
        if cell then
            Sequencer._fire_cell(ch, cell, entry.machine_map)
        end
        local auto_slot = pat:get_auto(row, ch)
        if auto_slot then
            local machine_id = entry.machine_map and entry.machine_map[ch]
            if machine_id then
                for param_id, value in pairs(auto_slot) do
                    DAG.set_param(machine_id, param_id, value)
                end
            end
        end
    end

    row = row + 1
    if row >= pat.rows then
        Sequencer._advance_order()  -- resets row = 0
    end
end

function Sequencer._fire_cell(ch, cell, machine_map)
    local machine_id = machine_map and machine_map[ch]
    if not machine_id then return end
    if not deliver_fn then return end

    -- Handle effects that affect sequencer state
    Sequencer._apply_row_fx(cell, ch, machine_map)

    if cell.note == Event.NOTE_OFF then
        deliver_fn(machine_id, "trig", Event.note_off_msg(
            ch_state[ch] and ch_state[ch].note or 0))
        ch_state[ch] = nil
    elseif cell.note and cell.note >= 0 and cell.note < 128 then
        local vol = cell.vol and (cell.vol / 255.0) or 1.0
        deliver_fn(machine_id, "trig", Event.note_msg(cell.note, vol, cell.inst))
        ch_state[ch] = { note = cell.note, machine_id = machine_id }
    end
end

function Sequencer._apply_row_fx(cell, ch, machine_map)
    local function apply(cmd, val)
        if cmd == Event.FX.SET_SPEED then
            if val < 32 then
                song.speed = math.max(1, val)
            else
                song.bpm = math.max(1, val)
            end
            Sequencer.recompute_timing()
        elseif cmd == Event.FX.JUMP then
            -- Defer jump to after row processing
            order_pos = math.max(1, math.min(#song.order, val + 1))
            row       = -1  -- will be incremented to 0
        elseif cmd == Event.FX.BREAK then
            row = val - 1  -- will be incremented past end
        elseif cmd == Event.FX.SET_VOL then
            -- handled by note firing
        end
    end
    if cell.fx1_cmd and cell.fx1_cmd ~= 0 then
        apply(cell.fx1_cmd, cell.fx1_val or 0)
        fx_state[ch] = { cmd = cell.fx1_cmd, val = cell.fx1_val or 0, ticks = 0 }
    end
    if cell.fx2_cmd and cell.fx2_cmd ~= 0 then
        apply(cell.fx2_cmd, cell.fx2_val or 0)
    end
end

function Sequencer._process_tick_effects()
    for ch, state in pairs(fx_state) do
        state.ticks = state.ticks + 1
        -- Arpeggio, vibrato etc. would fire here
    end
end

function Sequencer._advance_order()
    if loop_pattern then
        -- Stay on the current order slot, just reset the row
        row = 0
        return
    end
    order_pos = order_pos + 1
    local loop_end = song:effective_loop_end()
    if order_pos > loop_end then
        order_pos = (song.loop_start or 0) + 1
    end
    row = 0
end

return Sequencer
