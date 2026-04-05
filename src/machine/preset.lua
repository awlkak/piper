local Preset = {}

-- "plugins/generators/supersaw_osc.lua" → "supersaw_osc"
function Preset.slug(plugin_path)
  return plugin_path:match("([^/]+)%.lua$")
end

-- Returns array of { name, path, is_factory }
function Preset.list(plugin_path)
  local slug = Preset.slug(plugin_path)
  if not slug then return {} end

  local results = {}

  -- Factory presets
  local factory_dir = "plugins/presets/" .. slug
  local ok, items = pcall(love.filesystem.getDirectoryItems, factory_dir)
  if ok and items then
    for _, item in ipairs(items) do
      local name = item:match("^(.+)%.preset$")
      if name then
        results[#results + 1] = {
          name       = name,
          path       = factory_dir .. "/" .. item,
          is_factory = true,
        }
      end
    end
  end

  -- User presets
  local user_dir = "presets/user/" .. slug
  local ok2, items2 = pcall(love.filesystem.getDirectoryItems, user_dir)
  if ok2 and items2 then
    for _, item in ipairs(items2) do
      local name = item:match("^(.+)%.preset$")
      if name then
        results[#results + 1] = {
          name       = name,
          path       = user_dir .. "/" .. item,
          is_factory = false,
        }
      end
    end
  end

  return results
end

-- Loads a .preset file, returns { plugin, name, author, params } or nil
function Preset.load(path)
  local content, err = love.filesystem.read(path)
  if not content then return nil, err end

  local fn, load_err = load(content, "@" .. path, "t", {})
  if not fn then return nil, load_err end

  local ok, result = pcall(fn)
  if not ok or type(result) ~= "table" then
    return nil, "preset did not return a table"
  end

  return result
end

-- Simple inline serializer for params table
local function serialize_params(params)
  local parts = {}
  for k, v in pairs(params) do
    local key
    if type(k) == "string" and k:match("^[%a_][%w_]*$") then
      key = k
    else
      key = "[" .. string.format("%q", tostring(k)) .. "]"
    end

    local val
    if type(v) == "number" then
      val = tostring(v)
    elseif type(v) == "boolean" then
      val = tostring(v)
    elseif type(v) == "string" then
      val = string.format("%q", v)
    else
      val = string.format("%q", tostring(v))
    end

    parts[#parts + 1] = "      " .. key .. " = " .. val .. ","
  end
  return table.concat(parts, "\n")
end

-- Saves a user preset, returns path or nil, err
function Preset.save(plugin_path, name, params_table)
  local slug = Preset.slug(plugin_path)
  if not slug then return nil, "could not determine slug from plugin path" end

  local dir  = "presets/user/" .. slug
  local path = dir .. "/" .. name .. ".preset"

  local ok, err = love.filesystem.createDirectory(dir)
  if not ok then return nil, "could not create directory: " .. tostring(err) end

  local content = string.format(
    "return {\n  plugin = %q,\n  name   = %q,\n  author = \"user\",\n  params = {\n%s\n  },\n}\n",
    plugin_path,
    name,
    serialize_params(params_table)
  )

  local write_ok, write_err = love.filesystem.write(path, content)
  if not write_ok then return nil, "could not write preset: " .. tostring(write_err) end

  return path
end

-- Applies a preset to a node via DAG
function Preset.apply(node_id, preset)
  if not preset or type(preset.params) ~= "table" then return end

  local DAG = require("src.machine.dag")

  for param_id, value in pairs(preset.params) do
    DAG.set_param(node_id, param_id, value)
  end
end

-- Deletes a user preset (only paths under presets/user/)
function Preset.delete(path)
  if not path:match("^presets/user/") then
    return nil, "can only delete user presets"
  end

  local ok, err = love.filesystem.remove(path)
  if not ok then return nil, "could not delete preset: " .. tostring(err) end

  return true
end

return Preset
