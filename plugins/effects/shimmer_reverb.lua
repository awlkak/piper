-- Shimmer Reverb
-- FDN reverb with pitch-shifted feedback.

return {
    type    = "effect",
    name    = "Shimmer Reverb",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="size",           label="Size",           min=0,   max=1,   default=0.7,  type="float" },
        { id="damp",           label="Damp",           min=0,   max=1,   default=0.4,  type="float" },
        { id="pitch_shift",    label="Pitch Shift",    min=0.5, max=4,   default=2.0,  type="float" },
        { id="shimmer_amount", label="Shimmer Amount", min=0,   max=1,   default=0.4,  type="float" },
        { id="mix",            label="Mix",            min=0,   max=1,   default=0.35, type="float" },
        { id="predelay",       label="Pre-Delay (ms)", min=0,   max=100, default=10,   type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr             = piper.SAMPLE_RATE
        local size           = self.params[1].default
        local damp           = self.params[2].default
        local pitch_shift    = self.params[3].default
        local shimmer_amount = self.params[4].default
        local mix            = self.params[5].default
        local predelay       = self.params[6].default

        local BASE_LENGTHS = {1283, 1601, 2011, 2521}
        local dl_bufs = {}
        local dl_lens = {}
        local dl_pos  = {}
        local dl_lp   = {0, 0, 0, 0}

        local MAX_PRE    = 0
        local pre_buf_l  = {}
        local pre_buf_r  = {}
        local pre_write  = 1

        local GSIZ = 4096
        local gbuf_l = {}
        local gbuf_r = {}
        local gwrite = 1
        local h1 = 1.0
        local h2 = GSIZ / 2 + 1.0
        local gphase = 0.0

        local feedback_l = 0.0
        local feedback_r = 0.0

        local function alloc(sample_rate)
            sr = sample_rate
            dl_bufs = {}; dl_lens = {}; dl_pos = {}; dl_lp = {0,0,0,0}
            for k = 1, 4 do
                local len = math.floor(BASE_LENGTHS[k] * sr / 44100)
                dl_lens[k] = len
                dl_pos[k]  = 1
                local b = {}
                for j = 1, len do b[j] = 0.0 end
                dl_bufs[k] = b
            end
            MAX_PRE = math.ceil(sr * 0.101) + 1
            pre_buf_l = {}; pre_buf_r = {}
            for j = 1, MAX_PRE do pre_buf_l[j] = 0.0; pre_buf_r[j] = 0.0 end
            pre_write = 1
            gbuf_l = {}; gbuf_r = {}
            for i = 1, GSIZ do gbuf_l[i] = 0.0; gbuf_r[i] = 0.0 end
            gwrite = 1; h1 = 1.0; h2 = GSIZ / 2 + 1.0; gphase = 0.0
            feedback_l = 0.0; feedback_r = 0.0
        end

        alloc(sr)

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "size"           then size           = value
            elseif id == "damp"           then damp           = value
            elseif id == "pitch_shift"    then pitch_shift    = value
            elseif id == "shimmer_amount" then shimmer_amount = value
            elseif id == "mix"            then mix            = value
            elseif id == "predelay"       then predelay       = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local fb_gain  = 0.3 + size * 0.65
            local damp_c   = piper.clamp(1 - damp * 0.95, 0, 1)
            local pre_samp = piper.clamp(math.floor(predelay / 1000 * sr), 0, MAX_PRE - 1)
            local ps       = pitch_shift / GSIZ

            for i = 0, n - 1 do
                local inL = src[i*2+1]
                local inR = src[i*2+2]

                -- Pre-delay
                local pre_rp = ((pre_write - pre_samp - 1) % MAX_PRE) + 1
                local dL = pre_buf_l[pre_rp]
                local dR = pre_buf_r[pre_rp]
                pre_buf_l[pre_write] = inL
                pre_buf_r[pre_write] = inR
                pre_write = (pre_write % MAX_PRE) + 1

                local mono = (dL + dR) * 0.5 + (feedback_l + feedback_r) * 0.5

                -- Read from 4 delay lines
                local y1 = dl_bufs[1][dl_pos[1]]
                local y2 = dl_bufs[2][dl_pos[2]]
                local y3 = dl_bufs[3][dl_pos[3]]
                local y4 = dl_bufs[4][dl_pos[4]]

                -- One-pole damping
                dl_lp[1] = dl_lp[1] + damp_c * (y1 - dl_lp[1])
                dl_lp[2] = dl_lp[2] + damp_c * (y2 - dl_lp[2])
                dl_lp[3] = dl_lp[3] + damp_c * (y3 - dl_lp[3])
                dl_lp[4] = dl_lp[4] + damp_c * (y4 - dl_lp[4])

                -- Hadamard mix
                local d1, d2, d3, d4 = dl_lp[1], dl_lp[2], dl_lp[3], dl_lp[4]
                local m1 = 0.5*(d1+d2+d3+d4)
                local m2 = 0.5*(d1-d2+d3-d4)
                local m3 = 0.5*(d1+d2-d3-d4)
                local m4 = 0.5*(d1-d2-d3+d4)

                dl_bufs[1][dl_pos[1]] = mono + m1 * fb_gain
                dl_bufs[2][dl_pos[2]] = mono + m2 * fb_gain
                dl_bufs[3][dl_pos[3]] = mono + m3 * fb_gain
                dl_bufs[4][dl_pos[4]] = mono + m4 * fb_gain

                for k = 1, 4 do
                    dl_pos[k] = (dl_pos[k] % dl_lens[k]) + 1
                end

                local rev_out_l = (d1 + d3) * 0.5
                local rev_out_r = (d2 + d4) * 0.5

                -- Pitch shifter
                gbuf_l[gwrite] = rev_out_l
                gbuf_r[gwrite] = rev_out_r
                gwrite = (gwrite % GSIZ) + 1

                h1 = h1 + pitch_shift
                if h1 > GSIZ then h1 = h1 - GSIZ end
                h2 = h2 + pitch_shift
                if h2 > GSIZ then h2 = h2 - GSIZ end

                local i1 = math.floor(h1); local f1 = h1 - i1
                local s1_l = gbuf_l[((i1-1)%GSIZ)+1]*(1-f1) + gbuf_l[(i1%GSIZ)+1]*f1
                local s1_r = gbuf_r[((i1-1)%GSIZ)+1]*(1-f1) + gbuf_r[(i1%GSIZ)+1]*f1

                local i2 = math.floor(h2); local f2 = h2 - i2
                local s2_l = gbuf_l[((i2-1)%GSIZ)+1]*(1-f2) + gbuf_l[(i2%GSIZ)+1]*f2
                local s2_r = gbuf_r[((i2-1)%GSIZ)+1]*(1-f2) + gbuf_r[(i2%GSIZ)+1]*f2

                gphase = gphase + ps
                if gphase >= 1 then gphase = gphase - 1 end
                local w1 = 0.5 * (1 - math.cos(gphase * 2 * math.pi))

                local pitched_l = s1_l * w1 + s2_l * (1 - w1)
                local pitched_r = s1_r * w1 + s2_r * (1 - w1)

                feedback_l = rev_out_l * (1 - shimmer_amount) + pitched_l * shimmer_amount
                feedback_r = rev_out_r * (1 - shimmer_amount) + pitched_r * shimmer_amount

                dst[i*2+1] = inL * (1 - mix) + rev_out_l * mix
                dst[i*2+2] = inR * (1 - mix) + rev_out_r * mix
            end
        end

        function inst:reset()
            for k = 1, 4 do
                local b = dl_bufs[k]
                if b then for j = 1, #b do b[j] = 0.0 end end
                dl_pos[k] = 1; dl_lp[k] = 0.0
            end
            for j = 1, MAX_PRE do pre_buf_l[j] = 0.0; pre_buf_r[j] = 0.0 end
            pre_write = 1
            for ii = 1, GSIZ do gbuf_l[ii] = 0.0; gbuf_r[ii] = 0.0 end
            gwrite = 1; h1 = 1.0; h2 = GSIZ/2+1.0; gphase = 0.0
            feedback_l = 0.0; feedback_r = 0.0
        end

        function inst:destroy()
            dl_bufs = {}; pre_buf_l = {}; pre_buf_r = {}
            gbuf_l = {}; gbuf_r = {}
        end

        return inst
    end,
}
