-- Application State Machine
-- Wires together: Engine, DAG, Sequencer, UI, and project I/O.
-- Called from main.lua love callbacks.

local Engine    = require("src.audio.engine")
local DAG       = require("src.machine.dag")
local Registry  = require("src.machine.registry")
local Bus       = require("src.machine.bus")
local Loader    = require("src.machine.loader")
local Sequencer = require("src.sequencer.sequencer")
local Song      = require("src.sequencer.song")
local Pattern   = require("src.sequencer.pattern")
local Event     = require("src.sequencer.event")
local ProjLoader = require("src.project.loader")
local UI        = require("src.ui.ui")
local Input     = require("src.ui.input")
local Theme     = require("src.ui.theme")

local App = {}

local song    -- current Song
local current_project_path = nil

-- -------------------------
-- Initialization
-- -------------------------

function App.load()
    math.randomseed(os.time())
    love.graphics.setDefaultFilter("nearest", "nearest")

    -- Ensure save-directory layout exists on first run
    love.filesystem.createDirectory("songs")

    -- Init DAG
    DAG.init(Engine.BLOCK_SIZE)

    -- Wire engine -> DAG -> Sequencer -> Bus
    Engine.set_dag_renderer(function(buf, n)
        DAG.render_block(buf, n)
    end)

    Engine.set_queue_drainer(function(sample_offset)
        Bus.drain(function(mid, inlet_id, msg)
            DAG.deliver_message(mid, inlet_id, msg)
        end)
        Sequencer.queue_drain(Engine.BLOCK_SIZE)
    end)

    -- Wire Sequencer -> DAG message delivery
    Sequencer.set_deliver(function(machine_id, inlet_id, msg)
        DAG.deliver_message(machine_id, inlet_id, msg)
    end)
    Sequencer.set_sample_rate(Engine.SAMPLE_RATE)

    -- Start audio engine
    Engine.init()

    -- Load UI
    UI.load()
    UI.set_callbacks(
        function() Sequencer.play();    UI.set_playing(true)  end,
        function() Sequencer.stop();    UI.set_playing(false) end,
        function(path) pcall(App._save_project, path) end,
        function()
            -- New project
            Sequencer.stop()
            UI.set_playing(false)
            current_project_path = nil
            App._new_empty_project()
        end,
        function(path)
            -- Open project
            Sequencer.stop()
            UI.set_playing(false)
            local ok, err = pcall(App._load_project, path)
            if not ok then print("[App] load error: " .. tostring(err)) end
        end,
        -- Restart: seek to start and play
        function()
            Sequencer.restart()
            UI.set_playing(true)
        end,
        -- Loop pattern toggle
        function(enabled)
            Sequencer.set_loop_pattern(enabled)
            UI.set_loop_pattern(enabled)
        end,
        -- Seek to order slot
        function(order_pos)
            Sequencer.seek(order_pos, 0)
        end
    )
    UI.set_graph_callbacks(
        function(id, def, inst, params) end,  -- on_add: DAG/Registry already done in PatchGraph
        function(id) end,                     -- on_del: already done in PatchGraph
        function(from_id, from_pin, to_id, to_pin) end,
        function(idx, e) end
    )
    local w, h = love.graphics.getDimensions()
    UI.resize(w, h)

    -- Build or load initial project
    local ok = false
    if love.filesystem.getInfo("songs/demo.piper") then
        ok = pcall(App._load_project, "songs/demo.piper")
        if not ok then print("[App] demo.piper load failed, building default") end
    end
    if not ok then
        App._build_default_project()
    end
end

-- -------------------------
-- Default project
-- -------------------------

function App._new_empty_project()
    DAG.init(Engine.BLOCK_SIZE)
    Registry.clear()
    song = Song.new()
    song.bpm   = 120
    song.speed = 6
    local pat = Pattern.new("pat1", 32, 4)
    pat.label = "Pattern 1"
    song:add_pattern(pat)
    song:append_order("pat1", {})
    Sequencer.set_song(song)
    UI.set_song(song)
end

function App._build_default_project()
    -- Reset graph state for a fresh project
    DAG.init(Engine.BLOCK_SIZE)
    Registry.clear()

    -- Create a simple song: one pattern, one sine oscillator into master
    song = Song.new()
    song.bpm   = 120
    song.speed = 6

    -- Pattern
    local pat = Pattern.new("pat1", 32, 4)
    pat.label = "Intro"
    -- Simple melody on channel 0: C D E G (every 8 rows)
    local melody = {60, 62, 64, 67, 69, 67, 64, 62}
    for i, note in ipairs(melody) do
        pat:set_note((i - 1) * 4, 0, note, nil, 220)
    end
    -- Bass on channel 1
    pat:set_note(0,  1, 48, nil, 200)
    pat:set_note(16, 1, 43, nil, 200)
    song:add_pattern(pat)

    -- Load default sine oscillator machine
    local sine_def, sine_inst
    local ok, err = pcall(function()
        sine_def  = Loader.load("plugins/generators/sine_osc.lua",
                                Engine.SAMPLE_RATE, Engine.BLOCK_SIZE)
        sine_inst = Loader.instantiate(sine_def, {}, Engine.SAMPLE_RATE)
    end)
    if not ok then
        print("[App] WARNING: could not load sine_osc.lua: " .. tostring(err))
    end

    local bass_def, bass_inst
    ok, err = pcall(function()
        bass_def  = Loader.load("plugins/generators/square_osc.lua",
                                Engine.SAMPLE_RATE, Engine.BLOCK_SIZE)
        bass_inst = Loader.instantiate(bass_def, {}, Engine.SAMPLE_RATE)
    end)
    if not ok then
        print("[App] WARNING: could not load square_osc.lua: " .. tostring(err))
    end

    -- Register machines and add to DAG
    if sine_def and sine_inst then
        DAG.add_node("sine1", sine_def, sine_inst, {}, 100, 80)
        Registry.register("sine1", sine_def, sine_inst, {})
        DAG.add_edge("sine1", "out", DAG.master_id(), "in")
    end
    if bass_def and bass_inst then
        DAG.add_node("bass1", bass_def, bass_inst, {amp=0.3}, 100, 220)
        if bass_inst.set_param then bass_inst:set_param("amp", 0.3) end
        Registry.register("bass1", bass_def, bass_inst, {amp=0.3})
        DAG.add_edge("bass1", "out", DAG.master_id(), "in")
    end

    -- Order list
    local machine_map = { [0]="sine1", [1]="bass1" }
    song:append_order("pat1", machine_map)

    Sequencer.set_song(song)
    UI.set_song(song)
