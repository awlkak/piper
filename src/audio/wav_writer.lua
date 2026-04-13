-- WAV Writer
-- Streaming 16-bit PCM WAV file writer.
-- Opens a file handle and appends sample blocks as they are rendered,
-- then patches the RIFF/data size headers in finalize().
--
-- Works under both Love2D (app code has io access) and LuaJIT CLI.
-- For Love2D, pass an absolute path (use love.filesystem.getSaveDirectory()).

local WavWriter = {}
WavWriter.__index = WavWriter

-- Little-endian helpers
local function le16(n)
    n = math.floor(n) % 65536
    return string.char(n % 256, math.floor(n / 256) % 256)
end

local function le32(n)
    n = math.floor(n) % (2^32)
    local b0 = n % 256;             n = math.floor(n / 256)
    local b1 = n % 256;             n = math.floor(n / 256)
    local b2 = n % 256;             n = math.floor(n / 256)
    local b3 = n % 256
    return string.char(b0, b1, b2, b3)
end

-- Create a new WAV writer.
-- path: absolute filesystem path for the output file
-- sample_rate: e.g. 44100
-- channels: 1 or 2
-- bit_depth: 16 (only 16-bit PCM supported)
function WavWriter.new(path, sample_rate, channels, bit_depth)
    local self  = setmetatable({}, WavWriter)
    channels    = channels  or 2
    bit_depth   = bit_depth or 16
    sample_rate = sample_rate or 44100

    self._path        = path
    self._sample_rate = sample_rate
    self._channels    = channels
    self._bit_depth   = bit_depth
    self._frames      = 0   -- total frames written (for header patch)

    local f, err = io.open(path, "wb")
    if not f then
        error("WavWriter: cannot open '" .. path .. "': " .. tostring(err))
    end
    self._f = f

    -- Write RIFF/WAVE/fmt /data headers with placeholder sizes
    local byte_rate   = sample_rate * channels * (math.floor(bit_depth / 8))
    local block_align = channels * (math.floor(bit_depth / 8))

    -- RIFF chunk (size placeholder = 0)
    f:write("RIFF")
    f:write(le32(0))   -- total file size - 8 (patched in finalize)
    f:write("WAVE")

    -- fmt  chunk (16 bytes for PCM)
    f:write("fmt ")
    f:write(le32(16))
    f:write(le16(1))             -- PCM format tag
    f:write(le16(channels))
    f:write(le32(sample_rate))
    f:write(le32(byte_rate))
    f:write(le16(block_align))
    f:write(le16(bit_depth))

    -- data chunk (size placeholder = 0)
    f:write("data")
    f:write(le32(0))   -- data byte count (patched in finalize)

    return self
end

-- Append n_frames of interleaved stereo float samples to the file.
-- buf: flat Lua array [L1, R1, L2, R2, ...] of floats in [-1, 1]
-- n_frames: number of frames (buf length should be n_frames * channels)
function WavWriter:write_block(buf, n_frames)
    -- Build a Lua string of 16-bit LE PCM samples
    local samples = n_frames * self._channels
    local out = {}
    for i = 1, samples do
        local v = buf[i] or 0.0
        -- Clamp and scale to int16
        if v >  1.0 then v =  1.0 end
        if v < -1.0 then v = -1.0 end
        local s = math.floor(v * 32767.0 + 0.5)
        if s >  32767 then s =  32767 end
        if s < -32768 then s = -32768 end
        -- Two's complement unsigned
        if s < 0 then s = s + 65536 end
        out[i] = string.char(s % 256, math.floor(s / 256) % 256)
    end
    self._f:write(table.concat(out))
    self._frames = self._frames + n_frames
end

-- Finalize the WAV file by patching the RIFF and data chunk size fields.
-- Must be called after all blocks have been written.
function WavWriter:finalize()
    local bytes_per_frame = self._channels * math.floor(self._bit_depth / 8)
    local data_bytes      = self._frames * bytes_per_frame
    local riff_size       = 4 + 8 + 16 + 8 + data_bytes  -- "WAVE" + fmt chunk + data chunk

    -- Patch RIFF size at byte offset 4
    self._f:seek("set", 4)
    self._f:write(le32(riff_size))

    -- Patch data size at byte offset 40 (4+4+4 + 4+4+16 + 4 = 40)
    self._f:seek("set", 40)
    self._f:write(le32(data_bytes))

    self._f:close()
    self._f = nil
end

return WavWriter
