--[[---------------------------------------------------------------------------
    MCVPort — the MCV translation layer loader.

    Ports are full rewrites: a decompiled weapon's data is filled into a template
    that calls MCV.Define(), its sounds become plain sound.Add files, and the
    result depends only on the MCV base + this layer. The original mod is never
    required again.

    This file only wires up the global API (MCV.Define, the integration registry,
    the report command). The SWEP: method bridges live in mcvport/sh_animroles.lua,
    sh_events.lua and sh_lifecycle.lua and are included by the mcvport_* weapon
    bases, where the global SWEP is the base being defined.

    Organization modelled on Dandy's Hellraiser Base's DHR.Define
    (reference/dhrb/dhr/core.lua) — see docs/translation-layer-spec.md.
-----------------------------------------------------------------------------]]

if SERVER then
    local files = file.Find("mcvport/*.lua", "LUA")
    for _, f in ipairs(files) do
        AddCSLuaFile("mcvport/" .. f)
    end
end

-- Do not clobber a Define that someone else already registered (upstream MCV
-- adding its own would be the most likely collision).
if MCV and MCV.Define and not (MCVP and MCVP.LoadedDefine) then
    ErrorNoHalt("MCVPort: MCV.Define already exists before the translation layer loaded; refusing to overwrite it.\n")
    return
end

include("mcvport/sh_define.lua")   -- MCVP global, MCV.Define, validation
include("mcvport/sh_hooks.lua")    -- integration registry + hook runner
include("mcvport/sh_report.lua")   -- mcvport_report console command

if not (MCV and MCV.FIREMODE_AUTO) then
    ErrorNoHalt("MCVPort: the MCV base was not detected (MCV.FIREMODE_AUTO missing). "
        .. "Port weapons derive from mcv_base and will not work without it.\n")
end
