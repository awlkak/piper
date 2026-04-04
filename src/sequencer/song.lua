-- Song structure
-- The song is an ordered list of pattern slots.
-- Each slot references a pattern by ID and carries channel→machine mappings.

local Pattern = require("src.sequencer.pattern")

local Song = {}
Song.__index = Song

function Song.new()
    return setmetatable({
        bpm        = 120,
        speed      = 6,          -- ticks per row
        loop_start = 0,
        loop_end   = nil,         -- nil = end of order list
        patterns   = {},          -- id -> Pattern
        order      = {},          -- list of OrderEntry
        -- OrderEntry: { pattern_id, machine_map }
        -- machine_map: ch (0-based int) -> machine_id string
    }, Song)
end

-- Pattern management

function Song:add_pattern(pat)
    self.patterns[pat.id] = pat
    return pat
end

function Song:remove_pattern(id)
    self.patterns[id] = nil
    -- Remove from order
    for i = #self.order, 1, -1 do
        if self.order[i].pattern_id == id then
            table.remove(self.order, i)
        end
    end
end

function Song:get_pattern(id)
    return self.patterns[id]
end

-- Order list management

function Song:append_order(pattern_id, machine_map)
    table.insert(self.order, {
        pattern_id  = pattern_id,
        machine_map = machine_map or {},
    })
    return #self.order
end

function Song:insert_order(pos, pattern_id, machine_map)
    table.insert(self.order, pos, {
        pattern_id  = pattern_id,
        machine_map = machine_map or {},
    })
end

function Song:remove_order(pos)
    table.remove(self.order, pos)
end

function Song:move_order(from_pos, to_pos)
    local entry = table.remove(self.order, from_pos)
    table.insert(self.order, to_pos, entry)
end

function Song:get_order_entry(pos)
    return self.order[pos]
end

function Song:order_length()
    return #self.order
end

-- Get the pattern at a given order position
function Song:pattern_at(order_pos)
    local entry = self.order[order_pos]
    if not entry then return nil end
    return self.patterns[entry.pattern_id]
end

-- Get the machine_id for channel ch at order position pos
function Song:machine_at(order_pos, ch)
    local entry = self.order[order_pos]
    if not entry then return nil end
    return entry.machine_map[ch]
end

-- Set channel-to-machine binding
function Song:set_machine(order_pos, ch, machine_id)
    local entry = self.order[order_pos]
    if entry then entry.machine_map[ch] = machine_id end
end

-- Effective loop end (last order index if nil)
function Song:effective_loop_end()
    return self.loop_end or #self.order
end

-- Serialize to plain table
function Song:serialize()
    local pats = {}
    for id, pat in pairs(self.patterns) do
        pats[id] = pat:serialize()
    end
    -- Serialize machine_map keys as strings for Lua table literal safety
    local order = {}
    for _, e in ipairs(self.order) do
        local mm = {}
        for ch, mid in pairs(e.machine_map) do
            mm[tostring(ch)] = mid
        end
        table.insert(order, { pattern_id = e.pattern_id, machine_map = mm })
    end
    return {
        bpm        = self.bpm,
        speed      = self.speed,
        loop_start = self.loop_start,
        loop_end   = self.loop_end,
        patterns   = pats,
        order      = order,
    }
end

-- Deserialize from plain table
function Song.deserialize(t)
    local song = Song.new()
    song.bpm        = t.bpm        or 120
    song.speed      = t.speed      or 6
    song.loop_start = t.loop_start or 0
    song.loop_end   = t.loop_end

    for id, pat_t in pairs(t.patterns or {}) do
        song.patterns[id] = Pattern.deserialize(pat_t)
    end
    for _, e in ipairs(t.order or {}) do
        local mm = {}
        for ch_str, mid in pairs(e.machine_map or {}) do
            mm[tonumber(ch_str)] = mid
        end
        table.insert(song.order, { pattern_id = e.pattern_id, machine_map = mm })
    end
    return song
end

return Song
