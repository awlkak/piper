-- Chord Generator
-- Receives a single note and outputs a chord (multiple simultaneous notes).

return {
    type    = "control",
    name    = "Chord Generator",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "trig", kind = "control" },
    },

    params = {
        { id="chord_type", label="Chord Type", min=0, max=10, default=1, type="int" },
        { id="spread",     label="Spread",     min=0, max=4,  default=0, type="int" },
        { id="inversion",  label="Inversion",  min=0, max=3,  default=0, type="int" },
    },

    new = function(self, args)
        local inst = {}

        local chord_type = 1
        local spread     = 0
        local inversion  = 0

        local CHORDS = {
            [0]  = {0},
            [1]  = {0,4,7},
            [2]  = {0,3,7},
            [3]  = {0,4,7,10},
            [4]  = {0,3,7,10},
            [5]  = {0,4,7,11},
            [6]  = {0,2,7},
            [7]  = {0,5,7},
            [8]  = {0,3,6},
            [9]  = {0,4,8},
            [10] = {0,4,7,11,14},
        }

        local pending = {}

        local function build_chord(root_note)
            local intervals = CHORDS[chord_type] or CHORDS[1]
            local notes = {}
            for _, iv in ipairs(intervals) do
                table.insert(notes, root_note + iv)
            end
            -- Apply inversion: raise lower notes by octave
            for inv = 1, inversion do
                if #notes > 0 then
                    notes[1] = notes[1] + 12
                    table.sort(notes)
                end
            end
            -- Apply spread: distribute across octaves
            if spread > 0 then
                for i = 1, #notes do
                    notes[i] = notes[i] + math.floor((i-1) * spread / math.max(#notes-1,1)) * 12
                end
            end
            return notes
        end

        function inst:init(sample_rate) end

        function inst:set_param(id, value)
            if     id == "chord_type" then chord_type = math.floor(value)
            elseif id == "spread"     then spread     = math.floor(value)
            elseif id == "inversion"  then inversion  = math.floor(value)
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    local chord_notes = build_chord(msg.note)
                    for _, n in ipairs(chord_notes) do
                        table.insert(pending, {type="note", note=n, vel=msg.vel or 0.8})
                    end
                elseif msg.type == "note_off" then
                    local chord_notes = build_chord(msg.note)
                    for _, n in ipairs(chord_notes) do
                        table.insert(pending, {type="note_off", note=n, vel=0})
                    end
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local trig = out_bufs["trig"]
            if trig then
                for _, msg in ipairs(pending) do
                    table.insert(trig, msg)
                end
            end
            pending = {}
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
