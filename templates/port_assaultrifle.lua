--[[---------------------------------------------------------------------------
    MCVPort template — ASSAULT RIFLE (select fire, magazine reload,
    optional bayonet / rifle grenade / bipod)

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
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = false -- TODO: set true once the port is filled in

-- TODO: names and basic information
SWEP.PrintName = "Assault Rifle Port"
SWEP.Category = "MCV Ports"
SWEP.Country = ""
SWEP.SubCategory = "Assault Rifles"
SWEP.Caliber = "7.62x39mm"

SWEP.Slot = 3
SWEP.HoldType = "ar2"
SWEP.AimHoldType = "rpg"     -- MCV convention for shouldered rifles
SWEP.SprintHoldType = "passive"

SWEP.ViewModel = ""          -- TODO: models/.../v_rifle.mdl
SWEP.WorldModel = ""         -- TODO: models/.../w_rifle.mdl

SWEP.BodyGroups = ""         -- viewmodel bodygroup string
SWEP.WorldModelBodyGroups = ""
SWEP.BayonetBodygroup = 1    -- bodygroup index the bayonet hides/shows
SWEP.GrenadeLauncherBodygroup = 2
SWEP.GrenadeBodygroup = 3

-- TODO: stats ---------------------------------------------------------------

SWEP.DamageGeneric = 34
SWEP.DamageHeadMultiplier = 4.0
SWEP.DamageChestMultiplier = 1.9
SWEP.DamageStomachMultiplier = 1.85
SWEP.DamageLegMultiplier = 1.3
SWEP.DamageArmMultiplier = 1.25

SWEP.Num = 1                 -- pellets per shot; keep 1 for rifles

SWEP.MuzzleVelocity = 715
SWEP.RangeModifier = 0.98

SWEP.Firemodes = {
    MCV.FIREMODE_AUTO,
    MCV.FIREMODE_SEMI
}

SWEP.MagInTime = 1.6
SWEP.MagInTimeEmpty = 2.4
SWEP.MagOutTime = 0.8
SWEP.MagOutTimeEmpty = 0.8

SWEP.ViewSlideRecoilUp = 2.2
SWEP.ViewSlideRecoilRight = 0.55
SWEP.ViewSlideRecoilIronsightUp = 1.5
SWEP.ViewSlideRecoilIronsightRight = 0.4

SWEP.RecoilPushbackValue = 1.5

SWEP.ShakeScale = 1.2
SWEP.ShakeFreq = 40
SWEP.ShakeDuration = 0.45

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.9
SWEP.IronsightFov = 90 - 10
SWEP.IronsightWalkBobbingStrength = -0.25

SWEP.MovementPoseWalk = 145
SWEP.MovementPoseSprint = 250
SWEP.MovementPoseSighted = 130

SWEP.HasScope = false        -- true only with a scope texture + model support
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(-0.03, -2, 0.1) -- TODO: sight alignment
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, -1, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 6
SWEP.SpreadIronsighted = 1.2

SWEP.FireRate = 600          -- rounds per minute

SWEP.CrosshairMinDistance = 5
SWEP.CrosshairDeltaDistance = 6

SWEP.WeaponWeight = 3.8

SWEP.Primary.Ammo = "ar2"
SWEP.Primary.ClipSize = 30
SWEP.Primary.Chamber = 1
SWEP.Primary.DefaultClip = 90
SWEP.Primary.Automatic = true

SWEP.NearwallDistance = 40

SWEP.CrouchSpreadMultiplier = 0.85
SWEP.ProneSpreadMultiplier = 0.8
SWEP.StandMoveSpreadMultiplier = 1.3
SWEP.SneakMoveSpreadMultiplier = 1.2
SWEP.CrouchMoveSpreadMultiplier = 1.1
SWEP.JumpSpreadMultiplier = 2.5

-- Attachments (each needs its model anims; leave false when in doubt)
SWEP.HasBayonet = true
SWEP.HasBipod = false
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 40
SWEP.BayonetDamage = 100

-- Rifle grenade (optional; requires a grenade projectile entity)
-- SWEP.RifleGrenadeEntity = "mcv_proj_riflegrenade"
-- SWEP.RifleGrenadeForce = 2000
-- SWEP.Secondary.Automatic = true
-- SWEP.Secondary.ClipSize = 1
-- SWEP.Secondary.Ammo = "smg1_grenade"
-- SWEP.Secondary.DefaultClip = 1
-- SWEP.SoundGrenadeShot = "PORT_Rifle.GrenadeShot"

-- TODO: penetration ----------------------------------------------------------

SWEP.MetalPenetrationDepth = 8
SWEP.GlassPenetrationDepth = 14
SWEP.ConcretePenetrationDepth = 10
SWEP.WoodPenetrationDepth = 18
SWEP.OtherPenetrationDepth = 12

SWEP.MetalDamageModifier = 1.6
SWEP.GlassDamageModifier = 1.2
SWEP.ConcreteDamageModifier = 1.8
SWEP.WoodDamageModifier = 1.3
SWEP.OtherDamageModifier = 1.3

-- TODO: sounds (declare these in lua/autorun/port_sounds_<class>.lua) --------

SWEP.SoundSingleShot = "PORT_Rifle.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = "PORT_Rifle.ReloadThirdPerson"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundNearlyEmpty = "PORT_Generic.NearlyEmptyClick"
SWEP.SoundEmpty = "PORT_Generic.ClipEmpty_05"

SWEP.SoundCycleThirdPerson = "PORT_Rifle.CycleThirdPerson" -- bolt/pump cycle foley

-- TODO: particles -------------------------------------------------------------

SWEP.MuzzleParticle = "vietnam_muzzleflash_rifle_type1_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_rifle_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_rifle_type1_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_rifle_type1_fp_is_smoke"
SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_rifle_type1_tp"

SWEP.EjectBrassType = 1
SWEP.EjectBrassTrail = "vietnam_weaponeffect_shelleject_trail"
SWEP.EjectBrassParticle = "vietnam_weaponeffect_shelleject_side"

SWEP.TracerParticle = "vietnam_tracer_rifle_primary"
SWEP.TracerParticle2 = "vietnam_tracer_rifle_secondary"
SWEP.TracerRandomness = 6
SWEP.TracerFrequency = 1

--------------------------------------------------------------------------------
-- Translation layer data
--------------------------------------------------------------------------------

MCV.Define(SWEP, {
    anims = {
        -- idle = "idle01",
        draw = { "draw", ACT_VM_DRAW },
        fire = ACT_VM_PRIMARYATTACK,
        reload = ACT_VM_RELOAD,
        reload_empty = ACT_VM_RELOADEMPTY,
        firemode = ACT_VM_FIREMODE,   -- selector switch anim
        bash = ACT_VM_HITCENTER,
        -- bayonet_swing = ACT_VM_HITLEFT,       -- when HasBayonet
        -- bayonet_on = ACT_VM_ATTACH_SILENCER,
        -- bayonet_off = ACT_VM_DETACH_SILENCER,
        -- bipod_in = ACT_VM_DEPLOYED_IN,       -- when HasBipod
        -- bipod_out = ACT_VM_DEPLOYED_OUT,
        -- ubgl_in = ACT_VM_IIN_M203,           -- when an underbarrel launcher
    },

    events = {
        -- reload_empty = {
        --     { t = 0.8, sound = "PORT_Rifle.MagOut" },
        --     { t = 2.0, sound = "PORT_Rifle.MagIn" },
        --     { t = 2.3, sound = "PORT_Rifle.BoltBack" },
        -- },
    },

    hooks = {
        -- Example: bolt slams on the first shot after a fresh mag.
        -- OnShotFired = function(self, role, duration)
        --     -- custom first-shot-after-reload logic here
        -- end,
    },
})
