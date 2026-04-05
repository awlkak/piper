-- Diffusion Reverb
-- FDN reverb with 4 delay lines and Hadamard mixing matrix.

return {
    type    = "effect",
    name    = "Diffusion Reverb",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="size",      label="Size",         min=0, max=1,   default=0.6, type="float" },
        { id="damp",      label="Damp",         min=0, max=1,   default=0.5, type="float" },
        { id="diffusion", label="Diffusion",    min=0, max=1,   default=0.7, type="float" },
        { id="predelay", label="Pre-Delay (ms)", min=0, max=100, default=0,   type="float" },
        { id="mix",       label="Mix",          min=0, max=1,   default=0.3, type="float" },
        { id="width",     label="Width",        min=0, max=1,   default=0.8, type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr        = piper.SAMPLE_RATE
        local size      = self.params[1].default
        local damp      = self.params[2].default
        local diffusion = self.params[3].default
        local predelay  = self.params[4].default
        local mix       = self.params[5].default
        local width     = self.params[6].default

        -- 4 delay line lengths (at 44100, scaled by sr/44100)
        local BASE_LENGTHS = {1283, 1601, 2011, 2521}
        local dl_bufs = {}
        local dl_lens = {}
        local dl_pos  = {}
        local dl_lp   = {0,0,0,0}

        -- Pre-delay buffer
        local MAX_PRE = 0
        local pre_buf_l = {}
        local pre_buf_r = {}
        local pre_write = 1

        local function alloc(sample_rate)
            sr = sample_rate
            dl_bufs = {}
            dl_lens = {}
            dl_pos  = {}
            dl_lp   = {0,0,0,0}
            for k = 1, 4 do
                local len = math.floor(BASE_LENGTHS[k] * sr / 44100)
                dl_lens[k] = len
                dl_pos[k]  = 1
                local b = {}
                for j = 1, len do b[j] = 0.0 end
                dl_bufs[k] = b
            end
            MAX_PRE = math.ceil(sr * 0.101) + 1
            pre_buf_l = {}
            pre_buf_r = {}
            for j = 1, MAX_PRE do pre_buf_l[j] = 0.0; pre_buf_r[j] = 0.0 end
            pre_write = 1
        end

        function inst:init(sample_rate) alloc(sample_rate) end

        function inst:set_param(id, value)
            if     id == "size"      then size      = value
            elseif id == "damp"      then damp      = value
            elseif id == "diffusion" then diffusion = value
            elseif id == "predelay"  then predelay  = value
            elseif id == "mix"       then mix       = value
            elseif id == "width"     then width     = value
            end
        end

        function inst:on_message(inlet_id, msg) end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local fb_gain   = 0.3 + size * 0.6
            local damp_c    = piper.clamp(1 - damp, 0, 1)
            local pre_samp  = piper.clamp(math.floor(predelay / 1000 * sr), 0, MAX_PRE - 1)

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

                local mono = (dL + dR) * 0.5

                -- Read from 4 delay lines
                local y1 = dl_bufs[1][dl_pos[1]]
                local y2 = dl_bufs[2][dl_pos[2]]
                local y3 = dl_bufs[3][dl_pos[3]]
                local y4 = dl_bufs[4][dl_pos[4]]

                -- Hadamard mix
                local m1 = 0.5*(y1+y2+y3+y4)
                local m2 = 0.5*(y1-y2+y3-y4)
                local m3 = 0.5*(y1+y2-y3-y4)
                local m4 = 0.5*(y1-y2-y3+y4)

                -- One-pole damping per line
                dl_lp[1] = dl_lp[1] + damp_c*(m1 - dl_lp[1])
                dl_lp[2] = dl_lp[2] + damp_c*(m2 - dl_lp[2])
                dl_lp[3] = dl_lp[3] + damp_c*(m3 - dl_lp[3])
                dl_lp[4] = dl_lp[4] + damp_c*(m4 - dl_lp[4])

                -- Write back
                local fd = fb_gain * diffusion
                dl_bufs[1][dl_pos[1]] = mono + dl_lp[1] * fd
                dl_bufs[2][dl_pos[2]] = mono + dl_lp[2] * fd
                dl_bufs[3][dl_pos[3]] = mono + dl_lp[3] * fd
                dl_bufs[4][dl_pos[4]] = mono + dl_lp[4] * fd

                for k = 1, 4 do
                    dl_pos[k] = (dl_pos[k] % dl_lens[k]) + 1
                end

                -- Stereo out
                local revL = (y1 + y2) * 0.5
                local revR = (y3 + y4) * 0.5
                local mid  = (revL + revR) * 0.5
                local side = (revL - revR) * 0.5 * width
                local outL = mid + side
                local outR = mid - side

                dst[i*2+1] = inL*(1-mix) + outL*mix
                dst[i*2+2] = inR*(1-mix) + outR*mix
            end
        end

        function inst:reset()
            for k = 1, 4 do
                local b = dl_bufs[k]
                if b then for j = 1, #b do b[j] = 0.0 end end
                dl_pos[k] = 1
                dl_lp[k]  = 0.0
            end
            for j = 1, MAX_PRE do pre_buf_l[j] = 0.0; pre_buf_r[j] = 0.0 end
            pre_write = 1
        end

        function inst:destroy()
            dl_bufs = {}; pre_buf_l = {}; pre_buf_r = {}
        end

        return inst
    end,
}
