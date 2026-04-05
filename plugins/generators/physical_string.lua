local TAU = math.pi * 2

local plugin = {
  type    = "generator",
  name    = "Physical String",
  version = 1,
  inlets  = {
    { id = "trig", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",        label = "Amp",        min = 0,   max = 1,    default = 0.6,  type = "float" },
    { id = "pan",        label = "Pan",        min = -1,  max = 1,    default = 0,    type = "float" },
    { id = "tune",       label = "Tune",       min = -24, max = 24,   default = 0,    type = "float" },
    { id = "body_freq",  label = "Body Freq",  min = 100, max = 1000, default = 300,  type = "float" },
    { id = "body_q",     label = "Body Q",     min = 0.1, max = 5,    default = 1.0,  type = "float" },
    { id = "dispersion", label = "Dispersion", min = 0,   max = 1,    default = 0.1,  type = "float" },
    { id = "damping",    label = "Damping",    min = 0,   max = 1,    default = 0.5,  type = "float" },
    { id = "excitation", label = "Excitation", min = 0,   max = 1,    default = 0,    type = "int", step = 1 },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp        = 0.6
  inst.pan        = 0
  inst.tune       = 0
  inst.body_freq  = 300
  inst.body_q     = 1.0
  inst.dispersion = 0.1
  inst.damping    = 0.5
  inst.excitation = 0  -- 0=pluck, 1=bow
  inst.sr         = 44100
  inst.max_size   = 0

  -- KS buffers
  inst.bufL     = nil
  inst.bufR     = nil
  inst.ks_sizeL = 2
  inst.ks_sizeR = 3
  inst.ks_posL  = 1
  inst.ks_posR  = 1
  inst.lastL    = 0
  inst.lastR    = 0

  -- all-pass state: 2 stages, L and R
  -- ap[stage][LR]: x_prev, y_prev
  inst.ap = {
    { xpL=0, ypL=0, xpR=0, ypR=0 },
    { xpL=0, ypL=0, xpR=0, ypR=0 },
  }

  -- body biquad state
  inst.bqL = { x1=0, x2=0, y1=0, y2=0 }
  inst.bqR = { x1=0, x2=0, y1=0, y2=0 }
  -- biquad coeffs (normalized)
  inst.bq_b0 = 0; inst.bq_b1 = 0; inst.bq_b2 = 0
  inst.bq_a1 = 0; inst.bq_a2 = 0

  inst.active  = false
  inst.bowing  = false
  inst.bow_strength = 0.05

  local function compute_biquad(self)
    local w0    = TAU * self.body_freq / self.sr
    local alpha = math.sin(w0) / (2 * self.body_q)
    local b0    =  alpha
    local b1    =  0
    local b2    = -alpha
    local a0    =  1 + alpha
    local a1    = -2 * math.cos(w0)
    local a2    =  1 - alpha
    self.bq_b0 = b0 / a0
    self.bq_b1 = b1 / a0
    self.bq_b2 = b2 / a0
    self.bq_a1 = a1 / a0
    self.bq_a2 = a2 / a0
  end

  function inst:init(sr)
    self.sr       = sr
    self.max_size = math.floor(sr / 20) + 1
    self.bufL     = {}
    self.bufR     = {}
    for i = 1, self.max_size do
      self.bufL[i] = 0
      self.bufR[i] = 0
    end
    compute_biquad(self)
  end

  function inst:set_param(id, v)
    if     id == "amp"        then self.amp        = v
    elseif id == "pan"        then self.pan        = v
    elseif id == "tune"       then self.tune       = v
    elseif id == "body_freq"  then self.body_freq  = v; compute_biquad(self)
    elseif id == "body_q"     then self.body_q     = v; compute_biquad(self)
    elseif id == "dispersion" then self.dispersion = v
    elseif id == "damping"    then self.damping    = v
    elseif id == "excitation" then self.excitation = math.floor(v + 0.5)
    end
  end

  local function reset_ap(ap)
    for _, s in ipairs(ap) do
      s.xpL=0; s.ypL=0; s.xpR=0; s.ypR=0
    end
  end

  local function reset_bq(bq)
    bq.x1=0; bq.x2=0; bq.y1=0; bq.y2=0
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id ~= "trig" then return end
    if msg.type == "note" then
      local note  = (msg.note or 60) + self.tune
      local hz    = piper.note_to_hz(note)
      local sizeL = math.max(2, math.floor(self.sr / hz))
      local sizeR = math.max(2, sizeL + 1)
      sizeL = math.min(sizeL, self.max_size)
      sizeR = math.min(sizeR, self.max_size)
      self.ks_sizeL = sizeL
      self.ks_sizeR = sizeR

      if self.excitation == 0 then
        -- pluck: noise burst
        for i = 1, sizeL do self.bufL[i] = math.random() * 2 - 1 end
        for i = 1, sizeR do self.bufR[i] = math.random() * 2 - 1 end
        self.bowing = false
      else
        -- bow: silence buffer, sustain via continuous injection
        for i = 1, sizeL do self.bufL[i] = 0 end
        for i = 1, sizeR do self.bufR[i] = 0 end
        self.bowing = true
      end

      self.ks_posL = 1
      self.ks_posR = 1
      self.lastL   = 0
      self.lastR   = 0
      reset_ap(self.ap)
      reset_bq(self.bqL)
      reset_bq(self.bqR)
      self.active = true

    elseif msg.type == "note_off" then
      self.bowing = false
    end
  end

  function inst:render(out_bufs, n)
    local buf = out_bufs["out"]
    if not self.active then
      piper.buf_fill(buf, 0, n)
      return
    end

    local panL, panR = piper.pan_gains(self.pan)
    local amp        = self.amp
    -- decay factor: map damping 0..1 to stretch_factor ~0.998..0.9
    local decay_f    = 1 - self.damping * 0.1
    local sf         = 0.5 * decay_f

    local g  = self.dispersion * 0.7
    local ap = self.ap

    local bq_b0 = self.bq_b0; local bq_b1 = self.bq_b1; local bq_b2 = self.bq_b2
    local bq_a1 = self.bq_a1; local bq_a2 = self.bq_a2
    local bqL   = self.bqL;   local bqR   = self.bqR

    local bufL  = self.bufL;  local bufR  = self.bufR
    local posL  = self.ks_posL; local posR = self.ks_posR
    local sizeL = self.ks_sizeL; local sizeR = self.ks_sizeR
    local lastL = self.lastL;    local lastR = self.lastR
    local bowing = self.bowing
    local bow_s  = self.bow_strength

    for i = 0, n - 1 do
      -- KS feedback with optional bow injection
      local inL = bufL[posL]
      local inR = bufR[posR]

      if bowing then
        inL = inL + (math.random() * 2 - 1) * bow_s
        inR = inR + (math.random() * 2 - 1) * bow_s
      end

      -- one-pole lowpass
      local lpL = (inL + lastL) * sf
      local lpR = (inR + lastR) * sf
      lastL = lpL
      lastR = lpR

      -- all-pass dispersion chain
      local xL = lpL; local xR = lpR
      for st = 1, 2 do
        local s = ap[st]
        local yL = -g * xL + s.xpL + g * s.ypL
        local yR = -g * xR + s.xpR + g * s.ypR
        s.xpL = xL; s.ypL = yL
        s.xpR = xR; s.ypR = yR
        xL = yL; xR = yR
      end

      bufL[posL] = xL
      bufR[posR] = xR

      posL = (posL % sizeL) + 1
      posR = (posR % sizeR) + 1

      -- body biquad on output (not in feedback)
      local outL = bq_b0 * xL + bq_b1 * bqL.x1 + bq_b2 * bqL.x2
                 - bq_a1 * bqL.y1 - bq_a2 * bqL.y2
      bqL.x2 = bqL.x1; bqL.x1 = xL
      bqL.y2 = bqL.y1; bqL.y1 = outL

      local outR = bq_b0 * xR + bq_b1 * bqR.x1 + bq_b2 * bqR.x2
                 - bq_a1 * bqR.y1 - bq_a2 * bqR.y2
      bqR.x2 = bqR.x1; bqR.x1 = xR
      bqR.y2 = bqR.y1; bqR.y1 = outR

      -- mix KS + body resonance
      local sL = (xL + outL * 0.5) * panL * amp
      local sR = (xR + outR * 0.5) * panR * amp

      buf[i * 2 + 1] = sL
      buf[i * 2 + 2] = sR
    end

    self.ks_posL = posL
    self.ks_posR = posR
    self.lastL   = lastL
    self.lastR   = lastR
  end

  function inst:reset()
    self.active  = false
    self.bowing  = false
    self.ks_posL = 1
    self.ks_posR = 1
    self.lastL   = 0
    self.lastR   = 0
    reset_ap(self.ap)
    reset_bq(self.bqL)
    reset_bq(self.bqR)
    if self.bufL then
      for i = 1, self.max_size do self.bufL[i] = 0 end
    end
    if self.bufR then
      for i = 1, self.max_size do self.bufR[i] = 0 end
    end
  end

  function inst:destroy() end

  return inst
end

return plugin
