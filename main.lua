-- Piper: Modular Music Tracker
-- Love2D entry point

local App = require("src.app")

function love.load()
    App.load()
end

function love.update(dt)
    App.update(dt)
end

function love.draw()
    App.draw()
end

function love.quit()
    App.quit()
end

function love.resize(w, h)
    App.resize(w, h)
end

function love.keypressed(key, scancode, isrepeat)
    App.keypressed(key, scancode, isrepeat)
end

function love.keyreleased(key, scancode)
    App.keyreleased(key, scancode)
end

function love.textinput(text)
    App.textinput(text)
end

function love.mousepressed(x, y, button, istouch, presses)
    App.mousepressed(x, y, button, istouch, presses)
end

function love.mousereleased(x, y, button, istouch, presses)
    App.mousereleased(x, y, button, istouch, presses)
end

function love.mousemoved(x, y, dx, dy, istouch)
    App.mousemoved(x, y, dx, dy, istouch)
end

function love.wheelmoved(x, y)
    App.wheelmoved(x, y)
end

function love.touchpressed(id, x, y, dx, dy, pressure)
    App.touchpressed(id, x, y, dx, dy, pressure)
end

function love.touchreleased(id, x, y, dx, dy, pressure)
    App.touchreleased(id, x, y, dx, dy, pressure)
end

function love.touchmoved(id, x, y, dx, dy, pressure)
    App.touchmoved(id, x, y, dx, dy, pressure)
end
