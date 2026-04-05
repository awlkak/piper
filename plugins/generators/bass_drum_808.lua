local TAU = math.pi * 2

local plugin = {
  type    = "generator",
  name    = "Bass Drum 808",
  version = 1,
  inlets  = {
    { id = "trig", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",   label = "Amp",   min = 0,   max = 1,   default = 0.9, type = "float" },
    { id = "pan",   label = "Pan",   min = -1,  max = 1,   default = 0,   type = "float" },
    { id = "tone",  label = "Tone",  min = 40,  max = 200, default = 55,  type = "float" },
    { id = "decay", label = "Decay", min = 0.1, max = 5,   default = 1.5, type = "float" },
    { id = "punch", label = "Punch", min = 0,   max = 1,   default = 0.8, type = "float" },
    { id = "click", label = "Click", min = 0,   max = 1,   default = 0.5, type = "float" },
    { id = "dist",  label = "Dist",  min = 1,   max = 8,   default = 1.0, type = "float" },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp   = 0.9
  inst.pan   = 0
  inst.tone  = 55
  inst.decay = 1.5
  inst.punch = 0.8
  inst.click = 0.5
  inst.dist  = 1.0
  inst.sr    = 44100

  inst.active = false
  inst.t      = 0
  inst.phase  = 0

  -- attack ramp: ~1ms
  inst.attack_samples = 0

  function inst:init(sr)
    self.sr             = sr
    self.attack_samples = math.max(1, math.floor(sr * 0.001))
  end

  function inst:set_param(id, v)
    if     id == "amp"   then self.amp   = v
    elseif id == "pan"   then self.pan   = v
    elseif id == "tone"  then self.tone  = v
    elseif id == "decay" then self.decay = v
    elseif id == "punch" then self.punch = v
    elseif id == "click" then self.click = v
    elseif id == "dist"  then self.dist  = v
    end
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id ~= "trig" then return end
    if msg.type == "note" then
      self.t      = 0
      self.phase  = 0
      self.active = true
    end
    -- note_off: no effect — 808 decays naturally
  end

  function inst:render(out_bufs, n)
    local buf = out_bufs["out"]
    if not self.active then
      piper.buf_fill(buf, 0, n)
      return
    end

    local panL, panR  = piper.pan_gains(self.pan)
    local amp         = self.amp
    local sr          = self.sr
    local tone        = self.tone
    local decay       = self.decay
    local punch_amt   = self.punch
    local click_amt   = self.click
    local dist        = self.dist
    local atk         = self.attack_samples

    -- punch_hz is tone*6 at t=0, punch_rate tuned for ~20ms half-life
    local punch_hz    = tone * 6 * punch_amt
    -- punch_rate: solve exp(-0.02*sr * punch_rate) = 0.5
    -- => punch_rate = ln(2)/(0.02*sr)
    local punch_rate  = math.log(2) / (0.02 * sr)

    local t     = self.t
    local phase = self.phase

    for i = 0, n - 1 do
      -- pitch envelope: starts at tone + punch_hz, decays to tone
      local hz = tone + punch_hz * math.exp(-t * punch_rate)

      -- phase accumulation
      phase = phase + TAU * hz / sr
      if phase > TAU * 1000 then phase = phase % TAU end

      -- amplitude envelope: short linear attack then exponential decay
      local env
      if t < atk then
        env = t / atk
      else
        env = math.exp(-(t - atk) / (decay * sr))
      end

      local body = math.sin(phase) * env

      -- click: very short noise burst
      local click_env = math.exp(-t * 500 / sr)
      local click_sig = (math.random() * 2 - 1) * click_env * click_amt

      local s = body + click_sig

      -- distortion + softclip
      s = piper.softclip(s * dist) * amp

      buf[i * 2 + 1] = s * panL
      buf[i * 2 + 2] = s * panR

      t = t + 1
    end

    self.t     = t
    self.phase = phase
  end

  function inst:reset()
    self.active = false
    self.t      = 0
    self.phase  = 0
  end

  function inst:destroy() end

  return inst
end

return plugin
