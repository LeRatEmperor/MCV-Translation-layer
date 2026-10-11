--[[---------------------------------------------------------------------------
    MCVPort template — SHOTGUN (pump action, shell-by-shell reload)

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

    Shotgun specifics (docs/reload-ammo.md):
      - ShotgunReload = true switches to the shell-insertion state machine:
        reload_start -> insert loop -> finish, driven by ACT_SHOTGUN_*
        animations and the reload_start / reload_insert / reload_finish roles.
      - ReloadInsertTime is when, during the insert animation, a shell actually
        leaves the hand (in seconds — derive it from the source frame count
        divided by the sequence's fps, like the Type 17's 14/30).
      - NoEjectOnShoot = true moves brass ejection to the pump cycle, which is
        what most pump models expect.
      - SlamFire = true enables M1897-style hold-trigger pumping.
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = false -- TODO: set true once the port is filled in

-- TODO: names and basic information
SWEP.PrintName = "Shotgun Port"
SWEP.Category = "MCV Ports"
SWEP.Country = ""
SWEP.SubCategory = "Shotguns"
SWEP.Caliber = "12 Gauge"

SWEP.Slot = 2
SWEP.HoldType = "shotgun"
SWEP.AimHoldType = "shotgun"
SWEP.SprintHoldType = "passive"

SWEP.ViewModel = ""          -- TODO: models/.../v_shotgun.mdl
SWEP.WorldModel = ""         -- TODO: models/.../w_shotgun.mdl

SWEP.BodyGroups = ""
SWEP.WorldModelBodyGroups = ""

-- TODO: stats ---------------------------------------------------------------

SWEP.DamageGeneric = 20      -- PER PELLET; a buckshot cone multiplies this
SWEP.DamageHeadMultiplier = 2.5
SWEP.DamageChestMultiplier = 1.5
SWEP.DamageStomachMultiplier = 1.25
SWEP.DamageLegMultiplier = 0.9
SWEP.DamageArmMultiplier = 0.85

SWEP.Num = 8                 -- pellets per shot
SWEP.MuzzleVelocity = 400
SWEP.RangeModifier = 0.5     -- pellets shed damage fast

SWEP.Firemodes = {
    MCV.FIREMODE_PUMP
}

SWEP.ShotgunReload = true    -- shell-by-shell insertion state machine
SWEP.ShotgunReloadEmptyStartAnimation = true -- dedicated empty start anim?
SWEP.ShotgunReloadRounds = 4 -- shells per insert animation
SWEP.ReloadInsertTime = 15 / 30 -- TODO: seconds into the insert when a shell
                                -- seats (source frame / sequence fps)
SWEP.HasEmptyReload = true   -- chambering a round after fully empty

SWEP.LastShotAnimation = false
SWEP.NoEjectOnShoot = true   -- brass leaves on the pump, not the shot
SWEP.SlamFire = false        -- true for M1897-style hold-trigger pumping

SWEP.MagInTime = 0.5         -- only used for non-shell foley timing
SWEP.MagInTimeEmpty = 0.5

SWEP.ViewSlideRecoilUp = 3
SWEP.ViewSlideRecoilRight = 0.84
SWEP.ViewSlideRecoilIronsightUp = 2.24
SWEP.ViewSlideRecoilIronsightRight = 0.64

SWEP.RecoilPushbackValue = 2.5

SWEP.ShakeScale = 3
SWEP.ShakeFreq = 30
SWEP.ShakeDuration = 0.6

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 1
SWEP.IronsightFov = 90 - 15
SWEP.IronsightWalkBobbingStrength = -0.25

SWEP.MovementPoseWalk = 148
SWEP.MovementPoseSprint = 244
SWEP.MovementPoseSighted = 148

SWEP.HasScope = false
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(0, -2, 0.05) -- TODO: sight alignment
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, -1, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 8.25           -- outer cone; ironsighted tightens it
SWEP.SpreadIronsighted = 2.75

SWEP.FireRate = 70           -- rounds per minute of the ACTION

SWEP.CrosshairMinDistance = 6
SWEP.CrosshairDeltaDistance = 8

SWEP.WeaponWeight = 3.2

SWEP.Primary.Ammo = "buckshot"
SWEP.Primary.ClipSize = 8
SWEP.Primary.Chamber = 1     -- shell on the carrier
SWEP.Primary.DefaultClip = 32
SWEP.Primary.Automatic = true

SWEP.NearwallDistance = 50

SWEP.CrouchSpreadMultiplier = 1
SWEP.ProneSpreadMultiplier = 1
SWEP.StandMoveSpreadMultiplier = 1
SWEP.SneakMoveSpreadMultiplier = 1
SWEP.CrouchMoveSpreadMultiplier = 1
SWEP.JumpSpreadMultiplier = 1

SWEP.HasBayonet = false
SWEP.HasBipod = false
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 50

-- TODO: penetration ----------------------------------------------------------

SWEP.MetalPenetrationDepth = 3
SWEP.GlassPenetrationDepth = 8
SWEP.ConcretePenetrationDepth = 5
SWEP.WoodPenetrationDepth = 13
SWEP.OtherPenetrationDepth = 6

SWEP.MetalDamageModifier = 1.7
SWEP.GlassDamageModifier = 1.3
SWEP.ConcreteDamageModifier = 1.9
SWEP.WoodDamageModifier = 1.4
SWEP.OtherDamageModifier = 1.4

-- TODO: sounds (declare these in lua/autorun/port_sounds_<class>.lua) --------

SWEP.SoundSingleShot = "PORT_Shotgun.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""        -- shell insertion loop foley, first person
SWEP.SoundReloadThirdPerson = "PORT_Shotgun.ReloadThirdPerson"
SWEP.SoundReloadLoopThirdPerson = "PORT_Shotgun.ReloadLoopThirdPerson"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundNearlyEmpty = "PORT_Generic.NearlyEmptyClick"
SWEP.SoundEmpty = "PORT_Generic.ClipEmpty_09"

SWEP.SoundCycleThirdPerson = "PORT_Shotgun.PumpThirdPerson"

-- TODO: particles -------------------------------------------------------------

SWEP.MuzzleParticle = "vietnam_muzzleflash_shotgun_type1_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_shotgun_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_shotgun_type1_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_shotgun_type1_fp_is_smoke"
SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_shotgun_type1_tp"

SWEP.EjectBrassType = 2      -- shotgun hull selector
SWEP.EjectBrassTrail = "vietnam_weaponeffect_shelleject_trail"
SWEP.EjectBrassParticle = "vietnam_weaponeffect_shelleject_side"

SWEP.TracerParticle = "vietnam_tracer_shotgun_green_primary"
SWEP.TracerParticle2 = "vietnam_tracer_shotgun_green_secondary"
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
        reload_start = ACT_SHOTGUN_RELOAD_START,
        reload_insert = ACT_VM_RELOAD_INSERT,       -- shell goes in
        reload_insert_empty = ACT_VM_RELOAD_INSERT_EMPTY,
        reload_finish = ACT_SHOTGUN_RELOAD_FINISH,
        pump = ACT_SHOTGUN_PUMP,                    -- the rack
        bash = ACT_VM_HITCENTER,
    },

    events = {
        -- Models with unreadable event tracks can time their pump foley:
        -- pump = {
        --     { t = 0.25, sound = "PORT_Shotgun.PumpBack" },
        --     { t = 0.45, sound = "PORT_Shotgun.PumpForward" },
        -- },
    },

    hooks = {
        -- Eject the hull during the pump when the model has no eject event:
        -- OnRoleEvent = function(self, role, ev)
        --     if role == "pump" and ev.data and ev.data.kind == "eject" then
        --         self:DoEject()
        --     end
        -- end,
    },
})
