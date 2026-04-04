-- Unified Input
-- Merges mouse and touch events into a common "pointer" abstraction.
-- Also tracks keyboard state.
--
-- Pointer events use an id so multi-touch works:
--   id=1 is always the primary pointer (mouse or first finger)
--   id>1 are additional touch points
--
-- Pinch gesture is detected from two simultaneous touches.

local Input = {}

-- Pointer state table: id -> { x, y, down, dx, dy }
local pointers = {}

-- Keyboard: set of currently held keys
local keys_down = {}

-- Event queues (drained each frame by consuming code)
local events = {}   -- list of event tables

local function push_event(ev)
    table.insert(events, ev)
end

-- Drain and return all queued events, then clear the queue.
function Input.drain()
    local out = events
    events = {}
    return out
end

-- Current pointer state
function Input.pointer(id)
    return pointers[id or 1]
end

function Input.all_pointers()
    return pointers
end

function Input.is_key_down(key)
    return keys_down[key] == true
end

-- -------------------------
-- Internal handlers (called from main.lua / App)
-- -------------------------

function Input._mousepressed(x, y, button, istouch)
    if istouch then return end  -- handled by touch callbacks
    pointers[1] = { x=x, y=y, down=true, dx=0, dy=0, id=1 }
    push_event({ type="pointer_down", id=1, x=x, y=y, button=button })
end

function Input._mousereleased(x, y, button, istouch)
    if istouch then return end
    if pointers[1] then pointers[1].down = false end
    push_event({ type="pointer_up", id=1, x=x, y=y, button=button })
end

function Input._mousemoved(x, y, dx, dy, istouch)
    if istouch then return end
    if not pointers[1] then pointers[1] = { x=x, y=y, down=false, dx=0, dy=0, id=1 } end
    local p = pointers[1]
    p.x, p.y, p.dx, p.dy = x, y, dx, dy
    push_event({ type="pointer_move", id=1, x=x, y=y, dx=dx, dy=dy })
end

function Input._wheelmoved(dx, dy)
    local p = pointers[1]
    local px = p and p.x or 0
    local py = p and p.y or 0
    push_event({ type="wheel", x=px, y=py, dx=dx, dy=dy })
end

-- Touch (mobile)
local touch_id_map = {}   -- love touch id -> our integer id
local next_touch_id = 2   -- 1 is reserved for mouse

local function get_touch_id(lid)
    if not touch_id_map[lid] then
        touch_id_map[lid] = next_touch_id
        next_touch_id = next_touch_id + 1
    end
    return touch_id_map[lid]
end

function Input._touchpressed(lid, x, y)
    local id = get_touch_id(lid)
    pointers[id] = { x=x, y=y, down=true, dx=0, dy=0, id=id }
    push_event({ type="pointer_down", id=id, x=x, y=y, touch=true })
    -- Also simulate pointer 1 if not down (first touch = primary)
    if not pointers[1] or not pointers[1].down then
        pointers[1] = { x=x, y=y, down=true, dx=0, dy=0, id=1 }
        push_event({ type="pointer_down", id=1, x=x, y=y, touch=true })
    end
    Input._check_pinch()
end

function Input._touchreleased(lid, x, y)
    local id = get_touch_id(lid)
    if pointers[id] then pointers[id].down = false end
    push_event({ type="pointer_up", id=id, x=x, y=y, touch=true })
    touch_id_map[lid] = nil
    Input._check_pinch()
end

function Input._touchmoved(lid, x, y, dx, dy)
    local id = get_touch_id(lid)
    if not pointers[id] then
        pointers[id] = { x=x, y=y, down=true, dx=0, dy=0, id=id }
    end
    pointers[id].x, pointers[id].y = x, y
    pointers[id].dx, pointers[id].dy = dx, dy
    push_event({ type="pointer_move", id=id, x=x, y=y, dx=dx, dy=dy, touch=true })
    Input._check_pinch()
end

-- Pinch detection
local prev_pinch_dist = nil

function Input._check_pinch()
    -- Find two active touch pointers
    local pts = {}
    for id, p in pairs(pointers) do
        if id > 1 and p.down then table.insert(pts, p) end
    end
    if #pts < 2 then
        prev_pinch_dist = nil
        return
    end
    local p1, p2 = pts[1], pts[2]
    local dx = p2.x - p1.x
    local dy = p2.y - p1.y
    local dist = math.sqrt(dx*dx + dy*dy)
    if prev_pinch_dist then
        local scale = dist / prev_pinch_dist
        push_event({
            type  = "pinch",
            scale = scale,
            cx    = (p1.x + p2.x) * 0.5,
            cy    = (p1.y + p2.y) * 0.5,
        })
    end
    prev_pinch_dist = dist
end

function Input._keypressed(key, scancode, isrepeat)
    keys_down[key] = true
    push_event({ type="key_down", key=key, scancode=scancode, isrepeat=isrepeat })
end

function Input._keyreleased(key, scancode)
    keys_down[key] = false
    push_event({ type="key_up", key=key, scancode=scancode })
end

function Input._textinput(text)
    push_event({ type="text", text=text })
end

return Input
