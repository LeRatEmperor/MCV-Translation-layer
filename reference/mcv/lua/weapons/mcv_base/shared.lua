include("mcv/weapon_common/load.lua")

// Spawnable
SWEP.Base = "weapon_base"
SWEP.NPCUsable = true

SWEP.ViewModelAkimbo = ""

SWEP.BayonetBodygroup = 0
SWEP.GrenadeLauncherBodygroup = 0
SWEP.GrenadeBodygroup = 0

SWEP.WorldBayonetBodygroup = 0
SWEP.WorldGrenadeLauncherBodygroup = 0
SWEP.WorldGrenadeBodygroup = 0

SWEP.BulletBodygroups = nil
SWEP.BeltBodygroups = nil // bodygroup indices of the belt segment in the feed tray (the game's "clamped*"), hidden when no rounds are shown

// Stats

SWEP.DamageGeneric = 43 // damage for other objects (i.e. explosive barrels, breakable walls, or characters with no hitboxes set)
SWEP.DamageHeadMultiplier = 1
SWEP.DamageChestMultiplier = 1
SWEP.DamageStomachMultiplier = 1
SWEP.DamageLegMultiplier = 1
SWEP.DamageArmMultiplier = 1

SWEP.RangeModifier = 0.950 // Every 500 units the damage is multiplied by rangemodifier

SWEP.Firemodes = {
    MCV.FIREMODE_SEMI
}

SWEP.VolleyCount = 2

SWEP.ShootGesture = ACT_HL2MP_GESTURE_RANGE_ATTACK_AR2
SWEP.ReloadGesture = ACT_HL2MP_GESTURE_RELOAD_AR2
SWEP.BashGesture = ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND

SWEP.AdjustableScopes = false

// Weapon must be manually cycled
SWEP.PlayCycleAnimation = false

// Burst fire (MCV.FIREMODE_BURST): BurstRounds per trigger pull at the gun's FireRate. Runaway:
// BurstCount is not reset on release until it reaches BurstRounds, so the burst finishes on its
// own; the trigger must then be let go and pulled again (NeedTriggerPress) after BurstRecovery.
SWEP.BurstRounds = 3
SWEP.BurstRecovery = 0.2
SWEP.SlamFire = false // pump with the trigger held and fire as the action closes (M1897, M37)
SWEP.LastShotAnimation = false
SWEP.ShotgunReloadEmptyStartAnimation = false
SWEP.AkimboDualSingleActionReload = false // Halfway between reloading, change hand
SWEP.AnimationHandlesHammer = false
SWEP.InvertAnimationHammer = false

SWEP.RevolverFiremodePose = false // Adds handling for revolver firemode poses

SWEP.TriggerDelayTime = 0.25

SWEP.ShotgunReload = false
SWEP.ShotgunAltReload = false // Clip-loading rifles use this set of anims for bullet loading
// The model has a clip reload and round-by-round loading animations (Kar98k, Springfield, Vz.24):

// Tracers: TracerParticle (the game's vietnam_tracer_<class>_primary) plays on every round for
// the smoke it trails, and the glowing streak is drawn by effects/mcv_tracer.lua on every
// TracerFrequency-th. TracerParticle2 is the game's _secondary, the streak with no smoke; both
// fields come from the weapon script and are kept as the game has them, but the streak is drawn
// rather than played, so nothing reads the second one at the moment.
SWEP.HasEmptyReload = true
SWEP.ShotgunReloadRounds = 1
// Seconds into a single insert before the round counts as in the gun rather than on its way
// there, off the insert animation's own AE_WPN_CLIP_TO_POSEPARAM. nil shows it straight away.
SWEP.InsertClipPoseTime = nil

SWEP.MagInTime = 0 // seconds into the reload animation when the new magazine / belt is in (the rounds shown jump to the new count)
SWEP.MagInTimeEmpty = 0
SWEP.MagOutTime = 0 // seconds in when the old one comes out (no rounds shown until MagInTime); 0 = off
SWEP.MagOutTimeEmpty = 0
SWEP.MagInTimeGrenade = 0.5
SWEP.MagInClip = false

SWEP.Silencer = false

// View slide from recoil
SWEP.ViewSlideRecoilUp = 1.35
SWEP.ViewSlideRecoilRight = 0.48

SWEP.ViewSlideRecoilIronsightUp = 1.35
SWEP.ViewSlideRecoilIronsightRight = 0.48

// Additive recoil per preceding shot in the current burst (first shot adds zero).
// Degrees of vertical kick / horizontal random-kick amplitude, for hip and ADS.
// Applied before category, bipod, dual-wield and volley recoil multipliers.
SWEP.ProgressiveRecoilUp = 0
SWEP.ProgressiveRecoilRight = 0

SWEP.RecoilPushbackValue = 1.5

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.85
SWEP.IronsightFov = 90 - 15

SWEP.HasScope = false
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4
SWEP.RTScopeMaterialIndex = 1
// What the eyepiece shows when it is not being looked through. Empty leaves the model's own
// material, which on all but one scoped rifle is the glass lens; the Vz.54 Meopta's lens mesh
// wears the reticle texture, and needs to be told where its glass is.
SWEP.ScopeIdleLensMaterial = ""

