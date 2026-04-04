-- Drum Machine
-- 4-voice synthesized drums: kick, snare, hihat (closed/open).
-- Each voice triggered by note number:
--   36 = Kick, 38 = Snare, 42 = HiHat Closed, 46 = HiHat Open
-- Any other note triggers by closest match.
-- All synthesis is procedural (no samples needed).

return {
    type    = "generator",
    name    = "Drum Machine",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="kick_amp",  label="Kick Vol",   min=0, max=1, default=0.9,  type="float" },
        { id="snare_amp", label="Snare Vol",  min=0, max=1, default=0.7,  type="float" },
        { id="hat_amp",   label="HiHat Vol",  min=0, max=1, default=0.5,  type="float" },
        { id="kick_tune", label="Kick Tune",  min=20,max=80,default=50,   type="float" },
        { id="kick_dec",  label="Kick Decay", min=0.05,max=1,default=0.35,type="float" },
        { id="snare_dec", label="Snare Decay",min=0.05,max=0.5,default=0.15,type="float" },
        { id="hat_dec",   label="Hat Decay",  min=0.01,max=0.3,default=0.05,type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE
        local TAU  = 2.0 * math.pi

        local kick_amp  = 0.9
        local snare_amp = 0.7
        local hat_amp   = 0.5
        local kick_tune = 50.0
        local kick_dec  = 0.35
        local snare_dec = 0.15
        local hat_dec   = 0.05

        -- Voice state: phase, env, active, type, vel
        local KICK, SNARE, HAT_C, HAT_O = 1, 2, 3, 4
        local N_VOICES = 4
        local voices = {}
        for i = 1, N_VOICES do
            voices[i] = { phase=0, env=0, active=false, kind=i, vel=1, hat_open=false }
        end

        local function trigger(kind, vel_in, hat_open)
            local v = voices[kind]
            v.phase    = 0.0
            v.env      = 1.0
            v.active   = true
            v.vel      = vel_in or 1.0
            v.hat_open = hat_open or false
        end

        local function note_to_kind(note)
            -- GM drum map approximation
            if note <= 37 then return KICK
            elseif note <= 40 then return SNARE
            elseif note == 46 or note == 48 then return HAT_O, true
            else return HAT_C, false
            end
        end

        function inst:init(sample_rate) sr = sample_rate end

        function inst:set_param(id, value)
            if     id == "kick_amp"  then kick_amp  = value
            elseif id == "snare_amp" then snare_amp = value
            elseif id == "hat_amp"   then hat_amp   = value
            elseif id == "kick_tune" then kick_tune = value
            elseif id == "kick_dec"  then kick_dec  = value
            elseif id == "snare_dec" then snare_dec = value
            elseif id == "hat_dec"   then hat_dec   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" and msg.type == "note" then
                local kind, open = note_to_kind(msg.note)
                trigger(kind, msg.vel or 1.0, open)
            end
        end

        -- Simple one-pole lowpass state
        local lp_state = {0.0, 0.0, 0.0, 0.0}

        local function noise() return math.random() * 2.0 - 1.0 end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            for i = 0, n - 1 do
                local sL, sR = 0.0, 0.0

                -- Kick: pitched sine with frequency sweep + click
                local vk = voices[KICK]
                if vk.active then
                    local t_dec = 1.0 / (kick_dec * sr)
                    local freq  = kick_tune * vk.env + 30.0 * (1.0 - vk.env)
                    local s     = math.sin(vk.phase) * vk.env * kick_amp * vk.vel
                    sL = sL + s
                    sR = sR + s
                    vk.phase = vk.phase + TAU * freq / sr
                    vk.env   = vk.env   - t_dec
                    if vk.env <= 0 then vk.active = false; vk.env = 0 end
                end

                -- Snare: bandpassed noise + tonal body
                local vs = voices[SNARE]
                if vs.active then
                    local t_dec = 1.0 / (snare_dec * sr)
                    local tone  = math.sin(vs.phase) * vs.env * 0.4
                    local n_in  = noise()
                    -- Simple bandpass: 2-pole approx via two lowpass
                    lp_state[1] = lp_state[1] + 0.35 * (n_in      - lp_state[1])
                    lp_state[2] = lp_state[2] + 0.35 * (lp_state[1] - lp_state[2])
                    local bp    = lp_state[1] - lp_state[2]
                    local s     = (tone + bp * 0.8) * vs.env * snare_amp * vs.vel
                    sL = sL + s
                    sR = sR + s
                    vs.phase = vs.phase + TAU * 185.0 / sr
                    vs.env   = vs.env   - t_dec
                    if vs.env <= 0 then vs.active = false; vs.env = 0 end
                end

                -- HiHat: filtered noise
                local vh = voices[HAT_C]
                if not vh.active then vh = voices[HAT_O] end
                if vh.active then
                    local dec   = vh.hat_open and (hat_dec * 6.0) or hat_dec
                    local t_dec = 1.0 / (dec * sr)
                    local n_in  = noise()
                    -- Highpass approx: original - lowpass
                    lp_state[3] = lp_state[3] + 0.12 * (n_in - lp_state[3])
                    local hp    = n_in - lp_state[3]
                    local s     = hp * vh.env * hat_amp * vh.vel * 0.7
                    sL = sL + s * 0.9
                    sR = sR + s * 1.1
                    vh.env = vh.env - t_dec
                    if vh.env <= 0 then vh.active = false; vh.env = 0 end
                end

                buf[i * 2 + 1] = piper.clamp(sL, -1, 1)
                buf[i * 2 + 2] = piper.clamp(sR, -1, 1)
            end
        end

        function inst:reset()
            for i = 1, N_VOICES do
                voices[i].active = false
                voices[i].env    = 0.0
            end
        end

        function inst:destroy() end

        return inst
    end,
}
