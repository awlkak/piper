local TAU = math.pi * 2
local MAX_GRAINS = 16

local plugin = {
  type    = "generator",
  name    = "Granular Texture",
  version = 1,
  inlets  = {
    { id = "trig",    kind = "control" },
    { id = "density", kind = "control" },
  },
  outlets = {
    { id = "out", kind = "signal" },
  },
  params  = {
    { id = "amp",           label = "Amp",           min = 0,   max = 1,   default = 0.4, type = "float" },
    { id = "root_note",     label = "Root Note",     min = 0,   max = 127, default = 60,  type = "int", step = 1 },
    { id = "density",       label = "Density",       min = 1,   max = 50,  default = 10,  type = "float" },
    { id = "duration",      label = "Duration ms",   min = 10,  max = 500, default = 80,  type = "float" },
    { id = "pitch_scatter", label = "Pitch Scatter", min = 0,   max = 24,  default = 4,   type = "float" },
    { id = "amp_scatter",   label = "Amp Scatter",   min = 0,   max = 1,   default = 0.3, type = "float" },
    { id = "pan_scatter",   label = "Pan Scatter",   min = 0,   max = 1,   default = 0.5, type = "float" },
    { id = "grain_type",    label = "Grain Type",    min = 0,   max = 1,   default = 0,   type = "int", step = 1 },
  },
}

function plugin:new(args)
  local inst = {}

  inst.amp           = 0.4
  inst.root_note     = 60
  inst.density       = 10
  inst.duration      = 80
  inst.pitch_scatter = 4
  inst.amp_scatter   = 0.3
  inst.pan_scatter   = 0.5
  inst.grain_type    = 0  -- 0=sine, 1=noise
  inst.sr            = 44100
  inst.active        = false

  -- grain pool
  inst.grains = {}
  for i = 1, MAX_GRAINS do
    inst.grains[i] = {
      active           = false,
      phase            = 0,
      freq             = 440,
      amp              = 0,
      pan_l            = 0.7,
      pan_r            = 0.7,
      duration_samples = 0,
      current_sample   = 0,
      spawn_time       = 0,
      grain_type       = 0,
    }
  end

  inst.scheduler_counter = 0

  function inst:init(sr)
    self.sr = sr
  end

  function inst:set_param(id, v)
    if     id == "amp"           then self.amp           = v
    elseif id == "root_note"     then self.root_note     = math.floor(v + 0.5)
    elseif id == "density"       then self.density       = v
    elseif id == "duration"      then self.duration      = v
    elseif id == "pitch_scatter" then self.pitch_scatter = v
    elseif id == "amp_scatter"   then self.amp_scatter   = v
    elseif id == "pan_scatter"   then self.pan_scatter   = v
    elseif id == "grain_type"    then self.grain_type    = math.floor(v + 0.5)
    end
  end

  function inst:on_message(inlet_id, msg)
    if inlet_id == "trig" then
      if msg.type == "note" then
        self.active = true
      elseif msg.type == "note_off" then
        self.active = false
      elseif msg.type == "bang" then
        self.active = true
      end
    elseif inlet_id == "density" then
      if msg.type == "float" then
        self.density = piper.clamp(msg.v, 1, 50)
      end
    end
  end

  local function find_grain_slot(grains)
    -- find inactive slot first
    for i = 1, MAX_GRAINS do
      if not grains[i].active then return i end
    end
    -- find oldest (highest current_sample)
    local oldest_i  = 1
    local oldest_s  = -1
    for i = 1, MAX_GRAINS do
      if grains[i].current_sample > oldest_s then
        oldest_s = grains[i].current_sample
        oldest_i = i
      end
    end
    return oldest_i
  end

  local function spawn_grain(inst)
    local idx  = find_grain_slot(inst.grains)
    local g    = inst.grains[idx]
    local ps   = math.floor(inst.pitch_scatter)
    local note = inst.root_note + math.random(-ps, ps)
    note = piper.clamp(note, 0, 127)

    local raw_pan = (math.random() * 2 - 1) * inst.pan_scatter
    local gL, gR  = piper.pan_gains(raw_pan)

    g.active           = true
    g.phase            = 0
    g.freq             = piper.note_to_hz(note)
    g.amp              = inst.amp * (1 - inst.amp_scatter * math.random())
    g.pan_l            = gL
    g.pan_r            = gR
    g.duration_samples = math.max(1, math.floor(inst.duration / 1000 * inst.sr))
    g.current_sample   = 0
    g.grain_type       = inst.grain_type
  end

  function inst:render(out_bufs, n)
    local buf = out_bufs["out"]
    piper.buf_fill(buf, 0, n)

    local grains  = self.grains
    local sr      = self.sr
    local density = self.density
    local grain_interval = sr / density

    for i = 0, n - 1 do
      -- scheduler
      if self.active then
        self.scheduler_counter = self.scheduler_counter + 1
        if self.scheduler_counter >= grain_interval then
          self.scheduler_counter = self.scheduler_counter - grain_interval
          spawn_grain(self)
        end
      end

      local outL = 0
      local outR = 0

      for gi = 1, MAX_GRAINS do
        local g = grains[gi]
        if g.active then
          local cs  = g.current_sample
          local dur = g.duration_samples

          -- Hann window
          local w = 0.5 * (1 - math.cos(math.pi * cs / dur))
          local s

          if g.grain_type == 1 then
            -- noise grain
            s = w * g.amp * (math.random() * 2 - 1)
          else
            -- sine grain
            s = w * g.amp * math.sin(g.phase)
            g.phase = g.phase + TAU * g.freq / sr
            if g.phase > TAU * 1000 then g.phase = g.phase % TAU end
          end

          outL = outL + s * g.pan_l
          outR = outR + s * g.pan_r

          g.current_sample = cs + 1
          if g.current_sample >= dur then
            g.active = false
          end
        end
      end

      buf[i * 2 + 1] = outL
      buf[i * 2 + 2] = outR
    end
  end

  function inst:reset()
    self.active             = false
    self.scheduler_counter  = 0
    for i = 1, MAX_GRAINS do
      self.grains[i].active = false
    end
  end

  function inst:destroy() end

  return inst
end

return plugin
