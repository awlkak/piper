function love.conf(t)
    t.identity = "piper"
    t.version = "11.5"
    t.title = "Piper"
    t.author = "piper"
    t.url = ""

    t.window.title = "Piper"
    t.window.width = 1200
    t.window.height = 768
    t.window.resizable = true
    t.window.minwidth = 480
    t.window.minheight = 320
    t.window.highdpi = true

    t.audio.mic = false
    t.audio.mixwith = true

    t.modules.joystick = false
    t.modules.physics = false
    t.modules.video = false
end
