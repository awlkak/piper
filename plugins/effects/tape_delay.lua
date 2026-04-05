-- Tape Delay
-- Delay with wow/flutter LFO modulation and tape saturation.

return {
    type    = "effect",
    name    = "Tape Delay",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="time",          label="Time (ms)",      min=1,   max=2000, default=375, type="float" },
        { id="feedback",      label="Feedback",       min=0,   max=0.95, default=0.45, type="float" },
        { id="wow_rate",      label="Wow Rate (Hz)",  min=0.1, max=3,    default=0.3,  type="float" },
        { id="wow_depth",     label="Wow Depth (ms)", min=0,   max=20,   default=5,    type="float" },
        { id="flutter_rate",  label="Flutter Rate",   min=3,   max=15,   default=8,    type="float" },
        { id="flutter_depth", label="Flutter Depth",  min=0,   max=3,    default=0.5,  type="float" },
        { id="saturation",    label="Saturation",     min=1,   max=5,    default=1.5,  type="float" },
        { id="damp",          label="Damp",           min=0,   max=1,    default=0.4,  type="float" },
        { id="wet",           label="Wet",            min=0,   max=1,    default=0.4,  type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr           = piper.SAMPLE_RATE
        local time_ms      = self.params[1].default
        local feedback     = self.params[2].default
        local wow_rate     = self.params[3].default
        local wow_depth    = self.params[4].default
        local flutter_rate = self.params[5].default
        local flutter_depth= self.params[6].default
        local saturation   = self.params[7].default
        local damp         = self.params[8].default
        local wet          = self.params[9].default

        local MAX_DELAY = math.ceil(sr * 2.0) + 4
        local buf_l = {}
        local buf_r = {}
        local write_pos = 1
        local wow_phase = 0.0
        local flutter_phase = 0.0
        local lp_l = 0.0
        local lp_r = 0.0

        local function alloc(sample_rate)
            sr = sample_rate
            MAX_DELAY = math.ceil(sr * 2.0) + 4
            buf_l = {}
            buf_r = {}
            for i = 1, MAX_DELAY do buf_l[i] = 0.0; buf_r[i] = 0.0 end
            write_pos = 1
            wow_phase = 0.0
            flutter_phase = 0.0
            lp_l = 0.0
            lp_r = 0.0
        end

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "time"          then time_ms       = value
            elseif id == "feedback"      then feedback      = value
            elseif id == "wow_rate"      then wow_rate      = value
            elseif id == "wow_depth"     then wow_depth     = value
            elseif id == "flutter_rate"  then flutter_rate  = value
            elseif id == "flutter_depth" then flutter_depth = value
            elseif id == "saturation"    then saturation    = value
            elseif id == "damp"          then damp          = value
            elseif id == "wet"           then wet           = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local base_delay = piper.clamp(time_ms / 1000.0 * sr, 1, MAX_DELAY - 3)
            local damp_c = piper.clamp(damp, 0, 1)
            local tw = 2 * math.pi
            local inv_sr = 1.0 / sr

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                -- LFO modulation
                local lfo_offset = (wow_depth * math.sin(wow_phase) + flutter_depth * math.sin(flutter_phase)) / 1000.0 * sr
                local ds = piper.clamp(base_delay + lfo_offset, 1, MAX_DELAY - 3)
                local di = math.floor(ds)
                local df = ds - di

                local p0 = ((write_pos - di - 1) % MAX_DELAY) + 1
                local p1 = ((write_pos - di - 2) % MAX_DELAY) + 1

                local read_l = buf_l[p0] * (1 - df) + buf_l[p1] * df
                local read_r = buf_r[p0] * (1 - df) + buf_r[p1] * df

                -- Damp
                lp_l = lp_l + (1 - damp_c) * (read_l - lp_l)
                lp_r = lp_r + (1 - damp_c) * (read_r - lp_r)

                local fb_l = piper.softclip(lp_l * feedback * saturation)
                local fb_r = piper.softclip(lp_r * feedback * saturation)

                buf_l[write_pos] = inL + fb_l
                buf_r[write_pos] = inR + fb_r

                write_pos = (write_pos % MAX_DELAY) + 1

                wow_phase     = wow_phase     + tw * wow_rate     * inv_sr
                flutter_phase = flutter_phase + tw * flutter_rate * inv_sr
                if wow_phase     > tw then wow_phase     = wow_phase     - tw end
                if flutter_phase > tw then flutter_phase = flutter_phase - tw end

                dst[i*2+1] = inL * (1 - wet) + lp_l * wet
                dst[i*2+2] = inR * (1 - wet) + lp_r * wet
            end
        end

        function inst:reset()
            for i = 1, MAX_DELAY do buf_l[i] = 0.0; buf_r[i] = 0.0 end
            write_pos = 1; wow_phase = 0.0; flutter_phase = 0.0
            lp_l = 0.0; lp_r = 0.0
        end

        function inst:destroy()
            buf_l = {}; buf_r = {}
        end

        return inst
    end,
}
