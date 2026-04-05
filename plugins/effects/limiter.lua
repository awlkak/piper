-- Limiter
-- Lookahead brickwall limiter.

return {
    type    = "effect",
    name    = "Limiter",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="ceiling",   label="Ceiling (dB)",    min=-6,  max=0,    default=-0.3, type="float" },
        { id="release",   label="Release (ms)",    min=1,   max=1000, default=100,  type="float" },
        { id="lookahead", label="Lookahead (ms)",  min=0,   max=20,   default=5,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr          = piper.SAMPLE_RATE
        local ceiling_db  = self.params[1].default
        local release_ms  = self.params[2].default
        local lookahead_ms= self.params[3].default

        local function db2lin(db) return 10^(db/20) end

        -- Lookahead buffer: stereo interleaved, max 20ms
        local MAX_LA = math.floor(sr * 0.02) * 2 + 4
        local la_buf = {}
        local la_write = 1
        local la_read  = 1
        local la_size  = 2  -- will be computed per lookahead setting

        local gain = 1.0

        local function alloc(sample_rate)
            sr = sample_rate
            MAX_LA = math.floor(sr * 0.02) * 2 + 4
            la_buf = {}
            for i = 1, MAX_LA do la_buf[i] = 0.0 end
            la_write = 1
            gain = 1.0
        end

        alloc(sr)

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "ceiling"    then ceiling_db   = value
            elseif id == "release"    then release_ms   = value
            elseif id == "lookahead"  then lookahead_ms = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local ceiling_lin = db2lin(ceiling_db)
            local rel_c = 1 - math.exp(-1 / (release_ms / 1000 * sr))
            -- Lookahead in stereo pairs
            local la_samp = piper.clamp(math.floor(lookahead_ms / 1000 * sr), 0, MAX_LA/2 - 1)
            local la_pairs = MAX_LA / 2

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                -- Write current sample to lookahead buf
                local wi = ((la_write - 1) % la_pairs) * 2
                la_buf[wi + 1] = inL
                la_buf[wi + 2] = inR

                -- Read delayed sample
                local ri = ((la_write - la_samp - 1) % la_pairs)
                if ri < 0 then ri = ri + la_pairs end
                local del_L = la_buf[ri * 2 + 1] or 0.0
                local del_R = la_buf[ri * 2 + 2] or 0.0

                la_write = (la_write % la_pairs) + 1

                local peak = math.max(math.abs(inL), math.abs(inR))
                local tgt = 1.0
                if peak > ceiling_lin then
                    tgt = ceiling_lin / math.max(peak, 0.0001)
                end

                if tgt < gain then
                    gain = tgt
                else
                    gain = gain + rel_c * (1.0 - gain)
                end

                dst[i*2+1] = del_L * gain
                dst[i*2+2] = del_R * gain
            end
        end

        function inst:reset()
            for i = 1, MAX_LA do la_buf[i] = 0.0 end
            la_write = 1; gain = 1.0
        end

        function inst:destroy()
            la_buf = {}
        end

        return inst
    end,
}
