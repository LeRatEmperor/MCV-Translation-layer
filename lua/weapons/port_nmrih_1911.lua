--[[---------------------------------------------------------------------------
    MCVPort — Colt M1911 (TFA NMRiH port, revision 2)

    PORT OF:    TFA NMRiH "Colt M1911" (base tfa_nmrih_base_fa)
    SOURCE:     the weapon's shared.lua + the decompiled viewmodel QC
                (v_fa_1911.qc, Crowbar 0.74), received 2026-10-12
    ASSETS:     models/weapons/tfa_nmrih/{v,w}_fa_1911.mdl — copy the models
                into this addon (or keep the source addon mounted); NO TFA lua
                is required at runtime.

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
        Tier-2 candidate. All QC event times below are frame/fps at 1.0x.
    7.  ViewModelBoneMods dropped (TFA-only system; c-hands are already on via
        weapon_common shared.lua:182, so hands still render). The "MagLite"
        bone TFA hid has no bodygroup (the QC's only bodygroup is the whole
        reference mesh) — if a flashlight shows up on the model, the fix is
        recompiling the model without it, not lua.
    8.  TFA SafetyPos / InspectPos dropped (no MCV safety/inspect systems; F
        is bash). The model's "Shove" carries ACT_VM_HITCENTER, so MCV's bash
        and the "AmmoCheck" fidget (ACT_VM_FIDGET) resolve natively.
    9.  Walk / sprint animations: SOLVED by the layer's discrete movement
        bridge (lua/mcvport/sh_movement.lua, movement = true below). The
        model's full animset is bound by name: Walk/Walk_Empty,
        Sprint_/Sprint_Empty_ (trailing underscores are as authored), the
        Idle_to_Sprint / Sprint_to_Idle transitions with their empty
        variants, and Idle_empty for the slide-back idle. The maglite
        variants (Walk_flash, *_maglite, Light_On/Off) are ignored — no MCV
        flashlight system.
    10. fire_last = "Fire_Last" straight from the QC: MCV requests
        ACT_VM_SHOOTLAST when firing the last round (sh_shoot.lua:110-111);
        the model instead maps Fire_Last to ACT_VM_PRIMARYATTACK_EMPTY, so
        the role binds the sequence name first and the activity as fallback.
    11. Brass: EjectBrassType 18 (.45 ACP — models/weapons/shells/
        shell_x45apc.mdl; the full table is MCV.ShellTypes,
        reference sh_common.lua:82-176). The model's own engine brass event
        ("45acp Eject 140") spawns an error model in GMod; the fx bridge
        blocks it and MCV's code-side DoEject lands on the model's eject
        attachment via the attachments table below. The model's ports are
        named "1" (muzzle) and "2" (ejection), the HL2 convention.
    12. Foley mode "qc": the model's sequences carry their own 5004 sound
        events with exact frame timings (clipout @ 14/30 = 0.47s, clipin @
        51/30 = 1.70s, SlideBack @ 78/30 = 2.60s, SlideForward @ 84/30 =
        2.80s). While the soundscripts resolve, they play themselves — no
        synthetic events needed. If the foley is ever silent (source mod
        unmounted and wavs not copied), set foley = "synthetic" and enable
        the commented events block below, which carries the same timings.
    13. Sounds: SoundSingleShot = "Weapon_1911.Single" — the NMRiH
        soundscript name, which the TFA NMRiH pack defines (GMod mounts
        addon scripts/game_sounds + lua sound.Add). This works TODAY with
        the TFA pack mounted. Severing fully later: copy the 1911 wavs into
        sound/port/nmrih/1911/, point them at the PORT_1911.* declarations
        in lua/autorun/port_sounds_nmrih_1911.lua, and swap the slot below.
        Never declare our own sound.Add under the NMRiH names — a later
        registration wins and would clobber the pack's working definition.
    14. View offsets: TFA used VMPos_Additive = false (sighting REPLACES the
        base offset), which matches MCV's CustomPos -> IronsightPos switch, so
        the vectors carried over 1:1 on the same axes. IronFOV 80 ->
        IronsightFov 80. ViewModelFOV 50 is a native MCV field (mcv_m38_s).
        Fine-tune alignment in-game.
    15. Capacity 7+1 (TFA ClipSize 7; NMRiH chambering) -> ClipSize 7,
        Chamber 1, DefaultClip 21 (three magazines, as TFA shipped it).
    16. Reload timings from the QC (fps 30): MagOutTime 0.47, MagInTime
        1.70 — both flat fields drive MCV's counter pose params; the ammo
        itself transfers at animation end (audit: non-shotgun mags transfer
        once at anim end).
    17. The iron-sight sequences (Idle_Iron, Fire_Iron_*, Idle_to_Iron...) exist
        on the model but are NOT bound: MCV's vector ironsights own the sight
        pose, exactly as TFA drove this model. Binding them is a Tier-2 idea.
        Draw_first (slide rack on first deploy) is likewise unbound — MCV has
        no first-draw concept. The suicide sequence set is ignored.
    18. Third-person reload sound left empty — NMRiH's foley is viewmodel
        only (CHAN on the VM), and MCV's foley bank has no 1911. Silent
        rather than wrong-caliber noise; borrow an MCV generic later if it
        bothers.
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

SWEP.BodyGroups = ""

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

SWEP.LastShotAnimation = true -- Fire_Last: slide locks back on the last round

-- Reload timings from the QC (fps 30; judgment call 16)
SWEP.MagInTime = 1.7
SWEP.MagInTimeEmpty = 1.7
SWEP.MagOutTime = 0.47
SWEP.MagOutTimeEmpty = 0.47

-- View slide from recoil (judgment call 3)
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

SWEP.IronsightPos = Vector(-2.53, -1, 1.08) -- judgment call 14
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

SWEP.BashDamage = 25

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

-- Sound (judgment calls 12-13, 18)
SWEP.SoundSingleShot = "Weapon_1911.Single" -- NMRiH script; TFA pack defines it
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = ""
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

SWEP.EjectBrassType = 18 -- .45 ACP (judgment call 11)
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
    -- Every binding below is the decompiled QC's own sequence/activity pair;
    -- activity-first where the model is activity-mapped (the NMRiH animset is
    -- fully mapped), name-first for the activities GMod's enum doesn't carry
    -- (the _EMPTY family, WALK/SPRINT, DRYFIRE).
    anims = {
        idle           = ACT_VM_IDLE,          -- "Idle"
        idle_empty     = "Idle_empty",         -- slide locked back
        draw           = ACT_VM_DRAW,          -- "Draw"
        holster        = ACT_VM_HOLSTER,       -- "Holster"
        fire           = ACT_VM_PRIMARYATTACK, -- "Fire"
        fire_last      = { "Fire_Last", ACT_VM_PRIMARYATTACK_EMPTY },
        fire_empty     = "Fire_Empty",         -- dry-fire click (ACT_VM_DRYFIRE)
        reload         = ACT_VM_RELOAD,        -- "Reload"
        reload_empty   = ACT_VM_RELOAD_EMPTY,  -- "Reload_Dry"
        -- bash ("Shove", ACT_VM_HITCENTER) and fidget ("AmmoCheck",
        -- ACT_VM_FIDGET) resolve natively through the default activities

        -- discrete movement set (judgment call 9)
        walk             = "Walk",
        walk_empty       = "Walk_Empty",
        sprint           = "Sprint_",           -- trailing underscore, as authored
        sprint_empty     = "Sprint_Empty_",
        sprint_in        = "Idle_to_Sprint",
        sprint_in_empty  = "Idle_to_Sprint_Empty",
        sprint_out       = "Sprint_to_Idle",
        sprint_out_empty = "Sprint_to_Idle_Empty",
    },

    -- this model's attachment names: "1" = muzzle, "2" = ejection port
    -- (HL2 convention; MCV expects "muzzle"/"eject" — judgment call 11)
    attachments = {
        muzzle = "1",
        eject  = "2",
    },

    -- walk/sprint/idle_empty ride the idle loop via sh_movement.lua
    movement = true,

    -- the model's own 5004 events carry the reload foley with exact timings
    -- (judgment call 12); switch to "synthetic" + the events block below if
    -- the soundscripts ever stop resolving
    foley = "qc",

    -- Synthetic foley fallback — QC frame timings, ready to enable:
    -- swap foley to "synthetic" above and uncomment. Sound names point at
    -- the sever-later declarations in port_sounds_nmrih_1911.lua.
    -- events = {
    --     reload = {
    --         { t = 0.47, sound = "PORT_1911.MagOut" },   -- clipout  @ 14/30
    --         { t = 1.70, sound = "PORT_1911.MagIn" },    -- clipin   @ 51/30
    --     },
    --     reload_empty = {
    --         { t = 0.47, sound = "PORT_1911.MagOut" },   -- clipout  @ 14/30
    --         { t = 1.70, sound = "PORT_1911.MagIn" },    -- clipin   @ 51/30
    --         { t = 2.60, sound = "PORT_1911.SlideBack" },   -- @ 78/30
    --         { t = 2.80, sound = "PORT_1911.SlideForward" }, -- @ 84/30
    --     },
    -- },

    hooks = {
        -- none needed: everything this weapon does is flat fields + roles
    },
})
