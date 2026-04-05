-- Machine interface definition and validator.
--
-- Every plugin file must return a table conforming to this interface.
-- Primitives implement render/process directly; abstractions return a sub-graph.
--
-- Required fields:
--   type    : "generator" | "effect" | "control" | "abstraction"
--   name    : string
--   version : integer
--   inlets  : array of {id=string, kind="signal"|"control"}
--   outlets : array of {id=string, kind="signal"|"control"}
--   params  : array of {id, label, min, max, default, type="float"|"int"|"bool"|"enum"}
--   new     : function(self, args) -> instance   (for non-abstractions)
--          or graph : table                       (for abstractions)
--
-- Instance must implement:
--   init(sample_rate)
--   set_param(id, value)
--   on_message(inlet_id, msg)       -- handle control-rate messages
--   render(out_bufs, n)             -- generator: fill out_bufs[outlet_id] = float[]
--   process(in_bufs, out_bufs, n)   -- effect/control: transform in_bufs -> out_bufs
--   reset()
--   destroy()

local Machine = {}

local VALID_TYPES = { generator=true, effect=true, control=true, abstraction=true }
local VALID_KINDS = { signal=true, control=true }
local VALID_PARAM_TYPES = { float=true, int=true, bool=true, enum=true, file=true }

-- Validate a plugin definition table.  Raises error on failure.
function Machine.validate(def)
    assert(type(def) == "table", "plugin must return a table")
    assert(VALID_TYPES[def.type],
        "plugin.type must be generator|effect|control|abstraction, got: " .. tostring(def.type))
    assert(type(def.name) == "string" and #def.name > 0,
        "plugin.name must be a non-empty string")
    assert(type(def.version) == "number",
        "plugin.version must be a number")

    -- Inlets / outlets
    assert(type(def.inlets) == "table", "plugin.inlets must be a table")
    for i, pin in ipairs(def.inlets) do
        assert(type(pin.id) == "string", "inlet["..i.."].id must be string")
        assert(VALID_KINDS[pin.kind],
            "inlet["..i.."].kind must be signal|control, got: " .. tostring(pin.kind))
    end
    assert(type(def.outlets) == "table", "plugin.outlets must be a table")
    for i, pin in ipairs(def.outlets) do
        assert(type(pin.id) == "string", "outlet["..i.."].id must be string")
        assert(VALID_KINDS[pin.kind],
            "outlet["..i.."].kind must be signal|control, got: " .. tostring(pin.kind))
    end

    -- Params
    assert(type(def.params) == "table", "plugin.params must be a table")
    for i, p in ipairs(def.params) do
        assert(type(p.id)    == "string", "param["..i.."].id must be string")
        assert(type(p.label) == "string", "param["..i.."].label must be string")
        assert(VALID_PARAM_TYPES[p.type],
            "param["..i.."].type must be float|int|bool|enum")
    end

    -- Factory or graph
    if def.type == "abstraction" then
        assert(type(def.graph) == "table",
            "abstraction plugin must have a .graph table")
    else
        assert(type(def.new) == "function",
            "non-abstraction plugin must have a .new factory function")
    end

    -- Optional custom UI panel
    if def.gui ~= nil then
        assert(type(def.gui) == "table", "plugin.gui must be a table")
        assert(type(def.gui.height) == "number" and def.gui.height > 0,
            "plugin.gui.height must be a positive number")
        assert(type(def.gui.draw) == "function", "plugin.gui.draw must be a function")
        if def.gui.on_event ~= nil then
            assert(type(def.gui.on_event) == "function",
                "plugin.gui.on_event must be a function if provided")
        end
        if def.gui.width ~= nil then
            assert(type(def.gui.width) == "number" and def.gui.width > 0,
                "plugin.gui.width must be a positive number if provided")
        end
    end
end

-- Create a default no-op instance for testing / fallback.
function Machine.new_noop(name)
    local inst = {}
    function inst:init(_sr) end
    function inst:set_param(_id, _v) end
    function inst:on_message(_inlet, _msg) end
    function inst:render(out_bufs, n)
        for _, buf in pairs(out_bufs) do
            for i = 1, n * 2 do buf[i] = 0.0 end
        end
    end
    function inst:process(in_bufs, out_bufs, n)
        for id, buf in pairs(out_bufs) do
            local src = in_bufs[id]
            if src then
                for i = 1, n * 2 do buf[i] = src[i] end
            else
                for i = 1, n * 2 do buf[i] = 0.0 end
            end
        end
    end
    function inst:reset() end
    function inst:destroy() end
    return inst
end

return Machine
