-- Quantizer
-- Snap incoming float/note to nearest scale degree.

return {
    type    = "control",
    name    = "Quantizer",
    version = 1,

    inlets  = {
        { id = "in",   kind = "control" },
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="scale",  label="Scale",   min=0, max=8,    default=1,    type="int" },
        { id="root",   label="Root",    min=0, max=11,   default=0,    type="int" },
        { id="octave", label="Octave",  min=0, max=8,    default=4,    type="int" },
        { id="custom", label="Custom",  min=0, max=4095, default=2741, type="int" },
    },

    new = function(self, args)
        local inst = {}

        local scale_idx = 1
        local root      = 0
        local octave    = 4
        local custom    = 2741

        -- Preset scale masks: chromatic, major, minor, pent_major, pent_minor,
        --                     whole_tone, diminished, blues, custom
        local SCALES = {4095, 2741, 1453, 661, 1193, 1365, 2730, 1257, 2741}

        local last_note = 60
        local pending   = {}

        local function bit_test(mask, s)
            return math.floor(mask / (2^s)) % 2 == 1
        end

        local function get_mask()
            local idx = scale_idx
            if idx == 9 then return custom end
            return SCALES[idx] or 4095
        end

        local function quantize(v)
            local mask = get_mask()
            local note = math.floor(v + 0.5)
            local oct  = math.floor((note - root) / 12)
            local deg  = (note - root) % 12
            -- ensure deg is positive
            if deg < 0 then deg = deg + 12; oct = oct - 1 end

            local best = deg; local best_dist = 13
            for s = 0, 11 do
                if bit_test(mask, s) then
                    local d = math.abs(s - deg)
                    if d > 6 then d = 12 - d end
                    if d < best_dist then best_dist = d; best = s end
                end
            end
            return root + oct*12 + best
        end

        function inst:init(sample_rate) end

        function inst:set_param(id, value)
            if     id == "scale"  then scale_idx = math.floor(value) + 1
            elseif id == "root"   then root      = math.floor(value)
            elseif id == "octave" then octave    = math.floor(value)
            elseif id == "custom" then custom    = math.floor(value)
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "in" and msg.type == "float" then
                last_note = quantize(msg.v)
                table.insert(pending, last_note)
            elseif inlet_id == "trig" and (msg.type == "note" or msg.type == "bang") then
                local n = msg.note and quantize(msg.note) or last_note
                last_note = n
                table.insert(pending, n)
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]
            if ctl then
                for _, note in ipairs(pending) do
                    table.insert(ctl, {type="note", note=note, vel=1.0})
                end
            end
            pending = {}
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            last_note = 60; pending = {}
        end

        function inst:destroy() end

        return inst
    end,
}
