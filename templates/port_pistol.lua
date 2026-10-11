--[[---------------------------------------------------------------------------
    MCVPort template — PISTOL (semi-auto, magazine reload)

    PORT OF:    <original weapon name / class>
    SOURCE:     <original mod + base, decompile date>
    NOTES:      <judgment calls: dropped features, timings taken from where,
                 anything you had to invent — this is what future-you reads>

    Workflow (docs/translation-layer-spec.md):
      1. decompile the original mod
      2. copy this file to lua/weapons/<yourclass>.lua and fill in everything
         marked TODO, then set Spawnable = true
      3. copy templates/port_sounds.lua to lua/autorun/port_sounds_<class>.lua
         and declare the sounds it references
      4. done — the weapon depends on the MCV base + this layer only

    Two-homes rule: if MCV consumes a field natively, it stays a flat SWEP
    field below. Only translational data (anims/events/hooks) goes in
    MCV.Define. Every flat field here is real MCV schema — see
    docs/weapon-definitions.md for the full catalogue.
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = false -- TODO: set true once the port is filled in

-- TODO: names and basic information
SWEP.PrintName = "Pistol Port"
SWEP.Category = "MCV Ports"
SWEP.Country = ""            -- flavour text, shown in tooltips
SWEP.SubCategory = "Pistols"
SWEP.Caliber = "9x19mm"

SWEP.Slot = 1
SWEP.HoldType = "pistol"     -- player animation holdtype
SWEP.AimHoldType = "revolver" -- holdtype while sighted ("pistol" is usually right)
SWEP.SprintHoldType = "normal"

SWEP.ViewModel = ""          -- TODO: models/.../v_pistol.mdl
SWEP.WorldModel = ""         -- TODO: models/.../w_pistol.mdl

SWEP.BodyGroups = ""         -- viewmodel bodygroup string, e.g. "001"

-- Akimbo (optional; needs a dual viewmodel with the same anim contract)
-- SWEP.ViewModelAkimbo = "models/.../v_dual_pistol.mdl"
-- SWEP.HasAkimbo = true
-- SWEP.AkimboPoseRecoil = true
-- SWEP.IronsightPosAkimbo = Vector(0, -5, 0)
-- SWEP.IronsightAngAkimbo = Angle(0, 0, 0)

-- TODO: stats ---------------------------------------------------------------

SWEP.DamageGeneric = 25     -- damage vs objects and hitbox-less characters
SWEP.DamageHeadMultiplier = 3.5
SWEP.DamageChestMultiplier = 1.85
SWEP.DamageStomachMultiplier = 1.8
SWEP.DamageLegMultiplier = 1.25
SWEP.DamageArmMultiplier = 1.2

SWEP.MuzzleVelocity = 375   -- m/s; drives physbullet travel when enabled
SWEP.RangeModifier = 0.79   -- damage falloff per 500 units

SWEP.Firemodes = {
    MCV.FIREMODE_SEMI
}

-- Revolver instead? Use the single-action / double-action / fanning modes and
-- read docs/gun-core.md section on revolver state machines first:
--   MCV.FIREMODE_SA / MCV.FIREMODE_DA / MCV.FIREMODE_FAN

SWEP.LastShotAnimation = true -- model has a dedicated last-round fire anim?

SWEP.MagInTime = 1.4        -- seconds until the magazine is in
SWEP.MagInTimeEmpty = 1.9   -- ... with the slide locked back
SWEP.MagOutTime = 0.6       -- seconds until the old magazine is out
SWEP.MagOutTimeEmpty = 0.6

SWEP.ViewSlideRecoilUp = 1.72       -- viewmodel slide-back from recoil
SWEP.ViewSlideRecoilRight = 0.68
SWEP.ViewSlideRecoilIronsightUp = 1.48
SWEP.ViewSlideRecoilIronsightRight = 0.56

SWEP.RecoilPushbackValue = 1.5

SWEP.ShakeScale = 0.6       -- camera shake
SWEP.ShakeFreq = 50
SWEP.ShakeDuration = 0.35

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.85   -- movement speed while sighted
SWEP.IronsightFov = 90 - 15
SWEP.IronsightWalkBobbingStrength = -0.25

-- Movement pose values are MCV-rig pose-parameter ranges (player_movement).
-- Foreign models ignore them gracefully; MCV-rigged ports should set them.
SWEP.MovementPoseWalk = 161
SWEP.MovementPoseSprint = 260
SWEP.MovementPoseSighted = 130

SWEP.HasScope = false
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(-0.025, -5, 0.16) -- TODO: sight alignment
SWEP.IronsightAng = Angle(0.25, 0, 0)

SWEP.CustomPos = Vector(0, -2, 0) -- relaxed hip position offset
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 7             -- hipfire cone (degrees at the crosshair)
SWEP.SpreadIronsighted = 3

SWEP.FireRate = 450         -- rounds per minute

SWEP.CrosshairMinDistance = 4
SWEP.CrosshairDeltaDistance = 4

SWEP.WeaponWeight = 0.854   -- kg; used by the weight HUD / speed systems

SWEP.Primary.Ammo = "pistol"
SWEP.Primary.ClipSize = 15
SWEP.Primary.Chamber = 1    -- +1 in the chamber when tactical reloading
SWEP.Primary.DefaultClip = 60
SWEP.Primary.Automatic = true -- trigger semantics come from Firemodes

SWEP.NearwallDistance = 22  -- gun lowers this close to a wall

SWEP.CrouchSpreadMultiplier = 0.95
SWEP.ProneSpreadMultiplier = 0.9
SWEP.StandMoveSpreadMultiplier = 1.2
SWEP.SneakMoveSpreadMultiplier = 1.15
SWEP.CrouchMoveSpreadMultiplier = 1.1
SWEP.JumpSpreadMultiplier = 1.35

SWEP.HasBayonet = false
SWEP.HasBipod = false
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 25        -- melee bash (F or the bash key)

-- TODO: penetration (docs/shooting-ballistics.md) ---------------------------

SWEP.MetalPenetrationDepth = 6
SWEP.GlassPenetrationDepth = 12
SWEP.ConcretePenetrationDepth = 8
SWEP.WoodPenetrationDepth = 16
SWEP.OtherPenetrationDepth = 10

SWEP.MetalDamageModifier = 1.65
SWEP.GlassDamageModifier = 1.25
SWEP.ConcreteDamageModifier = 1.85
SWEP.WoodDamageModifier = 1.35
SWEP.OtherDamageModifier = 1.35

-- TODO: sounds (declare these in lua/autorun/port_sounds_<class>.lua) -------

SWEP.SoundSingleShot = "PORT_Pistol.Single"
SWEP.SoundDoubleShot = ""                    -- akimbo/alt fire if used
SWEP.SoundReload = ""                        -- first person reload loop, if any
SWEP.SoundReloadThirdPerson = "PORT_Pistol.ReloadThirdPerson"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundNearlyEmpty = "PORT_Generic.NearlyEmptyClick_Pistol"
SWEP.SoundEmpty = "PORT_Generic.ClipEmpty_03"

-- TODO: particles ------------------------------------------------------------
-- Use the original game's effects if the decompile ships them, otherwise pick
-- from MCV's vietnam_* set (they ship with the MCV addon).

SWEP.MuzzleParticle = "vietnam_muzzleflash_pistol_type3_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_pistol_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_pistol_type3_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_pistol_type1_fp_is_smoke"
SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_pistol_type3_tp"

SWEP.EjectBrassType = 5     -- brass model selector
SWEP.EjectBrassTrail = "vietnam_weaponeffect_shelleject_trail"
SWEP.EjectBrassParticle = "vietnam_weaponeffect_shelleject_side"

SWEP.TracerParticle = "vietnam_tracer_pistol_green_primary"
SWEP.TracerParticle2 = "vietnam_tracer_pistol_green_secondary"
SWEP.TracerRandomness = 6
SWEP.TracerFrequency = 2

--------------------------------------------------------------------------------
-- Translation layer data
--------------------------------------------------------------------------------

MCV.Define(SWEP, {
    -- Animation roles. Each value is an activity number, a sequence name, or
    -- a candidate list tried in order. Roles you omit keep MCV's default
    -- activity, so a model that already speaks ACT_VM_* needs almost nothing
    -- here. See MCVP.ActRoles for the full role catalogue.
    anims = {
        -- idle = "idle01",                     -- sequence name
        draw = { "draw", ACT_VM_DRAW },         -- try name, then activity
        fire = ACT_VM_PRIMARYATTACK,
        -- fire_last = "shoot_empty",           -- when LastShotAnimation = true
        -- fire_empty = ACT_VM_PRIMARYATTACK_EMPTY,
        reload = ACT_VM_RELOAD,
        reload_empty = ACT_VM_RELOADEMPTY,
        -- bash = ACT_VM_HITCENTER,
    },

    -- Synthetic timeline events (seconds after the animation starts).
    -- Only for models whose event tracks are missing/unreadable; prefer the
    -- flat MagInTime / MagOutTime fields above whenever they express it.
    events = {
        -- reload_empty = {
        --     { t = 0.7, sound = "PORT_Pistol.SlideBack" },
        --     { t = 1.9, sound = "PORT_Pistol.SlideRelease" },
        -- },
    },

    -- Custom mechanics. check = veto, event = notification.
    hooks = {
        -- CanFire = function(self) end,
        -- OnShotFired = function(self, role, duration) end,
        -- OnRoleEvent = function(self, role, ev) end,
    },
})
