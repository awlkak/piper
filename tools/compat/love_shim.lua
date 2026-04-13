-- Love2D API shim for LuaJIT CLI
-- Sets the global `love` table with the subset of Love2D APIs used by Piper's
-- audio pipeline. Must be required BEFORE any src.* modules are loaded.
--
-- Usage (at the top of piper-render.lua, before any other requires):
--   require("tools.compat.love_shim")

-- Base path for resolving relative asset paths (set by piper-render.lua
-- to the directory containing the .piper file being rendered)
local _base = "."

love = {
    filesystem = {
        -- Read a file and return its contents as a string, or nil + error.
        read = function(path)
            -- Try the path as-is first, then relative to _base
            local function try(p)
                local f, err = io.open(p, "rb")
                if not f then return nil, err end
                local data = f:read("*a")
                f:close()
                return data, nil
            end
            local data, err = try(path)
            if data then return data, nil end
            -- Try base-relative
            if not path:match("^/") then
                data, err = try(_base .. "/" .. path)
                if data then return data, nil end
            end
            return nil, err
        end,

        -- Write data to a file. Returns true on success, or false + error.
        write = function(path, data)
            local p = path:match("^/") and path or (_base .. "/" .. path)
            local f, err = io.open(p, "wb")
            if not f then return false, err end
            f:write(data)
            f:close()
            return true, nil
        end,

        getInfo = function(path)
            local function try(p)
                local f = io.open(p, "rb")
                if f then f:close(); return { type = "file" } end
                return nil
            end
            return try(path) or (not path:match("^/") and try(_base .. "/" .. path)) or nil
        end,

        createDirectory = function(path)
            -- Best-effort; ignore errors
            os.execute('mkdir -p "' .. path .. '" 2>/dev/null')
            return true
        end,

        getSaveDirectory = function()
            return _base
        end,

        getDirectoryItems = function(dir)
            -- Used by UI file picker; not needed for CLI rendering
            return {}
        end,
    },

    sound = {
        newSoundData = function(arg, sample_rate, bits, channels)
            local SoundData = require("tools.compat.sound_data")
            return SoundData.new(arg, sample_rate, bits, channels)
        end,
    },

    -- Stub out audio (not used during offline render)
    audio = {
        newQueueableSource = function(...) return {
            play  = function() end,
            stop  = function() end,
            queue = function() end,
            isPlaying = function() return false end,
            getFreeBufferCount = function() return 0 end,
        } end,
    },

    -- Stub graphics (not used in CLI)
    graphics = {
        getDimensions = function() return 800, 600 end,
    },

    -- Stub mouse
    mouse = nil,
}

-- Allow callers to set the asset base directory
function love.filesystem._set_base(path)
    _base = path
end
