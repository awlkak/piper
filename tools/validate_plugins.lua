-- Plugin Validator
-- Run with: luajit tools/validate_plugins.lua
-- Validates all plugins without requiring Love2D.
-- Mimics machine.lua's validate() plus basic instantiation smoke-test.

local VALID_TYPES       = { generator=true, effect=true, control=true, abstraction=true }
local VALID_KINDS       = { signal=true, control=true }
local VALID_PARAM_TYPES = { float=true, int=true, bool=true, enum=true, file=true }

-- Stub piper API
local piper = {
    SAMPLE_RATE = 44100,
    BLOCK_SIZE  = 64,
    note_to_hz  = function(n) return 440 * 2^((n-69)/12) end,
    db_to_amp   = function(db) return 10^(db/20) end,
    amp_to_db   = function(a) return 20*math.log10(math.max(a,1e-9)) end,
    clamp       = function(v,lo,hi) return math.min(math.max(v,lo),hi) end,
    lerp        = function(a,b,t) return a+(b-a)*t end,
    softclip    = function(x) return x/(1+math.abs(x)) end,
    hardclip    = function(x) return math.min(math.max(x,-1),1) end,
    buf_fill    = function(buf,val,n) for i=1,n*2 do buf[i]=val end end,
    buf_mix     = function(dst,src,g,n) for i=1,n*2 do dst[i]=(dst[i]or 0)+(src[i]or 0)*g end end,
    buf_copy    = function(dst,src,n) for i=1,n*2 do dst[i]=src[i] end end,
    buf_scale   = function(buf,g,n) for i=1,n*2 do buf[i]=(buf[i]or 0)*g end end,
    buf_new     = function(n) local t={} for i=1,n*2 do t[i]=0 end return t end,
    pan_gains   = function(p) local a=(p+1)*math.pi/4 return math.cos(a),math.sin(a) end,
    biquad_lowpass  = function(c,r,sr)
        local w=2*math.pi*c/sr; local cw=math.cos(w); local sw=math.sin(w)
        local a=sw/(2*r); local b0=(1-cw)/2; local b1=1-cw; local b2=b0
        local a0=1+a; local a1=-2*cw; local a2=1-a
        return b0/a0,b1/a0,b2/a0,a1/a0,a2/a0
    end,
    biquad_highpass = function(c,r,sr)
        local w=2*math.pi*c/sr; local cw=math.cos(w); local sw=math.sin(w)
        local a=sw/(2*r); local b0=(1+cw)/2; local b1=-(1+cw); local b2=b0
        local a0=1+a; local a1=-2*cw; local a2=1-a
        return b0/a0,b1/a0,b2/a0,a1/a0,a2/a0
    end,
}

local function make_env()
    local env = {
        math=math, table=table, string=string,
        pairs=pairs, ipairs=ipairs, next=next,
        type=type, tostring=tostring, tonumber=tonumber,
        select=select, unpack=table.unpack or unpack,
        rawget=rawget, rawset=rawset, rawequal=rawequal, rawlen=rawlen,
        error=error, assert=assert, pcall=pcall, xpcall=xpcall,
        piper=piper,
    }
    env._ENV = env
    return env
end

