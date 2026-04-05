-- Waveshaper Oscillator
-- Sine oscillator fed through a waveshaping transfer function.
-- Shape 4: custom transfer function loaded from a WAV file (maps -1..1 input to sample values).

return {
    type    = "generator",
    name    = "Waveshaper Oscillator",
    version = 1,

    inlets  = {
        { id = "trig",  kind = "control" },
        { id = "drive", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="file",    label="Shape File",  min=0,  max=0,     default="",   type="file"  },
        { id="freq",    label="Frequency",  min=20,  max=20000, default=440,  type="float" },
        { id="amp",     label="Amplitude",  min=0,   max=1,     default=0.5,  type="float" },
        { id="pan",     label="Pan",        min=-1,  max=1,     default=0,    type="float" },
        { id="tune",    label="Tune (semi)",min=-24, max=24,    default=0,    type="float" },
        { id="drive",   label="Drive",      min=1,   max=20,    default=3,    type="float" },
        { id="shape",   label="Shape",      min=0,   max=4,     default=0,    type="int"   },
        { id="attack",  label="Attack",     min=0,   max=2,     default=0.01, type="float" },
        { id="decay",   label="Decay",      min=0,   max=2,     default=0.15, type="float" },
        { id="sustain", label="Sustain",    min=0,   max=1,     default=0.7,  type="float" },
        { id="release", label="Release",    min=0,   max=4,     default=0.3,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        -- Custom transfer function table (512 samples, loaded from WAV)
        -- Input -1..1 maps to table index 0..511
        local TSIZE = 512
        local custom_table = nil

        local function load_shape_file(path)
            if not path or path == "" then return end
            local ok, sd = pcall(piper.load_sound, path)
            if not ok then
                print("[WaveshaperOsc] could not load: " .. tostring(path))
                return
            end
            local ch     = sd:getChannelCount()
            local frames = math.floor(sd:getSampleCount() / ch)
            local tbl    = {}
            for i = 0, TSIZE - 1 do
                local fi = math.floor(i / TSIZE * frames)
                fi = math.min(fi, frames - 1)
                local s
                if ch == 2 then
                    s = (sd:getSample(fi * 2) + sd:getSample(fi * 2 + 1)) * 0.5
                else
                    s = sd:getSample(fi)
                end
                tbl[i] = s
            end
            custom_table = tbl
        end

        local freq    = self.params[2].default
        local amp     = self.params[3].default
        local pan     = self.params[4].default
        local tune    = self.params[5].default
        local drive   = self.params[6].default
        local shape   = self.params[7].default
        local attack  = self.params[8].default
        local decay   = self.params[9].default
        local sustain = self.params[10].default
        local release = self.params[11].default

        local base_note_hz = freq
        local phase = 0.0
        local vel   = 1.0

        -- DC block state
        local dc_out  = 0.0
        local dc_prev = 0.0

        local ENV_OFF, ENV_ATTACK, ENV_DECAY, ENV_SUSTAIN, ENV_RELEASE = 0,1,2,3,4
        local env_state = ENV_OFF
        local env_val   = 0.0

        local function get_freq_hz()
            return base_note_hz * 2^(tune/12)
        end

        function inst:init(sample_rate)
            sr      = sample_rate
            phase   = 0.0
            dc_out  = 0.0
            dc_prev = 0.0
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:set_param(id, value)
            if     id == "file"    then load_shape_file(value)
            elseif id == "freq"    then base_note_hz = value
            elseif id == "amp"     then amp     = value
            elseif id == "pan"     then pan     = value
            elseif id == "tune"    then tune    = value
            elseif id == "drive"   then drive   = value
            elseif id == "shape"   then shape   = math.floor(value)
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
                    vel     = msg.vel or 1.0
                    phase   = 0.0
                    dc_out  = 0.0
                    dc_prev = 0.0
                    env_state = ENV_ATTACK
                    env_val   = 0.0
                elseif msg.type == "note_off" then
                    if env_state ~= ENV_OFF then env_state = ENV_RELEASE end
                end
            elseif inlet_id == "drive" and msg.type == "float" then
                drive = piper.clamp(msg.v, 1.0, 20.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            local hz = get_freq_hz()
            local inc = TAU * hz / sr
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

                local s_raw = math.sin(phase)
                phase = phase + inc
                if phase > TAU * 1000 then phase = phase % TAU end

                -- Waveshaping
                local s_shaped
                if shape == 0 then
                    s_shaped = piper.softclip(s_raw * drive)
                elseif shape == 1 then
                    s_shaped = piper.hardclip(s_raw * drive)
                elseif shape == 2 then
                    local x = s_raw * drive
                    for _ = 1, 8 do
                        if     x >  1.0 then x = 2.0 - x
                        elseif x < -1.0 then x = -2.0 - x
                        else break end
                    end
                    s_shaped = x
                elseif shape == 3 then
                    s_shaped = math.sin(s_raw * drive * math.pi * 0.5)
                else
                    -- shape == 4: WAV-loaded transfer function table
                    if custom_table then
                        -- Map s_raw*drive (-1..1 clamped) to table index 0..TSIZE-1
                        local x = piper.clamp(s_raw * drive, -1.0, 1.0)
                        local pos = (x + 1.0) * 0.5 * (TSIZE - 1)
                        local i0  = math.floor(pos)
                        local i1  = math.min(i0 + 1, TSIZE - 1)
                        local f   = pos - i0
                        s_shaped  = custom_table[i0] + (custom_table[i1] - custom_table[i0]) * f
                    else
                        s_shaped = piper.softclip(s_raw * drive)
                    end
                end

                -- DC block (one-pole highpass)
                dc_out  = 0.995 * dc_out + s_shaped - dc_prev
                dc_prev = s_shaped
                local s_final = dc_out

                local s = s_final * amp * vel * env_val
                buf[i*2+1] = s * pan_l
                buf[i*2+2] = s * pan_r
            end
        end

        function inst:reset()
            phase     = 0.0
            dc_out    = 0.0
            dc_prev   = 0.0
            env_state = ENV_OFF
            env_val   = 0.0
        end

        function inst:destroy() end

        return inst
    end,
}
