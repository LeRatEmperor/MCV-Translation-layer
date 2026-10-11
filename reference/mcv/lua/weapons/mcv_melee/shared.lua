include("mcv/weapon_common/load.lua")

// Knives, bayonets, machetes, shovels, fists, wrench. Left click slashes, right click
// stabs (heavier), sprint + attack charges, USE + attack throws the blade (models with a
// throw animation), the wrench repairs vehicles with right click.

SWEP.Base = "weapon_base"
SWEP.Spawnable = false

SWEP.SubCategory = "Melee"
SWEP.Slot = 0

SWEP.HoldType = "knife"
SWEP.SprintHoldType = "normal"
SWEP.AimHoldType = "knife"

SWEP.ShootGesture = ACT_HL2MP_GESTURE_RANGE_ATTACK_KNIFE
SWEP.ChargeGesture = ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND

// Damage and reach (the game's DamageGeneric / DamageGenericAlt, MeleeRange / MeleeRangeAlt)
SWEP.DamageGeneric = 42
SWEP.DamageGenericAlt = 63 // stab; defaults to 1.5x the slash
SWEP.MeleeRange = 56
SWEP.MeleeRangeAlt = 64
SWEP.ChargeDamageMultiplier = 2
SWEP.MeleeHullSize = 12

SWEP.SlashRate = 150 // swings per minute
SWEP.StabRate = nil  // stabs and charge hits per minute; the swing rate when it is not set
SWEP.HitDelay = 0.12 // seconds into the swing animation when the blade connects
SWEP.StabHitDelay = 0.2

SWEP.CanThrow = true
SWEP.ThrowForce = 1600
SWEP.ThrowDamage = nil // defaults to DamageGenericAlt
SWEP.ThrownEntity = "mcv_thrown_melee"

SWEP.CanRepair = false
SWEP.RepairPerSecond = 40

// Sounds (game SoundData: melee_hit, melee_hit_world, special1 = charge / thrust hit flesh,
// special2 = charge / thrust hit world)
SWEP.SoundHitFlesh = "MCV_Weapon_M1942.Stab"
SWEP.SoundHitWorld = "MCV_Weapon_M1942.Hit"
SWEP.SoundThrustFlesh = "MCV_Weapon_M1942.ThrustStab"
SWEP.SoundThrustWorld = "MCV_Weapon_M1942.ThrustHit"
SWEP.SoundSwing = ""

// Sequence names (auto-detected from the model where a list is given)
SWEP.SequencesSlash = {"slash", "slash2", "swing_a", "swing_b", "swing_c"}
SWEP.SequencesMiss = {"miss", "miss2"}
SWEP.SequencesStab = {"stab", "swing_hard"}
SWEP.SequenceChargeStart = "stab_charge"
SWEP.SequenceChargeLoop = "stab_charge_loop"
SWEP.SequencesChargeAttack = {"stab_charge_attack", "stab", "swing_hard"}
SWEP.SequenceThrow = "throw"
SWEP.SequenceThrowStart = "throw_start"
SWEP.SequenceThrowLoop = "throw_loop"
SWEP.SequenceThrowCancel = "throw_hold_end"
SWEP.SequenceRun = "run"
SWEP.SequenceIdleToRun = "idletorun"
SWEP.SequenceRunToIdle = "runtoidle"
SWEP.SequenceRepairStart = "idletorepair"
SWEP.SequenceRepairLoop = "repair"
SWEP.SequenceRepairEnd = "repairtoidle"

SWEP.Primary.Ammo = "none"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = true

SWEP.DrawCrosshair = true

AddCSLuaFile()

MCV.IncludeWeaponModules("weapons/mcv_melee")
