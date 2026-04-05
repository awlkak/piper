local TAU = math.pi * 2

local plugin = {
  type    = "generator",
  name    = "Karplus Strong",
  version = 1,
  inlets  = {
    { id = "trig", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",       label = "Amp",       min = 0,   max = 1,      default = 0.7,   type = "float" },
    { id = "pan",       label = "Pan",       min = -1,  max = 1,      default = 0,     type = "float" },
    { id = "tune",      label = "Tune",      min = -24, max = 24,     default = 0,     type = "float" },
    { id = "stretch",   label = "Stretch",   min = 0,   max = 1,      default = 0.5,   type = "float" },
    { id = "pluck_pos", label = "Pluck Pos", min = 0,   max = 1,      default = 0.5,   type = "float" },
    { id = "decay",     label = "Decay",     min = 0.9, max = 0.9999, default = 0.998, type = "float" },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp       = 0.7
  inst.pan       = 0
  inst.tune      = 0
  inst.stretch   = 0.5
  inst.pluck_pos = 0.5
  inst.decay     = 0.998
  inst.sr        = 44100
  inst.max_size  = 0
  inst.bufL      = nil
  inst.bufR      = nil
  inst.ks_sizeL  = 2
  inst.ks_sizeR  = 3
  inst.ks_posL   = 1
  inst.ks_posR   = 1
  inst.lastL     = 0
  inst.lastR     = 0
  inst.active    = false

  function inst:init(sr)
    self.sr       = sr
    self.max_size = math.floor(sr / 20) + 1
    self.bufL     = {}
    self.bufR     = {}
    for i = 1, self.max_size do
      self.bufL[i] = 0
      self.bufR[i] = 0
    end
  end

  function inst:set_param(id, v)
    if     id == "amp"       then self.amp       = v
    elseif id == "pan"       then self.pan       = v
    elseif id == "tune"      then self.tune      = v
    elseif id == "stretch"   then self.stretch   = v
    elseif id == "pluck_pos" then self.pluck_pos = v
    elseif id == "decay"     then self.decay     = v
    end
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id ~= "trig" then return end
    if msg.type == "note" then
      local note = (msg.note or 60) + self.tune
      local hz   = piper.note_to_hz(note)

      local sizeL = math.max(2, math.floor(self.sr / hz))
      local sizeR = math.max(2, sizeL + 1)
      sizeL = math.min(sizeL, self.max_size)
      sizeR = math.min(sizeR, self.max_size)

      self.ks_sizeL = sizeL
      self.ks_sizeR = sizeR

      local pp  = self.pluck_pos
      local ppL0 = math.floor(sizeL * pp * 0.5)
      local ppL1 = math.floor(sizeL * (1 - pp * 0.5))
      local ppR0 = math.floor(sizeR * pp * 0.5)
      local ppR1 = math.floor(sizeR * (1 - pp * 0.5))

      for i = 1, sizeL do
        if i > ppL0 and i <= ppL1 then
          self.bufL[i] = 0
        else
          self.bufL[i] = math.random() * 2 - 1
        end
      end
      for i = 1, sizeR do
        if i > ppR0 and i <= ppR1 then
          self.bufR[i] = 0
        else
          self.bufR[i] = math.random() * 2 - 1
        end
      end

      self.ks_posL = 1
      self.ks_posR = 1
      self.lastL   = 0
      self.lastR   = 0
      self.active  = true
    end
    -- note_off: no effect
  end

  function inst:render(out_bufs, n)
    local buf    = out_bufs["out"]
    local panL, panR = piper.pan_gains(self.pan)
    local amp    = self.amp
    local sf     = (1 + self.stretch) * 0.5 * self.decay

    if not self.active then
      piper.buf_fill(buf, 0, n)
      return
    end

    local bufL  = self.bufL
    local bufR  = self.bufR
    local posL  = self.ks_posL
    local posR  = self.ks_posR
    local sizeL = self.ks_sizeL
    local sizeR = self.ks_sizeR
    local lastL = self.lastL
    local lastR = self.lastR

    for i = 0, n - 1 do
      local filtL = (bufL[posL] + lastL) * 0.5 * sf
      local filtR = (bufR[posR] + lastR) * 0.5 * sf

      bufL[posL] = filtL
      bufR[posR] = filtR

      lastL = filtL
      lastR = filtR

      posL = (posL % sizeL) + 1
      posR = (posR % sizeR) + 1

      buf[i * 2 + 1] = filtL * panL * amp
      buf[i * 2 + 2] = filtR * panR * amp
    end

    self.ks_posL = posL
    self.ks_posR = posR
    self.lastL   = lastL
    self.lastR   = lastR
  end

  function inst:reset()
    self.active  = false
    self.ks_posL = 1
    self.ks_posR = 1
    self.lastL   = 0
    self.lastR   = 0
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
