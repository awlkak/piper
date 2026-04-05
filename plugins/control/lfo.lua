-- LFO (Low Frequency Oscillator)
-- Outputs control-rate float messages each block.
-- Shape: sine, triangle, square, sawtooth.

return {
    type    = "control",
    name    = "LFO",
    version = 1,

    inlets  = {
        { id = "rate",  kind = "control" },
        { id = "depth", kind = "control" },
        { id = "reset", kind = "control" },
    },
    outlets = {
        { id = "out", kind = "control" },
    },

    params = {
        { id="rate",  label="Rate (Hz)",  min=0.01, max=40,  default=1.0,  type="float" },
        { id="depth", label="Depth",      min=0,    max=1,   default=1.0,  type="float" },
        { id="shape", label="Shape",      min=0,    max=3,   default=0,    type="int"   },
        -- 0=sine 1=triangle 2=square 3=saw
        { id="offset",label="Offset",     min=-1,   max=1,   default=0,    type="float" },
    },

    gui = {
        height = 50,
        draw = function(ctx, state)
            local shape  = math.floor(state.shape  or 0)
            local depth  = state.depth  or 1.0
            local offset = state.offset or 0.0
            local phase  = state.phase  or 0.0
            local T      = ctx.theme

            ctx.rect(0, 0, ctx.w, ctx.h, {0.07,0.07,0.10,1}, nil)

            local pad = 4
            local mid = ctx.h * 0.5
            local amp = (ctx.h * 0.5 - pad) * depth

            -- Draw one full cycle as a polyline
            local N   = math.max(2, math.floor(ctx.w))
            local pts = {}
            for i = 0, N do
                local t = i / N  -- 0..1 within one cycle
                local v
                if shape == 0 then
                    v = math.sin(t * 2 * math.pi)
                elseif shape == 1 then
                    v = t < 0.5 and (t * 4 - 1) or (3 - t * 4)
                elseif shape == 2 then
                    v = t < 0.5 and 1.0 or -1.0
                else
                    v = t * 2 - 1
                end
                v = v * depth + offset
                pts[#pts+1] = t * ctx.w
                pts[#pts+1] = mid - v * (ctx.h * 0.5 - pad)
            end

            -- Zero line
            ctx.line(0, mid, ctx.w, mid, {0.18,0.18,0.22,1}, 1)

            ctx.plot(pts, T.accent2, 1.5)

            -- Playhead: vertical line at current phase
            local phx = phase * ctx.w
            ctx.line(phx, pad, phx, ctx.h - pad, {0.90,0.65,0.10,0.9}, 1.5)
        end,
    },

    new = function(self, args)
        local inst   = {}
        local sr     = piper.SAMPLE_RATE
        local bs     = piper.BLOCK_SIZE
        local rate   = self.params[1].default
        local depth  = self.params[2].default
        local shape  = self.params[3].default
        local offset = self.params[4].default
        local phase  = 0.0   -- 0..1

        function inst:init(sample_rate)
            sr = sample_rate
            phase = 0.0
        end

        function inst:set_param(id, value)
            if     id == "rate"   then rate   = value
            elseif id == "depth"  then depth  = value
            elseif id == "shape"  then shape  = math.floor(value)
            elseif id == "offset" then offset = value
            end
        end

        function inst:on_message(inlet_id, msg)
            if inlet_id == "rate"  and msg.type == "float" then rate  = msg.v
            elseif inlet_id == "depth" and msg.type == "float" then depth = msg.v
            elseif inlet_id == "reset" and (msg.type == "bang" or msg.type == "float") then
                phase = 0.0
            end
        end

        -- LFO is a control machine; process is called each block
        -- It outputs messages on "out" by writing to out_bufs["out"] list
        function inst:process(in_bufs, out_bufs, n)
            -- Advance phase by one block worth
            local phase_inc = rate * bs / sr
            phase = (phase + phase_inc) % 1.0

            -- Compute LFO value
            local v
            local s = shape
            if s == 0 then
                v = math.sin(phase * 2.0 * math.pi)
            elseif s == 1 then
                -- Triangle
                v = phase < 0.5 and (phase * 4.0 - 1.0) or (3.0 - phase * 4.0)
            elseif s == 2 then
                -- Square
                v = phase < 0.5 and 1.0 or -1.0
            else
                -- Sawtooth
                v = phase * 2.0 - 1.0
            end
            v = v * depth + offset

            -- Push float message to outlet
            local out_list = out_bufs["out"]
            if out_list then
                table.insert(out_list, piper and { type="float", v=v } or { type="float", v=v })
            end
        end

        function inst:render(out_bufs, n)
            self:process({}, out_bufs, n)
        end

        function inst:reset()
            phase = 0.0
        end

        function inst:destroy() end

        function inst:get_ui_state()
            return {
                shape  = shape,
                depth  = depth,
                offset = offset,
                phase  = phase,
            }
        end

        return inst
    end,
}
