local TAU = math.pi * 2

local plugin = {
  type    = "generator",
  name    = "Analog Kick",
  version = 1,
  inlets  = {
    { id = "trig", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",       label = "Amp",       min = 0,    max = 1,   default = 0.9, type = "float" },
    { id = "pan",       label = "Pan",       min = -1,   max = 1,   default = 0,   type = "float" },
    { id = "pitch",     label = "Pitch",     min = 30,   max = 200, default = 60,  type = "float" },
    { id = "pitch_end", label = "Pitch End", min = 20,   max = 80,  default = 35,  type = "float" },
    { id = "decay",     label = "Decay",     min = 0.05, max = 2,   default = 0.5, type = "float" },
    { id = "click",     label = "Click",     min = 0,    max = 1,   default = 0.4, type = "float" },
    { id = "sub",       label = "Sub",       min = 0,    max = 1,   default = 0.3, type = "float" },
    { id = "drive",     label = "Drive",     min = 1,    max = 5,   default = 1.5, type = "float" },
    { id = "tone",      label = "Tone",      min = 0,    max = 1,   default = 0.5, type = "float" },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp       = 0.9
  inst.pan       = 0
  inst.pitch     = 60
  inst.pitch_end = 35
  inst.decay     = 0.5
  inst.click     = 0.4
  inst.sub       = 0.3
  inst.drive     = 1.5
  inst.tone      = 0.5
  inst.sr        = 44100

  -- voice state
  inst.active    = false
  inst.t         = 0        -- sample counter
  inst.body_phase= 0
  inst.sub_phase = 0

  -- highpass state (one-pole) on body
  inst.hp_prev_in  = 0
  inst.hp_prev_out = 0

  function inst:init(sr)
    self.sr = sr
  end

  function inst:set_param(id, v)
    if     id == "amp"       then self.amp       = v
    elseif id == "pan"       then self.pan       = v
    elseif id == "pitch"     then self.pitch     = v
    elseif id == "pitch_end" then self.pitch_end = v
    elseif id == "decay"     then self.decay     = v
    elseif id == "click"     then self.click     = v
    elseif id == "sub"       then self.sub       = v
    elseif id == "drive"     then self.drive     = v
    elseif id == "tone"      then self.tone      = v
    end
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id ~= "trig" then return end
    if msg.type == "note" then
      self.t          = 0
      self.body_phase = 0
      self.sub_phase  = 0
      self.hp_prev_in  = 0
      self.hp_prev_out = 0
      self.active     = true
    end
    -- note_off: no effect
  end

  function inst:render(out_bufs, n)
    local buf = out_bufs["out"]
    if not self.active then
      piper.buf_fill(buf, 0, n)
      return
    end

    local panL, panR = piper.pan_gains(self.pan)
    local amp        = self.amp
    local sr         = self.sr
    local pitch      = self.pitch
    local pitch_end  = self.pitch_end
    local decay      = self.decay
    local drive      = self.drive
    local sub_amt    = self.sub
    local click_amt  = self.click

    -- sweep_rate: time constant in samples
    local sweep_rate = 8 / (decay * sr)
    -- highpass cutoff: tone 0..1 maps to 20..500 Hz
    local hp_cutoff = 20 + self.tone * 480
    local hp_rc     = 1 / (TAU * hp_cutoff / sr)
    local hp_alpha  = hp_rc / (hp_rc + 1 / sr * sr)  -- approximate
    -- simpler one-pole HP: alpha = 1/(1 + 2*pi*fc/sr)
    hp_alpha = 1 - (TAU * hp_cutoff / sr)
    hp_alpha = piper.clamp(hp_alpha, 0, 0.9999)

    local t          = self.t
    local body_phase = self.body_phase
    local sub_phase  = self.sub_phase
    local hp_in      = self.hp_prev_in
    local hp_out     = self.hp_prev_out

    for i = 0, n - 1 do
      -- pitch envelope
      local current_hz = pitch_end + (pitch - pitch_end) * math.exp(-t * sweep_rate)

      -- body sine
      body_phase = body_phase + TAU * current_hz / sr
      if body_phase > TAU * 1000 then body_phase = body_phase % TAU end
      local body_env = math.exp(-t * 3.0 / (decay * sr))
      local body_raw = math.sin(body_phase) * body_env

      -- one-pole highpass on body (tone shaping)
      local hp_body = hp_alpha * (hp_out + body_raw - hp_in)
      hp_in  = body_raw
      hp_out = hp_body
      -- blend raw and highpassed based on tone
      local body_val = body_raw + hp_body * self.tone

      -- sub layer
      sub_phase = sub_phase + TAU * (pitch / 2) / sr
      if sub_phase > TAU * 1000 then sub_phase = sub_phase % TAU end
      local sub_env = body_env
      local sub_val = math.sin(sub_phase) * sub_env * sub_amt

      -- click layer
      local click_env = math.exp(-t * 400 / sr)
      local click_val = (math.random() * 2 - 1) * click_env * click_amt

      -- mix
      local s = body_val * (1 - sub_amt) + sub_val + click_val

      -- drive + softclip
      s = piper.softclip(s * drive) * amp

      buf[i * 2 + 1] = s * panL
      buf[i * 2 + 2] = s * panR

      t = t + 1
    end

    self.t          = t
    self.body_phase = body_phase
    self.sub_phase  = sub_phase
    self.hp_prev_in  = hp_in
    self.hp_prev_out = hp_out
  end

  function inst:reset()
    self.active      = false
    self.t           = 0
    self.body_phase  = 0
    self.sub_phase   = 0
    self.hp_prev_in  = 0
    self.hp_prev_out = 0
  end

  function inst:destroy() end

  return inst
end

return plugin
