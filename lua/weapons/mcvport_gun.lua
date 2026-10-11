--[[---------------------------------------------------------------------------
    mcvport_gun — the translation base for ported guns.

    Derives from mcv_base and adds exactly three things:
      1. the animation role bridges    (mcvport/sh_animroles.lua)
      2. synthetic timeline events      (mcvport/sh_events.lua)
      3. thin lifecycle wrappers        (mcvport/sh_lifecycle.lua)

    Everything else — the fire pipeline, ballistics, reload state machines,
    sights, NPC support, prediction — is inherited from mcv_base untouched.

    A port weapon declares:

        SWEP.Base = "mcvport_gun"
        -- flat MCV fields, exactly like any native MCV weapon
        MCV.Define(SWEP, { anims = {...}, events = {...}, hooks = {...} })

    Melee / throwable / placeable ports get their own mcvport_* bases later,
    following the same three-include pattern against mcv_melee and friends.
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcv_base"

SWEP.Spawnable = false
SWEP.PrintName = "MCV Port Base (Guns)"
SWEP.Category = "MCV Ports"

-- The modules below define SWEP: methods on THIS base (the global SWEP while
-- they run). They must not be load-guarded: every mcvport_* base that
-- includes them needs its own set of methods.
include("mcvport/sh_animroles.lua")
include("mcvport/sh_events.lua")
include("mcvport/sh_lifecycle.lua")
