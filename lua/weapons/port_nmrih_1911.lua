--[[---------------------------------------------------------------------------
    MCVPort — Colt M1911 (first live port through the translation layer)

    PORT OF:    TFA NMRiH "Colt M1911" (base tfa_nmrih_base_fa)
    SOURCE:     the weapon's shared.lua, received 2026-10-12
    ASSETS:     models/weapons/tfa_nmrih/{v,w}_fa_1911.mdl — copy the models
                into this addon (or keep the source addon mounted); NO TFA lua
                is required at runtime. Same for the wavs referenced by
                lua/autorun/port_sounds_nmrih_1911.lua.

    JUDGMENT CALLS (what future-you reads before touching anything):

    1.  Damage 35 = TFA Primary.Damage verbatim. Hitbox multipliers are the
        MCV pistol standard (identical on mcv_tt33 / mcv_cz52).
    2.  Spread: TFA's 0.02 / 0.01 cone values live on a different scale than
        MCV's crosshair-degree system, so they were calibrated, not copied:
        5.0 hip / 2.0 sighted sits between cz52 (6.75/2.5) and TFA's
        laser-flat accuracy. Tune to taste.
    3.  Recoil: TFA KickUp .5 / KickDown .45 / KickHorizontal .2 mapped onto
        MCV's fields at .45-ACP magnitude (slide values just above cz52,
        ShakeScale 0.7). TFA StaticRecoilFactor (eye-angle punch) has no MCV
        home — dropped.
    4.  TFA spread bloom (SpreadMultiplierMax / Increment / Recovery) dropped —
        MCV's native stance/movement multipliers govern cone growth.
    5.  Range: TFA max-travel 6561u + 50% falloff point became RangeModifier
        0.79 (damage retained per 500u, heavy pistol class) + MuzzleVelocity
        253 m/s (real .45 ACP).
    6.  TFA SequenceRateOverride (reload x1.25, sprint x1.5, holster x1.25)
        DROPPED — the layer plays sequences at 1.0x; per-role rate is a
        Tier-2 candidate. All event times below assume 1.0x playback.
    7.  ViewModelBoneMods dropped (TFA-only system; c-hands are already on via
        weapon_common shared.lua:182, so hands still render). The "MagLite"
        bone TFA hid needs checking: if a maglite shows on the model, find its
        bodygroup index and set SWEP.BodyGroups below.
    8.  TFA SafetyPos / InspectPos dropped (no MCV safety/inspect systems; F
        is bash, like native MCV pistols). BashDamage 25 = template default —
        TFA set no bash stat.
    9.  The model HAS Walk / walk_empty / Sprint_* / holster sequences (the
        TFA file proves it) but MCV expresses movement through pose
        parameters — a foreign model runs discrete-mode, so no VM walk/sprint
        anims. Known, accepted limitation (docs/translation-layer-spec.md).
    10. fire_last is bound name-first ("shoot_empty"): NMRiH models drive the
        core set by activity (the TFA file's ACT_VM_RELOAD rate overrides prove
        activity mapping), but NMRiH has no engine activity for the last-round
        shot. VERIFY after first spawn with `mcvport_report` — if fire_last
        shows missing, put the real sequence name first in the candidate list.
    11. Dry-fire: MCV's SoundEmpty / SoundNearlyEmpty slots are currently
        vestigial upstream (docs/weapon-definitions.md), so a synthetic
        fire_empty event plays GMod's built-in "Default.ClipEmpty" click to
        match TFA behavior. Swap to a PORT_1911.Empty script for fidelity.
    12. Sounds: PORT_1911.* scripts are declared in
        lua/autorun/port_sounds_nmrih_1911.lua with best-guess NMRiH wav
        paths — VERIFY them against the decompile. The empty/nearly-empty
        slots point at MCV's generic pistol clicks (native addon provides).
    13. View offsets: TFA used VMPos_Additive = false (sighting REPLACES the
        base offset), which matches MCV's CustomPos -> IronsightPos switch, so
        the vectors carried over 1:1 on the same axes: CustomPos/CustomAng =
        TFA VMPos/VMAng, IronsightPos/Ang = TFA IronSightsPos/Ang.
        IronFOV 80 -> IronsightFov 80. ViewModelFOV 50 is a native MCV field
        (see mcv_m38_s) — direct copy. Fine-tune alignment in-game.
    14. Capacity 7+1 (TFA ClipSize 7; NMRiH chambering) -> ClipSize 7,
        Chamber 1, DefaultClip 21 (three magazines, as TFA shipped it).
    15. Sequences fire on it: Reload timings (MagOut/MagIn/SlideRelease
        events) are estimates. Run `mcvport_report` in game, read the resolved
        reload / reload_empty durations, and set the event t values + the
        Mag*Time fields to match. Fixing = editing six numbers.
-----------------------------------------------------------------------------]]

