-- Sampler
-- Loads a WAV file and plays it back at a pitch-shifted rate.
-- File path is set via the "file" parameter.
-- Pitch shifting is achieved by linear interpolation over the sample data.

return {
    type    = "generator",
    name    = "Sampler",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
        { id = "amp",  kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="file",    label="File",        min=0, max=0,   default="",   type="file"  },
        { id="amp",     label="Amplitude",   min=0, max=2,   default=1.0,  type="float" },
        { id="pan",     label="Pan",         min=-1,max=1,   default=0,    type="float" },
        { id="root",    label="Root Note",   min=0, max=127, default=60,   type="int"   },
        { id="loop",    label="Loop",        min=0, max=1,   default=0,    type="bool"  },
    },

    new = function(self, args)
        local inst   = {}
        local sr     = piper.SAMPLE_RATE
        local amp    = 1.0
        local pan    = 0.0
        local root   = 60
        local do_loop = false
        local active  = false

        -- Sample data (loaded from file)
        local sample_data  = nil
        local sample_count = 0  -- number of stereo frames
        local sample_sr    = 44100
        local playhead     = 0.0
        local pitch_ratio  = 1.0

        local function load_file(path)
            if not path or path == "" then return end
            local ok, sd = pcall(love.sound.newSoundData, path)
            if not ok then
                print("[Sampler] could not load: " .. tostring(path))
                return
            end
            sample_data  = sd
            sample_sr    = sd:getSampleRate()
            local ch     = sd:getChannelCount()
            sample_count = math.floor(sd:getSampleCount() / ch)
        end

        local function update_pitch(note)
            if sample_count == 0 then return end
            pitch_ratio = piper.note_to_hz(note) / piper.note_to_hz(root)
                        * (sample_sr / sr)
        end

        function inst:init(sample_rate)
            sr = sample_rate
        end

        function inst:set_param(id, value)
            if id == "file" then
                load_file(value)
            elseif id == "amp"  then amp  = value
            elseif id == "pan"  then pan  = value
            elseif id == "root" then root = value
            elseif id == "loop" then do_loop = (value ~= 0 and value ~= false)
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" then
                    update_pitch(msg.note)
                    amp      = (msg.vel or 1.0) * amp
                    playhead = 0.0
                    active   = true
                elseif msg.type == "note_off" then
                    if not do_loop then active = false end
                end
            elseif inlet_id == "amp" and msg.type == "float" then
                amp = msg.v
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end
            if not active or not sample_data or sample_count == 0 then
                piper.buf_fill(buf, 0.0, n)
                return
            end
            local pan_l, pan_r = piper.pan_gains(pan)
            local ch = sample_data:getChannelCount()

            for i = 0, n - 1 do
                local fi  = math.floor(playhead)
                local frac = playhead - fi

                if fi >= sample_count then
                    if do_loop then
                        playhead = 0.0
                        fi = 0
                    else
                        active = false
                        buf[i * 2 + 1] = 0.0
                        buf[i * 2 + 2] = 0.0
                        -- zero rest
                        for j = i + 1, n - 1 do
                            buf[j * 2 + 1] = 0.0
                            buf[j * 2 + 2] = 0.0
                        end
                        break
                    end
                end

                local fi2 = fi + 1
                if fi2 >= sample_count then fi2 = do_loop and 0 or fi end

                local sL, sR
                if ch == 2 then
                    local aL = sample_data:getSample(fi  * 2)
                    local aR = sample_data:getSample(fi  * 2 + 1)
                    local bL = sample_data:getSample(fi2 * 2)
                    local bR = sample_data:getSample(fi2 * 2 + 1)
                    sL = aL + (bL - aL) * frac
                    sR = aR + (bR - aR) * frac
                else
                    local a = sample_data:getSample(fi)
                    local b = sample_data:getSample(fi2)
                    sL = a + (b - a) * frac
                    sR = sL
                end

                sL = sL * amp
                sR = sR * amp
                buf[i * 2 + 1] = sL * pan_l
                buf[i * 2 + 2] = sR * pan_r

                playhead = playhead + pitch_ratio
            end
        end

        function inst:reset()
            active   = false
            playhead = 0.0
        end

        function inst:destroy()
            sample_data = nil
        end

        return inst
    end,
}
