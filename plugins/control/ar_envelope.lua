-- AR Envelope
-- Simple Attack-Release envelope with re-trigger support.

return {
    type    = "control",
    name    = "AR Envelope",
    version = 1,

    inlets  = {
        { id = "trig", kind = "control" },
    },
    outlets = {
        { id = "out",  kind = "control" },
        { id = "out~", kind = "signal"  },
    },

    params = {
        { id="attack",  label="Attack",  min=0.001, max=10,  default=0.01, type="float" },
        { id="release", label="Release", min=0.001, max=10,  default=0.3,  type="float" },
        { id="curve",   label="Curve",   min=0,     max=1,   default=0.5,  type="float" },
    },

    gui = {
        height = 50,
        draw = function(ctx, state)
            local a = state.attack  or 0.01
            local r = state.release or 0.3
            local c = state.curve   or 0.5
            local T = ctx.theme

            ctx.rect(0, 0, ctx.w, ctx.h, {0.07,0.07,0.10,1}, nil)

            local pad    = 4
            local top    = pad
            local bottom = ctx.h - pad
            local aw     = ctx.w * (a / math.max(a + r, 0.001))
            local rw     = ctx.w - aw
            local N      = math.max(2, math.floor(ctx.w))

            -- Build curve polyline: attack then release
            -- curve=0 → linear, curve=1 → very exponential
            local pts = {}
            for i = 0, N do
                local xn = i / N
                local yn
                if xn <= aw / ctx.w then
                    local t = xn / math.max(aw / ctx.w, 0.0001)
                    -- exponential attack
                    local exp = c * 4
                    yn = t ^ math.max(0.1, 1 - exp + 1)
                else
                    local t = (xn - aw / ctx.w) / math.max(rw / ctx.w, 0.0001)
                    -- exponential release
                    local exp = c * 4
                    yn = (1 - t) ^ math.max(0.1, exp + 1)
                end
                pts[#pts+1] = xn * ctx.w
                pts[#pts+1] = top + (1 - yn) * (bottom - top)
            end

            ctx.plot(pts, {0.90, 0.65, 0.10, 0.3}, 5)
            ctx.plot(pts, T.accent, 1.5)

            -- Playhead
            if state.env_val and state.active then
                local ev2 = state.env_val or 0
                local px2 = ctx.w * (state.phase_norm or 0)
                local py2 = top + (1 - ev2) * (bottom - top)
                ctx.circle(px2, py2, 3, "fill", T.accent)
            end
        end,
    },

    new = function(self, args)
        local inst = {}
        local sr   = piper.SAMPLE_RATE

        local attack  = 0.01
        local release = 0.3
        local curve   = 0.5

        local IDLE    = 0
        local ATTACK  = 1
        local RELEASE = 2

        local state   = IDLE
        local env_val = 0.0

        function inst:init(sample_rate)
            sr = sample_rate
            state = IDLE; env_val = 0.0
        end

        function inst:set_param(id, value)
            if     id == "attack"  then attack  = value
            elseif id == "release" then release = value
            elseif id == "curve"   then curve   = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "trig" then
                if msg.type == "note" or msg.type == "bang" then
                    state = ATTACK
                elseif msg.type == "note_off" then
                    state = RELEASE
                end
            end
        end

        function inst:process(in_bufs, out_bufs, n)
            local ctl = out_bufs["out"]
            local sig = out_bufs["out~"]

            local atk_inc = 1.0 / (attack  * sr)
            local rel_inc = 1.0 / (release * sr)
            local sum = 0.0

            for i = 0, n - 1 do
                if state == ATTACK then
                    env_val = env_val + atk_inc
                    if env_val >= 1.0 then env_val = 1.0; state = IDLE end
                elseif state == RELEASE then
                    env_val = env_val - rel_inc
                    if env_val <= 0.0 then env_val = 0.0; state = IDLE end
                end

                local exp = 1.0 / (0.1 + curve*4)
                local shaped = env_val^exp

                sum = sum + shaped
                if sig then
                    sig[i*2+1] = shaped
                    sig[i*2+2] = shaped
                end
            end

            if ctl then
                table.insert(ctl, {type="float", v=sum/n})
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            state = IDLE; env_val = 0.0
        end

        function inst:get_ui_state()
            return {
                attack  = attack,
                release = release,
                curve   = curve,
                env_val = env_val,
                active  = state ~= IDLE,
            }
        end

        function inst:destroy() end

        return inst
    end,
}
