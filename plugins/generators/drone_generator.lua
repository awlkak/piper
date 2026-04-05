-- Drone Generator
-- Always-on 4-oscillator sine drone with amplitude modulation and pitch drift.

return {
    type    = "generator",
    name    = "Drone Generator",
    version = 1,

    inlets  = {
        { id = "freq", kind = "control" },
        { id = "amp",  kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="root_hz",  label="Root Hz",   min=20,   max=2000, default=110,  type="float" },
        { id="amp",      label="Amplitude", min=0,    max=1,    default=0.4,  type="float" },
        { id="pan",      label="Pan",       min=-1,   max=1,    default=0,    type="float" },
        { id="ratio1",   label="Ratio 1",   min=0.1,  max=8,    default=1.0,  type="float" },
        { id="ratio2",   label="Ratio 2",   min=0.1,  max=8,    default=2.0,  type="float" },
        { id="ratio3",   label="Ratio 3",   min=0.1,  max=8,    default=1.5,  type="float" },
        { id="ratio4",   label="Ratio 4",   min=0.1,  max=8,    default=1.25, type="float" },
        { id="drift",    label="Drift",     min=0,    max=1,    default=0.2,  type="float" },
        { id="mod_rate", label="Mod Rate",  min=0.01, max=1,    default=0.1,  type="float" },
        { id="spread",   label="Spread",    min=0,    max=1,    default=0.6,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr  = piper.SAMPLE_RATE
        local TAU = 2.0 * math.pi

        local NUM_VOICES = 4

        local root_hz  = self.params[1].default
        local amp      = self.params[2].default
        local pan      = self.params[3].default
        local ratios   = { self.params[4].default, self.params[5].default,
                           self.params[6].default, self.params[7].default }
        local drift    = self.params[8].default
        local mod_rate = self.params[9].default
        local spread   = self.params[10].default

        local phases     = { 0.0, 0.0, 0.0, 0.0 }
        local mod_phases = { 0.0, 0.0, 0.0, 0.0 }
        local drift_phases = { 0.0, 0.3, 0.7, 1.1 }

        function inst:init(sample_rate)
            sr = sample_rate
            for i = 1, NUM_VOICES do
                phases[i]       = (i-1) * TAU / NUM_VOICES
                mod_phases[i]   = 0.0
                drift_phases[i] = (i-1) * 1.3
            end
        end

        function inst:set_param(id, value)
            if     id == "root_hz"  then root_hz  = value
            elseif id == "amp"      then amp      = value
            elseif id == "pan"      then pan      = value
            elseif id == "ratio1"   then ratios[1] = value
            elseif id == "ratio2"   then ratios[2] = value
            elseif id == "ratio3"   then ratios[3] = value
            elseif id == "ratio4"   then ratios[4] = value
            elseif id == "drift"    then drift    = value
            elseif id == "mod_rate" then mod_rate = value
            elseif id == "spread"   then spread   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "freq" and msg.type == "float" then
                root_hz = piper.clamp(msg.v, 20.0, 2000.0)
            elseif inlet_id == "amp" and msg.type == "float" then
                amp = piper.clamp(msg.v, 0.0, 1.0)
            end
        end

        function inst:render(out_bufs, n)
            local buf = out_bufs["out"]
            if not buf then return end

            -- Fixed pan positions for 4 voices scaled by spread + pan offset
            local VOICE_PANS = { -1.0, -1.0/3.0, 1.0/3.0, 1.0 }

            local drift_rate = 0.05  -- Hz for drift LFO

            for i = 0, n-1 do
                local out_l, out_r = 0.0, 0.0

                for v = 1, NUM_VOICES do
                    -- Drift LFO
                    local drift_cents = drift * 50.0 * math.sin(drift_phases[v] + (v-1) * 1.3)
                    local actual_hz   = root_hz * ratios[v] * 2^(drift_cents / 1200.0)

                    -- Amplitude modulation LFO
                    local amp_mod = 0.7 + 0.3 * math.sin(mod_phases[v])

                    local s = math.sin(phases[v]) * amp_mod

                    local vp = piper.clamp(VOICE_PANS[v] * spread + pan, -1.0, 1.0)
                    local vl, vr = piper.pan_gains(vp)
                    out_l = out_l + s * vl
                    out_r = out_r + s * vr

                    -- Advance phases
                    phases[v]       = phases[v]       + TAU * actual_hz / sr
                    mod_phases[v]   = mod_phases[v]   + TAU * (mod_rate + (v-1) * 0.017) / sr
                    drift_phases[v] = drift_phases[v] + TAU * drift_rate / sr

                    if phases[v]       > TAU * 1000 then phases[v]       = phases[v]       % TAU end
                    if mod_phases[v]   > TAU * 1000 then mod_phases[v]   = mod_phases[v]   % TAU end
                    if drift_phases[v] > TAU * 1000 then drift_phases[v] = drift_phases[v] % TAU end
                end

                local scale = amp / NUM_VOICES
                buf[i*2+1] = out_l * scale
                buf[i*2+2] = out_r * scale
            end
        end

        function inst:reset()
            for i = 1, NUM_VOICES do
                phases[i]       = (i-1) * TAU / NUM_VOICES
                mod_phases[i]   = 0.0
                drift_phases[i] = (i-1) * 1.3
            end
        end

        function inst:destroy() end

        return inst
    end,
}
