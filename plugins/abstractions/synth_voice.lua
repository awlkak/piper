-- Synth Voice Abstraction
-- A complete monophonic voice: sine_osc -> envelope (amp) -> lowpass
--
-- This is an abstraction: it returns a .graph table instead of a .new function.
-- The loader expands it into individual node instances.
--
-- Exposed inlets:  "trig" (control) - note on/off
-- Exposed outlets: "out"  (signal)  - audio output

return {
    type    = "abstraction",
    name    = "Synth Voice",
    version = 1,

    inlets  = {
        { id = "trig",   kind = "control" },
    },
    outlets = {
        { id = "out", kind = "signal" },
    },

    params = {
        { id="cutoff",  label="Filter Cutoff", min=20,   max=20000, default=2000, type="float" },
        { id="res",     label="Resonance",     min=0.1,  max=10,    default=0.7,  type="float" },
        { id="attack",  label="Attack",        min=0.001,max=10,    default=0.01, type="float" },
        { id="decay",   label="Decay",         min=0.001,max=10,    default=0.1,  type="float" },
        { id="sustain", label="Sustain",       min=0,    max=1,     default=0.7,  type="float" },
        { id="release", label="Release",       min=0.001,max=10,    default=0.3,  type="float" },
    },

    -- Sub-graph definition
    graph = {
        nodes = {
            {
                id     = "osc",
                plugin = "plugins/generators/sine_osc.lua",
                params = {},
                x = 50, y = 100,
            },
            {
                id     = "env",
                plugin = "plugins/control/envelope.lua",
                params = { attack="$1", decay="$2", sustain="$3", release="$4" },
                x = 50, y = 200,
            },
            {
                id     = "filter",
                plugin = "plugins/effects/lowpass.lua",
                params = {},
                x = 200, y = 100,
            },
        },
        edges = {
            -- trig inlet (from abstraction inlet) -> osc trig
            { from_id="__inlet_trig__", from_pin="trig", to_id="osc",    to_pin="trig"   },
            -- trig inlet -> envelope trig
            { from_id="__inlet_trig__", from_pin="trig", to_id="env",    to_pin="trig"   },
            -- oscillator audio -> filter input
            { from_id="osc",  from_pin="out",  to_id="filter", to_pin="in"    },
            -- filter output -> abstraction outlet
            { from_id="filter", from_pin="out", to_id="__outlet_out__", to_pin="out" },
            -- envelope control output -> osc amplitude
            { from_id="env",  from_pin="out",  to_id="osc",    to_pin="amp"   },
        },
        -- Map exposed parameter IDs to inner node params
        param_map = {
            cutoff  = { node="filter", param="cutoff" },
            res     = { node="filter", param="res"    },
            attack  = { node="env",    param="attack"  },
            decay   = { node="env",    param="decay"   },
            sustain = { node="env",    param="sustain" },
            release = { node="env",    param="release" },
        },
    },
}
