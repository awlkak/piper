#!/usr/bin/env luajit
-- piper-render: Offline song renderer for Piper music tracker
-- Renders a .piper project file to WAV (and optionally FLAC, Ogg, MP3, M4A via ffmpeg).
--
-- Usage:
--   luajit tools/piper-render.lua <song.piper> <output.wav> [options]
--
-- Options:
--   --format  flac|ogg|mp3|m4a|wav   Output format (default: inferred from extension or wav)
--   --tail    <seconds>              Reverb/delay decay tail (default: 2.0)
--   --rate    <hz>                   Sample rate (default: 44100)
--
-- Multi-format output requires ffmpeg to be installed.

-- ---------------------------------------------------------------------------
-- Setup: find repo root and configure require paths
-- ---------------------------------------------------------------------------

local script_path = arg[0] or "tools/piper-render.lua"
-- Resolve script directory
local script_dir = script_path:match("^(.*)/[^/]+$") or "."
local repo_root  = script_dir .. "/.."

package.path = repo_root .. "/?.lua;"
            .. repo_root .. "/?/init.lua;"
            .. package.path

-- Install love shim BEFORE any src.* requires (it sets the global `love`)
require("tools.compat.love_shim")

-- ---------------------------------------------------------------------------
-- Argument parsing
-- ---------------------------------------------------------------------------

local function usage()
    io.stderr:write(
        "Usage: luajit tools/piper-render.lua <song.piper> <output> [options]\n" ..
        "  --format  flac|ogg|mp3|m4a|wav  (default: from output extension or 'wav')\n" ..
        "  --tail    <seconds>             Reverb tail length (default: 2.0)\n" ..
        "  --rate    <hz>                  Sample rate (default: 44100)\n"
    )
    os.exit(1)
end

local input_path  = nil
local output_path = nil
local format      = nil
local tail        = 2.0
local rate        = 44100

local i = 1
while i <= #arg do
    local a = arg[i]
    if a == "--format" then
        i = i + 1
        format = arg[i]
    elseif a == "--tail" then
        i = i + 1
        tail = tonumber(arg[i]) or tail
    elseif a == "--rate" then
        i = i + 1
        rate = tonumber(arg[i]) or rate
    elseif a:sub(1, 1) ~= "-" then
        if not input_path then
            input_path = a
        elseif not output_path then
            output_path = a
        end
    else
        io.stderr:write("Unknown option: " .. a .. "\n")
        usage()
    end
    i = i + 1
end

if not input_path or not output_path then
    usage()
end

-- Infer format from output extension if not specified
if not format then
    format = output_path:match("%.([^./]+)$") or "wav"
    format = format:lower()
end

local SUPPORTED_FORMATS = { wav=true, flac=true, ogg=true, mp3=true, m4a=true }
if not SUPPORTED_FORMATS[format] then
    io.stderr:write("Unsupported format: " .. format ..
                    " (supported: wav flac ogg mp3 m4a)\n")
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Resolve absolute paths
-- ---------------------------------------------------------------------------

local function abs_path(p)
    if p:sub(1, 1) == "/" then return p end
    -- Get CWD
    local handle = io.popen("pwd")
    local cwd = handle:read("*l"):gsub("%s+$", "")
    handle:close()
    return cwd .. "/" .. p
end

input_path  = abs_path(input_path)
output_path = abs_path(output_path)

-- Set asset base to the directory of the .piper file so plugins and samples
-- referenced by relative paths resolve correctly
local input_dir = input_path:match("^(.*)/[^/]+$") or "."
love.filesystem._set_base(input_dir)

-- Also set repo_root as a fallback base for plugin files (plugins/ lives there)
-- We override love.filesystem.read to try repo_root too
local orig_read = love.filesystem.read
love.filesystem.read = function(path)
    local data, err = orig_read(path)
    if data then return data, nil end
    -- Also try from repo root
    if not path:match("^/") then
        local f = io.open(repo_root .. "/" .. path, "rb")
        if f then
            local d = f:read("*a"); f:close()
            return d, nil
        end
    end
    return nil, err
end

-- ---------------------------------------------------------------------------
-- Load Piper modules
-- ---------------------------------------------------------------------------