SWEP.IronsightPos = Vector(0, 0, 0)
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, 0, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 6.3
SWEP.SpreadIronsighted = 1.15

SWEP.FireRate = 300 // in rounds per minute
// A revolver fires at three rates: FireRate is the hammer-back single action, these two are
// the double action pull and fanning (the game's SecondaryFireRate and TertiaryFireRate).
// Zero falls back to FireRate.
SWEP.FireRate_DA = 0
SWEP.FireRate_Fan = 0
// Cycle animation duration comes from the model's original pump/bolt motion.
SWEP.CyclePostDelay = 0.65 // how long to wait after cycling before we can fire again

SWEP.ShootEntity = nil
SWEP.ShootEntityForce = 5000

SWEP.Primary.Ammo = "ar2"
SWEP.Primary.ClipSize = 10
SWEP.Primary.Chamber = 1
SWEP.Primary.DefaultClip = 30

SWEP.NearwallDistance = 40

// Bullet spread multiplier according to current stance
SWEP.CrouchSpreadMultiplier = 0.85
SWEP.ProneSpreadMultiplier = 0.75
SWEP.StandMoveSpreadMultiplier = 1.5
SWEP.SneakMoveSpreadMultiplier = 1.4
SWEP.CrouchMoveSpreadMultiplier = 1.35
SWEP.JumpSpreadMultiplier = 3.0

// Deferred actions this base can have waiting (mcv/weapon_common/sh_timers.lua). The order is what
// travels between the realms, so it is fixed: append, never insert.
SWEP.DeferredActions = {"BayonetOff", "AkimboSwap", "LauncherSwap", "BayonetLoop", "BayonetHit", "ReloadInsert"}
SWEP.HasRifleGrenade = false
SWEP.RifleGrenadeIsUBGL = false
SWEP.HasAkimbo = false

SWEP.RifleGrenadeEntity = "mcv_proj_riflegrenade"
SWEP.RifleGrenadeForce = 5000

SWEP.HasBipod = false

// Playback rate multiplier for fire animations. Models ported with the 60-frame idle base
// (the default of work/port_qc.py) need 0.5; models ported with --base-len match need 1.
SWEP.ShootAnimRate = 0.5

// Dual wield: drive per-hand recoil through the "recoil_r" / "recoil_l" pose parameters
// instead of switching sequences (models ported with port_qc.py --pose-recoil). Both hands
// recoil independently and the idle, walk and run layers keep playing underneath.
SWEP.AkimboPoseRecoil = false
SWEP.AkimboRecoilTime = 0.8 // seconds; should match the length of the hand's shoot animation

// Penetration
SWEP.MetalPenetrationDepth = 8
SWEP.GlassPenetrationDepth = 14
SWEP.ConcretePenetrationDepth = 10
SWEP.WoodPenetrationDepth = 18
SWEP.OtherPenetrationDepth = 12

SWEP.MetalDamageModifier = 1.55
SWEP.GlassDamageModifier = 1.15
SWEP.ConcreteDamageModifier = 1.75
SWEP.WoodDamageModifier = 1.25
SWEP.OtherDamageModifier = 1.25

// Sound
SWEP.SoundSingleShot = "MCV_Weapon_SKS.Single"
SWEP.SoundDoubleShot = ""
// What everyone but the person holding it hears. Their own foley rides the viewmodel's
// animation events, which nobody else gets, so without these a reload is silent to the room.
SWEP.SoundReloadThirdPerson = ""
SWEP.SoundReloadLoopThirdPerson = ""  // per round on a shotgun or stripper reload
SWEP.SoundCycleThirdPerson = ""       // a bolt or a pump worked between shots

SWEP.SoundReload = ""
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundGrenadeShot = "Weapon_SKS.RifleGrenade"
SWEP.SoundNearlyEmpty = "MCV_Weapon_Generic.NearlyEmptyClick"
SWEP.SoundEmpty = "MCV_Weapon_Generic.ClipEmpty_01"

// Particles
SWEP.MuzzleParticle = "vietnam_muzzleflash_rifle_type1_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_rifle_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_rifle_type1_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_rifle_type1_fp_is_smoke"

SWEP.MuzzleFlashLightTexture = "effects/flashlight_muzzleflash"

SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_rifle_type1_tp"

SWEP.NoEjectOnShoot = false

SWEP.EjectBrassType = 5
SWEP.EjectBrassTrail = "vietnam_weaponeffect_shelleject_trail"
SWEP.EjectBrassParticle = "vietnam_weaponeffect_shelleject_side"

SWEP.TracerParticle = "vietnam_tracer_rifle_primary"
SWEP.TracerParticle2 = "vietnam_tracer_rifle_secondary"

SWEP.TracerRandomness = 6
SWEP.TracerFrequency = 1

AddCSLuaFile()

MCV.IncludeWeaponModules("weapons/mcv_base")