local function validate(def)
    assert(type(def)=="table", "plugin must return a table")
    assert(VALID_TYPES[def.type], "plugin.type must be generator|effect|control|abstraction, got: "..tostring(def.type))
    assert(type(def.name)=="string" and #def.name>0, "plugin.name must be non-empty string")
    assert(type(def.version)=="number", "plugin.version must be a number")
    assert(type(def.inlets)=="table", "plugin.inlets must be a table")
    for i,pin in ipairs(def.inlets) do
        assert(type(pin.id)=="string", "inlet["..i.."].id must be string")
        assert(VALID_KINDS[pin.kind], "inlet["..i.."].kind must be signal|control, got: "..tostring(pin.kind))
    end
    assert(type(def.outlets)=="table", "plugin.outlets must be a table")
    for i,pin in ipairs(def.outlets) do
        assert(type(pin.id)=="string", "outlet["..i.."].id must be string")
        assert(VALID_KINDS[pin.kind], "outlet["..i.."].kind must be signal|control, got: "..tostring(pin.kind))
    end
    assert(type(def.params)=="table", "plugin.params must be a table")
    for i,p in ipairs(def.params) do
        assert(type(p.id)=="string", "param["..i.."].id must be string")
        assert(type(p.label)=="string", "param["..i.."].label must be string")
        assert(VALID_PARAM_TYPES[p.type], "param["..i.."].type must be float|int|bool|enum|file, got: "..tostring(p.type))
    end
    if def.type=="abstraction" then
        assert(type(def.graph)=="table", "abstraction must have .graph table")
    else
        assert(type(def.new)=="function", "non-abstraction must have .new factory function")
    end
end

local function smoke_test(def, path)
    if def.type == "abstraction" then return end  -- skip abstractions for now
    local SR = 44100
    local N  = 64

    -- Instantiate
    local inst = def:new({})
    assert(type(inst)=="table", "new() must return a table")

    -- Check methods
    for _, m in ipairs({"init","set_param","on_message","reset","destroy"}) do
        assert(type(inst[m])=="function", "instance missing method: "..m)
    end

    -- init
    inst:init(SR)

    -- set_param with defaults
    for _, p in ipairs(def.params) do
        inst:set_param(p.id, p.default)
    end

    -- on_message with note trigger
    inst:on_message("trig", {type="note", note=60, vel=0.8})

    -- render or process one block
    if def.type == "generator" then
        assert(type(inst.render)=="function", "generator instance missing render()")
        -- Build out_bufs
        local out_bufs = {}
        for _, outlet in ipairs(def.outlets) do
            if outlet.kind == "signal" then
                out_bufs[outlet.id] = piper.buf_new(N)
            else
                out_bufs[outlet.id] = {}
            end
        end
        inst:render(out_bufs, N)
        -- Check signal outlets are filled with numbers
        for _, outlet in ipairs(def.outlets) do
            if outlet.kind == "signal" then
                local buf = out_bufs[outlet.id]
                for i = 1, N*2 do
                    local v = buf[i]
                    assert(type(v)=="number", "outlet '"..outlet.id.."' buf["..i.."] is not a number, got: "..tostring(v))
                    assert(v==v, "outlet '"..outlet.id.."' buf["..i.."] is NaN")
                end
            end
        end
    elseif def.type == "effect" or def.type == "control" then
        local has_process = type(inst.process)=="function"
        local has_render  = type(inst.render)=="function"
        assert(has_process or has_render, "effect/control instance missing process() or render()")

        local in_bufs  = {}
        local out_bufs = {}
        for _, inlet in ipairs(def.inlets) do
            if inlet.kind == "signal" then
                in_bufs[inlet.id] = piper.buf_new(N)
                -- fill with a test signal
                for i = 1, N*2 do in_bufs[inlet.id][i] = math.sin(i*0.1)*0.5 end
            else
                in_bufs[inlet.id] = {}
            end
        end
        for _, outlet in ipairs(def.outlets) do
            if outlet.kind == "signal" then
                out_bufs[outlet.id] = piper.buf_new(N)
            else
                out_bufs[outlet.id] = {}
            end
        end

        if has_process then
            inst:process(in_bufs, out_bufs, N)
        else
            inst:render(out_bufs, N)
        end

        -- Check signal outlets
        for _, outlet in ipairs(def.outlets) do
            if outlet.kind == "signal" then
                local buf = out_bufs[outlet.id]
                for i = 1, N*2 do
                    local v = buf[i]
                    assert(type(v)=="number", "outlet '"..outlet.id.."' buf["..i.."] is not a number, got: "..tostring(v))
                    assert(v==v, "outlet '"..outlet.id.."' buf["..i.."] is NaN")
                end
            end
        end
    end

    -- reset and destroy
    inst:reset()
    inst:destroy()
end

local function gui_smoke_test(def)
    if not def.gui then return end
    -- Stub ctx: all method calls are no-ops
    local stub_ctx = setmetatable({}, {
        __index = function() return function() end end
    })
    stub_ctx.w       = 150
    stub_ctx.h       = def.gui.height
    stub_ctx.z       = 1
    stub_ctx.mouse_x = 0
    stub_ctx.mouse_y = 0
    stub_ctx.theme   = setmetatable({}, { __index = function() return {} end })
    local state = {}
    local ok, err = pcall(def.gui.draw, stub_ctx, state)
    assert(ok, "gui.draw raised an error: " .. tostring(err))
end

-- Collect plugin files: from args if provided, else all dirs
local ok_count   = 0
local fail_count = 0
local failures   = {}

local function validate_file(path)
            local src, err_read = io.open(path, "r")
            if not src then
                table.insert(failures, {path=path, err="cannot read: "..tostring(err_read)})
                fail_count = fail_count + 1
                return
            end
            local code = src:read("*a")
            src:close()
            local env = make_env()
            local chunk, cerr = load(code, "@"..path, "t", env)
            if not chunk then
                table.insert(failures, {path=path, err="syntax: "..tostring(cerr)})
                fail_count = fail_count + 1
                return
            end
            local ok, def = pcall(chunk)
            if not ok then
                table.insert(failures, {path=path, err="runtime: "..tostring(def)})
                fail_count = fail_count + 1
                return
            end
            local vok, verr = pcall(validate, def)
            if not vok then
                table.insert(failures, {path=path, err="validate: "..tostring(verr)})
                fail_count = fail_count + 1
                return
            end
            local sok, serr = pcall(smoke_test, def, path)
            if not sok then
                table.insert(failures, {path=path, err="smoke: "..tostring(serr)})
                fail_count = fail_count + 1
                return
            end
            local gsok, gserr = pcall(gui_smoke_test, def)
            if not gsok then
                table.insert(failures, {path=path, err="gui_smoke: "..tostring(gserr)})
                fail_count = fail_count + 1
                return
            end
            ok_count = ok_count + 1
            print("  OK  " .. path)
end

if #arg > 0 then
    for _, path in ipairs(arg) do
        validate_file(path)
    end
else
    local dirs = {
        "plugins/generators",
        "plugins/effects",
        "plugins/control",
    }
    for _, dir in ipairs(dirs) do
        local handle = io.popen("ls " .. dir .. "/*.lua 2>/dev/null")
        if handle then
            for path in handle:lines() do
                validate_file(path)
            end
            handle:close()
        end
    end
end

print("")
print(string.format("Results: %d passed, %d failed", ok_count, fail_count))
if #failures > 0 then
    print("")
    print("FAILURES:")
    for _, f in ipairs(failures) do
        print("  FAIL " .. f.path)
        print("       " .. f.err)
    end
    os.exit(1)
end
