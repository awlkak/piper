-- Named Message Bus (Max/MSP send/receive pattern)
-- Machines can send messages to named channels and subscribe to receive them.
-- Messages are queued and delivered at the next control block boundary.

local Bus = {}

-- subscriptions[channel] = list of {machine_id, inlet_id, callback}
local subscriptions = {}

-- Pending message queue: list of {channel, msg}
-- Drained by the audio engine each block before DAG render
local pending = {}

-- Subscribe a machine inlet to a named channel
function Bus.subscribe(channel, machine_id, inlet_id, callback)
    if not subscriptions[channel] then
        subscriptions[channel] = {}
    end
    -- Avoid duplicates
    for _, sub in ipairs(subscriptions[channel]) do
        if sub.machine_id == machine_id and sub.inlet_id == inlet_id then
            return
        end
    end
    table.insert(subscriptions[channel], {
        machine_id = machine_id,
        inlet_id   = inlet_id,
        callback   = callback,
    })
end

-- Unsubscribe a machine from all channels (call on machine removal)
function Bus.unsubscribe_all(machine_id)
    for _, subs in pairs(subscriptions) do
        for i = #subs, 1, -1 do
            if subs[i].machine_id == machine_id then
                table.remove(subs, i)
            end
        end
    end
end

function Bus.unsubscribe(channel, machine_id)
    local subs = subscriptions[channel]
    if not subs then return end
    for i = #subs, 1, -1 do
        if subs[i].machine_id == machine_id then
            table.remove(subs, i)
        end
    end
end

-- Send a message to a named channel (queued for next block)
function Bus.send(channel, msg)
    table.insert(pending, { channel = channel, msg = msg })
end

-- Drain the queue and deliver messages to subscribers.
-- Called by the audio engine before each control block render.
-- deliver_fn(machine_id, inlet_id, msg) routes to the DAG.
function Bus.drain(deliver_fn)
    local to_process = pending
    pending = {}
    for _, item in ipairs(to_process) do
        local subs = subscriptions[item.channel]
        if subs then
            for _, sub in ipairs(subs) do
                if sub.callback then
                    sub.callback(item.msg)
                elseif deliver_fn then
                    deliver_fn(sub.machine_id, sub.inlet_id, item.msg)
                end
            end
        end
    end
end

function Bus.clear()
    subscriptions = {}
    pending = {}
end

return Bus
