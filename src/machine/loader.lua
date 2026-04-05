-- Plugin Loader
-- Loads Lua plugin files in a restricted sandbox.
-- Supports primitive plugins (generator/effect/control) and abstractions.
--
-- Sandbox exposes only:
--   math, table, string, pairs, ipairs, type, tostring, tonumber, select,
--   unpack (or table.unpack), and the piper.* API.
-- No io, os, debug, require, load, dofile, love, or package.

local Machine = require("src.machine.machine")
local DSP     = require("src.audio.dsp")

local Loader = {}

-- Build the restricted sandbox environment for plugin scripts
local function make_sandbox(sample_rate, block_size)
    local piper_api = {
        SAMPLE_RATE = sample_rate,
        BLOCK_SIZE  = block_size,
        -- DSP utilities
        note_to_hz = DSP.note_to_hz,
        db_to_amp  = DSP.db_to_amp,
        amp_to_db  = DSP.amp_to_db,
        clamp      = DSP.clamp,
        lerp       = DSP.lerp,
        buf_fill   = DSP.buf_fill,
        buf_mix    = DSP.buf_mix,
        buf_copy   = DSP.buf_copy,
        buf_scale  = DSP.buf_scale,
        buf_new    = DSP.buf_new,
        softclip   = DSP.softclip,
        hardclip   = DSP.hardclip,
        pan_gains  = DSP.pan_gains,
        biquad_lowpass  = DSP.biquad_lowpass,
        biquad_highpass = DSP.biquad_highpass,
        -- Audio file loading (safe subset of love.sound)
        load_sound      = function(path) return love.sound.newSoundData(path) end,
    }

    local env = {
        -- Safe stdlib subset
        math     = math,
        table    = table,
        string   = string,
        pairs    = pairs,
        ipairs   = ipairs,
        next     = next,
        type     = type,
        tostring = tostring,
        tonumber = tonumber,
        select   = select,
        unpack   = table.unpack or unpack,
        rawget   = rawget,
        rawset   = rawset,
        rawequal = rawequal,
        rawlen   = rawlen,
        error    = error,
        assert   = assert,
        pcall    = pcall,
        xpcall   = xpcall,
        -- Piper audio API
        piper    = piper_api,
    }
    env._ENV = env
    return env
end

-- Load a single plugin file. Returns the definition table.
-- Raises on syntax or runtime error, or if validation fails.
function Loader.load(path, sample_rate, block_size)
    local src, err = love.filesystem.read(path)
    if not src then
        error("Loader.load: cannot read file '" .. path .. "': " .. tostring(err))
    end

    local env = make_sandbox(sample_rate or 44100, block_size or 64)

    local chunk, cerr = load(src, "@" .. path, "t", env)
    if not chunk then
        error("Loader.load: syntax error in '" .. path .. "': " .. tostring(cerr))
    end

    local ok, def = pcall(chunk)
    if not ok then
        error("Loader.load: runtime error in '" .. path .. "': " .. tostring(def))
    end
    if type(def) ~= "table" then
        error("Loader.load: plugin '" .. path .. "' must return a table")
    end

    -- Store the path on the def so it can be serialized
    def._path = path

    -- Validate interface
    Machine.validate(def)

    return def
end

-- Instantiate a primitive plugin (generator/effect/control).
-- args: optional creation arguments (like Pd abstractions' $1 $2...)
function Loader.instantiate(def, args, sample_rate)
    assert(def.type ~= "abstraction", "use Loader.expand_abstraction for abstractions")
    local inst = def:new(args or {})
    if inst.init then inst:init(sample_rate or 44100) end
    -- Apply default parameters
    for _, p in ipairs(def.params or {}) do
        if inst.set_param then inst:set_param(p.id, p.default) end
    end
    return inst
end

-- Expand an abstraction definition into a flat list of (id, def, instance) triples.
-- Each inner node gets a namespaced ID: instance_id .. "#" .. inner_id
-- Returns: list of {id, def, instance, params, edges}
function Loader.expand_abstraction(abs_def, instance_id, args, sample_rate, block_size)
    local graph = abs_def.graph
    assert(type(graph) == "table", "abstraction .graph must be a table")

    local result_nodes = {}
    local result_edges = {}

    -- Substitute $1..$9 args in parameter defaults
    local function subst(v)
        if type(v) == "string" then
            return v:gsub("%$(%d)", function(n)
                return tostring(args and args[tonumber(n)] or "")
            end)
        end
        return v
    end

    for _, node_spec in ipairs(graph.nodes or {}) do
        local inner_id = instance_id .. "#" .. node_spec.id
        local node_def, err = pcall(Loader.load, node_spec.plugin, sample_rate, block_size)
        if not node_def then
            print("[Loader] WARNING: could not load inner plugin '" ..
                  tostring(node_spec.plugin) .. "': " .. tostring(err))
        else
            -- node_def is actually the second return from pcall
            local ok
            ok, node_def = pcall(Loader.load, node_spec.plugin, sample_rate, block_size)
            if not ok then
                print("[Loader] WARNING: " .. tostring(node_def))
                goto continue
            end
            local params = {}
            for k, v in pairs(node_spec.params or {}) do
                params[k] = subst(v)
            end
            local inst
            if node_def.type == "abstraction" then
                -- Recursive expansion
                local sub_nodes, sub_edges = Loader.expand_abstraction(
                    node_def, inner_id, args, sample_rate, block_size)
                for _, n in ipairs(sub_nodes) do table.insert(result_nodes, n) end
                for _, e in ipairs(sub_edges) do table.insert(result_edges, e) end
            else
                inst = Loader.instantiate(node_def, args, sample_rate)
                for k, v in pairs(params) do inst:set_param(k, v) end
                table.insert(result_nodes, {
                    id       = inner_id,
                    def      = node_def,
                    instance = inst,
                    params   = params,
                    x        = node_spec.x or 0,
                    y        = node_spec.y or 0,
                })
            end
        end
        ::continue::
    end

    -- Remap edge node IDs to namespaced IDs
    for _, e in ipairs(graph.edges or {}) do
        table.insert(result_edges, {
            from_id  = instance_id .. "#" .. e.from_id,
            from_pin = e.from_pin,
            to_id    = instance_id .. "#" .. e.to_id,
            to_pin   = e.to_pin,
        })
    end

    return result_nodes, result_edges
end

return Loader
