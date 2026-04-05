local TAU = math.pi * 2

local plugin = {
  type    = "generator",
  name    = "Analog Snare",
  version = 1,
  inlets  = {
    { id = "trig", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",         label = "Amp",         min = 0,    max = 1,   default = 0.7,  type = "float" },
    { id = "pan",         label = "Pan",         min = -1,   max = 1,   default = 0,    type = "float" },
    { id = "tune",        label = "Tune",        min = -12,  max = 12,  default = 0,    type = "float" },
    { id = "snap",        label = "Snap",        min = 0,    max = 1,   default = 0.5,  type = "float" },
    { id = "decay",       label = "Decay",       min = 0.05, max = 0.5, default = 0.15, type = "float" },
    { id = "tone_decay",  label = "Tone Decay",  min = 0.02, max = 0.3, default = 0.08, type = "float" },
    { id = "noise_decay", label = "Noise Decay", min = 0.05, max = 0.6, default = 0.2,  type = "float" },
    { id = "body_freq",   label = "Body Freq",   min = 100,  max = 400, default = 185,  type = "float" },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp         = 0.7
  inst.pan         = 0
  inst.tune        = 0
  inst.snap        = 0.5
  inst.decay       = 0.15
  inst.tone_decay  = 0.08
  inst.noise_decay = 0.2
  inst.body_freq   = 185
  inst.sr          = 44100

  inst.active   = false
  inst.t        = 0
  inst.phase1   = 0
  inst.phase2   = 0

  -- bandpass biquad state
  inst.bq = { x1=0, x2=0, y1=0, y2=0 }
  -- biquad coeffs (computed on note-on / param change)
  inst.bq_b0 = 0; inst.bq_b2 = 0
  inst.bq_a1 = 0; inst.bq_a2 = 0

  local function compute_bp(self)
    local center = self.body_freq * 20
    center = piper.clamp(center, 20, self.sr * 0.49)
    local q     = 1.5
    local w0    = TAU * center / self.sr
    local alpha = math.sin(w0) / (2 * q)
    local b0    =  alpha
    local b2    = -alpha
    local a0    =  1 + alpha
    local a1    = -2 * math.cos(w0)
    local a2    =  1 - alpha
    self.bq_b0 = b0 / a0
    self.bq_b2 = b2 / a0
    self.bq_a1 = a1 / a0
    self.bq_a2 = a2 / a0
  end

  function inst:init(sr)
    self.sr = sr
    compute_bp(self)
  end

  function inst:set_param(id, v)
    if     id == "amp"         then self.amp         = v
    elseif id == "pan"         then self.pan         = v
    elseif id == "tune"        then self.tune        = v
    elseif id == "snap"        then self.snap        = v
    elseif id == "decay"       then self.decay       = v
    elseif id == "tone_decay"  then self.tone_decay  = v
    elseif id == "noise_decay" then self.noise_decay = v
    elseif id == "body_freq"   then self.body_freq   = v; compute_bp(self)
    end
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id ~= "trig" then return end
    if msg.type == "note" then
      local vel = (msg.velocity or 1)
      self.vel     = vel
      self.t       = 0
      self.phase1  = 0
      self.phase2  = 0
      local bq     = self.bq
      bq.x1=0; bq.x2=0; bq.y1=0; bq.y2=0
      compute_bp(self)
      self.active  = true
    end
  end

  function inst:render(out_bufs, n)
    local buf = out_bufs["out"]
    if not self.active then
      piper.buf_fill(buf, 0, n)
      return
    end

    local panL, panR = piper.pan_gains(self.pan)
    local amp        = self.amp * (self.vel or 1)
    local sr         = self.sr
    local snap       = self.snap

    -- tune shifts both oscillator frequencies
    local tune_ratio = 2^(self.tune/12)
    local f1 = self.body_freq * tune_ratio
    local f2 = f1 * 1.78

    local bq_b0 = self.bq_b0; local bq_b2 = self.bq_b2
    local bq_a1 = self.bq_a1; local bq_a2 = self.bq_a2
    local bq    = self.bq

    local t      = self.t
    local ph1    = self.phase1
    local ph2    = self.phase2
    local td     = self.tone_decay
    local nd     = self.noise_decay

    for i = 0, n - 1 do
      -- tone layer
      local tone_env  = math.exp(-t * 3 / (td * sr))
      ph1 = ph1 + TAU * f1 / sr
      ph2 = ph2 + TAU * f2 / sr
      if ph1 > TAU * 1000 then ph1 = ph1 % TAU end
      if ph2 > TAU * 1000 then ph2 = ph2 % TAU end
      local body = (math.sin(ph1) + math.sin(ph2)) * 0.5 * tone_env

      -- noise layer through bandpass
      local noise_env    = math.exp(-t * 3 / (nd * sr))
      local raw_noise    = (math.random() * 2 - 1) * noise_env
      local filtered     = bq_b0 * raw_noise + bq_b2 * bq.x2
                         - bq_a1 * bq.y1 - bq_a2 * bq.y2
      bq.x2 = bq.x1; bq.x1 = raw_noise
      bq.y2 = bq.y1; bq.y1 = filtered

      -- mix
      local s = (body * (1 - snap) + filtered * snap) * amp

      buf[i * 2 + 1] = s * panL
      buf[i * 2 + 2] = s * panR

      t = t + 1
    end

    self.t      = t
    self.phase1 = ph1
    self.phase2 = ph2
  end

  function inst:reset()
    self.active  = false
    self.t       = 0
    self.phase1  = 0
    self.phase2  = 0
    local bq     = self.bq
    bq.x1=0; bq.x2=0; bq.y1=0; bq.y2=0
  end

  function inst:destroy() end

  return inst
end

return plugin
