-- Machine Registry
-- Runtime map of machine_id -> live node (def + instance).
-- Acts as the single source of truth for all active machines.

local Registry = {}

local entries = {}  -- id -> { id, def, instance, params }

function Registry.register(id, def, instance, params)
    entries[id] = { id = id, def = def, instance = instance, params = params or {} }
end

function Registry.unregister(id)
    local entry = entries[id]
    if entry and entry.instance and entry.instance.destroy then
        entry.instance:destroy()
    end
    entries[id] = nil
end

function Registry.get(id)
    return entries[id]
end

function Registry.get_instance(id)
    local e = entries[id]
    return e and e.instance or nil
end

function Registry.all()
    return entries
end

function Registry.clear()
    for id, entry in pairs(entries) do
        if entry.instance and entry.instance.destroy then
            entry.instance:destroy()
        end
        entries[id] = nil
    end
end

return Registry