AddCSLuaFile()

SWEP.Base = "mcvport_gun"

SWEP.Spawnable = true

-- Names and basic information

SWEP.PrintName = "Colt M1911"
SWEP.Category = "MCV Ports"
SWEP.Country = "USA"
SWEP.SubCategory = "Pistols"
SWEP.Caliber = ".45 ACP"

SWEP.Slot = 1
SWEP.HoldType = "pistol"
SWEP.AimHoldType = "revolver"
SWEP.SprintHoldType = "normal"

SWEP.ViewModel = "models/weapons/tfa_nmrih/v_fa_1911.mdl"
SWEP.WorldModel = "models/weapons/tfa_nmrih/w_fa_1911.mdl"
SWEP.ViewModelFOV = 50

SWEP.BodyGroups = "" -- TODO judgment call 7: hide the MagLite here if it renders

-- Stats

SWEP.DamageGeneric = 35 -- judgment call 1
SWEP.DamageHeadMultiplier = 3.5
SWEP.DamageChestMultiplier = 1.85
SWEP.DamageStomachMultiplier = 1.8
SWEP.DamageLegMultiplier = 1.25
SWEP.DamageArmMultiplier = 1.2

SWEP.MuzzleVelocity = 253 -- judgment call 5
SWEP.RangeModifier = 0.79

SWEP.Firemodes = {
    MCV.FIREMODE_SEMI
}

SWEP.LastShotAnimation = true -- shoot_empty: slide locks on the last round

-- Reload timings: mag swap with slide release when empty. TODO judgment call
-- 15: verify against the resolved sequence durations from mcvport_report.
SWEP.MagInTime = 1.8
SWEP.MagInTimeEmpty = 2.3
SWEP.MagOutTime = 0.7
SWEP.MagOutTimeEmpty = 0.7

-- View slide from recoil (judgment call 3; cosmetic on foreign models,
-- live values if the model is ever MCV-rigged)
SWEP.ViewSlideRecoilUp = 1.9
SWEP.ViewSlideRecoilRight = 0.75

SWEP.ViewSlideRecoilIronsightUp = 1.6
SWEP.ViewSlideRecoilIronsightRight = 0.62

SWEP.RecoilPushbackValue = 1.5

-- Camera shake from recoil
SWEP.ShakeScale = 0.7
SWEP.ShakeFreq = 50
SWEP.ShakeDuration = 0.35

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.8 -- TFA IronSightsMoveSpeed 0.8
SWEP.IronsightFov = 80          -- TFA Secondary.IronFOV 80
SWEP.IronsightWalkBobbingStrength = -0.25
SWEP.MovementPoseWalk = 161
SWEP.MovementPoseSprint = 260
SWEP.MovementPoseSighted = 130

SWEP.HasScope = false
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(-2.53, -1, 1.08) -- judgment call 13
SWEP.IronsightAng = Angle(0.419, 0.025, 0)

SWEP.CustomPos = Vector(1.5, 0, -1)
SWEP.CustomAng = Angle(0, 0, -2)

SWEP.Spread = 5     -- judgment call 2
SWEP.SpreadIronsighted = 2

SWEP.FireRate = 400 -- TFA Primary.RPM

