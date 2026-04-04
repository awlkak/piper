-- Event type definitions and constants for the sequencer.

local Event = {}

-- Note constants
Event.NOTE_OFF  = 128   -- sentinel: stop note
Event.NOTE_NONE = nil   -- empty cell

-- Effect command codes (tracker-style hex commands)
Event.FX = {
    NONE        = 0x00,
    ARPEGGIO    = 0x00,  -- 0xy: arpeggio (semitone offsets)
    PORTA_UP    = 0x01,  -- 1xx: portamento up
    PORTA_DOWN  = 0x02,  -- 2xx: portamento down
    PORTA_NOTE  = 0x03,  -- 3xx: portamento to note
    VIBRATO     = 0x04,  -- 4xy: vibrato speed/depth
    VOL_SLIDE   = 0x0A,  -- Axy: volume slide
    JUMP        = 0x0B,  -- Bxx: position jump
    SET_VOL     = 0x0C,  -- Cxx: set volume
    BREAK       = 0x0D,  -- Dxx: pattern break
    SET_SPEED   = 0x0F,  -- Fxx: set speed/BPM (< 32 = speed, >= 32 = BPM)
    RETRIG      = 0x19,  -- Qxx: retrigger note
    DELAY_NOTE  = 0x1D,  -- SDx: note delay (d ticks)
    SET_TEMPO   = 0x1F,  -- Txx: set BPM (extended)
}

-- Construct a note event message (sent to machine on_message)
function Event.note_msg(note, velocity, inst)
    return { type="note", note=note, vel=velocity or 1.0, inst=inst }
end

function Event.note_off_msg(note)
    return { type="note_off", note=note or 0 }
end

function Event.bang_msg()
    return { type="bang" }
end

function Event.float_msg(v)
    return { type="float", v=v }
end

function Event.int_msg(v)
    return { type="int", v=v }
end

function Event.list_msg(values)
    return { type="list", v=values }
end

return Event
