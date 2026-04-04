-- DSP utility functions exposed to plugins and used internally

local DSP = {}

-- Convert MIDI note number to frequency in Hz
-- A4 = MIDI 69 = 440 Hz
function DSP.note_to_hz(note)
    return 440.0 * 2.0 ^ ((note - 69) / 12.0)
end

-- Convert decibels to linear amplitude
function DSP.db_to_amp(db)
    return 10.0 ^ (db / 20.0)
end

-- Convert linear amplitude to decibels
function DSP.amp_to_db(amp)
    if amp <= 0 then return -math.huge end
    return 20.0 * math.log(amp) / math.log(10)
end

-- Clamp value between lo and hi
function DSP.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- Linear interpolation
function DSP.lerp(a, b, t)
    return a + (b - a) * t
end

-- Fill a buffer (plain Lua array, interleaved stereo) with a constant value
-- n = number of frames (buffer length = n * 2)
function DSP.buf_fill(buf, val, n)
    local len = n * 2
    for i = 1, len do
        buf[i] = val
    end
end

-- Mix src into dst with gain: dst[i] += src[i] * gain
-- n = number of frames
function DSP.buf_mix(dst, src, gain, n)
    local len = n * 2
    for i = 1, len do
        dst[i] = dst[i] + src[i] * gain
    end
end

-- Copy src into dst
-- n = number of frames
function DSP.buf_copy(dst, src, n)
    local len = n * 2
    for i = 1, len do
        dst[i] = src[i]
    end
end

-- Scale buffer in-place by gain
function DSP.buf_scale(buf, gain, n)
    local len = n * 2
    for i = 1, len do
        buf[i] = buf[i] * gain
    end
end

-- Allocate a zeroed interleaved stereo buffer of n frames
function DSP.buf_new(n)
    local buf = {}
    local len = n * 2
    for i = 1, len do buf[i] = 0.0 end
    return buf
end

-- Soft-clip / tanh approximation to prevent hard clipping
-- Approx: x / (1 + |x|)  (cheaper than math.tanh)
function DSP.softclip(x)
    return x / (1.0 + math.abs(x))
end

-- Hard clamp to [-1, 1]
function DSP.hardclip(x)
    if x >  1.0 then return  1.0 end
    if x < -1.0 then return -1.0 end
    return x
end

-- Pan law: equal-power pan (pan in [-1, 1])
-- Returns left_gain, right_gain
function DSP.pan_gains(pan)
    local angle = (pan + 1.0) * 0.25 * math.pi  -- 0 to pi/2
    return math.cos(angle), math.sin(angle)
end

-- Biquad lowpass coefficients (returns b0,b1,b2,a1,a2)
function DSP.biquad_lowpass(cutoff, resonance, sample_rate)
    local w0    = 2.0 * math.pi * cutoff / sample_rate
    local cosw0 = math.cos(w0)
    local sinw0 = math.sin(w0)
    local alpha = sinw0 / (2.0 * resonance)
    local norm  = 1.0 / (1.0 + alpha)
    local b0    = ((1.0 - cosw0) * 0.5) * norm
    local b1    = (1.0 - cosw0) * norm
    local b2    = b0
    local a1    = (-2.0 * cosw0) * norm
    local a2    = (1.0 - alpha) * norm
    return b0, b1, b2, a1, a2
end

-- Biquad highpass coefficients
function DSP.biquad_highpass(cutoff, resonance, sample_rate)
    local w0    = 2.0 * math.pi * cutoff / sample_rate
    local cosw0 = math.cos(w0)
    local sinw0 = math.sin(w0)
    local alpha = sinw0 / (2.0 * resonance)
    local norm  = 1.0 / (1.0 + alpha)
    local b0    =  ((1.0 + cosw0) * 0.5) * norm
    local b1    = -(1.0 + cosw0) * norm
    local b2    = b0
    local a1    = (-2.0 * cosw0) * norm
    local a2    = (1.0 - alpha) * norm
    return b0, b1, b2, a1, a2
end

return DSP