SWEP.CrosshairMinDistance = 4
SWEP.CrosshairDeltaDistance = 4

SWEP.WeaponWeight = 1.1 -- kg, real M1911

SWEP.Primary.Ammo = "pistol"
SWEP.Primary.ClipSize = 7
SWEP.Primary.Chamber = 1 -- 7+1, NMRiH chambering
SWEP.Primary.DefaultClip = 21
SWEP.Primary.Automatic = true -- trigger semantics come from Firemodes

SWEP.NearwallDistance = 22

-- Bullet spread multiplier according to current stance
SWEP.CrouchSpreadMultiplier = 0.95
SWEP.ProneSpreadMultiplier = 0.9
SWEP.StandMoveSpreadMultiplier = 1.2
SWEP.SneakMoveSpreadMultiplier = 1.15
SWEP.CrouchMoveSpreadMultiplier = 1.1
SWEP.JumpSpreadMultiplier = 1.35

SWEP.HasBayonet = false
SWEP.HasBipod = false
SWEP.HasRifleGrenade = false

SWEP.BashDamage = 25 -- judgment call 8

-- Penetration (MCV pistol set, cz52-calibrated)
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

-- Sound (identity sounds declared in lua/autorun/port_sounds_nmrih_1911.lua;
-- empty clicks borrow MCV's generic pistol set — judgment call 12)
SWEP.SoundSingleShot = "PORT_1911.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = "" -- reload foley is the timed events below
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundNearlyEmpty = "MCV_Weapon_Generic.NearlyEmptyClick_Pistol"
SWEP.SoundEmpty = "MCV_Weapon_Generic.ClipEmpty_03"

-- Particles (MCV's own vietnam set ships with the base addon)
SWEP.MuzzleParticle = "vietnam_muzzleflash_pistol_type3_fp"
SWEP.MuzzleParticleSmoke = "vietnam_muzzleflash_pistol_type1_fp_smoke"
SWEP.MuzzleParticleIronsighted = "vietnam_muzzleflash_pistol_type3_fp_is"
SWEP.MuzzleParticleIronsightedSmoke = "vietnam_muzzleflash_pistol_type1_fp_is_smoke"
SWEP.MuzzleParticle3rdPerson = "vietnam_muzzleflash_pistol_type3_tp"

SWEP.EjectBrassType = 5
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
    -- Activity-first where the NMRiH model is activity-mapped (proven by the
    -- TFA file's ACT_VM_RELOAD rate overrides); name-first where NMRiH never
    -- had an engine activity. Judgment call 10: verify with mcvport_report.
    anims = {
        idle         = { ACT_VM_IDLE, "idle" },
        draw         = { ACT_VM_DRAW, "draw" },
        holster      = { "holster", ACT_VM_HOLSTER }, -- seq name proven by TFA
        fire         = { ACT_VM_PRIMARYATTACK, "shoot" },
        fire_last    = { "shoot_empty", ACT_VM_SHOOTLAST },
        fire_empty   = { "dryfire", "dry_fire" },
        reload       = { ACT_VM_RELOAD, "reload" },
        reload_empty = { ACT_VM_RELOAD_EMPTY, "reload_empty" },
    },

    -- First-person reload foley + the dry-fire click (NMRiH models carry no
    -- usable event tracks for these). t = seconds after the animation starts.
    -- TODO judgment call 15: these are estimates — read the resolved durations
    -- from `mcvport_report` and correct them.
    events = {
        reload = {
            { t = 0.7, sound = "PORT_1911.MagOut" },
            { t = 1.8, sound = "PORT_1911.MagIn" },
        },
        reload_empty = {
            { t = 0.7, sound = "PORT_1911.MagOut" },
            { t = 1.8, sound = "PORT_1911.MagIn" },
            { t = 2.3, sound = "PORT_1911.SlideRelease" },
        },
        fire_empty = {
            { t = 0.05, sound = "Default.ClipEmpty" }, -- judgment call 11
        },
    },

    hooks = {
        -- none needed: everything this weapon does is flat fields + roles
    },
})
