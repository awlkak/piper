-- Plugin Discovery
-- Scans the plugins/ directory (in both the source bundle and the save directory)
-- and returns a categorized list of plugin file paths.

local Discovery = {}

local CATEGORIES = { "generators", "effects", "control", "abstractions" }

-- Scan a base directory for plugin .lua files under each category.
local function scan_dir(base, results)
    for _, cat in ipairs(CATEGORIES) do
        local dir = base .. "/" .. cat
        local items = love.filesystem.getDirectoryItems(dir)
        if items then
            for _, name in ipairs(items) do
                if name:match("%.lua$") then
                    local path = dir .. "/" .. name
                    if not results[cat] then results[cat] = {} end
                    -- Avoid duplicates
                    local found = false
                    for _, existing in ipairs(results[cat]) do
                        if existing == path then found = true; break end
                    end
                    if not found then
                        table.insert(results[cat], path)
                    end
                end
            end
        end
    end
end

-- Scan all known plugin locations and return a table:
-- { generators = {paths...}, effects = {paths...}, control = {paths...}, abstractions = {paths...} }
function Discovery.scan()
    local results = {}
    for _, cat in ipairs(CATEGORIES) do results[cat] = {} end

    -- Bundled plugins (read-only source directory)
    scan_dir("plugins", results)

    -- User plugins in save directory ("user_plugins/" relative to save dir)
    -- Create the directory structure on first run so users know where to put plugins.
    for _, cat in ipairs(CATEGORIES) do
        love.filesystem.createDirectory("user_plugins/" .. cat)
    end
    scan_dir("user_plugins", results)

    return results
end

-- Flatten all plugins into a single list of {path, category}
function Discovery.flat_list()
    local all = Discovery.scan()
    local list = {}
    for cat, paths in pairs(all) do
        for _, path in ipairs(paths) do
            table.insert(list, { path = path, category = cat })
        end
    end
    table.sort(list, function(a, b) return a.path < b.path end)
    return list
end

-- Return the display name for a plugin path (filename without .lua)
function Discovery.display_name(path)
    return path:match("([^/]+)%.lua$") or path
end

return Discovery
