-- Machine DAG
-- Manages the directed acyclic graph of machines (nodes) and connections (edges).
-- Performs topological sort (Kahn's algorithm) to determine render order.
-- Dispatches render_block() calls in dependency order each audio block.

local DSP       = require("src.audio.dsp")
local MasterDef = require("src.machine.master_def")

local DAG = {}

-- Node: { id, def, instance, params, x, y, out_bufs, in_bufs }
-- Edge: { from_id, from_pin, to_id, to_pin, kind }  (kind = "signal"|"control")

local nodes = {}    -- id -> node
local edges = {}    -- list of edge tables
local render_order = {}  -- list of node ids in topo order (recomputed on graph change)
local dirty = true  -- topo sort needed

local MASTER_ID = "__master__"
local block_size = 64  -- updated by init

-- Outgoing message dispatch (set by bus.lua)
local message_dispatch = nil

function DAG.set_message_dispatch(fn) message_dispatch = fn end

function DAG.init(bs)
    block_size = bs or 64
    nodes = {}
    edges = {}
    render_order = {}
    dirty = true

    -- Always create master output node
    nodes[MASTER_ID] = {
        id        = MASTER_ID,
        def       = MasterDef,
        instance  = nil,
        params    = {},
        x = 0, y = 0,
        out_bufs  = {},
        out_kinds = {},
        in_bufs   = { ["in"] = DSP.buf_new(block_size) },
        in_kinds  = { ["in"] = "signal" },
    }

    -- Master metering instance: tracks scope samples and peak/hold for the GUI
    local HOLD_TIME    = 1.5   -- seconds before peak-hold tick starts falling
    local dt_per_block = block_size / 44100.0

    local inst = {
        _scope        = {},
        _scope_n      = block_size,
        peak_l        = 0, peak_r        = 0,
        hold_l        = 0, hold_r        = 0,
        hold_timer_l  = 0, hold_timer_r  = 0,
    }
    for i = 1, block_size do inst._scope[i] = 0 end

    function inst:_update(buf, n)
        local pl, pr = 0, 0
        for i = 0, n - 1 do
            local l = buf[i * 2 + 1] or 0
            local r = buf[i * 2 + 2] or 0
            self._scope[i + 1] = (l + r) * 0.5
            local al, ar = math.abs(l), math.abs(r)
            if al > pl then pl = al end
            if ar > pr then pr = ar end
        end
        self.peak_l = pl
        self.peak_r = pr
        -- Peak-hold with timed decay
        if pl >= self.hold_l then
            self.hold_l = pl; self.hold_timer_l = HOLD_TIME
        else
            self.hold_timer_l = self.hold_timer_l - dt_per_block
            if self.hold_timer_l <= 0 then self.hold_l = pl end
        end
        if pr >= self.hold_r then
            self.hold_r = pr; self.hold_timer_r = HOLD_TIME
        else
            self.hold_timer_r = self.hold_timer_r - dt_per_block
            if self.hold_timer_r <= 0 then self.hold_r = pr end
        end
    end

    function inst:get_ui_state()
        local s = {}
        for i = 1, self._scope_n do s[i] = self._scope[i] end
        return {
            scope_samples = s,
            peak_l        = self.peak_l,
            peak_r        = self.peak_r,
            peak_hold_l   = self.hold_l,
            peak_hold_r   = self.hold_r,
        }
    end

    nodes[MASTER_ID].instance = inst
end

function DAG.master_id() return MASTER_ID end

-- Add a machine node.  def = plugin definition, instance = live instance.
function DAG.add_node(id, def, instance, params, x, y)
    assert(not nodes[id], "DAG node already exists: " .. id)
    local out_bufs = {}
    local out_kinds = {}   -- pin_id -> "signal"|"control"
    for _, pin in ipairs(def.outlets or {}) do
        if pin.kind == "signal" then
            out_bufs[pin.id] = DSP.buf_new(block_size)
        else
            out_bufs[pin.id] = {}  -- cleared each block
        end
        out_kinds[pin.id] = pin.kind
    end
    local in_bufs = {}
    local in_kinds = {}    -- pin_id -> "signal"|"control"
    for _, pin in ipairs(def.inlets or {}) do
        if pin.kind == "signal" then
            in_bufs[pin.id] = DSP.buf_new(block_size)
        else
            in_bufs[pin.id] = {}
        end
        in_kinds[pin.id] = pin.kind
    end
    nodes[id] = {
        id        = id,
        def       = def,
        instance  = instance,
        params    = params or {},
        x         = x or 0,
        y         = y or 0,
        out_bufs  = out_bufs,
        out_kinds = out_kinds,
        in_bufs   = in_bufs,
        in_kinds  = in_kinds,
    }
    dirty = true
end

function DAG.remove_node(id)
    assert(id ~= MASTER_ID, "cannot remove master node")
    nodes[id] = nil
    -- Remove all edges connected to this node
    for i = #edges, 1, -1 do
        local e = edges[i]
        if e.from_id == id or e.to_id == id then
            table.remove(edges, i)
        end
    end
    dirty = true
end

-- Add a signal or control connection.
function DAG.add_edge(from_id, from_pin, to_id, to_pin)
    assert(nodes[from_id], "DAG.add_edge: unknown from_id " .. tostring(from_id))
    assert(nodes[to_id],   "DAG.add_edge: unknown to_id "   .. tostring(to_id))
    -- Determine kind from the source outlet declaration
    local kind = "signal"
    if nodes[from_id].def then
        for _, pin in ipairs(nodes[from_id].def.outlets or {}) do
            if pin.id == from_pin then kind = pin.kind; break end
        end
    end
    table.insert(edges, {
        from_id  = from_id,
        from_pin = from_pin,
        to_id    = to_id,
        to_pin   = to_pin,
        kind     = kind,
    })
    dirty = true
end

function DAG.remove_edge(from_id, from_pin, to_id, to_pin)
    for i = #edges, 1, -1 do
        local e = edges[i]
        if e.from_id == from_id and e.from_pin == from_pin
        and e.to_id == to_id   and e.to_pin   == to_pin then
            table.remove(edges, i)
        end
    end
    dirty = true
end

function DAG.get_nodes() return nodes end
function DAG.get_edges() return edges end

-- Kahn's algorithm topological sort.
-- Returns ordered list of node IDs; logs a warning on cycle detection.
local function topo_sort()
    local in_degree = {}
    for id in pairs(nodes) do in_degree[id] = 0 end
    for _, e in ipairs(edges) do
        in_degree[e.to_id] = (in_degree[e.to_id] or 0) + 1
    end

    local queue = {}
    for id, deg in pairs(in_degree) do
        if deg == 0 then table.insert(queue, id) end
    end
    -- Sort for determinism (once, before the loop)
    table.sort(queue)

    local order = {}
    local visited = 0

    while #queue > 0 do
        local id = table.remove(queue, 1)
        table.insert(order, id)
        visited = visited + 1
        for _, e in ipairs(edges) do
            if e.from_id == id then
                in_degree[e.to_id] = in_degree[e.to_id] - 1
                if in_degree[e.to_id] == 0 then
                    table.insert(queue, e.to_id)
                end
            end
        end
    end

    local total = 0
    for _ in pairs(nodes) do total = total + 1 end
    if visited < total then
        -- Cycle detected; remaining nodes are skipped
        print("[DAG] WARNING: cycle detected in machine graph; some nodes skipped")
    end

    -- Ensure master is last
    for i, id in ipairs(order) do
        if id == MASTER_ID then
            table.remove(order, i)
            table.insert(order, MASTER_ID)
            break
        end
    end

    return order
end

-- Update node position (for UI)
function DAG.set_position(id, x, y)
    if nodes[id] then
        nodes[id].x = x
        nodes[id].y = y
    end
end

-- Update a parameter on a live node
function DAG.set_param(id, param_id, value)
    local node = nodes[id]
    if not node then return end
    node.params[param_id] = value
    if node.instance then
        node.instance:set_param(param_id, value)
    end
end

-- Deliver a control message to a node's inlet (called from message queue)
function DAG.deliver_message(to_id, inlet_id, msg)
    local node = nodes[to_id]
    if not node or not node.instance then return end
    node.instance:on_message(inlet_id, msg)
end

-- Called once per audio block from engine.lua
-- Fills out_buf (interleaved stereo float, length = n*2) with the master mix
function DAG.render_block(out_buf, n)
    if dirty then
        render_order = topo_sort()
        dirty = false
    end

    local master = nodes[MASTER_ID]

    -- Clear all input and output buffers before processing
    for _, node in pairs(nodes) do
        -- Clear input buffers
        if node.in_kinds then
            for pin_id, kind in pairs(node.in_kinds) do
                local buf = node.in_bufs[pin_id]
                if buf then
                    if kind == "signal" then
                        DSP.buf_fill(buf, 0.0, n)
                    else
                        for i = #buf, 1, -1 do buf[i] = nil end
                    end
                end
            end
        end
        -- Clear control output buffers (signal outs are overwritten by render/process)
        if node.out_kinds then
            for pin_id, kind in pairs(node.out_kinds) do
                if kind == "control" then
                    local buf = node.out_bufs[pin_id]
                    if buf then
                        for i = #buf, 1, -1 do buf[i] = nil end
                    end
                end
            end
        end
    end

    -- Zero master mix input
    if master then
        DSP.buf_fill(master.in_bufs["in"], 0.0, n)
    end

    -- Process nodes in topo order
    for _, id in ipairs(render_order) do
        local node = nodes[id]
        if not node then goto continue end

        if id == MASTER_ID then
            -- Copy accumulated mix to output and update metering
            DSP.buf_copy(out_buf, master.in_bufs["in"], n)
            if master.instance then master.instance:_update(master.in_bufs["in"], n) end
        elseif node.instance then
            local inst = node.instance
            local def_type = node.def and node.def.type

            if def_type == "generator" then
                inst:render(node.out_bufs, n)
            elseif def_type == "effect" or def_type == "control" then
                inst:process(node.in_bufs, node.out_bufs, n)
            end

            -- Propagate outputs to connected nodes' inputs
            for _, e in ipairs(edges) do
                if e.from_id == id then
                    local src_buf = node.out_bufs[e.from_pin]
                    if not src_buf then goto next_edge end

                    if e.kind == "signal" then
                        if e.to_id == MASTER_ID then
                            DSP.buf_mix(master.in_bufs["in"], src_buf, 1.0, n)
                        else
                            local dst_node = nodes[e.to_id]
                            if dst_node then
                                local dst_buf = dst_node.in_bufs[e.to_pin]
                                if dst_buf then
                                    DSP.buf_mix(dst_buf, src_buf, 1.0, n)
                                end
                            end
                        end
                    else
                        -- Control: move messages into destination inlet
                        local dst_node = nodes[e.to_id]
                        if dst_node then
                            local dst_buf = dst_node.in_bufs[e.to_pin]
                            if dst_buf then
                                for _, msg in ipairs(src_buf) do
                                    table.insert(dst_buf, msg)
                                end
                            end
                        end
                    end
                    ::next_edge::
                end
            end
        end
        ::continue::
    end
end

-- Serialize graph to a plain table (for project save)
function DAG.serialize()
    local out = { nodes = {}, edges = {} }
    for id, node in pairs(nodes) do
        if id ~= MASTER_ID then
            table.insert(out.nodes, {
                id     = id,
                plugin = node.def and node.def._path or nil,
                params = node.params,
                x      = node.x,
                y      = node.y,
            })
        end
    end
    for _, e in ipairs(edges) do
        table.insert(out.edges, {
            from_id  = e.from_id,
            from_pin = e.from_pin,
            to_id    = e.to_id,
            to_pin   = e.to_pin,
        })
    end
    return out
end

return DAG
