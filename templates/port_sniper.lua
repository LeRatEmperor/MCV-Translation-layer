--[[---------------------------------------------------------------------------
    MCVPort template — SNIPER (scoped, semi-auto, magazine reload)

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

    Scope specifics (docs/gun-core.md, sights section):
      - HasScope switches to the scope overlay; ScopeMaterial is a Material()
        of the reticle texture. RTScopeMaterialIndex picks the bodygroup skin
        for the render-target lens when the model has one. AdjustableScopes
        enables the zeroing dial (and plays the fidget role).
      - ScopeFOV / ScopeFOV2 are the two zoom levels (primary / hold-breath).
      - SightedViewModelFOV narrows the viewmodel FOV while sighted so the
        scope tube looks right.
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = false -- TODO: set true once the port is filled in

-- TODO: names and basic information
SWEP.PrintName = "Sniper Port"
SWEP.Category = "MCV Ports"
SWEP.Country = ""
SWEP.SubCategory = "Sniper Rifles"
SWEP.Caliber = "7.62x54mmR"

SWEP.Slot = 5
SWEP.HoldType = "ar2"
SWEP.AimHoldType = "rpg"
SWEP.SprintHoldType = "passive"

SWEP.ViewModel = ""          -- TODO: models/.../v_sniper.mdl
SWEP.WorldModel = ""         -- TODO: models/.../w_sniper.mdl

SWEP.BodyGroups = ""
SWEP.WorldModelBodyGroups = ""

SWEP.SightedViewModelFOV = 30

-- TODO: stats ---------------------------------------------------------------

SWEP.DamageGeneric = 70
SWEP.DamageHeadMultiplier = 3.0
SWEP.DamageChestMultiplier = 1.4
SWEP.DamageStomachMultiplier = 1.35
SWEP.DamageLegMultiplier = 0.95
SWEP.DamageArmMultiplier = 0.9

SWEP.Num = 1
SWEP.MuzzleVelocity = 830
SWEP.RangeModifier = 0.995   -- snipers hold damage a long way out

SWEP.Firemodes = {
    MCV.FIREMODE_SEMI
}

SWEP.MagInTime = 2.0
SWEP.MagInTimeEmpty = 3.1
SWEP.MagOutTime = 1.0
SWEP.MagOutTimeEmpty = 1.0

SWEP.ViewSlideRecoilUp = 2.2
SWEP.ViewSlideRecoilRight = 0.6
SWEP.ViewSlideRecoilIronsightUp = 1.44
SWEP.ViewSlideRecoilIronsightRight = 0.4

SWEP.RecoilPushbackValue = 2.0

SWEP.ShakeScale = 1.5
SWEP.ShakeFreq = 45
SWEP.ShakeDuration = 0.4

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.8
SWEP.IronsightFov = 90 - 15
SWEP.IronsightWalkBobbingStrength = -0.4 -- steadier when sighted

SWEP.MovementPoseWalk = 134
SWEP.MovementPoseSprint = 228
SWEP.MovementPoseSighted = 130

SWEP.HasScope = true
SWEP.ScopeMaterial = Material("scope/port_reticle") -- TODO: reticle texture
SWEP.ScopeFOV = 8            -- primary zoom
SWEP.ScopeFOV2 = 4           -- hold-breath zoom
SWEP.RTScopeMaterialIndex = 2 -- model skin with the lens hole, if any
SWEP.AdjustableScopes = true  -- zeroing dial

SWEP.IronsightPos = Vector(-0.04, -0.1, 0.015) -- TODO: scope alignment
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, -1, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 10             -- wide from the hip
SWEP.SpreadIronsighted = 0.15 -- tight through the glass

SWEP.FireRate = 120

SWEP.CrosshairMinDistance = 8
SWEP.CrosshairDeltaDistance = 4

SWEP.WeaponWeight = 4.3

SWEP.Primary.Ammo = "ar2"
SWEP.Primary.ClipSize = 10
SWEP.Primary.Chamber = 1
SWEP.Primary.DefaultClip = 40
SWEP.Primary.Automatic = true

SWEP.NearwallDistance = 50

SWEP.CrouchSpreadMultiplier = 0.7
SWEP.ProneSpreadMultiplier = 0.6
SWEP.StandMoveSpreadMultiplier = 1.6
SWEP.SneakMoveSpreadMultiplier = 1.5
SWEP.CrouchMoveSpreadMultiplier = 1.4
SWEP.JumpSpreadMultiplier = 5

SWEP.HasBayonet = false
SWEP.HasBipod = true         -- snipers often take one
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 40

-- TODO: penetration ----------------------------------------------------------

SWEP.MetalPenetrationDepth = 12
SWEP.GlassPenetrationDepth = 18
SWEP.ConcretePenetrationDepth = 14
SWEP.WoodPenetrationDepth = 22
SWEP.OtherPenetrationDepth = 16

SWEP.MetalDamageModifier = 1.5
SWEP.GlassDamageModifier = 1.1
SWEP.ConcreteDamageModifier = 1.7
SWEP.WoodDamageModifier = 1.2
SWEP.OtherDamageModifier = 1.2

-- TODO: sounds (declare these in lua/autorun/port_sounds_<class>.lua) --------

SWEP.SoundSingleShot = "PORT_Sniper.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = "PORT_Sniper.ReloadThirdPerson"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundNearlyEmpty = "PORT_Generic.NearlyEmptyClick"
SWEP.SoundEmpty = "PORT_Generic.ClipEmpty_07"

-- TODO: particles -------------------------------------------------------------

SWEP.MuzzleParticle = "vietnam_muzzleflash_sniperrifle_type1_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_sniperrifle_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_sniperrifle_type1_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_sniperrifle_type1_fp_is_smoke"
SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_sniperrifle_type1_tp"

SWEP.EjectBrassType = 8
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
        fidget = ACT_VM_FIDGET,       -- the zeroing dial, with AdjustableScopes
        bash = ACT_VM_HITCENTER,
        -- bipod_in = ACT_VM_DEPLOYED_IN,   -- with HasBipod
        -- bipod_out = ACT_VM_DEPLOYED_OUT,
        -- bipod_idle = ACT_VM_DEPLOY,
    },

    events = {
        -- reload_empty = {
        --     { t = 1.0, sound = "PORT_Sniper.MagOut" },
        --     { t = 2.4, sound = "PORT_Sniper.MagIn" },
        -- },
    },

    hooks = {
        -- Example: breath hold / steadiness of your own design.
        -- OnThink = function(self) end,
    },
})
