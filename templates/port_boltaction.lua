--[[---------------------------------------------------------------------------
    MCVPort template — BOLT-ACTION RIFLE (manual cycle, stripper clip or
    single-round loading)

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

    Bolt-action specifics (docs/gun-core.md cycle state machine):
      - FIREMODE_BOLT blocks the next shot until the bolt is worked. The cycle
        waits for the trigger to be RELEASED (except SlamFire shotguns).
      - PlayCycleAnimation = true plays the bolt animation after each shot.
        The state blocks the next shot even without one (dual-model note in
        sh_think.lua:112-132), so a model without a bolt anim still works.
      - IMPORTANT for foreign models: leave AnimationHandlesHammer = false.
        The native true path reads MCV.HammerEvents, a generated table that
        only covers the eight shipped manually-cycled MCV models; a foreign
        model is not in it and the hammer would never drop. false uses the
        timed cycle (duration * CyclePostDelay), which always works.
      - MagInClip = true switches the reload to stripper-clip insertion
        (ShotgunReloadRounds rounds per clip pass) instead of a magazine.
      - NoEjectOnShoot = true: the hull ejects during the bolt cycle, which
        most bolt models animate (or time it via a synthetic pump/cycle event).
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = false -- TODO: set true once the port is filled in

-- TODO: names and basic information
SWEP.PrintName = "Bolt-Action Port"
SWEP.Category = "MCV Ports"
SWEP.Country = ""
SWEP.SubCategory = "Bolt-Action Rifles"
SWEP.Caliber = "7.62x54mmR"

SWEP.Slot = 3
SWEP.HoldType = "ar2"
SWEP.AimHoldType = "rpg"
SWEP.SprintHoldType = "passive"

SWEP.ViewModel = ""          -- TODO: models/.../v_bolt.mdl
SWEP.WorldModel = ""         -- TODO: models/.../w_bolt.mdl

SWEP.BodyGroups = ""
SWEP.WorldModelBodyGroups = ""
SWEP.BayonetBodygroup = 1

-- TODO: stats ---------------------------------------------------------------

SWEP.DamageGeneric = 65
SWEP.DamageHeadMultiplier = 3.05
SWEP.DamageChestMultiplier = 2.8
SWEP.DamageStomachMultiplier = 2.7
SWEP.DamageLegMultiplier = 1.5
SWEP.DamageArmMultiplier = 1.4

SWEP.Num = 1
SWEP.MuzzleVelocity = 865
SWEP.RangeModifier = 0.995

SWEP.Firemodes = {
    MCV.FIREMODE_BOLT
}

SWEP.PlayCycleAnimation = true -- work the bolt after every shot
SWEP.CyclePostDelay = 0.9      -- fraction of the cycle anim after which you
                               -- may fire again
SWEP.AnimationHandlesHammer = false -- keep false on foreign models (see header)

SWEP.MagInClip = true        -- stripper clip loading; false for a magazine
SWEP.ShotgunReloadEmptyStartAnimation = false
SWEP.ReloadInsertTime = 18 / 30 -- TODO: when a round seats during the insert
SWEP.HasEmptyReload = true

SWEP.LastShotAnimation = false
SWEP.NoEjectOnShoot = true   -- the bolt cycle ejects

SWEP.MagInTime = 2.5         -- clip/magazine seated (foley timing when native)
SWEP.MagInTimeEmpty = 3.2

SWEP.ViewSlideRecoilUp = 2.84
SWEP.ViewSlideRecoilRight = 0.48
SWEP.ViewSlideRecoilIronsightUp = 1.36
SWEP.ViewSlideRecoilIronsightRight = 0.24

SWEP.RecoilPushbackValue = 2.0

SWEP.ShakeScale = 1.2
SWEP.ShakeFreq = 30
SWEP.ShakeDuration = 0.5

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.95
SWEP.IronsightFov = 90 - 15
SWEP.IronsightWalkBobbingStrength = -0.25

SWEP.MovementPoseWalk = 141
SWEP.MovementPoseSprint = 236
SWEP.MovementPoseSighted = 130

SWEP.HasScope = false        -- most bolt ports are ironsighted; see the sniper
SWEP.ScopeMaterial = NULL    -- template when the model carries a scope
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(0, -3, 0.05) -- TODO: sight alignment
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, -2, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 5
SWEP.SpreadIronsighted = 0.4

SWEP.FireRate = 600          -- the ACTION's animation rate, not real RPM; the
                             -- bolt cycle enforces the practical rate

SWEP.CrosshairMinDistance = 8
SWEP.CrosshairDeltaDistance = 4

SWEP.WeaponWeight = 4.0

SWEP.Primary.Ammo = "357"
SWEP.Primary.ClipSize = 5
SWEP.Primary.Chamber = 0
SWEP.Primary.DefaultClip = 40
SWEP.Primary.Automatic = true

SWEP.NearwallDistance = 40

SWEP.CrouchSpreadMultiplier = 0.65
SWEP.ProneSpreadMultiplier = 0.55
SWEP.StandMoveSpreadMultiplier = 1.25
SWEP.SneakMoveSpreadMultiplier = 1.15
SWEP.CrouchMoveSpreadMultiplier = 1.05
SWEP.JumpSpreadMultiplier = 3

SWEP.HasBayonet = true
SWEP.HasBipod = false
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 50
SWEP.BayonetDamage = 100

-- Rifle grenade (optional)
-- SWEP.RifleGrenadeEntity = "mcv_proj_riflegrenade_vc"
-- SWEP.RifleGrenadeForce = 2000
-- SWEP.Secondary.Automatic = true
-- SWEP.Secondary.ClipSize = 1
-- SWEP.Secondary.Ammo = "smg1_grenade"
-- SWEP.Secondary.DefaultClip = 1
-- SWEP.SoundGrenadeShot = "PORT_Bolt.GrenadeShot"

-- TODO: penetration ----------------------------------------------------------

SWEP.MetalPenetrationDepth = 10
SWEP.GlassPenetrationDepth = 16
SWEP.ConcretePenetrationDepth = 12
SWEP.WoodPenetrationDepth = 20
SWEP.OtherPenetrationDepth = 14

SWEP.MetalDamageModifier = 1.5
SWEP.GlassDamageModifier = 1.1
SWEP.ConcreteDamageModifier = 1.7
SWEP.WoodDamageModifier = 1.2
SWEP.OtherDamageModifier = 1.2

-- TODO: sounds (declare these in lua/autorun/port_sounds_<class>.lua) --------

SWEP.SoundSingleShot = "PORT_Bolt.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = "PORT_Bolt.ReloadThirdPerson"
SWEP.SoundReloadLoopThirdPerson = "PORT_Bolt.ReloadLoopThirdPerson"
SWEP.SoundCycleThirdPerson = "PORT_Bolt.CycleThirdPerson"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundGrenadeShot = ""
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
        cycle = ACT_VM_RELOAD_INSERT_PULL, -- the bolt work
        reload = ACT_VM_RELOAD,            -- clip pass
        reload_empty = ACT_VM_RELOADEMPTY,
        reload_insert = ACT_VM_RELOAD_INSERT,
        reload_insert_empty = ACT_VM_RELOAD_INSERT_EMPTY,
        bash = ACT_VM_HITCENTER,
        -- bayonet_swing = ACT_VM_HITLEFT,
        -- bayonet_on = ACT_VM_ATTACH_SILENCER,
        -- bayonet_off = ACT_VM_DETACH_SILENCER,
    },

    events = {
        -- Time the bolt's eject/foley when the model has no event track:
        -- cycle = {
        --     { t = 0.35, sound = "PORT_Bolt.BoltUp" },
        --     { t = 0.60, sound = "PORT_Bolt.BoltBack" },
        --     { t = 0.95, sound = "PORT_Bolt.BoltForward" },
        -- },
    },

    hooks = {
        -- Eject the hull at the bolt's backstroke on event-track-less models:
        -- OnRoleEvent = function(self, role, ev)
        --     if role == "cycle" and ev.data and ev.data.kind == "eject" then
        --         self:DoEject()
        --     end
        -- end,
    },
})
