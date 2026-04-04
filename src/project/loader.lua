-- Project Loader
-- Reads a .piper project file, validates it, and rebuilds the application state
-- (Song, DAG, Registry).

local Song       = require("src.sequencer.song")
local Pattern    = require("src.sequencer.pattern")
local DAG        = require("src.machine.dag")
local Registry   = require("src.machine.registry")
local MachLoader = require("src.machine.loader")
local Serializer = require("src.project.serializer")

local CURRENT_VERSION = 1

local ProjectLoader = {}

-- Save the current project state to a .piper file.
-- state = { song, dag_serial, bpm, speed }  (built by app.lua)
function ProjectLoader.save(path, state)
    Serializer.write(path, state)
end

-- Load a .piper file and return a reconstructed state table.
-- Raises on any error.
function ProjectLoader.load(path, sample_rate, block_size)
    local src, err = love.filesystem.read(path)
    if not src then
        error("ProjectLoader.load: cannot read '" .. path .. "': " .. tostring(err))
    end

    -- .piper files are Lua table literals (return {...})
    local env = { math = math }
    local chunk, cerr = load(src, "@" .. path, "t", env)
    if not chunk then
        error("ProjectLoader.load: parse error in '" .. path .. "': " .. tostring(cerr))
    end

    local ok, data = pcall(chunk)
    if not ok then
        error("ProjectLoader.load: runtime error in '" .. path .. "': " .. tostring(data))
    end
    if type(data) ~= "table" then
        error("ProjectLoader.load: '" .. path .. "' did not return a table")
    end

    -- Version check
    local ver = data.version or 1
    if ver > CURRENT_VERSION then
        print("[ProjectLoader] WARNING: project version " .. ver ..
              " is newer than supported (" .. CURRENT_VERSION .. ")")
    end

    -- Reconstruct Song
    local song = Song.deserialize(data)

    -- Reconstruct machines into DAG + Registry
    DAG.init(block_size or 64)
    Registry.clear()

    for _, m in ipairs(data.machines or {}) do
        local def, inst
        if m.plugin then
            local ok2, result = pcall(MachLoader.load, m.plugin, sample_rate, block_size)
            if not ok2 then
                print("[ProjectLoader] WARNING: could not load plugin '" ..
                      tostring(m.plugin) .. "': " .. tostring(result))
                goto continue
            end
            def = result
            local ok3, result2 = pcall(MachLoader.instantiate, def, {}, sample_rate)
            if not ok3 then
                print("[ProjectLoader] WARNING: could not instantiate '" ..
                      tostring(m.plugin) .. "': " .. tostring(result2))
                goto continue
            end
            inst = result2
            -- Apply saved params
            for k, v in pairs(m.params or {}) do
                inst:set_param(k, v)
            end
        end
        DAG.add_node(m.id, def or {outlets={},inlets={},params={},type="effect"},
                     inst, m.params or {}, m.x or 0, m.y or 0)
        Registry.register(m.id, def, inst, m.params)
        ::continue::
    end

    for _, e in ipairs(data.connections or {}) do
        local ok2, err2 = pcall(DAG.add_edge,
            e.from_id, e.from_pin, e.to_id, e.to_pin)
        if not ok2 then
            print("[ProjectLoader] WARNING: bad edge: " .. tostring(err2))
        end
    end

    return {
        song    = song,
        version = ver,
    }
end

-- Build a serializable state table from current runtime state.
function ProjectLoader.build_state(song, extra_machines, extra_edges)
    local song_t = song:serialize()
    return {
        version     = CURRENT_VERSION,
        bpm         = song.bpm,
        speed       = song.speed,
        machines    = extra_machines or {},
        connections = extra_edges    or {},
        patterns    = song_t.patterns,
        order       = song_t.order,
        loop_start  = song.loop_start,
        loop_end    = song.loop_end,
    }
end

return ProjectLoader
