-- Arpeggiator
-- Chord accumulator and arpeggio pattern player.

return {
    type    = "control",
    name    = "Arpeggiator",
    version = 1,

    inlets  = {
        { id = "clock", kind = "control" },
        { id = "trig",  kind = "control" },
    },
    outlets = {
        { id = "trig", kind = "control" },
    },

    params = {
        { id="mode",     label="Mode",     min=0, max=3,  default=0,   type="int"   },
        { id="octaves",  label="Octaves",  min=1, max=4,  default=1,   type="int"   },
        { id="gate_len", label="Gate Len", min=0, max=1,  default=0.5, type="float" },
        { id="latch",    label="Latch",    min=0, max=1,  default=0,   type="bool"  },
    },

    new = function(self, args)
        local inst = {}

        local mode     = 0
        local octaves  = 1
        local gate_len = 0.5
        local latch    = false

        local chord   = {}   -- held notes
        local arp_idx = 1
        local updown_dir = 1  -- for pingpong
        local prev_note  = nil
        local pending    = {}

        local function chord_has(note)
            for _, n in ipairs(chord) do
                if n == note then return true end
            end
            return false
        end

        local function remove_note(note)
            for i = #chord, 1, -1 do
                if chord[i] == note then table.remove(chord, i); return end
            end
        end

        local function build_sequence()
            if #chord == 0 then return {} end
            -- Sort a copy
            local sorted = {}
            for _, n in ipairs(chord) do table.insert(sorted, n) end
            table.sort(sorted)
            -- Expand across octaves
            local seq = {}
            for o = 0, octaves-1 do
                for _, n in ipairs(sorted) do
                    table.insert(seq, n + o*12)
                end
            end
            if mode == 1 then
                -- Reverse
                local rev = {}
                for i = #seq, 1, -1 do table.insert(rev, seq[i]) end
                return rev
            elseif mode == 3 then
                -- Shuffle in place (random order)
                for i = #seq, 2, -1 do
                    local j = math.random(i)
                    seq[i], seq[j] = seq[j], seq[i]
                end
                return seq
            end
            return seq  -- mode 0 (up) or 2 (updown, handled during play)
        end

        local seq = {}

        function inst:init(sample_rate)
            chord = {}; arp_idx = 1; updown_dir = 1; prev_note = nil; seq = {}
        end

        function inst:set_param(id, value)
            if     id == "mode"     then mode     = math.floor(value)
            elseif id == "octaves"  then octaves  = math.floor(value)
            elseif id == "gate_len" then gate_len = value
            elseif id == "latch"    then latch    = value >= 0.5
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    if not chord_has(msg.note) then
                        table.insert(chord, msg.note)
                        seq = build_sequence()
                    end
                elseif msg.type == "note_off" then
                    if not latch then
                        remove_note(msg.note)
                        seq = build_sequence()
                    end
                end
            elseif inlet_id == "clock" and (msg.type == "bang" or msg.type == "float" or msg.type == "note") then
                if #chord == 0 then return end

                seq = build_sequence()
                if #seq == 0 then return end

                -- Note off previous
                if prev_note then
                    table.insert(pending, {type="note_off", note=prev_note, vel=0})
                    prev_note = nil
                end

                -- Handle updown (mode 2) ping-pong
                local note
                if mode == 2 then
                    note = seq[arp_idx]
                    arp_idx = arp_idx + updown_dir
                    if arp_idx > #seq then arp_idx = #seq - 1; updown_dir = -1
                    elseif arp_idx < 1 then arp_idx = 2; updown_dir = 1 end
                    arp_idx = math.max(1, math.min(arp_idx, #seq))
                else
                    if arp_idx > #seq then arp_idx = 1 end
                    note = seq[arp_idx]
                    arp_idx = arp_idx % #seq + 1
                end

                table.insert(pending, {type="note", note=note, vel=0.8})
                prev_note = note
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
            chord = {}; arp_idx = 1; updown_dir = 1; prev_note = nil; seq = {}; pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
