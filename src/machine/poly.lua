-- Poly Voice Allocator (Max poly~ equivalent)
-- Wraps N instances of a plugin definition and implements voice stealing.
-- Exposes the same machine interface as a single machine,
-- but internally routes note_on/note_off to individual voices.

local Loader = require("src.machine.loader")
local DSP    = require("src.audio.dsp")

local Poly = {}
Poly.__index = Poly

-- Allocation modes
local MODE_ROUND_ROBIN = "round_robin"
local MODE_STEAL_OLDEST = "steal_oldest"

-- Create a poly wrapper around a plugin definition.
-- n_voices: number of voice instances
-- mode: allocation strategy
function Poly.new(def, n_voices, sample_rate, mode)
    assert(def.type == "generator" or def.type == "abstraction",
        "poly only wraps generator or abstraction plugins")
    n_voices  = n_voices or 4
    sample_rate = sample_rate or 44100
    mode = mode or MODE_STEAL_OLDEST

    local self = setmetatable({}, Poly)
    self.def         = def
    self.n_voices    = n_voices
    self.sample_rate = sample_rate
    self.mode        = mode
    self.voices      = {}  -- list of {instance, note, active, age}

    for i = 1, n_voices do
        local inst = Loader.instantiate(def, {}, sample_rate)
        self.voices[i] = {
            instance = inst,
            note     = -1,
            active   = false,
            age      = 0,
        }
    end

    self._age_counter = 0
    return self
end

function Poly:init(sr)
    self.sample_rate = sr
    for _, v in ipairs(self.voices) do
        if v.instance.init then v.instance:init(sr) end
    end
end

function Poly:set_param(id, value)
    for _, v in ipairs(self.voices) do
        if v.instance.set_param then v.instance:set_param(id, value) end
    end
end

function Poly:on_message(inlet_id, msg)
    if msg.type == "note" then
        if msg.vel and msg.vel > 0 then
            self:note_on(msg.note, msg.vel)
        else
            self:note_off(msg.note)
        end
    elseif msg.type == "note_off" then
        self:note_off(msg.note)
    else
        -- Forward control messages to all voices
        for _, v in ipairs(self.voices) do
            if v.instance.on_message then
                v.instance:on_message(inlet_id, msg)
            end
        end
    end
end

function Poly:note_on(note, velocity)
    local voice = self:_allocate_voice(note)
    voice.note   = note
    voice.active = true
    self._age_counter = self._age_counter + 1
    voice.age    = self._age_counter
    if voice.instance.note_on then
        voice.instance:note_on(note, velocity)
    elseif voice.instance.on_message then
        voice.instance:on_message("trig", { type="note", note=note, vel=velocity })
    end
end

function Poly:note_off(note)
    for _, v in ipairs(self.voices) do
        if v.active and v.note == note then
            v.active = false
            if v.instance.note_off then
                v.instance:note_off(note)
            elseif v.instance.on_message then
                v.instance:on_message("trig", { type="note_off", note=note })
            end
            break
        end
    end
end

function Poly:_allocate_voice(note)
    -- First: reuse a voice already playing this note
    for _, v in ipairs(self.voices) do
        if v.active and v.note == note then return v end
    end
    -- Second: use a free voice
    for _, v in ipairs(self.voices) do
        if not v.active then return v end
    end
    -- Third: steal oldest active voice
    local oldest = self.voices[1]
    for _, v in ipairs(self.voices) do
        if v.age < oldest.age then oldest = v end
    end
    -- Send note_off to stolen voice
    if oldest.instance.note_off then
        oldest.instance:note_off(oldest.note)
    end
    oldest.active = false
    return oldest
end

-- Render all voices and sum into out_bufs
function Poly:render(out_bufs, n)
    -- Zero outputs
    for _, buf in pairs(out_bufs) do
        DSP.buf_fill(buf, 0.0, n)
    end
    local voice_bufs = {}
    for id in pairs(out_bufs) do
        voice_bufs[id] = DSP.buf_new(n)
    end
    for _, v in ipairs(self.voices) do
        -- Zero voice buf
        for id, buf in pairs(voice_bufs) do
            DSP.buf_fill(buf, 0.0, n)
        end
        if v.active or true then  -- render all (envelope handles silence)
            v.instance:render(voice_bufs, n)
        end
        -- Sum into out_bufs
        for id, buf in pairs(out_bufs) do
            if voice_bufs[id] then
                DSP.buf_mix(buf, voice_bufs[id], 1.0, n)
            end
        end
    end
end

function Poly:process(in_bufs, out_bufs, n)
    self:render(out_bufs, n)
end

function Poly:reset()
    for _, v in ipairs(self.voices) do
        v.active = false
        v.note   = -1
        v.age    = 0
        if v.instance.reset then v.instance:reset() end
    end
end

function Poly:destroy()
    for _, v in ipairs(self.voices) do
        if v.instance.destroy then v.instance:destroy() end
    end
end

return Poly
