-- Wavetable Oscillator
-- 8 pre-computed wavetables (256 samples each), morphed between two selected tables.
-- Wave slot 8 can be loaded from a WAV file (first cycle extracted as a custom table).

return {
    type    = "generator",
    name    = "Wavetable Oscillator",
    version = 1,

    inlets  = {
        { id = "trig",  kind = "control" },
        { id = "morph", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="file",    label="Wave File",  min=0,    max=0,     default="",   type="file"  },
        { id="freq",    label="Frequency",  min=20,   max=20000, default=440,  type="float" },
        { id="amp",     label="Amplitude",  min=0,    max=1,     default=0.5,  type="float" },
        { id="pan",     label="Pan",        min=-1,   max=1,     default=0,    type="float" },
        { id="tune",    label="Tune (semi)",min=-24,  max=24,    default=0,    type="float" },
        { id="wave_a",  label="Wave A",     min=0,    max=8,     default=0,    type="int"   },
        { id="wave_b",  label="Wave B",     min=0,    max=8,     default=1,    type="int"   },
        { id="morph",   label="Morph",      min=0,    max=1,     default=0,    type="float" },
        { id="attack",  label="Attack",     min=0,    max=2,     default=0.01, type="float" },
        { id="decay",   label="Decay",      min=0,    max=2,     default=0.15, type="float" },
        { id="sustain", label="Sustain",    min=0,    max=1,     default=0.7,  type="float" },
        { id="release", label="Release",    min=0,    max=4,     default=0.3,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local WS = 256
        local tables = {}

        local function build_tables()
            -- 0: sine
            tables[0] = {}
            for i = 0, WS-1 do tables[0][i] = math.sin(2*math.pi*i/WS) end
            -- 1: triangle
            tables[1] = {}
            for i = 0, WS-1 do
                local t = i/WS
                tables[1][i] = t < 0.5 and (t*4-1) or (3-t*4)
            end
            -- 2: sawtooth
            tables[2] = {}
            for i = 0, WS-1 do tables[2][i] = i/WS*2-1 end
            -- 3: square
            tables[3] = {}
            for i = 0, WS-1 do tables[3][i] = i < WS/2 and 1.0 or -1.0 end
            -- 4: soft square (sine squared with sign)
            tables[4] = {}
            for i = 0, WS-1 do
                local s = math.sin(2*math.pi*i/WS)
                tables[4][i] = s * math.abs(s)
            end
            -- 5: pulse 25%
            tables[5] = {}
            for i = 0, WS-1 do tables[5][i] = i < WS*0.25 and 1.0 or -1.0 end
            -- 6: sine + 3rd harmonic
            tables[6] = {}
            for i = 0, WS-1 do
                tables[6][i] = math.sin(2*math.pi*i/WS)*0.7 + math.sin(6*math.pi*i/WS)*0.3
            end
            -- 7: half-rectified sine
            tables[7] = {}
            for i = 0, WS-1 do
                local s = math.sin(2*math.pi*i/WS)
                tables[7][i] = math.max(0, s)*2 - 0.5
            end
        end

        local function read_table(tbl, phase_norm)
            local pos  = phase_norm * WS
            local i0   = math.floor(pos) % WS
            local i1   = (i0 + 1) % WS
            local frac = pos - math.floor(pos)
            return tbl[i0] + (tbl[i1] - tbl[i0]) * frac
        end

        -- Load a WAV file into table slot 8 (first WS samples extracted)
        local function load_wave_file(path)
            if not path or path == "" then return end
            local ok, sd = pcall(piper.load_sound, path)
            if not ok then
                print("[WavetableOsc] could not load: " .. tostring(path))
                return
            end
            local ch     = sd:getChannelCount()
            local frames = math.floor(sd:getSampleCount() / ch)
            local tbl    = {}
            for i = 0, WS - 1 do
                -- Map 0..WS-1 across the full sample length
                local fi = math.floor(i / WS * frames)
                fi = math.min(fi, frames - 1)
                local s
                if ch == 2 then
                    s = (sd:getSample(fi * 2) + sd:getSample(fi * 2 + 1)) * 0.5
                else
                    s = sd:getSample(fi)
                end
                tbl[i] = s
            end
            tables[8] = tbl
        end

        -- Params
        local freq    = self.params[2].default
        local amp     = self.params[3].default
        local pan     = self.params[4].default
        local tune    = self.params[5].default
        local wave_a  = self.params[6].default
        local wave_b  = self.params[7].default
        local morph   = self.params[8].default
        local attack  = self.params[9].default
        local decay   = self.params[10].default
        local sustain = self.params[11].default
        local release = self.params[12].default

        local base_note_hz = freq
        local phase = 0.0
        local vel   = 1.0

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local function recalc_freq(hz)
            freq = hz * 2^(tune/12)
        end

        build_tables()

        function inst:init(sample_rate)
            sr = sample_rate
            phase = 0.0
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "file"    then load_wave_file(value)
            elseif id == "freq"    then base_note_hz = value; recalc_freq(value)
            elseif id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value; recalc_freq(base_note_hz)
            elseif id == "wave_a"  then wave_a  = math.floor(value)
            elseif id == "wave_b"  then wave_b  = math.floor(value)
            elseif id == "morph"   then morph   = value
            elseif id == "attack"  then attack  = value
            elseif id == "decay"   then decay   = value
            elseif id == "sustain" then sustain = value
            elseif id == "release" then release = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    base_note_hz = piper.note_to_hz(msg.note)
                    recalc_freq(base_note_hz)
                    vel       = msg.vel or 1.0
                    phase     = 0.0
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then
                        env_state = ENV_RELEASE
                    end
                end
            elseif inlet_id == "morph" and msg.type == "float" then
                morph = piper.clamp(msg.v, 0.0, 1.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local ta = tables[wave_a] or tables[0]
            local tb = tables[wave_b] or tables[1]
            local inc = freq / sr
            local pan_l, pan_r = piper.pan_gains(pan)

            for i = 0, n-1 do
                -- Envelope
                if env_state == ENV_ATTACK then
                    env_val = env_val + 1.0 / (math.max(0.001, attack) * sr)
                    if env_val >= 1.0 then env_val = 1.0; env_state = ENV_DECAY end
                elseif env_state == ENV_DECAY then
                    env_val = env_val - (1.0 - sustain) / (math.max(0.001, decay) * sr)
                    if env_val <= sustain then env_val = sustain; env_state = ENV_SUSTAIN end
                elseif env_state == ENV_RELEASE then
                    env_val = env_val - env_val / (math.max(0.001, release) * sr)
                    if env_val < 0.0001 then env_val = 0.0; env_state = ENV_OFF end
                end

                local pn = phase - math.floor(phase)  -- normalize 0..1
                local va = read_table(ta, pn)
                local vb = read_table(tb, pn)
                local s  = (va * (1.0 - morph) + vb * morph) * amp * vel * env_val

                phase = phase + inc
                if phase > 1000.0 then phase = phase - math.floor(phase) end

                buf[i*2+1] = s * pan_l
                buf[i*2+2] = s * pan_r
            end
        end

        function inst:reset()
            phase     = 0.0
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
