-- Lua table serializer
-- Converts a Lua value to a human-readable Lua table literal string.
-- No external dependencies. Handles: nil, bool, number, string, table.
-- Cycle detection via a 'seen' set.

local Serializer = {}

local function serialize_value(val, indent, seen)
    local t = type(val)
    if t == "nil" then
        return "nil"
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "number" then
        if val ~= val then return "0/0"           end  -- NaN
        if val ==  math.huge then return "math.huge"  end
        if val == -math.huge then return "-math.huge" end
        -- Use %g for compact output; fall back to full precision for integers
        if math.floor(val) == val and math.abs(val) < 1e15 then
            return string.format("%d", val)
        end
        return string.format("%.10g", val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        if seen[val] then
            return "nil --[[cycle]]"
        end
        seen[val] = true

        local parts = {}
        local next_indent = indent .. "  "

        -- Check if it's an array-like table
        local max_n = 0
        for k in pairs(val) do
            if type(k) == "number" and k == math.floor(k) and k >= 1 then
                if k > max_n then max_n = k end
            end
        end
        local is_array = (max_n == #val)

        if is_array and max_n > 0 then
            for i = 1, max_n do
                local v = serialize_value(val[i], next_indent, seen)
                table.insert(parts, next_indent .. v)
            end
            -- Also handle mixed non-array keys
            for k, v in pairs(val) do
                if not (type(k) == "number" and k >= 1 and k <= max_n) then
                    local ks = type(k) == "string" and k:match("^[%a_][%w_]*$")
                              and k
                              or ("[" .. serialize_value(k, "", seen) .. "]")
                    table.insert(parts, next_indent .. ks .. " = " ..
                                 serialize_value(v, next_indent, seen))
                end
            end
        else
            -- Pure hash table
            local keys = {}
            for k in pairs(val) do table.insert(keys, k) end
            -- Sort for determinism
            table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta ~= tb then return ta < tb end
                if ta == "number" then return a < b end
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local ks = type(k) == "string" and k:match("^[%a_][%w_]*$")
                          and k
                          or ("[" .. serialize_value(k, "", seen) .. "]")
                table.insert(parts, next_indent .. ks .. " = " ..
                             serialize_value(val[k], next_indent, seen))
            end
        end

        seen[val] = nil  -- allow same table to appear in sibling branches
        if #parts == 0 then return "{}" end
        return "{\n" .. table.concat(parts, ",\n") .. "\n" .. indent .. "}"
    else
        return "nil --[[unsupported: " .. t .. "]]"
    end
end

-- Serialize a value to a Lua literal string.
function Serializer.serialize(val)
    return serialize_value(val, "", {})
end

-- Serialize as a complete Lua file (return statement).
function Serializer.to_file(val)
    return "return " .. Serializer.serialize(val) .. "\n"
end

-- Write a project to a file path via love.filesystem.
-- Creates parent directories as needed (love.filesystem uses "/" on all platforms).
function Serializer.write(path, val)
    -- Ensure parent directory exists
    local dir = path:match("^(.+)/[^/]+$")
    if dir and dir ~= "" then
        love.filesystem.createDirectory(dir)
    end
    local content = Serializer.to_file(val)
    local ok, err = love.filesystem.write(path, content)
    if not ok then
        error("Serializer.write: could not write '" .. path .. "': " .. tostring(err))
    end
end

return Serializer
