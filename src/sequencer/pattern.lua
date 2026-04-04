-- Pattern data structure
-- A pattern is a 2D grid of cells: rows × channels.
-- Storage is sparse: only non-empty cells are stored.
--
-- Cell fields:
--   note     : MIDI note 0-127, Event.NOTE_OFF (128), or nil (empty)
--   inst     : machine/instrument id string or nil
--   vol      : 0-255 (255 = default / inherit)
--   fx1_cmd  : effect command byte
--   fx1_val  : effect value byte
--   fx2_cmd  : second effect command
--   fx2_val  : second effect value

local Event = require("src.sequencer.event")

local Pattern = {}
Pattern.__index = Pattern

function Pattern.new(id, rows, channels)
    return setmetatable({
        id       = id or ("pat_" .. tostring(math.random(100000))),
        rows     = rows     or 32,
        channels = channels or 8,
        data     = {},      -- sparse: data[row * channels + ch + 1] = Cell
        auto     = {},      -- sparse: auto[row * channels + ch + 1] = { [param_id]=value, ... }
        label    = "",
    }, Pattern)
end

-- Get cell at (row, ch). Returns nil if empty.
function Pattern:get_cell(row, ch)
    return self.data[row * self.channels + ch + 1]
end

-- Set cell at (row, ch). Pass nil to clear.
function Pattern:set_cell(row, ch, cell)
    self.data[row * self.channels + ch + 1] = cell
end

-- Helper: set just the note field
function Pattern:set_note(row, ch, note, inst, vol)
    local idx = row * self.channels + ch + 1
    local cell = self.data[idx] or {}
    cell.note = note
    if inst   ~= nil then cell.inst    = inst end
    if vol    ~= nil then cell.vol     = vol  end
    self.data[idx] = cell
end

-- Get automation values at (row, ch). Returns nil if empty.
function Pattern:get_auto(row, ch)
    return self.auto[row * self.channels + ch + 1]
end

-- Set automation value for a param at (row, ch).
-- Call with param_id=nil to clear the whole slot.
function Pattern:set_auto(row, ch, param_id, value)
    local idx = row * self.channels + ch + 1
    if param_id == nil then
        self.auto[idx] = nil
        return
    end
    local slot = self.auto[idx] or {}
    slot[param_id] = value
    self.auto[idx] = slot
end

-- Clear a single automation param at (row, ch).
function Pattern:clear_auto(row, ch, param_id)
    local idx = row * self.channels + ch + 1
    local slot = self.auto[idx]
    if not slot then return end
    slot[param_id] = nil
    -- Remove slot if empty
    local empty = true
    for _ in pairs(slot) do empty = false; break end
    if empty then self.auto[idx] = nil end
end

-- Set an effect on a cell (slot 1 or 2)
function Pattern:set_fx(row, ch, slot, cmd, val)
    local idx = row * self.channels + ch + 1
    local cell = self.data[idx] or {}
    if slot == 1 then
        cell.fx1_cmd = cmd
        cell.fx1_val = val
    else
        cell.fx2_cmd = cmd
        cell.fx2_val = val
    end
    self.data[idx] = cell
end

-- Clear entire pattern
function Pattern:clear()
    self.data = {}
    self.auto = {}
end

-- Clear a single row across all channels
function Pattern:clear_row(row)
    for ch = 0, self.channels - 1 do
        local idx = row * self.channels + ch + 1
        self.data[idx] = nil
        self.auto[idx] = nil
    end
end

-- Resize pattern (rows or channels). Existing data is preserved where possible.
function Pattern:resize(new_rows, new_channels)
    local new_data = {}
    local new_auto = {}
    local old_ch = self.channels
    for row = 0, math.min(self.rows, new_rows) - 1 do
        for ch = 0, math.min(old_ch, new_channels) - 1 do
            local old_idx = row * old_ch + ch + 1
            local new_idx = row * new_channels + ch + 1
            if self.data[old_idx] then
                new_data[new_idx] = self.data[old_idx]
            end
            if self.auto[old_idx] then
                new_auto[new_idx] = self.auto[old_idx]
            end
        end
    end
    self.rows     = new_rows
    self.channels = new_channels
    self.data     = new_data
    self.auto     = new_auto
end

-- Serialize to plain table
function Pattern:serialize()
    local cells = {}
    for idx, cell in pairs(self.data) do
        cells[tostring(idx)] = cell
    end
    local auto_s = {}
    for idx, slot in pairs(self.auto) do
        auto_s[tostring(idx)] = slot
    end
    return {
        id       = self.id,
        rows     = self.rows,
        channels = self.channels,
        label    = self.label,
        data     = cells,
        auto     = auto_s,
    }
end

-- Deserialize from plain table
function Pattern.deserialize(t)
    local pat = Pattern.new(t.id, t.rows, t.channels)
    pat.label = t.label or ""
    for idx_str, cell in pairs(t.data or {}) do
        pat.data[tonumber(idx_str)] = cell
    end
    for idx_str, slot in pairs(t.auto or {}) do
        pat.auto[tonumber(idx_str)] = slot
    end
    return pat
end

return Pattern
