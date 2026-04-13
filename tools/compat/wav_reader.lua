-- Pure Lua WAV file decoder (LuaJIT compatible)
-- Supports PCM (format 1) and IEEE float (format 3).
-- Bit depths: 8, 16, 24, 32 PCM; 32 float.
-- Returns: { samples = {}, sample_rate = n, channels = n }
-- All samples are normalized to [-1, 1] floats.

local ffi_ok, ffi = pcall(require, "ffi")

local WavReader = {}

local function read_u16_le(s, i)
    return string.byte(s, i) + string.byte(s, i+1) * 256
end

local function read_u32_le(s, i)
    return string.byte(s, i)
         + string.byte(s, i+1) * 256
         + string.byte(s, i+2) * 65536
         + string.byte(s, i+3) * 16777216
end

local function read_i16_le(s, i)
    local v = read_u16_le(s, i)
    if v >= 32768 then v = v - 65536 end
    return v
end

local function read_i24_le(s, i)
    local v = string.byte(s, i)
              + string.byte(s, i+1) * 256
              + string.byte(s, i+2) * 65536
    if v >= 8388608 then v = v - 16777216 end
    return v
end

local function read_f32_le(s, i)
    if ffi_ok then
        local buf = ffi.new("uint8_t[4]",
            string.byte(s, i), string.byte(s, i+1),
            string.byte(s, i+2), string.byte(s, i+3))
        return ffi.cast("float*", buf)[0]
    else
        -- Fallback: manual IEEE 754 decode
        local b0, b1, b2, b3 =
            string.byte(s, i), string.byte(s, i+1),
            string.byte(s, i+2), string.byte(s, i+3)
        local bits = b0 + b1*256 + b2*65536 + b3*16777216
        local sign  = (bits >= 2147483648) and -1 or 1
        local exp   = math.floor(bits / 8388608) % 256
        local mant  = bits % 8388608
        if exp == 0 then
            return sign * math.ldexp(mant, -149)
        elseif exp == 255 then
            return (mant == 0) and (sign * math.huge) or (0/0)
        else
            return sign * math.ldexp(mant + 8388608, exp - 150)
        end
    end
end

-- Load a WAV file from path.
-- Returns { samples={...}, sample_rate, channels } or raises on error.
function WavReader.load(path)
    local f, err = io.open(path, "rb")
    if not f then
        error("WavReader: cannot open '" .. path .. "': " .. tostring(err))
    end
    local data = f:read("*a")
    f:close()

    if #data < 44 then
        error("WavReader: file too small: " .. path)
    end

    -- RIFF header
    if data:sub(1, 4) ~= "RIFF" then
        error("WavReader: not a RIFF file: " .. path)
    end
    if data:sub(9, 12) ~= "WAVE" then
        error("WavReader: not a WAVE file: " .. path)
    end

    -- Scan for fmt  and data chunks
    local pos = 13
    local fmt_tag, channels, sample_rate, bits_per_sample
    local data_start, data_size

    while pos < #data - 8 do
        local id   = data:sub(pos, pos + 3)
        local size = read_u32_le(data, pos + 4)
        pos = pos + 8

        if id == "fmt " then
            fmt_tag        = read_u16_le(data, pos)
            channels       = read_u16_le(data, pos + 2)
            sample_rate    = read_u32_le(data, pos + 4)
            bits_per_sample = read_u16_le(data, pos + 14)
        elseif id == "data" then
            data_start = pos
            data_size  = size
            break
        end

        -- Advance to next chunk (chunks are word-aligned)
        pos = pos + size + (size % 2)
    end

    if not data_start then
        error("WavReader: no data chunk found in: " .. path)
    end
    if fmt_tag ~= 1 and fmt_tag ~= 3 then
        error("WavReader: unsupported format tag " .. tostring(fmt_tag) .. " in: " .. path)
    end

    local bytes_per_sample = math.floor(bits_per_sample / 8)
    local total_samples    = math.floor(data_size / bytes_per_sample)
    local samples = {}

    if fmt_tag == 1 then
        -- PCM integer
        if bits_per_sample == 8 then
            -- 8-bit PCM is unsigned [0, 255]
            for i = 1, total_samples do
                local b = string.byte(data, data_start + i - 1)
                samples[i] = (b - 128) / 128.0
            end
        elseif bits_per_sample == 16 then
            for i = 1, total_samples do
                local off = data_start + (i - 1) * 2
                samples[i] = read_i16_le(data, off) / 32768.0
            end
        elseif bits_per_sample == 24 then
            for i = 1, total_samples do
                local off = data_start + (i - 1) * 3
                samples[i] = read_i24_le(data, off) / 8388608.0
            end
        elseif bits_per_sample == 32 then
            for i = 1, total_samples do
                local off = data_start + (i - 1) * 4
                local v = read_u32_le(data, off)
                if v >= 2147483648 then v = v - 4294967296 end
                samples[i] = v / 2147483648.0
            end
        else
            error("WavReader: unsupported bit depth " .. bits_per_sample)
        end
    else
        -- IEEE float (fmt_tag == 3), 32-bit
        if bits_per_sample ~= 32 then
            error("WavReader: only 32-bit IEEE float WAV is supported, got " .. bits_per_sample)
        end
        for i = 1, total_samples do
            local off = data_start + (i - 1) * 4
            samples[i] = read_f32_le(data, off)
        end
    end

    return {
        samples     = samples,
        sample_rate = sample_rate,
        channels    = channels,
    }
end

return WavReader