end

-- -------------------------
-- Project I/O
-- -------------------------

function App._load_project(path)
    local state = ProjLoader.load(path, Engine.SAMPLE_RATE, Engine.BLOCK_SIZE)
    song = state.song
    current_project_path = path
    Sequencer.set_song(song)
    UI.set_song(song)
end

function App._save_project(path)
    path = path or current_project_path or "songs/untitled.piper"
    local dag_data = DAG.serialize()
    local state = ProjLoader.build_state(song, dag_data.nodes, dag_data.edges)
    ProjLoader.save(path, state)
    current_project_path = path
    print("[App] saved: " .. path)
end

-- -------------------------
-- Love2D callbacks
-- -------------------------

function App.update(dt)
    Engine.update()
    -- Sync playhead to UI
    local pos = Sequencer.position()
    UI.set_playhead(pos.order_pos, pos.row)
    if Sequencer.is_playing() then
        UI.set_playing(true)
    end
end

function App.draw()
    love.graphics.clear(Theme.bg[1], Theme.bg[2], Theme.bg[3])
    UI.draw()
end

function App.quit()
    Engine.quit()
end

function App.resize(w, h)
    UI.resize(w, h)
end

-- Input forwarding to UI input module, then dispatch via UI
function App.keypressed(key, scancode, isrepeat)
    Input._keypressed(key, scancode, isrepeat)
    -- Global shortcuts
    if key == "space" and love.keyboard.isDown("lctrl") then
        if Sequencer.is_playing() then
            Sequencer.stop()
            UI.set_playing(false)
        else
            Sequencer.play()
            UI.set_playing(true)
        end
    elseif key == "return" and love.keyboard.isDown("lctrl") then
        -- Ctrl+Enter: restart from beginning
        Sequencer.restart()
        UI.set_playing(true)
    elseif key == "l" and love.keyboard.isDown("lctrl") then
        -- Ctrl+L: toggle loop pattern
        local enabled = not Sequencer.get_loop_pattern()
        Sequencer.set_loop_pattern(enabled)
        UI.set_loop_pattern(enabled)
    elseif key == "s" and love.keyboard.isDown("lctrl") then
        local shift = love.keyboard.isDown("lshift") or love.keyboard.isDown("rshift")
        if shift or not current_project_path then
            -- Ctrl+Shift+S (Save As) or first save: open dialog to pick filename
            local default = current_project_path and current_project_path:match("([^/]+)$") or nil
            UI.open_save_dialog(default)
        else
            -- Ctrl+S with known path: save directly
            local ok, err = pcall(App._save_project)
            if not ok then print("[App] save error: " .. tostring(err)) end
        end
    end
    UI.handle_events()
end

function App.keyreleased(key, scancode)
    Input._keyreleased(key, scancode)
end

function App.textinput(text)
    Input._textinput(text)
end

function App.mousepressed(x, y, button, istouch, presses)
    Input._mousepressed(x, y, button, istouch)
    UI.handle_events()
end

function App.mousereleased(x, y, button, istouch, presses)
    Input._mousereleased(x, y, button, istouch)
    UI.handle_events()
end

function App.mousemoved(x, y, dx, dy, istouch)
    Input._mousemoved(x, y, dx, dy, istouch)
    UI.handle_events()
end

function App.wheelmoved(x, y)
    Input._wheelmoved(x, y)
    UI.handle_events()
end

function App.touchpressed(id, x, y, dx, dy, pressure)
    Input._touchpressed(id, x, y)
    UI.handle_events()
end

function App.touchreleased(id, x, y, dx, dy, pressure)
    Input._touchreleased(id, x, y)
    UI.handle_events()
end

function App.touchmoved(id, x, y, dx, dy, pressure)
    Input._touchmoved(id, x, y, dx, dy)
    UI.handle_events()
end

-- Expose for external use (UI transport bar)
App.play  = function() Sequencer.play();  UI.set_playing(true)  end
App.stop  = function() Sequencer.stop();  UI.set_playing(false) end
App.save  = App._save_project
App.song  = function() return song end

return App