local Engine     = require("src.audio.engine")
local DAG        = require("src.machine.dag")
local Bus        = require("src.machine.bus")
local Sequencer  = require("src.sequencer.sequencer")
local ProjLoader = require("src.project.loader")
local Exporter   = require("src.audio.exporter")

-- Override Engine constants with CLI values
Engine.SAMPLE_RATE = rate

-- ---------------------------------------------------------------------------
-- Load project
-- ---------------------------------------------------------------------------

io.write("Loading: " .. input_path .. "\n")
io.flush()

local ok, result = pcall(ProjLoader.load, input_path, rate, Engine.BLOCK_SIZE)
if not ok then
    io.stderr:write("Error loading project: " .. tostring(result) .. "\n")
    os.exit(1)
end
local song = result.song

-- Wire up the same way App.load() does
Sequencer.set_deliver(function(machine_id, inlet_id, msg)
    DAG.deliver_message(machine_id, inlet_id, msg)
end)
Sequencer.set_sample_rate(rate)
Sequencer.set_song(song)

-- ---------------------------------------------------------------------------
-- Determine output path (WAV is always rendered first; convert after if needed)
-- ---------------------------------------------------------------------------

local wav_path
local needs_conversion = (format ~= "wav")

if needs_conversion then
    wav_path = output_path .. ".tmp_render.wav"
else
    wav_path = output_path
end

-- ---------------------------------------------------------------------------
-- Check ffmpeg availability (needed for non-WAV formats)
-- ---------------------------------------------------------------------------

if needs_conversion then
    local h = io.popen("ffmpeg -version 2>&1")
    local out = h and h:read("*l") or ""
    if h then h:close() end
    if not out:find("ffmpeg") then
        io.stderr:write(
            "Error: format '" .. format .. "' requires ffmpeg, which was not found.\n" ..
            "Install it with:\n" ..
            "  macOS:  brew install ffmpeg\n" ..
            "  Ubuntu: sudo apt install ffmpeg\n"
        )
        os.exit(1)
    end
end

-- ---------------------------------------------------------------------------
-- Run offline export
-- ---------------------------------------------------------------------------

io.write("Rendering to WAV...\n")
io.flush()

local last_pct = -1
local opts = {
    path         = wav_path,
    tail_seconds = tail,
    bit_depth    = 16,
    song         = song,
    on_progress  = function(frac)
        local pct = math.floor(frac * 100)
        if pct ~= last_pct then
            last_pct = pct
            io.write(string.format("\r  %3d%%", pct))
            io.flush()
        end
    end,
}

-- Run the export synchronously (no coroutine needed for CLI)
local coro = coroutine.create(Exporter.export)
local export_ok, export_err = coroutine.resume(coro, opts)
while export_ok and coroutine.status(coro) ~= "dead" do
    export_ok, export_err = coroutine.resume(coro)
end

io.write("\r  100%\n")
io.flush()

if not export_ok then
    io.stderr:write("Export error: " .. tostring(export_err) .. "\n")
    os.remove(wav_path)
    os.exit(1)
end

io.write("WAV written: " .. wav_path .. "\n")

-- ---------------------------------------------------------------------------
-- Format conversion via ffmpeg
-- ---------------------------------------------------------------------------

if needs_conversion then
    local codec_flags = {
        flac = "-c:a flac",
        ogg  = "-c:a libvorbis -q:a 6",
        mp3  = "-c:a libmp3lame -q:a 2",
        m4a  = "-c:a aac -b:a 256k",
    }

    local flags = codec_flags[format]
    if not flags then
        io.stderr:write("No codec flags for format: " .. format .. "\n")
        os.remove(wav_path)
        os.exit(1)
    end

    io.write(string.format("Converting to %s...\n", format:upper()))
    io.flush()

    local cmd = string.format(
        'ffmpeg -y -i "%s" %s "%s" 2>&1',
        wav_path, flags, output_path)
    local h = io.popen(cmd)
    local ffmpeg_out = h:read("*a")
    local ok_close   = h:close()

    -- Clean up temp WAV
    os.remove(wav_path)

    if not ok_close then
        io.stderr:write("ffmpeg failed:\n" .. ffmpeg_out .. "\n")
        os.exit(1)
    end
end

io.write("Done: " .. output_path .. "\n")
