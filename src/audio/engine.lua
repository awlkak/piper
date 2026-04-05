-- Audio Engine
-- Manages the Love2D QueueableSource and drives the dual-rate render loop.
--
-- Architecture (from Pd):
--   BLOCK_SIZE = 64 samples = one "control block"
--   Each control block: drain message queue, then run DAG for 64 samples
--   RENDER_BUFS blocks are accumulated into one SoundData and queued to the source
--
-- Timing:
--   samples_per_tick = SAMPLE_RATE * 60 / (BPM * speed)
--   The sequencer tracks a fractional tick accumulator per sample.

local Buffer = require("src.audio.buffer")
local DSP    = require("src.audio.dsp")

local Engine = {}

-- Constants (can be changed before Engine.init)
Engine.SAMPLE_RATE  = 44100
Engine.BLOCK_SIZE   = 64      -- samples per control block
Engine.RENDER_BUFS  = 32      -- blocks per QueueableSource buffer (~46ms)
Engine.POOL_SIZE    = 6

-- Runtime state
local source          -- QueueableSource
local mix_buf         -- flat Lua float buffer for one full render buffer
local block_buf       -- flat Lua float buffer for one block (reused)

-- Injected dependencies (set via Engine.set_*)
local dag_render_block   -- function(block_buf, n_frames) fills block_buf
local queue_drain        -- function(sample_offset) fires scheduled events
local playing = false

-- Queued buffer tracking for pool release
local queued_slots = {}   -- FIFO of slots queued to source

function Engine.set_dag_renderer(fn)   dag_render_block = fn  end
function Engine.set_queue_drainer(fn)  queue_drain = fn       end

function Engine.init()
    Buffer.init(Engine.SAMPLE_RATE, Engine.BLOCK_SIZE, Engine.RENDER_BUFS, Engine.POOL_SIZE)

    local frames = Engine.BLOCK_SIZE * Engine.RENDER_BUFS
    mix_buf   = DSP.buf_new(frames)
    block_buf = DSP.buf_new(Engine.BLOCK_SIZE)

    source = love.audio.newQueueableSource(Engine.SAMPLE_RATE, 16, 2, Engine.POOL_SIZE)
    source:play()
    playing = true
end

function Engine.update()
    if not source then return end

    -- Release slots that the source has already consumed
    local free = source:getFreeBufferCount()
    for i = 1, free do
        local slot = table.remove(queued_slots, 1)
        if slot then Buffer.release(slot) end
    end

    -- Fill as many free slots as the pool allows
    local frames = Engine.BLOCK_SIZE * Engine.RENDER_BUFS
    while source:getFreeBufferCount() > 0 do
        local slot = Buffer.acquire()
        Engine._render_full_buffer(mix_buf, frames)
        Buffer.write_from_float(slot, mix_buf, frames)
        source:queue(slot.sounddata)
        table.insert(queued_slots, slot)
    end

    if playing and not source:isPlaying() then
        source:play()
    end
end

-- Render RENDER_BUFS * BLOCK_SIZE frames into mix_buf
function Engine._render_full_buffer(buf, frames)
    local block_size = Engine.BLOCK_SIZE
    local num_blocks = Engine.RENDER_BUFS

    for b = 0, num_blocks - 1 do
        local frame_offset = b * block_size
        local sample_offset = frame_offset  -- for event scheduling

        -- Fire any events due in this block
        if queue_drain then
            queue_drain(block_size)
        end

        -- Zero the block buffer
        DSP.buf_fill(block_buf, 0.0, block_size)

        -- Run the machine DAG for this block
        if dag_render_block then
            dag_render_block(block_buf, block_size)
        end

        -- Copy block into mix_buf at the right offset
        local base = frame_offset * 2
        for i = 1, block_size * 2 do
            buf[base + i] = block_buf[i]
        end
    end
end

function Engine.play()
    playing = true
    if source and not source:isPlaying() then
        source:play()
    end
end

function Engine.pause()
    playing = false
end

function Engine.stop()
    playing = false
    if source then source:stop() end
end

function Engine.is_playing()
    return playing
end

function Engine.quit()
    if source then
        source:stop()
        source:release()
        source = nil
    end
end

return Engine
