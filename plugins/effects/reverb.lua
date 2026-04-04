-- Reverb
-- Schroeder/Moorer-style reverb: parallel comb filters into series all-pass filters.
-- 4 feedback comb filters + 2 all-pass stages.

return {
    type    = "effect",
    name    = "Reverb",
    version = 1,

    inlets  = {
        { id = "in", kind = "signal" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="room",    label="Room Size",  min=0,  max=1,   default=0.6,  type="float" },
        { id="damp",    label="Damping",    min=0,  max=1,   default=0.5,  type="float" },
        { id="width",   label="Width",      min=0,  max=1,   default=0.8,  type="float" },
        { id="mix",     label="Wet Mix",    min=0,  max=1,   default=0.3,  type="float" },
        { id="predelay",label="Pre-delay(ms)",min=0,max=100, default=0,    type="float" },
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local room     = 0.6
        local damp     = 0.5
        local width    = 0.8
        local mix      = 0.3
        local predelay = 0.0

        -- Comb filter delay times (in samples at 44100; scaled proportionally)
        local COMB_DELAYS = {1557, 1617, 1491, 1422, 1277, 1356, 1188, 1116}
        local N_COMBS = 8

        -- All-pass filter delays
        local AP_DELAYS = {225, 341, 441, 556}
        local N_APS = 4

        local combs = {}  -- { bufL, bufR, pos, filterL, filterR }
        local aps   = {}  -- { bufL, bufR, pos }

        local pd_buf = {}
        local pd_size = 0
        local pd_pos  = 1

        local function make_comb(delay_samples)
            local sz = math.floor(delay_samples * sr / 44100) + 1
            local c = { pos=1, filterL=0, filterR=0, sz=sz }
            c.bufL = {}; c.bufR = {}
            for i = 1, sz do c.bufL[i] = 0.0; c.bufR[i] = 0.0 end
            return c
        end

        local function make_ap(delay_samples)
            local sz = math.floor(delay_samples * sr / 44100) + 1
            local a = { pos=1, sz=sz }
            a.bufL = {}; a.bufR = {}
            for i = 1, sz do a.bufL[i] = 0.0; a.bufR[i] = 0.0 end
            return a
        end

        local function init_all()
            combs = {}
            for i = 1, N_COMBS do
                -- Slightly different delays for L/R (stereo spread)
                local off = (i <= N_COMBS/2) and 0 or 23
                combs[i] = make_comb(COMB_DELAYS[i] + off)
            end
            aps = {}
            for i = 1, N_APS do
                aps[i] = make_ap(AP_DELAYS[i])
            end
            pd_size = math.max(1, math.floor(predelay / 1000.0 * sr))
            pd_buf = {}
            for i = 1, pd_size * 2 + 2 do pd_buf[i] = 0.0 end
            pd_pos = 1
        end

        function inst:init(sample_rate)
            sr = sample_rate
            init_all()
        end

        function inst:set_param(id, value)
            if     id == "room"     then room     = value
            elseif id == "damp"     then damp     = value
            elseif id == "width"    then width    = value
            elseif id == "mix"      then mix      = value
            elseif id == "predelay" then
                predelay = value
                pd_size  = math.max(1, math.floor(predelay / 1000.0 * sr))
                pd_buf   = {}
                for i = 1, pd_size * 2 + 2 do pd_buf[i] = 0.0 end
                pd_pos   = 1
            end
        end

        function inst:on_message() end

        function inst:process(in_bufs, out_bufs, n)
            local src = in_bufs["in"]
            local dst = out_bufs["out"]
            if not src or not dst then return end

            local feedback_g = 0.28 + room * 0.68  -- comb feedback gain
            local damp1      = damp * 0.4
            local damp2      = 1.0 - damp1
            local dry        = 1.0 - mix
            local wet1       = mix * (width * 0.5 + 0.5)
            local wet2       = mix * ((1.0 - width) * 0.5)

            for i = 0, n - 1 do
                local inL = src[i * 2 + 1]
                local inR = src[i * 2 + 2]

                -- Pre-delay
                local pdL, pdR = inL, inR
                if pd_size > 1 then
                    local ri = ((pd_pos - pd_size - 1) % pd_size) + 1
                    pdL = pd_buf[ri * 2 - 1]
                    pdR = pd_buf[ri * 2]
                    pd_buf[pd_pos * 2 - 1] = inL
                    pd_buf[pd_pos * 2]     = inR
                    pd_pos = (pd_pos % pd_size) + 1
                end

                local mono = (pdL + pdR) * 0.5

                -- Parallel comb filters
                local outL, outR = 0.0, 0.0
                for ci = 1, N_COMBS do
                    local c  = combs[ci]
                    local rL = c.bufL[c.pos]
                    local rR = c.bufR[c.pos]
                    c.filterL = rL * damp2 + c.filterL * damp1
                    c.filterR = rR * damp2 + c.filterR * damp1
                    c.bufL[c.pos] = mono + c.filterL * feedback_g
                    c.bufR[c.pos] = mono + c.filterR * feedback_g
                    c.pos = (c.pos % c.sz) + 1
                    if ci <= N_COMBS/2 then
                        outL = outL + c.filterL
                    else
                        outR = outR + c.filterR
                    end
                end

                -- Series all-pass filters
                local scale = 1.0 / (N_COMBS / 2)
                outL = outL * scale
                outR = outR * scale
                for ai = 1, N_APS do
                    local a   = aps[ai]
                    local apg = 0.5
                    local xL  = outL
                    local xR  = outR
                    outL = -xL + a.bufL[a.pos]
                    outR = -xR + a.bufR[a.pos]
                    a.bufL[a.pos] = xL + outL * apg
                    a.bufR[a.pos] = xR + outR * apg
                    a.pos = (a.pos % a.sz) + 1
                end

                dst[i * 2 + 1] = inL * dry + (outL * wet1 + outR * wet2)
                dst[i * 2 + 2] = inR * dry + (outR * wet1 + outL * wet2)
            end
        end

        function inst:reset() init_all() end

        function inst:destroy()
            combs = {}; aps = {}; pd_buf = {}
        end

        return inst
    end,
}
