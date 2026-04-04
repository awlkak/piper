-- SoundData buffer pool
-- Avoids allocating new SoundData objects every frame (which would trigger GC).
-- Buffers are acquired before filling, then queued to the QueueableSource.
-- Once the source has consumed them, they are returned to the pool.

local Buffer = {}

-- Must be configured before use (called from engine.lua)
local SAMPLE_RATE  = 44100
local BLOCK_SIZE   = 64
local RENDER_BUFS  = 32   -- blocks per SoundData buffer
local CHANNELS     = 2
local BITS         = 16
local POOL_SIZE    = 6

local pool = {}
local frames_per_buf  -- BLOCK_SIZE * RENDER_BUFS

function Buffer.init(sample_rate, block_size, render_bufs, pool_size)
    SAMPLE_RATE  = sample_rate  or SAMPLE_RATE
    BLOCK_SIZE   = block_size   or BLOCK_SIZE
    RENDER_BUFS  = render_bufs  or RENDER_BUFS
    POOL_SIZE    = pool_size    or POOL_SIZE
    frames_per_buf = BLOCK_SIZE * RENDER_BUFS

    pool = {}
    for i = 1, POOL_SIZE do
        pool[i] = {
            sounddata = love.sound.newSoundData(frames_per_buf, SAMPLE_RATE, BITS, CHANNELS),
            in_use    = false,
            index     = i,
        }
    end
end

-- Returns a free buffer slot, or nil if pool is exhausted
function Buffer.acquire()
    for _, slot in ipairs(pool) do
        if not slot.in_use then
            slot.in_use = true
            return slot
        end
    end
    -- Pool exhausted: allocate a temporary (will be GC'd, but rare)
    return {
        sounddata = love.sound.newSoundData(frames_per_buf, SAMPLE_RATE, BITS, CHANNELS),
        in_use    = true,
        index     = -1,
    }
end

-- Release a buffer back to the pool (call after source has consumed it)
function Buffer.release(slot)
    slot.in_use = false
end

-- Returns the number of frames per SoundData buffer
function Buffer.frames()
    return frames_per_buf
end

-- Write a Lua float buffer (interleaved stereo, values in [-1,1]) into a SoundData slot.
-- love.sound.SoundData:setSample expects normalized floats in [-1, 1].
function Buffer.write_from_float(slot, float_buf, n_frames)
    local sd = slot.sounddata
    for i = 0, n_frames - 1 do
        local L = float_buf[i * 2 + 1]
        local R = float_buf[i * 2 + 2]
        -- Soft clip
        if L >  1.0 then L =  1.0 elseif L < -1.0 then L = -1.0 end
        if R >  1.0 then R =  1.0 elseif R < -1.0 then R = -1.0 end
        sd:setSample(i * 2,     L)
        sd:setSample(i * 2 + 1, R)
    end
end

return Buffer
