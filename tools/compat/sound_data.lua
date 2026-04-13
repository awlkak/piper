-- SoundData shim for LuaJIT CLI
-- Implements the Love2D SoundData interface used by Piper plugins (sampler etc.)
-- Constructor modes:
--   SoundData.new(path)                         -- load from WAV file
--   SoundData.new(n_frames, rate, bits, ch)     -- blank buffer

local SoundData = {}
SoundData.__index = SoundData

function SoundData.new(arg, sample_rate, bits, channels)
    local self = setmetatable({}, SoundData)

    if type(arg) == "string" then
        -- Load from file
        local WavReader = require("tools.compat.wav_reader")
        local result    = WavReader.load(arg)
        self._samples  = result.samples
        self._rate     = result.sample_rate
        self._channels = result.channels
        self._count    = #result.samples
    else
        -- Blank buffer: arg = n_frames
        local n  = (arg or 0) * (channels or 2)
        local t  = {}
        for i = 1, n do t[i] = 0.0 end
        self._samples  = t
        self._rate     = sample_rate or 44100
        self._channels = channels    or 2
        self._count    = n
    end

    return self
end

-- getSample / setSample use 0-based flat indices (Love2D convention)
function SoundData:getSample(i)
    return self._samples[i + 1] or 0.0
end

function SoundData:setSample(i, v)
    self._samples[i + 1] = v
end

function SoundData:getSampleCount()
    return self._count
end

function SoundData:getSampleRate()
    return self._rate
end

function SoundData:getChannelCount()
    return self._channels
end

return SoundData
