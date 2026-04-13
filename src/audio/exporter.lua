-- Exporter
-- Offline render engine for exporting a song to WAV.
-- Drives the same DAG + Sequencer pipeline as real-time playback,
-- but accumulates output to a WavWriter instead of a QueueableSource.
--
-- Designed to run as a coroutine so the UI stays responsive:
--   local coro = coroutine.create(Exporter.export)
--   coroutine.resume(coro, options)   -- start
--   coroutine.resume(coro)            -- continue each frame
--
-- options table:
--   path         string   Output file path (absolute for Love2D, any for CLI)
--   tail_seconds number   Extra silence after song end for reverb decay (default 2.0)
--   bit_depth    number   16 (only supported value currently)
--   on_progress  function Optional: called with (fraction 0..1) periodically

local WavWriter  = require("src.audio.wav_writer")
local DSP        = require("src.audio.dsp")
local DAG        = require("src.machine.dag")
local Bus        = require("src.machine.bus")
local Sequencer  = require("src.sequencer.sequencer")
local Engine     = require("src.audio.engine")

local Exporter = {}

-- Yield every this many frames to keep the UI responsive (~0.5s of audio per yield)
local YIELD_INTERVAL = 22050  -- frames

function Exporter.export(options)
    local path         = options.path         or "render.wav"
    local tail_seconds = options.tail_seconds or 2.0
    local bit_depth    = options.bit_depth    or 16
    local on_progress  = options.on_progress
    local song         = options.song

    local BLOCK_SIZE  = Engine.BLOCK_SIZE
    local SAMPLE_RATE = Engine.SAMPLE_RATE

    -- Estimate total frames for progress reporting
    local total_frames = song and song:estimate_frames(SAMPLE_RATE) or 0
    local tail_frames  = math.floor(tail_seconds * SAMPLE_RATE)
    local grand_total  = total_frames + tail_frames

    -- Open WAV writer
    local writer = WavWriter.new(path, SAMPLE_RATE, 2, bit_depth)

    -- Save sequencer state so we can restore after export
    local saved_state = Sequencer.save_state()

    -- Reset all machine instances (oscillator phases, envelope states, delay buffers)
    DAG.reset_all_instances()

    -- Clear any pending bus messages from prior playback
    Bus.clear()

    -- Enter export mode and seek to song start
    Sequencer.set_export_mode(true)
    Sequencer.restart()

    local block_buf        = DSP.buf_new(BLOCK_SIZE)
    local frames_written   = 0
    local yield_accum      = 0

    -- Phase 1: render song until sequencer signals end
    while not Sequencer.is_export_done() do
        DSP.buf_fill(block_buf, 0.0, BLOCK_SIZE)
        Bus.drain(function(mid, inlet_id, msg)
            DAG.deliver_message(mid, inlet_id, msg)
        end)
        Sequencer.queue_drain(BLOCK_SIZE)
        DAG.render_block(block_buf, BLOCK_SIZE)
        writer:write_block(block_buf, BLOCK_SIZE)
        frames_written = frames_written + BLOCK_SIZE
        yield_accum    = yield_accum    + BLOCK_SIZE

        if yield_accum >= YIELD_INTERVAL then
            yield_accum = 0
            if on_progress and grand_total > 0 then
                on_progress(math.min(1.0, frames_written / grand_total))
            end
            coroutine.yield(grand_total > 0 and (frames_written / grand_total) or 0)
        end
    end

    -- Phase 2: tail (let reverb/delay rings decay)
    Sequencer.stop()
    local tail_written = 0
    while tail_written < tail_frames do
        local n = math.min(BLOCK_SIZE, tail_frames - tail_written)
        DSP.buf_fill(block_buf, 0.0, BLOCK_SIZE)
        DAG.render_block(block_buf, n)
        writer:write_block(block_buf, n)
        tail_written   = tail_written   + n
        frames_written = frames_written + n
        yield_accum    = yield_accum    + n

        if yield_accum >= YIELD_INTERVAL then
            yield_accum = 0
            if on_progress and grand_total > 0 then
                on_progress(math.min(1.0, frames_written / grand_total))
            end
            coroutine.yield(grand_total > 0 and (frames_written / grand_total) or 0)
        end
    end

    -- Finalize WAV headers
    writer:finalize()

    -- Restore sequencer to pre-export state
    Sequencer.restore_state(saved_state)

    if on_progress then on_progress(1.0) end
    coroutine.yield(1.0)
end

return Exporter
