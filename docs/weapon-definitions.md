# MCV Base — Weapon Definition Format (Exhaustive Audit)

This document is the exhaustive audit of **how an individual weapon Lua file declares itself to
the MCV base** — the field surface, the inheritance machinery that fills in defaults, the
variant/derivation idioms, and the special-base definitions. For the translation layer this is
the **target schema**: a foreign SWEP written for another base (TFA, ARC9, FAS2, Mad Cows…)
will ultimately be converted *into* this shape, so completeness of the field catalogue in §3 is
the primary deliverable. Every behavioural claim cites `path/file.lua:LINE` relative to
`reference/mcv/lua/`. Cross-references: animation internals live in
[animation-system.md](animation-system.md) (§5 model contract, §10 animation-related fields) —
this doc does not duplicate them, it links them. Parallel sibling audits:
`gun-core.md`, `shooting-ballistics.md`, `reload-ammo.md`, `special-weapon-bases.md`,
`projectiles-entities.md`, `sound-system.md`, `effects.md`, `hud-settings.md`,
`support-systems.md`.

Upstream context: 244 spawnable classes over 19 categories (reference/mcv/weapon_list.md), all
generated from the game's own weapon scripts by `work/port_weapon.py` (the generator's banner is
on most files, e.g. weapons/mcv_csg.lua:7), then hand-tuned (AGENTS.md house rules forbid
regenerating whole files because the generator drops hand-tuned keys).

---

## 1. Architecture — Definition File Anatomy

### 1.1 The two file shapes

**Single file** — every gun is one `lua/weapons/mcv_<name>.lua` (167–190 lines) that assigns
onto the global `SWEP` table. The class name *is* the file name.

```lua
-- weapons/mcv_m38.lua:1-6
SWEP.Base = "mcv_base"
SWEP.Base = "mcv_base"   // duplicated line, generator artifact, harmless

SWEP.Spawnable = true

AddCSLuaFile()
```

**Folder** — the special bases and their derived weapons use
`lua/weapons/mcv_<base>/shared.lua` (see §5 for the full list of eight). Convention:
`shared.lua` holds the defaults and the header `include`, sibling `sh_*.lua` / `sv_*.lua` /
`cl_*.lua` files hold the logic and are auto-included by prefix
(mcv/weapon_common/load.lua:4-19).

### 1.2 The base chain — what `SWEP.Base = "mcv_base"` actually composes

The gun base `weapons/mcv_base/shared.lua` is **not** written as an ordinary SWEP that derives
from something; it composes three layers in file order:

```lua
-- weapons/mcv_base/shared.lua:1
include("mcv/weapon_common/load.lua")
-- ...226 lines of gun defaults...
-- weapons/mcv_base/shared.lua:226
MCV.IncludeWeaponModules("weapons/mcv_base")
```

1. **The weapon_common module template.** `mcv/weapon_common/shared.lua` describes itself as
   *"a module template, not a registered SWEP or an inheritance layer"*
   (mcv/weapon_common/shared.lua:1-5). `mcv/weapon_common/load.lua:21-33` runs it in a sandbox
   and **copies** the result into the real SWEP:

```lua
-- mcv/weapon_common/load.lua:21-33
if !MCV.WeaponCommon then
    local target = SWEP
    SWEP = {Primary = {}, Secondary = {}}
    local ok, err = pcall(include, "mcv/weapon_common/shared.lua")
    local common = SWEP
    SWEP = target
    if !ok then error(err) end
    MCV.WeaponCommon = common
end

for key, value in pairs(MCV.WeaponCommon) do
    SWEP[key] = istable(value) and table.Copy(value) or value
end
```

   Because the sandbox's `weapon_common/shared.lua` ends with
   `MCV.IncludeWeaponModules("mcv/weapon_common")` (line 191), the cached template contains both
   the defaults *and* every `sh_anim/sh_vm/sh_think/sh_deploy/sh_timers/sh_movement/sh_clock`
   function. The `table.Copy` per base is deliberate: *"Functions (and module hooks) are shared;
   mutable default tables belong to each base"* (load.lua:1-2). So each base gets a **deep copy**
   of `Primary`, `Secondary`, `Firemodes`, `DeferredActions`, etc. — this is why a base may
   rewrite `SWEP.Firemodes` without polluting its siblings.

2. **The base's own defaults** — the body of `weapons/mcv_base/shared.lua` (all gun stats,
   §3 below) overriding the weapon_common generics.

3. **The base's own modules** — `MCV.IncludeWeaponModules("weapons/mcv_base")` includes
   `sh_gun/sh_shoot/sh_reload/sh_think/sh_sights/sh_vm/sh_bash/sh_bipod/sh_akimbo/sh_ubgl/
   sh_bayonet_charge/sh_npc/sh_effects/sh_penetration/cl_pipscope` directly onto the base SWEP
   (mcv/weapon_common/load.lua:4-19: skips `shared.lua`/`load.lua`, dispatches on the `sv`/`cl`
   prefix, recurses into subfolders).

A weapon file then declares `SWEP.Base = "mcv_base"` and **GMod's built-in baseclass
inheritance** merges the finished `mcv_base` table under the weapon's own assignments. The
same three-step composition is repeated verbatim by `mcv_melee`, `mcv_throwable`,
`mcv_placeable`, `mcv_flamethrower`, `mcv_m79_base`, `mcv_binoculars`, `mcv_equipment_box`
(each folder's `shared.lua` starts with `include("mcv/weapon_common/load.lua")`). `mcv_base`
itself roots at the engine's `weapon_base` (weapons/mcv_base/shared.lua:4).

### 1.3 The nested-table inheritance trap (critical for variants)

GMod merges inherited nested tables **index by index**, not wholesale. Three separate defenses
exist in the base, and the translation layer must respect all of them:

- `SWEP:Initialize` dedupes `Firemodes`: *"GMod merges nested lists: a derived one-mode gun can
  inherit a duplicate second entry"* (mcv/weapon_common/sh_deploy.lua:143-157).
- `BulletBodygroups` is iterated with `pairs` + `isnumber(i)` guard because *"the BaseClass
  entry added by SWEP table inheritance"* pollutes sparse numeric keys
  (weapons/mcv_base/sh_vm.lua:136-140; AGENTS.md house rule).
- `FuseModes` on throwables: *"a weapon's shorter FuseModes still sees the base's later entries
  (the molotov's {0} read as {0, 5})"* — so `GetFuseModes` re-derives a single-mode list when
  `FuseImpact` (weapons/mcv_throwable/sh_throw.lua:32-38).

Practical rule: **when overriding any table-valued field in a derived SWEP, you are patching,
not replacing** — unless the layer runs before instances exist (`Initialize` rewrites
`self.Firemodes` per instance) or the table was deep-copied per base (load.lua:31-33).

### 1.4 The `MilitaryConflictVietnam` marker

`SWEP.MilitaryConflictVietnam = true` (mcv/weapon_common/shared.lua:184) is the flag every
global system greps for to recognise an MCV weapon: NPC weapon selection
(mcv/shared/sh_npc.lua:8), the random-weapon kit giver (mcv/shared/sh_random_weapons.lua:98),
third-person animation-event gestures (mcv/shared/sh_animevents.lua:31), bone-merged world
models (mcv/weapon_common/cl_worldmodel.lua:85,269), movement prediction
(mcv/weapon_common/sh_movement.lua:21,60), clock resets (mcv/weapon_common/sh_clock.lua:87),
and the flamethrower tank explosion (weapons/mcv_flamethrower/sh_flame.lua:253). A translated
weapon gets it for free from the weapon_common copy — but a translation shim that builds a
SWEP table by hand **must** set it or half the base silently ignores the weapon.

### 1.5 Ammo type availability

Custom ammo names used by `Primary.Ammo` are registered on both realms at load:
`mcv_grenade, mcv_molotov, mcv_mine, mcv_explosive_charge, mcv_flamethrower_fuel,
mcv_crossbowbolt, mcv_flareround, mcv_ammobox, mcv_medicbox, mcv_flame_cartridge`
(mcv/shared/sh_common.lua:64-80). Guns otherwise use engine ammo (`ar2`, `pistol`, `smg1`,
`357`, `buckshot`, `rpg_round`, `smg1_grenade`). The selectable launchers remap ammo by
firemode via `MCV.FiremodeAmmo` — HE → `smg1_grenade`, buckshot → `buckshot`
(mcv/shared/sh_common.lua:22-25).

---

## 2. Worked Example — `weapons/mcv_m38.lua` Line by Line

The Mosin-Nagant M38 is the canonical bolt-action: manual cycle, stripper clip, rifle grenade,
bayonet lug. Every chunk below is verbatim with the consuming code identified.

### 2.1 Identity (lines 1–26)

```lua
-- weapons/mcv_m38.lua:1-26
SWEP.Base = "mcv_base"
SWEP.Base = "mcv_base"

SWEP.Spawnable = true

AddCSLuaFile()

// Names and basic information
SWEP.PrintName = "Mosin-Nagant M38"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.Country = "Soviet Union"
SWEP.SubCategory = "Bolt-Action Rifles" -- classed as a carbine in MCV but putting it here to pad out the bolt actions category for our sake
SWEP.Caliber = "7.62x54mmR"

SWEP.Slot = 3

SWEP.ViewModel = "models/weapons/mcv/v_m38.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_m38.mdl"

SWEP.BodyGroups = "00100"
SWEP.WorldModelBodyGroups = "0010"
SWEP.BayonetBodygroup = 1
SWEP.GrenadeLauncherBodygroup = 2
SWEP.GrenadeBodygroup = 3

SWEP.WeaponSelectIcon = NULL
```

- `PrintName`/`Country`/`Caliber` feed the spawn-menu info box (mcv/weapon_common/cl_hud.lua:613,
  661-662). `SubCategory` does double duty: spawn-menu grouping **and** the key into the
  per-category stat-multiplier convars via `SWEP:StatMult` (mcv/weapon_common/shared.lua:80-82 →
  mcv/shared/sh_categories.lua:94-99). The comment shows the authors deliberately fudging the
  category — the category *is* the balance group.
- `BodyGroups` is the engine's digit-string form (`SetBodyGroups`, applied to the viewmodel on
  deploy, mcv/weapon_common/sh_vm.lua:29). `WorldModelBodyGroups` is the same set remapped onto
  the world model's own bodypart order — *"the M14 is the M21's model with the scope off, and
  it kept the scope in third person"* without it (mcv/weapon_common/shared.lua:85-89; applied
  server-side at sh_deploy.lua:184-186).
- `BayonetBodygroup`/`GrenadeLauncherBodygroup`/`GrenadeBodygroup` are viewmodel bodygroup
  **indices** toggled live when the bayonet/launcher state flips (weapons/mcv_base/sh_vm.lua:189-206).
- `WeaponSelectIcon = NULL` is **vestigial** — written by the generator into every gun, never
  read by MCV code (see §3.18).

### 2.2 Damage & ballistics (lines 28–55)

```lua
-- weapons/mcv_m38.lua:30-55
SWEP.DamageGeneric = 45 // damage for other objects (i.e. explosive barrels, breakable walls, or characters with no hitboxes set)
SWEP.DamageHeadMultiplier = 3.05
SWEP.DamageChestMultiplier = 2.8
SWEP.DamageStomachMultiplier = 2.7
SWEP.DamageLegMultiplier = 1.5
SWEP.DamageArmMultiplier = 1.4

SWEP.Num = 1

SWEP.MuzzleVelocity = 735

SWEP.RangeModifier = 0.955 // Every 500 units the damage is multiplied by rangemodifier

SWEP.Firemodes = {
    MCV.FIREMODE_BOLT
}

SWEP.LastShotAnimation = false
SWEP.MagInClip = true
SWEP.ShotgunReloadEmptyStartAnimation = false
SWEP.PlayCycleAnimation = true
SWEP.AnimationHandlesHammer = true
SWEP.InvertAnimationHammer = true

SWEP.RifleGrenadeEntity = "mcv_proj_riflegrenade_vc"
SWEP.RifleGrenadeForce = 2000
```

- `DamageGeneric` is the per-bullet base, scaled at fire time by
  `self:StatMult("damage")` (weapons/mcv_base/sh_shoot.lua:625). The five `Damage*Multiplier`s
  are applied per hitgroup inside `ApplyBulletDamage` (weapons/mcv_base/sh_penetration.lua:44-55).
- `MuzzleVelocity` (units/s) is the physical-bullet speed: `MCV.PhysicalBulletsEnabled` requires
  it > 0 (mcv/shared/sh_physbullets.lua:4, 67-68) and the HUD range readout uses it.
- `MCV.FIREMODE_BOLT` (value 6, mcv/shared/sh_common.lua:7) — one mode, so `+use +reload` does
  nothing (`#self.Firemodes <= 1`, sh_shoot.lua:767).
- `PlayCycleAnimation = true` is *the* bolt-action switch: it arms `NeedCycle` on every shot
  (sh_shoot.lua:168-170) and the think loop plays `ACT_VM_RELOAD_INSERT_PULL` as the bolt
  motion (weapons/mcv_base/sh_think.lua:112-132). `AnimationHandlesHammer = true` +
  `InvertAnimationHammer = true` hand the "cycle complete" moment to the model's baked hammer
  event (sh_shoot.lua:213; anim doc §5.6 — the M38 is one of the 8 models in
  `MCV.HammerEvents`).
- `RifleGrenadeEntity`/`RifleGrenadeForce` only matter because the (unquoted-here)
  `SWEP.HasRifleGrenade = true` at line 118 turned the feature on; the secondary fire path
  substitutes them for `ShootEntity`/`ShootEntityForce` (sh_shoot.lua:668-671).

### 2.3 Recoil, shake, sights, movement (lines 57–94)

```lua
-- weapons/mcv_m38.lua:58-94
SWEP.ViewSlideRecoilUp = 2.84
SWEP.ViewSlideRecoilRight = 0.48

SWEP.ViewSlideRecoilIronsightUp = 1.36
SWEP.ViewSlideRecoilIronsightRight = 0.24

SWEP.RecoilPushbackValue = 1.5

// Camera shake from recoil
SWEP.ShakeScale = 1
SWEP.ShakeFreq = 30
SWEP.ShakeDuration = 0.5

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.95
SWEP.IronsightFov = 90 - 15
SWEP.IronsightWalkBobbingStrength = -0.25
SWEP.MovementPoseWalk = 141
SWEP.MovementPoseSprint = 236
SWEP.MovementPoseSighted = 130

SWEP.HasScope = false
SWEP.ScopeMaterial = NULL
SWEP.ScopeFOV = 8
SWEP.ScopeFOV2 = 4

SWEP.IronsightPos = Vector(0, -3, 0)
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.CustomPos = Vector(0, -2, 0)
SWEP.CustomAng = Angle(0, 0, 0)

SWEP.Spread = 5
SWEP.SpreadIronsighted = 0.6

SWEP.FireRate = 600 // in rounds per minute
SWEP.CyclePostDelay = 0.9
```

- Recoil degrees: hip pair lerps to the ironsight pair by sight amount, plus
  `ProgressiveRecoil*` per preceding burst shot, then category/bipod/akimbo/volley multipliers
  (sh_shoot.lua:405-446). `RecoilPushbackValue` feeds the queued camera push
  (`QueueRecoilImpulse`, sh_shoot.lua:477; sh_movement.lua).
- `IronsightSpeedScale` converts to a transition time `0.2 / scale`
  (weapons/mcv_base/sh_sights.lua:3); `IronsightFov` is the aimed screen FOV used for zoom and
  mouse sensitivity (weapons/mcv_base/sh_gun.lua:41-58).
- `MovementPose*` are the values driven into the viewmodel's `player_movement` pose parameter
  (anim doc §4.2-4.3; mcv/weapon_common/sh_think.lua:63-86). They are **model-specific** —
  per-model numbers read off the ported runlayer blends.
- The `HasScope = false` block is present-but-inert: with no scope, `ScopeMaterial/ScopeFOV/
  ScopeFOV2` are never consulted (cl_pipscope.lua:46,105). The generator emits the block
  uniformly.
- `Spread` (hip cone, degrees-ish, `/100` at use — sh_shoot.lua:402) blends to
  `SpreadIronsighted` by the sight amount times stance multipliers (sh_shoot.lua:365-402).
- `FireRate = 600` here is **the shot cadence, not the cycle cadence**: the bolt adds
  `CyclePostDelay * cycle-duration` after the cycle animation (sh_think.lua:123). A 600 RPM
  number on a bolt gun *"describes the shot, not working the action"*
  (weapons/mcv_base/sh_npc.lua:33-37).

### 2.4 Ammo, stance, features (lines 96–136)

```lua
-- weapons/mcv_m38.lua:101-118
SWEP.Primary.Ammo = "357"
SWEP.Primary.ClipSize = 5
SWEP.Primary.Chamber = 0
SWEP.Primary.DefaultClip = 40
SWEP.Primary.Automatic = true

SWEP.NearwallDistance = 40
...
SWEP.CrouchSpreadMultiplier = 0.65
SWEP.ProneSpreadMultiplier = 0.55
SWEP.StandMoveSpreadMultiplier = 1.25
SWEP.SneakMoveSpreadMultiplier = 1.15
SWEP.CrouchMoveSpreadMultiplier = 1.05
SWEP.JumpSpreadMultiplier = 3

SWEP.HasBayonet = true
SWEP.HasRifleGrenade = true

SWEP.BashDamage = 50
SWEP.BayonetDamage = 100

SWEP.HasBipod = false
```

- `Primary.Chamber = 0` — no chambered round on top of the 5-round clip;
  `GetClip1Capacity() = ClipSize + Chamber` (sh_reload.lua:129-135). `DefaultClip = 40` = mag
  + starting reserve on fresh spawn.
- The six stance/movement spread multipliers are consumed in `GetStanceSpreadMultiplier`
  (sh_shoot.lua:238-242). `NearwallDistance` is currently **vestigial** (§3.18).
- `HasBayonet = true` gates the `+use +attack2` fix-bayonet toggle
  (mcv/weapon_common/sh_bash.lua:136-160); actually fixing one still requires carrying an
  `IsBayonet` melee weapon in the inventory (sh_bash.lua:111-119).
- `HasRifleGrenade = true` + the `Secondary.*` block at lines 182-185 (`smg1_grenade`, clip 1)
  arm the integral rifle-grenade mode, toggled with `+walk +use` (sh_ubgl.lua:26-36).

### 2.5 Penetration (lines 125–136)

```lua
-- weapons/mcv_m38.lua:126-136
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
```

Read **dynamically** by material group — the mat enum maps to a prefix and the field is
composed at runtime:

```lua
-- weapons/mcv_base/sh_penetration.lua:3-16
local materials = {
    [MAT_METAL] = "Metal", [MAT_GRATE] = "Metal", [MAT_VENT] = "Metal",
    [MAT_GLASS] = "Glass",
    [MAT_CONCRETE] = "Concrete", [MAT_TILE] = "Concrete",
    [MAT_WOOD] = "Wood",
}
...
function SWEP:GetPenetrationStats(mat)
    local name = materials[mat] or "Other"
    return math.max(self[name .. "PenetrationDepth"] or 0, 0) * self:StatMult("penetration"),
        math.max(self[name .. "DamageModifier"] or 1, 1), name
end
```

MAT_GRATE/VENT count as Metal; MAT_TILE counts as Concrete; everything unlisted is `Other`.
A translated weapon can supply any subset — the `or 0` / `or 1` fallbacks make missing groups
safe (though `OtherPenetrationDepth = 0` disables penetration entirely, §3.18 rules).

### 2.6 Sound & particles (lines 138–180)

```lua
-- weapons/mcv_m38.lua:139-149
SWEP.SoundSingleShot = "MCV_Weapon_M38.Single"
SWEP.SoundDoubleShot = ""
SWEP.SoundReload = ""
SWEP.SoundReloadThirdPerson = "MCV_Weapon_Foley_ThirdPerson_M38.Reload"
SWEP.SoundReloadLoopThirdPerson = "MCV_Weapon_Foley_ThirdPerson_M40.ReloadLoop"
SWEP.SoundCycleThirdPerson = "MCV_Weapon_Foley_ThirdPerson_M38.Cycle"
SWEP.SoundSpecial1 = ""
SWEP.SoundSpecial2 = ""
SWEP.SoundGrenadeShot = "MCV_Weapon_M38.RifleGrenade"
SWEP.SoundNearlyEmpty = "MCV_Weapon_Generic.NearlyEmptyClick"
SWEP.SoundEmpty = "MCV_Weapon_Generic.ClipEmpty_07"
```

- Only `SoundSingleShot`/`SoundDoubleShot` fire from the shot path (sh_shoot.lua:465-468, with
  automatic `"<name>Distant"` layering, sh_shoot.lua:480-498). The first-person reload/cycle
  foley is **not** here at all — it rides the viewmodel's own animation events through the
  `MCV_*` soundscripts (anim doc §5.5); the `*ThirdPerson` fields exist because *"nobody else
  gets"* the viewmodel's events (mcv/weapon_common/shared.lua:28-31, 43-78).
- `SoundSpecial1/2`, `SoundNearlyEmpty`, `SoundEmpty` are set but **never read** (§3.18).
- The commented-out particle blocks (lines 152-161) are the generator keeping the game's
  defaults visible; the live block swaps the rifle muzzle flash for the sniper-rifle one and
  sets `NoEjectOnShoot = true` (shell leaves on the bolt's own `eject` animation event instead,
  sh_shoot.lua:201-205) with `EjectBrassType = 8` (7.62x54mmR rimmed, mcv/shared/sh_common.lua:111-114).

### 2.7 Tracers & secondary (lines 176–185)

```lua
-- weapons/mcv_m38.lua:176-185
SWEP.TracerParticle = "vietnam_tracer_rifle_primary"
SWEP.TracerParticle2 = "vietnam_tracer_rifle_secondary"

SWEP.TracerRandomness = 6
SWEP.TracerFrequency = 1

SWEP.Secondary.Automatic = true
SWEP.Secondary.ClipSize = 1
SWEP.Secondary.Ammo = "smg1_grenade"
SWEP.Secondary.DefaultClip = 1
```

`TracerParticle` plays every round for its smoke trail; the glowing streak is drawn by
`effects/mcv_tracer.lua` on every `TracerFrequency`-th round of the magazine
(effects/mcv_tracer.lua:47, 89-93); `TracerParticle2` is currently unread
(weapons/mcv_base/shared.lua:66-70 comment). The `Secondary` block is the rifle-grenade
"magazine": `Clip2`/`Ammo2` are the grenade rounds (sh_reload.lua:113-127, sh_ubgl.lua).

---

## 3. The Complete Field Catalogue

Every field a weapon definition can set, grouped. "Default" cites where the default is
assigned; "Consumed" cites the principal read sites (file:line). Fields marked ◇ are **vestigial**
in Part 1 (defined/set but no Lua consumer — §3.18). The animation-contract fields
(`MovementPose*`, `Speed*`, `ShootAnimRate`, reload/hammer timing, bodygroup indices) are
catalogued here for schema completeness; their *behaviour* is specified in
[animation-system.md](animation-system.md) §4/§5/§10 and `reload-ammo.md` — do not re-derive
from this table alone.

### 3.1 Identity, spawn & category

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `Base` | string | — (each base sets `weapon_base`) | GMod baseclass merge; mcv_base/shared.lua:4 | `mcv_m38.lua:1` `"mcv_base"` |
| `Spawnable` | bool | `false` (weapon_common/shared.lua:7) | engine spawn menu | `mcv_m38.lua:4` `true` |
| `AdminOnly` | bool | `false` (weapon_common/shared.lua:8) | engine | (unused in Part 1 weapons) |
| `PrintName` | string | `""` (weapon_common/shared.lua:18) | cl_hud.lua:661 | `mcv_tt33.lua:8` `"TT-33"` |
| `Category` | string | `"Military Conflict: Vietnam"` (weapon_common/shared.lua:9) | engine spawn menu tree | `mcv_m38.lua:10` |
| `SubCategory` | string | `""` (weapon_common/shared.lua:20) | cl_subcategories spawn tree; `StatMult` key weapon_common/shared.lua:81; sh_categories.lua:94-99 | `mcv_m38.lua:12` `"Bolt-Action Rifles"` |
| `Country` | string | `""` (weapon_common/shared.lua:19) | cl_hud.lua:651,662 | `mcv_tt33.lua:10` `"Soviet Union"` |
| `Caliber` | string | `""` (weapon_common/shared.lua:21) | cl_hud.lua:613 | `mcv_m38.lua:13` `"7.62x54mmR"` |
| `Slot` | int | per-base (melee 0, pistol 1, primary 3, heavy/equip 4) | engine weapon-selection bucket | `mcv_tt33.lua:14` `1` |
| `WeaponWeight` ◇ | number | `3.85` (weapon_common/shared.lua:165) | — (informational, real-world kg) | `mcv_ptrd.lua:96` `17.3` |
| `IconOverride` | string | — | cl_hud.lua:136,710,715; cl_subcategories.lua:85; killicons fallback | `mcv_shanxi_type17.lua:25` `"entities/mcv_type17.png"` |
| `WeaponSelectIcon` ◇ | IMaterial | `NULL` (every weapon) | — | `mcv_m38.lua:26` |
| `MilitaryConflictVietnam` | bool | `true` (weapon_common/shared.lua:184) | 8+ global gates, §1.4 | (never overridden) |
| `NPCUsable` | bool | `false` common / `true` mcv_base (shared.lua:11 / mcv_base:5) | CanBePickedUpByNPCs weapon_common:13-15; sh_npc.lua:109,127; sh_npc.lua:8 | `mcv_binoculars/shared.lua:6` `false` |

Icons: with no `IconOverride`, the HUD falls back to `entities/<class>.png`
(cl_hud.lua:136,710) and the kill-icon system aliases each projectile to its firing weapon's
icon (mcv/client/cl_killicons.lua:13,30-36).

### 3.2 Models, bodygroups & skins

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `ViewModel` | string | `"models/weapons/mcv/v_sks.mdl"` (weapon_common:23) | engine; akimbo swap sh_deploy.lua:6-7; SafeMovementModels lookup sh_think.lua:79-80 | `mcv_tt33.lua:19` |
| `WorldModel` | string | `"models/weapons/mcv/w_sks.mdl"` (weapon_common:24) | engine; thrown/placed entity fallbacks sh_throw.lua:196, sh_place.lua:172,213,411-413 | `mcv_tt33.lua:22` |
| `ViewModelAkimbo` | string | `""` (mcv_base:7) | SyncViewModel sh_deploy.lua:7; precache sh_deploy.lua:168-170; anim model select sh_shoot.lua:4 | `mcv_tt33.lua:20` `"models/weapons/mcv/v_dual_tt33.mdl"` |
| `ViewModelFOV` | number | `80` (weapon_common:91) | MCV.ViewmodelFOV cl_viewsettings.lua:23 | `mcv_m38_s.lua:26` `80` |
| `SightedViewModelFOV` | number | `40` (weapon_common:92) | cl_viewsettings.lua:24 | `mcv_svd.lua:27` `30`; `mcv_ptrd_sniper.lua:30` `25` |
| `ViewModelZNear` | number/false | `false` (weapon_common:147) | custom near clip in `cam.Start3D` weapon_common/sh_vm.lua:66-69 | scoped weapons (mcv-2; no Part-1 weapon sets it, unverified) |
| `UseHands` | bool | `true` (weapon_common:182) | engine (C-hands on viewmodel) | (never overridden) |
| `BodyGroups` | string | `""` (weapon_common:84) | `vm:SetBodyGroups` sh_vm.lua:29 | `mcv_m38.lua:20` `"00100"` |
| `WorldModelBodyGroups` | string/nil | `nil` (weapon_common:89) | server `SetBodyGroups` sh_deploy.lua:184-186 | `mcv_m38.lua:21` `"0010"` |
| `BayonetBodygroup` | int | `0` (mcv_base:9) | vm:SetBodygroup sh_vm.lua:189-191 | `mcv_ak47.lua:27` `1` |
| `GrenadeLauncherBodygroup` | int | `0` (mcv_base:10) | sh_vm.lua:195-205 | `mcv_m38.lua:23` `2` |
| `GrenadeBodygroup` | int | `0` (mcv_base:11) | sh_vm.lua:200-206 | `mcv_m38.lua:24` `3` |
| `WorldBayonetBodygroup` | int | `0` (mcv_base:13) | world-model bayonet group (cl_worldmodel.lua; special-bases doc) | `mcv_ak47.lua:29` `1` |
| `WorldGrenadeLauncherBodygroup` | int | `0` (mcv_base:14) | world-model grenade group | (mcv-2) |
| `WorldGrenadeBodygroup` | int | `0` (mcv_base:15) | world-model grenade group | (mcv-2) |
| `BulletBodygroups` | table | `nil` (mcv_base:17) | round-counter bodygroups sh_vm.lua:136-148 (`pairs`+`isnumber`!) | `mcv_vz59b.lua:15-16` `for i=1,21 do SWEP.BulletBodygroups[i]={i,1} end` |
| `BeltBodygroups` | table | `nil` (mcv_base:18) | belt segment groups sh_vm.lua:150+ | `mcv_vz59b.lua:17` `{22}` |
| `MineBodygroups` | table | `{mine=0, stick=1}` (placeable:39) | sh_place.lua:197-201,443-450 | (default kept by mcv_rg42) |
| `ModelSkin` | int/nil | `nil` (throwable:10-16) | SetSkin on weapon + vm + thrown ent sh_throw.lua:10-17,215 | (mcv-2 grenades) |

### 3.3 Animation-contract fields (cross-ref anim doc §4, §5, §10)

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `HoldType` | string | `"ar2"` (weapon_common:94) | Think_HoldType sh_think.lua:155-178; gesture table weapon_common:103-115; NPC_Deploy sh_npc.lua:81 | `mcv_tt33.lua:17` `"pistol"` |
| `SprintHoldType` | string | `"passive"` (weapon_common:95) | sh_think.lua:159,169 | `mcv_tt33.lua:15` `"normal"` |
| `AimHoldType` | string | `"rpg"` (weapon_common:96) | sh_think.lua:165 | `mcv_tt33.lua:16` `"revolver"` |
| `HoldTypeNPC` | string | — | sh_npc.lua:81 | (rare; mcv-2) |
| `MovementPoseWalk` | number | `148` (sh_think.lua:53) | GetMovementPose sh_think.lua:64-71 | `mcv_tt33.lua:74` `161` |
| `MovementPoseSprint` | number | `245` (sh_think.lua:54) | sh_think.lua:64-71 | `mcv_tt33.lua:75` `260` |
| `MovementPoseSighted` | number | `130` (sh_think.lua:60) | sh_think.lua:75 | `mcv_ptrd.lua:73` `60` |
| `MovementPoseWalkMax` | number | `0.95` (sh_think.lua:55) | sh_think.lua:65 | (never overridden) |
| `SpeedRun` / `SpeedSprint` / `SpeedWalk` | number | `100`/`273`/`25` (sh_think.lua:39-41) | GetTargetSpeed/GetMovementPose sh_think.lua:68-101 | (melee uses SpeedSprintThreshold) |
| `SpeedSprintThreshold` | number | `150` (sh_think.lua:42) | hold-type + melee run sh_melee.lua:356-368 | (default) |
| `SpeedAcceleration` | number | `750` (sh_think.lua:43) | blend integration sh_think.lua:151 | (default) |
| `SightedSwayFraction` | number | `0.2` (sh_think.lua:61) | sh_think.lua:75 | (default) |
| `SafeMovementAnimations` | bool | — (model-list fallback sh_think.lua:79-80) | at-ease pose clamp sh_think.lua:81-83 | `mcv_svd_irons.lua:12` `true` |
| `ShootAnimRate` | number | `0.5` (mcv_base:165) | fire-anim playback rate sh_shoot.lua:66 | (default everywhere; 1 for `--base-len` ports) |
| `CyclePostDelay` | number | `0.65` (mcv_base:131) | post-cycle lock sh_think.lua:123 | `mcv_m38.lua:94` `0.9` |
| `TriggerDelayTime` | number | `0.25` (mcv_base:60) | DA release sh_think.lua:90 | (default) |
| `ShootGesture` | act/false | `ACT_HL2MP_GESTURE_RANGE_ATTACK_AR2` (mcv_base:37) | GetShootGesture weapon_common:117-120; DoAnimationEvent sh_shoot.lua:455 | `mcv_melee/shared.lua:17` (knife) |
| `ReloadGesture` | act/false | `ACT_HL2MP_GESTURE_RELOAD_AR2` (mcv_base:38) | GetReloadGesture weapon_common:122-125 | (default) |
| `BashGesture` | act | `ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND` (weapon_common:126) | sh_bash.lua:36 | (default) |
| `ChargeGesture` | act | `ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND` (melee:18) | sh_melee.lua:160 | (default) |
| `IronsightWalkBobbingStrength` | number | `-0.25` (weapon_common:148) | walk bob while aimed (render pipeline) | (uniform `-0.25`) |

### 3.4 Sights & optics

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `Ironsight` | bool | `true` (mcv_base:101) | Think_Sights gate sh_sights.lua:88 | `mcv_binoculars/shared.lua:15` `true` |
| `IronsightSpeedScale` | number | `0.85` (mcv_base:102) | transition time sh_sights.lua:3 | `mcv_m38.lua:72` `0.95` |
| `IronsightFov` | number | `75` (mcv_base:103) | world FOV + sensitivity sh_gun.lua:43,57 | (uniform `90-15`) |
| `IronsightPos` / `IronsightAng` | Vector/Angle | `0` (weapon_common:144-145) | GetViewModelPosition sh_vm.lua:214 | `mcv_svd.lua:80` |
| `IronsightPosAkimbo` / `IronsightAngAkimbo` | Vector/Angle | — | sh_vm.lua:216-217 | `mcv_tt33.lua:85-86` |
| `IronsightPosLauncher` / `IronsightAngLauncher` | Vector/Angle | — | sh_vm.lua:218-220 | (mcv-2 UBGL rifles) |
| `CustomPos` / `CustomAng` | Vector/Angle | `0` (weapon_common:142-143) | hip viewmodel pose sh_vm.lua:214 | `mcv_m38.lua:87-88` |
| `HasScope` | bool | `false` (mcv_base:105) | pipscope cl_pipscope.lua:46,105,137; FOV sh_gun.lua:42-57; HUD tag cl_hud.lua:639 | `mcv_svd.lua:73` `true` |
| `ScopeMaterial` | IMaterial | `NULL` (mcv_base:106) | reticle texture cl_pipscope.lua:92 | `mcv_svd.lua:74` `Material("models/weapons/mcv/optics/crosshair_svd")` |
| `ScopeFOV` / `ScopeFOV2` | number | `8` / `4` (mcv_base:107-108) | lens FOV per ScopeLevel cl_pipscope.lua:34-37 | `mcv_svd.lua:75-76` `23.5`/`9.5` |
| `RTScopeMaterialIndex` | int | `1` (mcv_base:109) | lens submaterial slot cl_pipscope.lua:150-162 | `mcv_svd.lua:77` `2`; `mcv_ptrd_sniper.lua:26` `2` |
| `ScopeIdleLensMaterial` | string | `""` (mcv_base:113) | idle lens swap cl_pipscope.lua:159-162 | `mcv_ptrd_sniper.lua:23` |
| `ScopeLensMaterial` | string/nil | `nil` (cl_pipscope.lua:19) | lens submaterial cl_pipscope.lua:150 | (rare) |
| `AdjustableScopes` | bool | `false` (mcv_base:41) | `+use +reload` becomes magnification sh_shoot.lua:748-765; sh_gun.lua:93 | `mcv_svd.lua:78` `true` |
| `ScopeScreenZoom` | number | `2` (sh_gun.lua:39) | screen pre-zoom sh_gun.lua:44 | (default) |
| `ScopeLensSize` … `ScopeDebug` | number | cl_pipscope.lua:22-31,118 | lens shader constants cl_pipscope.lua:80-95 | (never overridden — tuning surface) |
| `ReticleStrength` | number | `1` (cl_pipscope.lua:31) | cl_pipscope.lua:95 | (default) |
| `OEGScope` | bool | — | OEG composite sh_vm.lua:279-297; pipscope cl_pipscope.lua:40-61; FOV sh_gun.lua:43,54 | (mcv-2 XM177 OEG family) |
| `OEGSceneAlpha` | number | `0.5` (sh_vm.lua:263) | sh_vm.lua:297 | (default) |
| `ZoomLevels` | table | — | binoculars/shared.lua:43-44,71 | `mcv_binoculars/shared.lua:17` `{4,8}` |
| `OverlayMaterial` | string | — | binoculars mask binoculars/shared.lua:113 | `mcv_binoculars/shared.lua:18` |

### 3.5 Ballistics & damage

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `DamageGeneric` | number | `43` (mcv_base:22) | FireBullets damage sh_shoot.lua:625; DoImpactEffect weapon_common:306; melee sh_melee.lua:452; flame sh_flame.lua:76,93 | `mcv_ptrd.lua:30` `150` |
| `DamageHeadMultiplier` … `DamageArmMultiplier` (5) | number | `1` (mcv_base:23-27) | hitgroup scaling sh_penetration.lua:44-55 | `mcv_tt33.lua:31-35` |
| `DamageGenericAlt` | number | `nil` → `DamageGeneric*1.5` (melee:22, sh_melee.lua:26-28) | stab damage sh_melee.lua:456 | `mcv_katana.lua:25` `90` |
| `Num` | int | `1` (weapon_common:130) | GetBulletCount weapon_common:313 | (uniform 1; pellets via FIREMODE_BUCKSHOT) |
| `AmmoPerShot` | int | `1` (weapon_common:131) | NPC ammo draw sh_npc.lua:130 | (default) |
| `MuzzleVelocity` | number | — (0 disables physbullets, sh_physbullets.lua:4) | physical bullets sh_physbullets.lua:67-68 | `mcv_tt33.lua:40` `315` |
| `BulletLaunchVelocity` | number | — | burn-phase launch speed sh_physbullets.lua:67 | (rocket-assisted, rare) |
| `DamageRampDistance` | number | — | damage ramp sh_physbullets.lua:42-44; HUD cl_hud.lua:570-573 | (mcv-2, e.g. gyrojet) |
| `RangeModifier` | number | `0.95` (mcv_base:29 / weapon_common:133) | hitscan falloff `MCV.BulletRangeMultiplier`; HUD range row cl_hud.lua:609-610 | `mcv_tt33.lua:42` `0.775` |
| `ArmorPiercing` | bool | — | special-NPC damage types sh_penetration.lua:26-42; HUD tag cl_hud.lua:640 | `mcv_ptrd.lua:12` `true` |
| `ExplosionDamage` / `ExplosionRadius` | number | `0`-ish per base | projectile handoff sh_shoot.lua:680-684; throwable sh_throw.lua:203-204; placeable sh_place.lua:168-169 | `mcv_csg.lua:27-28` `150`/`350` |
| `ShootEntity` | string/nil | `nil` (mcv_base:133) | GetProjectileClass weapon_common:314; RocketAttack sh_shoot.lua:665 | `mcv_rpg7.lua:37` `"mcv_proj_rpg"` |
| `ShootEntityForce` | number | `5000` (mcv_base:134) | launch force sh_shoot.lua:666 | `mcv_rpg7.lua:38` `115/0.0254` |
| `ShootForce` ◇ | number | — | — (rpg7 sets it; unread) | `mcv_rpg7.lua:43` `5000` |
| `RocketGravity` | number | — | opt-in rocket flight sh_shoot.lua:699-702 | `mcv_rpg7.lua:39` `9.80665/0.0254` |
| `RocketBoostSpeed` | number | — | boost phase sh_shoot.lua:701 | `mcv_rpg7.lua:40` |
| `RocketBoostDelay` / `RocketBoostDuration` | number | — | sh_shoot.lua:702 | `mcv_rpg7.lua:41-42` |
| `Metal/Glass/Concrete/Wood/OtherPenetrationDepth` (5) | number | `8/14/10/18/12` (mcv_base:174-178) | composed by mat sh_penetration.lua:12-16 | `mcv_ptrd.lua:119-123` `25/40/30/50/40` |
| `Metal/Glass/Concrete/Wood/OtherDamageModifier` (5) | number | `1.55/1.15/1.75/1.25/1.25` (mcv_base:180-184) | loss exponent sh_penetration.lua:15,105 | `mcv_ptrd.lua:125-129` |

### 3.6 Spread & stance

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `Spread` | number | `6.3` (mcv_base:121) | cone amplitude sh_shoot.lua:324,365; NPC sh_npc.lua:5; HUD cl_hud.lua:404 | `mcv_svd.lua:86` `10` |
| `SpreadIronsighted` | number | `1.15` (mcv_base:122) | sh_shoot.lua:366 | `mcv_svd.lua:87` `0.25` |
| `SpreadBipod` / `SpreadBipodIronsighted` | number | — | bipod override sh_shoot.lua:369-371 | `mcv_ptrd.lua:88-89` `3`/`0.15` |
| `CrouchSpreadMultiplier` | number | `0.85` (mcv_base:144) | sh_shoot.lua:240 | `mcv_m38.lua:110` `0.65` |
| `ProneSpreadMultiplier` | number | `0.75` (mcv_base:145) | sh_shoot.lua:240 | `mcv_m38.lua:111` `0.55` |
| `StandMoveSpreadMultiplier` | number | `1.5` (mcv_base:146) | sh_shoot.lua:242 | `mcv_m38.lua:112` |
| `SneakMoveSpreadMultiplier` | number | `1.4` (mcv_base:147) | sh_shoot.lua:240 | `mcv_m38.lua:113` |
| `CrouchMoveSpreadMultiplier` | number | `1.35` (mcv_base:148) | sh_shoot.lua:240 | `mcv_m38.lua:114` |
| `JumpSpreadMultiplier` | number | `3.0` (mcv_base:149) | sh_shoot.lua:238 | `mcv_tt33.lua:115` `1.35` |
| `HipSwayScale` | number | `0.25` (sh_shoot.lua:281) | realistic-mode barrel sway sh_shoot.lua:324 | (default) |
| `NPCSpread` | number | — | GetNPCSpread sh_npc.lua:4-6 (falls back to `Spread`) | (rare) |

### 3.7 Recoil & camera

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `ViewSlideRecoilUp` / `ViewSlideRecoilRight` | number | `1.35`/`0.48` (mcv_base:87-88) | view punch sh_shoot.lua:432-445 | `mcv_ptrd.lua:54-55` `6.4`/`1.28` |
| `ViewSlideRecoilIronsightUp` / `…Right` | number | `1.35`/`0.48` (mcv_base:90-91) | sh_shoot.lua:432-435 | `mcv_ptrd.lua:57-58` |
| `ProgressiveRecoilUp` / `…Right` | number | `0` (mcv_base:96-97) | per-burst-shot additive sh_shoot.lua:433-435 | (auto guns, mcv-2) |
| `RecoilPushbackValue` | number | `1.5` (mcv_base:99) | impulse queue sh_shoot.lua:477 | (uniform `1.5`) |
| `ShakeScale` / `ShakeFreq` / `ShakeDuration` | number | `1`/`45`/`0.4` (weapon_common:151-153) | screen shake on fire | `mcv_rpg7.lua:55-57` `2.5`/`40`/`1` |

### 3.8 Fire modes & trigger

Firemode constants (mcv/shared/sh_common.lua:1-13): `AUTO 0, SEMI 1, BURST 2, SA 3, DA 4,
FAN 5, BOLT 6, PUMP 7, FAST 8, SLOW 9, VOLLEY 10, HE 11, BUCKSHOT 12`. Names for the HUD at
sh_common.lua:28-42.

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `Firemodes` | table | `{MCV.FIREMODE_SEMI}` (mcv_base:31-33) | GetFiremodeValue sh_shoot.lua:713-715; change cycle sh_shoot.lua:767-784; dedup sh_deploy.lua:143-157; NPC clamp sh_npc.lua:80 | `mcv_ak47.lua:47-50` `{AUTO, SEMI}` |
| `FireRate` | number | `300` (mcv_base:124) | GetFiremodeRate sh_shoot.lua:557-571; flamethrower tick sh_flame.lua:51 | `mcv_tt33.lua:94` `450` |
| `FireRate_DA` / `FireRate_Fan` / `FireRate_Fast` / `FireRate_Slow` | number | `0` (fall back to FireRate) (mcv_base:128-129) | sh_shoot.lua:560-567 | (revolvers; m1895-type, mcv-2) |
| `BurstRounds` | int | `3` (mcv_base:49) | runaway burst sh_shoot.lua:159-166,719-723; NPC sh_npc.lua:46 | `mcv_m16a1` family (mcv-2) |
| `BurstRecovery` | number | `0.2` (mcv_base:50) | sh_shoot.lua:162; sh_npc.lua:59 | (default) |
| `VolleyCount` | int | `2` (mcv_base:35) | volley fire sh_shoot.lua:69,413,460,595,650 | (duck-foot/pistol volley, mcv-2) |
| `SlamFire` | bool | `false` (mcv_base:51) | cycle-while-held sh_think.lua:112 | (M1897/M37, mcv-2) |
| `RevolverFiremodePose` | bool | `false` (mcv_base:58) | hammer pose on mode change sh_vm.lua:209 | (Shanxi/m1895, mcv-2) |
| `SelectableGrenadeAmmo` | bool | — | M79 cartridge selection family mcv_m79_base/shared.lua:5,19-43 | `mcv_m79_base/shared.lua:5` `true` |
| `LastShotAnimation` | bool | `false` (mcv_base:52) | ACT_VM_SHOOTLAST selection sh_shoot.lua:83-86,110-111; akimbo sh_akimbo.lua:48 | `mcv_tt33.lua:49` `true` |

### 3.9 Reload & ammo transfer

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `ShotgunReload` | bool | `false` (mcv_base:62) | round-by-round loop sh_reload.lua:49-56,226-245; counter logic sh_vm.lua:25-26,68-75; cancel sh_think.lua:82 | `mcv_shanxi_type17.lua:49` `true` |
| `ShotgunAltReload` | bool | `false` (mcv_base:63) | insert anim choice sh_reload.lua:241; sh_vm.lua:69 | `mcv_m38_s.lua:52` `true` |
| `ShotgunReloadRounds` | int | `1` (mcv_base:72) | rounds per insert sh_reload.lua:175,181; sh_vm.lua:52,73 | `mcv_shanxi_type17.lua:51` `5` (stripper) |
| `ShotgunReloadEmptyStartAnimation` | bool | `false` (mcv_base:53) | ACT_VM_RELOAD_INSERT_EMPTY start sh_reload.lua:50-53 | `mcv_shanxi_type17.lua:50` `true` |
| `HasEmptyReload` | bool | `true` (mcv_base:71) | ACT_VM_RELOADEMPTY selection sh_reload.lua:74-79 | `mcv_rpg7.lua:111` `false` |
| `MagInTime` / `MagInTimeEmpty` | number | `0` (mcv_base:77-78) | counter "new mag in" sh_vm.lua:31,34 | `mcv_svd.lua:20-21` `2`/`3.07` |
| `MagOutTime` / `MagOutTimeEmpty` | number | `0` = off (mcv_base:79-80) | counter "old mag out" sh_vm.lua:32,35 | (belt guns, mcv-2) |
| `MagInClip` | bool | `false` (mcv_base:82) | clip-loading counter semantics sh_vm.lua:35,91-95 | `mcv_m38.lua:48` `true` |
| `MagInTimeGrenade` | number | `0.5` (mcv_base:81) | UBGL round counter sh_vm.lua:199 | (default) |
| `ReloadInsertTime` | number | — | deferred ammo transfer sh_reload.lua:171-183; counter preview sh_vm.lua:49-53 | `mcv_shanxi_type17.lua:52` `14/30` |
| `InsertClipPoseTime` | number/nil | `nil` (mcv_base:75) | model event point sh_vm.lua:68-75 | `mcv_m38_s.lua:51` `0.2` |
| `CycleClipPoseTime` | number | — | cycle counter refresh sh_vm.lua:54-63 | (homemade pistol, mcv-2) |
| `CycleAmmoPose2` | bool | — | `ammo_fraction2` on cycle sh_vm.lua:79-81 | (mcv-2) |
| `AkimboMagInTimes` | table | — | per-hand mag-in cues sh_vm.lua:123-127 | (duals, mcv-2) |
| `AkimboDualSingleActionReload` | bool | `false` (mcv_base:54) | two-gun round-by-round sh_reload.lua:100-102,191-225 | (dual revolvers, mcv-2) |
| `Primary` | table | per base (mcv_base:136-139) | ammo system everywhere; capacity sh_reload.lua:129-135 | `mcv_m38.lua:101-105` |
| `Secondary` | table | (weapon_common:173-176) | rifle-grenade mode sh_reload.lua:40-43,113-127,187-189; sh_ubgl.lua:26-36 | `mcv_m38.lua:182-185` |

Non-shotgun magazines transfer **once, at animation end** — `Think_Reload` waits out the anim
lock then `RestoreClip(Primary.ClipSize)` (sh_reload.lua:246-253); `MagIn/MagOutTime` only
steer what the *counter pose parameters* show mid-reload (sh_vm.lua:25-36). Full mechanics in
`reload-ammo.md`.

### 3.10 Sounds

All values are soundscript names registered by `sh_soundscript_weapons.lua` /
`sh_soundscript_foley.lua` (see `sound-system.md`). First-person foley is **not** a SWEP field —
it rides the viewmodel MDL's own event tracks.

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `SoundSingleShot` | string | `"MCV_Weapon_SKS.Single"` (mcv_base:187) | EmitShotSound sh_shoot.lua:466-468 (+auto Distant layer 480-498); NPC sh_npc.lua:148 | `mcv_tt33.lua:135` |
| `SoundDoubleShot` | string | `""` (mcv_base:188) | volley sound sh_shoot.lua:465-466 | (volley guns, mcv-2) |
| `SoundReload` ◇ | string | `""` (mcv_base:195) | — | `mcv_m38.lua:141` `""` |
| `SoundReloadThirdPerson` | string | `""` (mcv_base:191) | EmitThirdPersonSound sh_reload.lua:91 | `mcv_tt33.lua:138` |
| `SoundReloadLoopThirdPerson` | string | `""` (mcv_base:192) | per-insert loop sh_reload.lua:223,243 | `mcv_m38.lua:143` |
| `SoundCycleThirdPerson` | string | `""` (mcv_base:193) | bolt/pump worked sh_think.lua:120 | `mcv_m38.lua:144` |
| `SoundGrenadeShot` | string | `"Weapon_SKS.RifleGrenade"` (mcv_base:198) | UBGL fire sh_ubgl.lua:68 | `mcv_m38.lua:147` |
| `SoundNearlyEmpty` ◇ | string | (mcv_base:199) | commented out sh_shoot.lua:473-475 | `mcv_m38.lua:148` |
| `SoundEmpty` ◇ | string | (mcv_base:200) | — | `mcv_m38.lua:149` |
| `SoundSpecial1` / `SoundSpecial2` ◇ | string | `""` (mcv_base:196-197) | — | `mcv_m38.lua:145-146` |
| `SoundFireStart` / `SoundFireLoop` / `SoundFireStop` | string | (flamethrower:37-39) | flame stream sh_flame.lua:31-39,143; loop-stop on clock reset sh_clock.lua:73 | `mcv_lpo50.lua:28-30` |
| `SoundFuseLoop` | string | `""` (placeable:55) | held-burning fuse sh_place.lua:306-320,395-398 | `mcv_dynamite.lua:38` |
| `SoundSwing` | string | `""` (melee:47) | melee whoosh sh_melee.lua:120 | (default silent) |
| `SoundHitFlesh` / `SoundHitWorld` | string | (melee:43-44) | melee impact sh_melee.lua:86-88 | `mcv_katana.lua:32-33` |
| `SoundThrustFlesh` / `SoundThrustWorld` | string | (melee:45-46) | stab/charge impact sh_melee.lua:86-88,230-231 | `mcv_wrench.lua:36-37` |

### 3.11 Particles, tracers & brass

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `MuzzleParticle` / `MuzzleParticleSmoke` | string | rifle type1 fp (mcv_base:203-204) | effects/mcv_muzzleeffect.lua:8 (fp pair) | `mcv_tt33.lua:156-157` pistol type3 |
| `MuzzleParticleIronsighted` / `…Smoke` | string | (mcv_base:205-206) | mcv_muzzleeffect.lua:24 (aimed pair) | `mcv_tt33.lua:158-159` |
| `MuzzleParticle3rdPerson` | string | (mcv_base:210) | mcv_muzzleeffect.lua:32 | `mcv_tt33.lua:161` |
| `MuzzleFlashLightTexture` | string | `"effects/flashlight_muzzleflash"` (mcv_base:208) | projected muzzle light sh_effects.lua:153 | (default) |
| `NoEjectOnShoot` | bool | `false` (mcv_base:212) | eject-on-fire gate sh_shoot.lua:448-451; NPC sh_npc.lua:150 | `mcv_m38.lua:170` `true` |
| `EjectBrassType` | int | `5` (mcv_base:214) | shell model index → `MCV.ShellTypes` (23 entries, sh_common.lua:82-175) via `data:SetFlags` sh_effects.lua:117 | `mcv_m38.lua:172` `8` |
| `EjectBrassTrail` / `EjectBrassParticle` | string | (mcv_base:215-216) | mcv_shelleffect.lua:108,115 | (uniform) |
| `TracerParticle` | string | `"vietnam_tracer_rifle_primary"` (mcv_base:218) | mcv_tracer.lua:47,128 | `mcv_tt33.lua:167` green pistol |
| `TracerParticle2` ◇ | string | (mcv_base:219) | — (streak drawn, not played; mcv_base:66-70) | `mcv_tt33.lua:168` |
| `TracerRandomness` | number | `6` (mcv_base:221) | tracer pick (effects doc) | (uniform) |
| `TracerFrequency` | int | `1` (mcv_base:222) | every Nth round glows mcv_tracer.lua:89-93 | `mcv_tt33.lua:171` `2` |
| `Silencer` | bool | `false` (mcv_base:84) | muzzle light dimming sh_effects.lua:142-143,155-163; HUD tag cl_hud.lua:636 | (Welrod/PB, mcv-2) |
| `LitAttachment` | string | `"Wick"` (weapon_common:332) | lit-particle anchor (anim doc §5.4) | (default) |
| `LitParticle` | string | per base (`zippo`/`dynamite` defaults sh_throw.lua:62, sh_place.lua:96) | GetLitParticle sh_throw.lua:60-63; sh_place.lua:94-97 | (molotov/dynamite) |

### 3.12 NPC surface

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `NPCUsable` | bool | `true` guns / `false` others | §3.1 | `mcv_flamethrower/shared.lua:7` `false` |
| `NPCSpread` | number | — | sh_npc.lua:4-6 | (rare) |
| `NPCShotInterval` | number | `0` floor | sh_npc.lua:38 | (rare) |
| `HoldTypeNPC` | string | — | sh_npc.lua:81 | (rare) |
| `ActivityTranslateAI` | table | engine | sh_npc.lua:85-88 (fallback to `ar2` hold type if `ACT_RANGE_ATTACK1` missing) | (engine-provided) |

NPCs fire through a server-only path (no usercmds/viewmodel/reserve pool — sh_npc.lua:1-3);
proficiency-based semi-auto RPM table at sh_npc.lua:13-19; bolt/pump NPCs get a floor delay
(sh_npc.lua:33-37).

### 3.13 HUD & icons

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `DrawCrosshair` | bool | `true` (weapon_common:179) | engine + DoDrawCrosshair cl_hud.lua:413-432 | `mcv_binoculars/shared.lua:27` `false` |
| `AccurateCrosshair` | bool | `false` (weapon_common:180) | engine (legacy) | (unused) |
| `CrosshairCircle` | bool | — | circle vs cross cl_hud.lua:482 | `mcv_flamethrower/shared.lua:10` `true` |
| `CrosshairMinDistance` ◇ / `CrosshairDeltaDistance` ◇ | number | `8`/`4` (weapon_common:162-163) | — (gap is live-spread driven, cl_hud.lua:392-397) | `mcv_m38.lua:96-97` |
| `DrawWeaponInfoBox` | bool | `true` (weapon_common:181) | info-box gate cl_hud.lua:645 | (default) |

Definition-side **function** overrides that shape the HUD (all optional; defaults in
weapon_common/shared.lua:310-347): `GetFiremodeName()`, `GetHUDAmmo()`, `GetBulletCount()`,
`GetProjectileClass()`, `GetControlHints()` (e.g. mcv_fists.lua:40-46), `GetPrecacheParticles()`,
`ViewModelHidden()`, `GetLitParticle()`, `IsLit()`, plus the whole hook contract of
§weapon_common/shared.lua:287-350 (ThinkWeapon, DoBodygroupsWeapon, PreDrawViewModelWeapon,
PreDrawViewModelBlend, PostDrawViewModelWeapon, DrawHUDExtra, SecondaryAttack, IdleActivity,
IdleSequence, DeployAnimation, OnDeploy, ScopeToggle, GetZoomMagnification, DoImpactEffect).

### 3.14 Feature flags: bayonet, bipod, UBGL, akimbo

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `HasBayonet` | bool | `false` (weapon_common:156) | toggle sh_bash.lua:126,137-140; hints sh_gun.lua:102-104; HUD cl_hud.lua:186,638; world bg sh_think.lua:22-28 | `mcv_ak47.lua:114` `true` |
| `IsBayonet` | bool | — | OwnerHasBayonet sh_bash.lua:112-119; HUD cl_hud.lua:190 | `mcv_ak47_bayonet.lua:2` `true` |
| `BashDamage` / `BashRange` | number | `50`/`96` (weapon_common:157-158) | sh_bash.lua:39-40 | `mcv_throwable/shared.lua:57-58` `30`/`72` |
| `BayonetDamage` / `BayonetRange` | number | `100`/`128` (weapon_common:159-160) | sh_bash.lua:39-40 | `mcv_m38.lua:120-121` |
| `SequencesBayonetSwing` | table | `{"bash_bayonet","slash_bayonet"}` (sh_bash.lua:6) | BayonetSwing sh_bash.lua:8-17 | (default) |
| `SequenceBayonetChargeStart` / `…Loop` / `SequencesBayonetChargeAttack` | string/table | (sh_bayonet_charge.lua:8-10) | charge state machine sh_bayonet_charge.lua:29,44,56 | (default) |
| `BayonetChargeDamageMultiplier` / `BayonetChargeWindup` / `BayonetChargeHitDelay` / `BayonetChargeMaxTime` | number | `2`/`0.3`/`0.1`/`4` (sh_bayonet_charge.lua:13-19) | charge hit | (default) |
| `HasRifleGrenade` | bool | `false` (mcv_base:154) | ToggleUBGL sh_ubgl.lua:26; hints sh_gun.lua:96-98; world bg sh_think.lua:30-36; HUD cl_hud.lua:601-602,634-635 | `mcv_m38.lua:118` `true` |
| `RifleGrenadeIsUBGL` | bool | `false` (mcv_base:155) | anim selection sh_gun.lua:19,29; muzzle port sh_effects.lua:55-56; HUD tag | (mcv-2 M203/M79 rifles) |
| `RifleGrenadeEntity` | string | `"mcv_proj_riflegrenade"` (mcv_base:158) | sh_shoot.lua:669 | `mcv_m38.lua:54` `"mcv_proj_riflegrenade_vc"` |
| `RifleGrenadeForce` | number | `5000` (mcv_base:159) | sh_shoot.lua:670 | `mcv_m38.lua:55` `2000` |
| `HasBipod` | bool | `false` (mcv_base:161) | Think_Bipod sh_bipod.lua:32; hints sh_gun.lua:105-106; HUD tag | `mcv_ptrd.lua:115` `true` |
| `MustBipod` | bool | — | fire gate sh_shoot.lua:36; sights gate sh_sights.lua:91,128 | `mcv_ptrd.lua:116` `true` |
| `HasAkimbo` | bool | `false` (mcv_base:156) | second-weapon pickup sh_akimbo.lua:6; UBGL block sh_ubgl.lua:21; hints sh_gun.lua:99-101; HUD cl_hud.lua:179-186,633 | `mcv_tt33.lua:119` `true` |
| `AkimboPoseRecoil` | bool | `false` (mcv_base:170) | pose-recoil path sh_shoot.lua:87-95 (HasPoseRecoil) | `mcv_tt33.lua:21` `true` |
| `AkimboRecoilTime` | number | `0.8` (mcv_base:171) | sh_shoot.lua:95 | (default) |
| `NearwallDistance` ◇ | number | `40` (mcv_base:141) | — (reserved; MCV.SafeMovementModels is the live near-wall mechanism, sh_think.lua:79-80) | `mcv_ptrd.lua:104` `90` |

### 3.15 Melee base fields (`SWEP.Base = "mcv_melee"`)

Defaults in weapons/mcv_melee/shared.lua; logic sh_melee.lua. Cadence is
rate-based, **not** animation-locked: *"the animations are as long as they are, and waiting on
them made even a quick knife feel slow"* (sh_melee.lua:100-106).

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `DamageGeneric` | number | `42` (melee:21) | slash damage sh_melee.lua:452 | `mcv_katana.lua:24` `45` |
| `DamageGenericAlt` | number | `63` (melee:22) | stab via GetStabDamage sh_melee.lua:26-28,456 | `mcv_katana.lua:25` `90` |
| `MeleeRange` / `MeleeRangeAlt` | number | `56`/`64` (melee:23-24) | slash/stab/charge traces sh_melee.lua:113,383,452,456,460 | `mcv_crowbar.lua:27-28` `48`/`64` |
| `MeleeHullSize` | number | `12` (melee:26) | hull half-extent sh_melee.lua:38-43 | (default) |
| `SlashRate` | number | `150` (melee:28) | SwingDelay sh_melee.lua:103,126 | `mcv_wrench.lua:29` `75` |
| `StabRate` | number | `nil`→SlashRate (melee:29) | sh_melee.lua:139,164 | (default) |
| `HitDelay` / `StabHitDelay` | number | `0.12`/`0.2` (melee:30-31) | deferred hit sh_melee.lua:123,137 | (default) |
| `ChargeDamageMultiplier` | number | `2` (melee:25) | charge hit sh_melee.lua:460 | (default) |
| `CanThrow` | bool | `true` (melee:33) | throw gate sh_melee.lua:180-182,413-417,491 | `mcv_crowbar.lua:31` `false`; `mcv_sickle.lua:29` `true` |
| `ThrowForce` | number | `1600` (melee:34) | blade launch sh_melee.lua:241 | (bayonets) |
| `ThrowDamage` | number | `nil`→stab damage (melee:35) | sh_melee.lua:229 | (default) |
| `ThrownEntity` | string | `"mcv_thrown_melee"` (melee:36) | sh_melee.lua:223 | (default) |
| `CanRepair` | bool | `false` (melee:38) | repair gate sh_melee.lua:435-438,494-496 | `mcv_wrench.lua:32` `true` |
| `RepairPerSecond` | number | `40` (melee:39) | repair tick sh_melee.lua:333 | (default) |
| `SequencesSlash` | table | `{"slash","slash2","swing_a","swing_b","swing_c"}` (melee:50) | PickSequence sh_melee.lua:114-115 | (default) |
| `SequencesMiss` | table | `{"miss","miss2"}` (melee:51) | sh_melee.lua:114 | (default) |
| `SequencesStab` | table | `{"stab","swing_hard"}` (melee:52) | sh_melee.lua:131 | (default) |
| `SequenceChargeStart` / `SequenceChargeLoop` / `SequencesChargeAttack` | string/table | (melee:53-55) | sh_melee.lua:146,150,158,352,464 | (default) |
| `SequenceThrow` / `SequenceThrowStart` / `SequenceThrowLoop` / `SequenceThrowCancel` | string | (melee:56-59) | sh_melee.lua:181,185-209,353,470 | (default) |
| `SequenceRun` / `SequenceIdleToRun` / `SequenceRunToIdle` | string | (melee:60-62) | run blend sh_melee.lua:356-376 | (default) |
| `SequenceRepairStart` / `SequenceRepairLoop` / `SequenceRepairEnd` | string | (melee:63-65) | sh_melee.lua:310,318,354,480 | (default) |
| `HoldType`/`AimHoldType` | string | `"knife"` (melee:13-15) | §3.3 | `mcv_fists.lua:23-24` `"fist"` |

Melee `DeferredActions` is its own list: `{"SlashHit","StabHit","ChargeLoop","ChargeHit",
"ThrowLoop","ThrowBlade","RepairLoop"}` (sh_melee.lua:10).

### 3.16 Throwable base fields (`SWEP.Base = "mcv_throwable"`)

Defaults weapons/mcv_throwable/shared.lua; logic sh_throw.lua. Windup-hold-release state
machine; fuse presets cycle on `+use +reload` using the firemode NetworkVar.

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `ThrowEntity` | string | `"mcv_grenade_frag"` (throwable:20) | ents.Create sh_throw.lua:193 | `mcv_css.lua:24` `"mcv_grenade_smoke"` |
| `ThrowModel` | string/nil | `nil`→WorldModel (throwable:21) | sh_throw.lua:196 | `mcv_css.lua:22` (ignited skin) |
| `ThrowForceOverhand` / `ThrowForceUnderhand` / `ThrowForceRoll` | number | `1250`/`600`/`450` (throwable:22-24) | sh_throw.lua:172,177,185 | (default) |
| `ThrowSpin` | number | `400` (throwable:25) | angular velocity sh_throw.lua:236 | (default) |
| `ThrowReleaseTime` / `ThrowReleaseTimeUnderhand` | number | `0.22`/`0.3` (throwable:26-28) | deferred release sh_throw.lua:121 | (default) |
| `FuseModes` | table | `{3,5}` (throwable:31) | GetFuseTime sh_throw.lua:35-45,264-269; HUD name sh_throw.lua:47-52 | `mcv_csg.lua:24` `{3,5}` |
| `FuseImpact` | bool | `false` (throwable:32) | impact fuse sh_throw.lua:36,48,61,87,164,198-202,219,292 | (molotov, mcv-2) |
| `ExplosionDamage` / `ExplosionRadius` | number | `150`/`350` (throwable:35-36) | projectile handoff sh_throw.lua:203-204 | `mcv_csg2.lua:27-28` `225`/`250` |
| `IgniteRadius` | number | `0` (throwable:37) | sh_throw.lua:205 | (incendiary, mcv-2) |
| `SmokeColor` | Vector/nil | `nil` (throwable:38) | sh_throw.lua:207 | `mcv_css.lua:30` `Vector(53,53,51)` |
| `EffectDuration` | number | `25` (throwable:39) | sh_throw.lua:206 | (smoke/gas) |
| `HasUnderhand` | bool | `true` (throwable:41) | sh_throw.lua:287-288,329-331 | `mcv_csg.lua:25` |
| `RemoveWhenEmpty` | bool | `true` (throwable:42) | strip-after-throw sh_throw.lua:242-261 | (default) |
| `SequenceWindupHigh`/`SequenceThrowHigh`/`SequenceWindupLow`/`SequenceThrowLow`/`SequenceRoll`/`SequenceFiremode` | string | (throwable:45-50) | sh_throw.lua:98-115,271-275 | (default) |

Throwable `DeferredActions`: `{"ThrowRelease","ThrowEnd"}` (sh_throw.lua:6).

### 3.17 Placeable / flamethrower / equipment-box fields

Placeable (`mcv_placeable`, defaults placeable/shared.lua, logic sh_place.lua):

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `PlaceKind` | string | `"c4"` (placeable:18) | whole state machine (mine/dynamite/c4) sh_place.lua:15-16,69,86,95,127,159,173,286,333,378-382,489-505 | `mcv_rg42.lua:25` `"mine"`; `mcv_dynamite.lua:23` `"dynamite"` |
| `PlacedEntityClass` | string | `"mcv_placed_c4"` (placeable:19) | sh_place.lua:112,185,251,272 | `mcv_rg42.lua:26` `"mcv_placed_mine"` |
| `StakeEntityClass` | string | `"mcv_mine_stake"` (placeable:20) | sh_place.lua:211 | (default) |
| `PlaceRange` | number | `72` (placeable:21) | placement trace sh_place.lua:57-61 | (default) |
| `PlaceDelay` | number | `0.5` (placeable:22) | deferred spawn sh_place.lua:143 | (default) |
| `ThrowForce` | number | `700` (placeable:23) | thrown-lit dynamite sh_place.lua:263 | (default) |
| `FuseTime` | number | `6` (placeable:24) | dynamite delay sh_place.lua:174 | (default) |
| `WireLength` | number | `256` (placeable:25) | mine-stake distance sh_place.lua:74 | (default) |
| `PlacedModel` / `StakeModel` | string/nil | `nil`→WorldModel (placeable:37-38) | sh_place.lua:172,213,411-413 | (default) |
| `PlacedAngleOffset` | Angle/nil | `nil` (placeable:43) | PlaceAngle sh_place.lua:42-47 | `mcv_dynamite.lua:34` `Angle(90,0,90)` |
| `StakeAngleOffset` / `StakeRaise` | Angle/number | `Angle(0,0,180)`/`6` (placeable:44-45) | sh_place.lua:215-216,441-442 | (default) |
| `SequencePlant`/`SequencePlaceMine`/`SequencePlaceStick`/`SequenceWindup`/`SequenceThrow` | string | (placeable:30-34) | sh_place.lua:126-133,230-237,365,382 | (default) |
| `SoundFuseLoop` | string | `""` (placeable:55) | §3.10 | `mcv_dynamite.lua:38` |
| `RemoveWhenEmpty` | bool | `true` (placeable:57) | sh_place.lua:283-297 | (default) |

Placeable `DeferredActions`: `{"Place","PlaceEnd","ThrowLit"}` (sh_place.lua:6).

Flamethrower (`mcv_flamethrower/shared.lua` + `sh_flame.lua`):

| Field | Type | Default (site) | Consumed at | Example |
|---|---|---|---|---|
| `FlameRange` | number | `420` (flame:20) | traces sh_flame.lua:66,88,201 | `mcv_underbarrel_flame/shared.lua:7` `240` |
| `FlameHull` | number | `24` (flame:21) | sh_flame.lua:57 | (default) |
| `FlameDamage` | number | — (UBGL flame only, ubfl:8) | pulse damage ubfl:48 | (default) |
| `FlameDuration` / `FlameInterval` | number | `0.8`/`0.1` (ubfl:9-10) | burst window ubfl:28,57 | (default) |
| `FlameAttachment` | string | `"muzzle"` (ubfl:6) | sh_flame.lua:167 | (default) |
| `IgniteTime` | number | `6` (flame:22) | MCV.Burn sh_flame.lua:83,98,269 | (default) |
| `BurnDamagePerSecond` | number | `10` (flame:23) | sh_flame.lua:83,98,269 | (default) |
| `FuelPerTick` | number | `1` (flame:24) | fuel draw sh_flame.lua:50 | (default) |
| `FlameParticle` / `PilotParticle` | string | `"lpo50_flame"` / `"lpo50_flame_pilot"` (flame:26-27) | precache sh_flame.lua:2; emitter sh_flame.lua:169 | (default) |
| `TankExplodes` | bool | `true` (flame:42) | backpack blast sh_flame.lua:253,267 | (default) |
| `TankExplosionDamage` / `TankExplosionRadius` | number | `150`/`250` (flame:43-44) | sh_flame.lua:267 | (default) |

Equipment box (`mcv_equipment_box/shared.lua`, logic sh_box.lua):
`BoxKind` (`"ammo"`/`"medic"`, :16), `HealAmount` (`50`, :17), `AmmoMagazines` (`1`, :18),
`GiveRange` (`96`, :19), `DroppedEntity` (`"mcv_supply_box"`, :20), `SequenceGive`/`SequenceSelf`/
`SequenceThrow`/`SequenceDraw` (:22-25), `GiveDelay` (`0.4`, :26), `ThrowDelay` (`0.3`, :27).

### 3.18 Vestigial & informational fields (set by definitions, unread by Part-1 Lua)

Grep-verified across `mcv/` + all base folders (no consumer outside the default assignment and
weapon files themselves):

| Field | Status |
|---|---|
| `WeaponSelectIcon` | generator writes `NULL` into every gun; nothing reads it. Icons are `IconOverride` / `entities/<class>.png` (cl_hud.lua:136,710). |
| `SoundEmpty`, `SoundNearlyEmpty`, `SoundSpecial1`, `SoundSpecial2` | dry-fire/low-ammo clicks are model animation events, not Lua — `SoundNearlyEmpty` survives only as a comment (sh_shoot.lua:473-475). |
| `CrosshairMinDistance`, `CrosshairDeltaDistance` | crosshair gap is derived from live spread (cl_hud.lua:392-397,459). |
| `NearwallDistance` | the live near-wall mechanism is `MCV.SafeMovementModels` + `SafeMovementAnimations` (sh_think.lua:77-83); the distance field is reserved. |
| `WeaponWeight` | real-world kg metadata; no code reads it. |
| `TracerParticle2`, `ShootForce`, `SoundReload` | kept "as the game has them" (mcv_base:66-70) but currently unread. |

A translation layer should still populate the semantic ones (`NearwallDistance`,
`WeaponWeight`, `SoundEmpty`…) for forward compatibility, but must not depend on them doing
anything.

### 3.19 Engine-standard & structural fields

`Primary` (`Ammo`, `ClipSize`, `Chamber`, `DefaultClip`, `Automatic`) and `Secondary`
(`Automatic`, `ClipSize`, `Ammo`, `DefaultClip`) — the ammo system keys (mcv_base:136-139,
weapon_common:167-176; capacity math sh_reload.lua:125-135). `DeferredActions` — the fixed
prediction-safe deferred-action name list; *"the order is what travels between the realms, so
it is fixed: append, never insert"* (mcv_base:151-153; sh_timers.lua). `Slot`/`SlotPos`,
`BobScale` (`0`), `SwayScale` (`0.1`) (weapon_common:186-187) — engine knobs the base pins.
`SWEP` functions defined at definition time are also part of the format (e.g. `GetControlHints`
on mcv_fists.lua:40-46, `IsBuckshotSelected` family on mcv_m79_base/shared.lua:19-43,
`GetMagnification` on mcv_binoculars/shared.lua:42-55) — the hook contract is
weapon_common/shared.lua:287-350.

---

## 4. Variant & Derivation Idioms

MCV ships 244 classes from far fewer unique weapon "families"; variants are **separate
spawnable SWEPs that derive from the full parent definition** (`SWEP.Base = "mcv_<parent>"`)
and override only what differs. Because GMod inheritance patches nested tables index-by-index
(§1.3), variants must be aware of what they inherit.

### 4.1 `_irons` — strip the optic, keep the ballistics (`mcv_svd_irons`)

```lua
-- weapons/mcv_svd_irons.lua:1-23 (complete)
AddCSLuaFile()

SWEP.Base = "mcv_svd"
SWEP.Spawnable = true
SWEP.PrintName = "SVD Irons"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Battle Rifles"
SWEP.Country = "Soviet Union"
SWEP.ViewModel = "models/weapons/mcv/v_svd_irons.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_svd_irons.mdl"
SWEP.IconOverride = "entities/mcv_svd_irons.png"
SWEP.SafeMovementAnimations = true

// Retain the SVD's ballistics and handling, with the scope removed from both meshes.
SWEP.HasScope = false
SWEP.AdjustableScopes = false
SWEP.ScopeMaterial = NULL
SWEP.SightedViewModelFOV = 40
// Align the bare front post/rear notch in the existing aimed pose.
SWEP.IronsightPos = Vector(-0.045, -0.1, 1.1)
SWEP.IronsightAng = Angle(0.5, 0, 0)

SWEP.Primary.Ammo = "ar2"
```

Pattern: identity + models + icon + `SafeMovementAnimations` (the new model's locomotion is
grip-corrected, sh_think.lua:79) + the optic removal block + re-tuned `IronsightPos/Ang` for
the bare sights. Note `SWEP.Primary.Ammo = "ar2"` is re-stated even though the parent already
has it — a generator habit, but also insurance against the nested-table trap. 23 lines total;
everything else (damage, sounds, reload timings) is the SVD's.

### 4.2 `_drum` — capacity + donor reload animations (`mcv_type56_drum`)

```lua
-- weapons/mcv_type56_drum.lua:14-20
// Type 56-1 handling and folded stock; RPK drum and both RPK reload sequences.
SWEP.Primary.ClipSize = 75
SWEP.Primary.Chamber = 1
SWEP.Primary.DefaultClip = 150
SWEP.MagInTime = 1.5
SWEP.MagInTimeEmpty = 1.5
SWEP.SoundReloadThirdPerson = "MCV_Weapon_Foley_ThirdPerson_RPK.Reload"
```

The variant swaps the viewmodel/worldmodel to the drum mag (lines 9-10) and re-states the
*derived* numbers: because `ClipSize` feeds `GetClip1Capacity()` (sh_reload.lua:129-135) and
the reserve display, and `MagInTime*` must match the new (RPK) reload animations, the changed
capacity drags three more fields with it. The first-person reload foley changes automatically —
it rides the new model's event tracks.

### 4.3 Belt-feed conversion (`mcv_vz59b`)

```lua
-- weapons/mcv_vz59b.lua:15-21
SWEP.BulletBodygroups = {}
for i = 1, 21 do SWEP.BulletBodygroups[i] = {i, 1} end
SWEP.BeltBodygroups = {22}
SWEP.BodyGroups = ""
SWEP.MagInTime = 64 / 30
SWEP.MagInTimeEmpty = 89 / 30
SWEP.SafeMovementAnimations = true
```

The most table-heavy idiom: `BulletBodygroups` is a sparse **round-count-threshold map** —
"at more than `i` rounds visible, set group `i` to option 1" (sh_vm.lua:136-148), here built
with a loop for the 21 belt links; `BeltBodygroups` hides the empty feed tray. Note also:
frame-division time notation (`64/30` s) — the porting convention for frame-exact events, and
the *same* world model reused with no separate belt variant (line 9-10 comment).

### 4.4 `_sniper` — user kitbash adding an optic (`mcv_ptrd_sniper`)

```lua
-- weapons/mcv_ptrd_sniper.lua:1-2,14-30
// User kitbash: PTRD-41 with the canted Meopta optic.
SWEP.Base = "mcv_ptrd"
...
SWEP.BodyGroups = "00" // gun and the separately animated PTRD cartridge
SWEP.WorldModelBodyGroups = "00"
// Match the donor's frame-13 cartridge reveal through shared predicted state.
SWEP.BulletBodygroups = {{1, 1}}
SWEP.MagInTime = 13 / 30
SWEP.MagInTimeEmpty = 13 / 30

SWEP.HasScope = true
SWEP.ScopeMaterial = Material("models/weapons/mcv/optics/crosshair_meopta256")
SWEP.ScopeIdleLensMaterial = "models/weapons/mcv/optics/lens_meopta"
SWEP.ScopeFOV = 12.5
SWEP.ScopeFOV2 = 23.5
SWEP.RTScopeMaterialIndex = 2
SWEP.IronsightPos = Vector(-2.38, 5, 0.755)
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.SightedViewModelFOV = 25
```

The reverse of `_irons`: full scope block added (`ScopeIdleLensMaterial` is the rare
field — *"the Vz.54 Meopta's lens mesh wears the reticle texture"* and needs its glass
repointed, mcv_base/shared.lua:110-113). `HoldType = "passive"` (line 12) is re-picked for the
carried look. The `BulletBodygroups = {{1,1}}` + `MagInTime = 13/30` pair re-synchronises the
single-round counter with the new model's frame-13 reveal.

### 4.5 Bayonet melee weapons — the inventory-side half (`mcv_ak47_bayonet`, `mcv_type30_bayonet`)

```lua
-- weapons/mcv_ak47_bayonet.lua:1-2,20-31
SWEP.Base = "mcv_melee"
SWEP.IsBayonet = true // carrying it lets the rifles fix their bayonet
...
SWEP.MovementPoseWalk = 167
SWEP.MovementPoseSprint = 268
SWEP.MovementPoseSighted = 167

SWEP.DamageGeneric = 35
SWEP.DamageGenericAlt = 55
SWEP.MeleeRange = 32
SWEP.MeleeRangeAlt = 48
SWEP.SlashRate = 150

SWEP.CanThrow = true
```

Two things make a bayonet: `SWEP.IsBayonet = true` (checked against the *owner's whole
inventory*, sh_bash.lua:112-119 — a rifle's `HasBayonet` does nothing without one carried) and
being a normal `mcv_melee` weapon in its own right. The two files differ only in stats — the
pattern is "copy the sibling, change numbers" (compare mcv_type30_bayonet.lua:25-29: 55/75/48/64).

### 4.6 Grenade family — one entity, N stat blocks (`mcv_csg`, `mcv_csg2`, `mcv_css`)

All three are structurally identical 34-line files: identity, models, movement poses, then

```lua
-- weapons/mcv_csg.lua:23-34
SWEP.ThrowEntity = "mcv_grenade_frag"
SWEP.FuseModes = {3, 5}
SWEP.HasUnderhand = true

SWEP.ExplosionDamage = 150
SWEP.ExplosionRadius = 350

SWEP.Primary.Ammo = "mcv_grenade"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = 2

SWEP.WeaponWeight = 1
```

`mcv_csg2` differs only in `ExplosionDamage = 225` / `ExplosionRadius = 250` (mcv_csg2.lua:27-28)
— same projectile entity, different blast numbers, exactly as AGENTS.md prescribes: *"a
projectile's basic numbers … belong to the weapon that fires it, not to the entity"*.
`mcv_css` adds the smoke specialisations: `ThrowModel` (ignited world skin, line 22),
`ThrowEntity = "mcv_grenade_smoke"`, `SmokeColor = Vector(53,53,51)` (line 30), and a
`0`-damage/`500`-radius blast (lines 28-29).

### 4.7 The SOG / `_s` / `_vc` families

`weapon_list.md` shows the scale: `mcv_m38_s` (scoped M91/30 PU) is a *full* redefinition off
`mcv_base` (not off `mcv_m38` — 193 lines, weapons/mcv_m38_s.lua:1), while `mcv_rpd_sog`,
`mcv_vz61_sog`, `mcv_rpdb_sog` are short derivations off their parents that swap models/icons
(same shape as §4.1). Rule of thumb in the shipped set: **optical/ejection-variant conversions
that change the reload or fire animations get a full file; skin/ammo/icon conversions derive.**

### 4.8 What a variant must never do

From the base's own defenses (§1.3) and AGENTS.md: never rewrite `Primary`/`Secondary`/`Firemodes`
*tables* from a variant expecting wholesale replacement (patch semantics); never insert into
`DeferredActions`; never regenerate a whole weapon lua to change a few fields (generator drops
hand-tuned keys: sights, secondaries, rifle-grenade keys, placement offsets — AGENTS.md:64-66).

---

## 5. Folder-Based Special Weapons

Six bases use the folder form. Their `shared.lua` follows the §1.2 composition; the class name
is the folder. Deep dives belong to `special-weapon-bases.md`; this is the definition-surface
view.

| Base folder | Roots at | Own defaults | Modules | Derived weapons |
|---|---|---|---|---|
| `weapons/mcv_m79_base/` | `mcv_base` | shared.lua:1-15 | (all logic inline in shared.lua, 112 lines) | `mcv_m79`, `mcv_m79_sog`, `mcv_chinalake`… |
| `weapons/mcv_binoculars/` | `mcv_base` | shared.lua:4-36 | (inline, 119 lines) | `mcv_binoculars_us`, `mcv_binoculars_vc` |
| `weapons/mcv_melee/` | `weapon_base` + weapon_common | shared.lua (77 lines) | `sh_melee.lua` (499) | 13 melee classes |
| `weapons/mcv_throwable/` | same | shared.lua (65 lines) | `sh_throw.lua` (338) | 14 grenade classes |
| `weapons/mcv_placeable/` | same | shared.lua (62 lines) | `sh_place.lua` (512) | C4, dynamite, 2 mines |
| `weapons/mcv_flamethrower/` | `mcv_base` | shared.lua (74 lines, own file-loop loader at :58-73) | `sh_flame.lua` | LPO-50, M9A1 |
| `weapons/mcv_equipment_box/` | weapon_common | shared.lua (37 lines) | `sh_box.lua` | 4 box classes |
| `weapons/mcv_underbarrel_flame/` | `mcv_base` | shared.lua (94 lines) | (inline) | (mated to a host rifle in mcv-2) |

Two definition idioms unique to these folders:

**Break-action cartridge selection** — `mcv_m79_base/shared.lua` replaces the firemode list
with cartridge modes and *overrides functions* rather than adding fields:

```lua
-- weapons/mcv_m79_base/shared.lua:3-15
SWEP.Base = "mcv_base"
SWEP.Spawnable = false
SWEP.SelectableGrenadeAmmo = true
SWEP.Firemodes = {MCV.FIREMODE_HE, MCV.FIREMODE_BUCKSHOT}
SWEP.ShootEntity = "mcv_proj_40mm"
SWEP.DamageGeneric = 25
...
// The first firemode is each variant's starting cartridge. All selection state is
// predicted; never rewrite Primary or other inherited configuration tables.
```

`IsBuckshotSelected`/`GetSelectedAmmo`/`GetPrimaryAmmoType`/`Ammo1`/`GetBulletCount`/
`GetProjectileClass` (lines 19-43) re-route the ammo system through the selected firemode, and
`DoBodygroupsWeapon` (45-59) drives the model's named `ammo` bodygroup off predicted state.

**Binoculars** — a gun base with nothing to fire: `NPCUsable = false` ("Optical equipment
inherits the gun base but cannot fire", shared.lua:6), `FireRate = 0`, `DrawCrosshair = false`,
`ZoomLevels = {4, 8}` with `GetZoomMagnification() = 90 / magnification` (lines 42-55), an
`OverlayMaterial` Refract mask drawn from `DrawHUDExtra` (108-118), and no-op
`ToggleUBGL`/`ToggleBayonet` stubs (86-87). This is the minimal "inherits mcv_base but is not
a gun" template.

---

## 6. Minimal Viable Definition

The smallest *correct* gun, using only defaults that exist on `mcv_base` (everything in §3 has
a default; nothing is mandatory except identity, models and ammo):

```lua
SWEP.Base = "mcv_base"
SWEP.Spawnable = true
AddCSLuaFile()

SWEP.PrintName = "Example Rifle"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Assault Rifles"     -- balance category (StatMult key)!
SWEP.Country = "Narnia"
SWEP.Caliber = "7.62x39mm"
SWEP.Slot = 3

SWEP.ViewModel = "models/weapons/mcv/v_ak47.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_ak47.mdl"

SWEP.DamageGeneric = 40
SWEP.MuzzleVelocity = 735              -- 0/nil = hitscan-only, no physical bullets
SWEP.FireRate = 600
SWEP.Spread = 7.5
SWEP.SpreadIronsighted = 1.5
SWEP.Firemodes = { MCV.FIREMODE_AUTO, MCV.FIREMODE_SEMI }

SWEP.Primary.Ammo = "smg1"
SWEP.Primary.ClipSize = 30
SWEP.Primary.Chamber = 1
SWEP.Primary.DefaultClip = 90

SWEP.SoundSingleShot = "MCV_Weapon_AK47.Single"
```

This fires, reloads, ironsights, penetrates and shows in the spawn menu with the full default
muzzle flash, tracer, brass, recoil, NPC support and gestures. Everything else in §3 is
optional refinement. The three fields people forget, ranked by breakage:

1. `SubCategory` — empty means no balance category (follows only the `All` multipliers,
   sh_categories.lua:83-99) and no spawn-menu grouping.
2. `MuzzleVelocity` — without it the weapon never spawns physical bullets
   (sh_physbullets.lua:4).
3. `Primary.Chamber` — the +1 that `GetClip1Capacity` adds (sh_reload.lua:129-135); set 0 for
   internal-mag/shotgun-style counting.

For melee/throwable/placeable the minimum is even smaller (see mcv_csg.lua — 34 lines, of
which 12 are identity), because the base carries the whole input grammar.

---

## 7. Translation-Layer Surface

How a foreign SWEP's fields map onto this schema, and what is mandatory.

### 7.1 The mapping table (foreign concept → MCV field)

| Foreign-base concept (typical) | MCV field(s) | Notes |
|---|---|---|
| `Primary.Damage` | `DamageGeneric` + `Damage*Multiplier` ×5 | MCV splits base vs hitgroup; `DamageGeneric` is *not* the HL2 0-dmg convention |
| `Primary.ClipSize` / `Primary.DefaultClip` | same + `Primary.Chamber` | MCV capacity = `ClipSize + Chamber` |
| RPM (`Primary.Delay` = 60/RPM) | `FireRate` | per-mode rates via `FireRate_DA/_Fan/_Fast/_Slow` |
| `Primary.Automatic` | `Firemodes` (`AUTO` vs `SEMI`) | MCV is a list; player cycles with `+use +reload` |
| `Primary.Sound` / `SoundSingle` | `SoundSingleShot` (+ soundscript layering, auto `Distant`) | sound must be a registered soundscript or raw path; see `sound-system.md` |
| `ViewModel` / `WorldModel` | same | but must satisfy the MCV model contract, anim doc §5 |
| `IronSightsPos/Ang`, `VMPos` | `IronsightPos/Ang` + `CustomPos/Ang` | MCV separates hip (`Custom*`) from aim (`Ironsight*`) |
| `Cone` / `Spread` | `Spread` / `SpreadIronsighted` (+6 stance mults) | degrees×100 convention: MCV divides by 100 at use (sh_shoot.lua:402) |
| `KickUp/KickSide` | `ViewSlideRecoilUp/Right` (+ ironsight pair, `Progressive*`) | degrees of view punch |
| `ReloadSound`, npc tables | `SoundReloadThirdPerson` etc.; `NPCUsable`/`NPCSpread`/`NPCShotInterval` | first-person foley must come from model events |
| `ShootEntity` | `ShootEntity` + `ShootEntityForce` (+`Rocket*` for boosted flight) | blast numbers live on the *weapon* |
| Muzzle flash / shell fields | `MuzzleParticle*` ×5, `EjectBrassType` (1-23 index), `TracerParticle/Frequency` | see `effects.md` |
| Firemode tables (TFA/ARC9) | `Firemodes` + `BurstRounds`/`BurstRecovery` | `FIREMODE_*` constants, sh_common.lua:1-13 |

### 7.2 Mandatory vs optional

**Mandatory** (no working default): `Base` (an MCV base), `Spawnable`, `PrintName`, `Category`,
`SubCategory`, `ViewModel`, `WorldModel`, `Primary.Ammo/ClipSize/DefaultClip`, and a working
`SoundSingleShot`. **Conditionally mandatory**: the model contract — the viewmodel must carry
the activities, sequences, pose parameters and `muzzle`/`eject` attachments enumerated in anim
doc §5 (a foreign model won't, which is the layer's core problem); `AnimationHandlesHammer`
must be false unless a hammer-event entry exists (anim doc §11.11); `MovementPose*` must match
the actual model or locomotion looks wrong. **Everything else** (≈90% of §3) has a sane
default and can be omitted.

### 7.3 Traps for the translator

1. **`ShootAnimRate = 0.5` default** — MCV's ported models run fire animations at half rate;
   a normally-compiled foreign model needs `1` (mcv_base/shared.lua:163-165; anim doc §11.10).
2. **Nested-table patch semantics** — a derived table field merges index-by-index (§1.3);
   the translation layer should emit *complete* tables, never partial ones, and let
   `Initialize`'s dedupe handle collisions.
3. **Timing fields are sequence-relative seconds**, often written as `frames/30` — they must
   be re-measured against the translated model's real sequence lengths or ammo transfer drifts
   (anim doc §11.9).
4. **`MilitaryConflictVietnam = true`** must survive any table surgery — eight global systems
   gate on it (§1.4).
5. **No new NetworkVars** — the datatable is fixed and shared by every base
   (weapon_common/shared.lua:194-285); translation state must be plain per-instance fields or
   NW2 (anim doc §11.7).
6. **`DeferredActions` order is wire format** — append-only (mcv_base:151-153).
7. **Stat multipliers apply at the consumption site**, not the definition: `damage`, `spread`,
   `spread_sights`, `recoil`, `firerate`, `penetration`, `explosion_damage`,
   `explosion_radius`, `projectile_speed` (sh_categories.lua:35-47) — a translator computing
   final numbers itself will double-apply.
8. **Vestigial fields exist** (§3.18) — don't build translation logic on `SoundEmpty`,
   `CrosshairMinDistance`, `NearwallDistance` or `WeaponSelectIcon`.
9. **Melee/equipment address sequences by name**, not activities (ACT_VM_SLASH etc. don't
   exist in GMod — sh_anim.lua:100-102; anim doc §5.2): a translated melee weapon's model must
   carry those names, or the `PickSequence` fallbacks silently degrade to fixed 0.5 s swings
   (sh_melee.lua:117,134).
10. **`EjectBrassType` is an index**, not a path — into `MCV.ShellTypes`
    (sh_common.lua:82-175); map the foreign shell to the nearest entry.

### 7.4 The full emission order (recommended)

When converting a foreign SWEP, emit fields in the canonical file order the shipped weapons
use (compare §2 and any weapons/mcv_*.lua): identity → `Slot`/hold types → models → bodygroups
→ icon → stats (damage → muzzle velocity → range → firemodes → anim flags → grenade keys →
recoil → shake → ironsight/movement poses → scope block → sight offsets → spread → fire rate
→ crosshair → weight → `Primary` → nearwall → stance mults → feature flags → penetration →
sounds → particles → tracers → `Secondary`. Keeping the order makes diffs against shipped
weapons meaningful, which is how the upstream authors work (AGENTS.md:64-66).

---

## 8. File Map

| File | Lines | Role in the definition format |
|---|---|---|
| `lua/weapons/mcv_base/shared.lua` | 226 | Gun field defaults (the schema's backbone) |
| `lua/mcv/weapon_common/shared.lua` | 400 | Generic defaults, NetworkVar layout, hook contract, gestures |
| `lua/mcv/weapon_common/load.lua` | 33 | Module-template sandbox + copy; `IncludeWeaponModules` |
| `lua/mcv/weapon_common/sh_deploy.lua` | 187 | `Initialize` (Firemodes dedupe, precache, world bodygroups) |
| `lua/mcv/weapon_common/sh_think.lua` | 179 | Movement/hold-type defaults & blend |
| `lua/weapons/mcv_base/sh_shoot.lua` | 820 | Fire rates, recoil, sounds, projectiles, firemode change |
| `lua/weapons/mcv_base/sh_reload.lua` | 257 | Reload state machine, clip capacity math |
| `lua/weapons/mcv_base/sh_vm.lua` | 305 | Counter pose params & bodygroups (MagIn/Out, BulletBodygroups) |
| `lua/weapons/mcv_base/sh_penetration.lua` | 114 | Composed penetration-depth reads, hitgroup mults |
| `lua/weapons/mcv_base/sh_npc.lua` | 167 | NPC field surface |
| `lua/weapons/mcv_base/sh_effects.lua` | 182 | Brass/muzzle-light consumption |
| `lua/weapons/mcv_base/sh_gun.lua` | 132 | HUD name/ammo, control hints, scope FOV |
| `lua/weapons/mcv_base/cl_pipscope.lua` | 169 | Scope visual field defaults |
| `lua/mcv/weapon_common/cl_hud.lua` | 725 | HUD/info-box/stat readouts |
| `lua/mcv/shared/sh_common.lua` | 175 | FIREMODE constants, ammo types, shell types |
| `lua/mcv/shared/sh_categories.lua` | 99 | SubCategory ↔ stat-multiplier machinery |
| `lua/mcv/client/cl_killicons.lua` | 43 | Projectile→weapon icon aliasing |
| `lua/weapons/mcv_m38.lua` (et al.) | 167-193 | The worked examples of §2 |
| `lua/weapons/mcv_svd_irons.lua` etc. | 20-38 | Variant idioms of §4 |
| `lua/weapons/mcv_melee/shared.lua` + `sh_melee.lua` | 77/498 | Melee schema |
| `lua/weapons/mcv_throwable/shared.lua` + `sh_throw.lua` | 65/337 | Throwable schema |
| `lua/weapons/mcv_placeable/shared.lua` + `sh_place.lua` | 62/511 | Placeable schema |
| `lua/weapons/mcv_flamethrower/shared.lua` + `sh_flame.lua` | 74/280 | Flamethrower schema |
| `lua/weapons/mcv_equipment_box/shared.lua` + `sh_box.lua` | 37/225 | Equipment schema |
| `lua/weapons/mcv_m79_base/shared.lua` | 112 | Cartridge-selection function-override idiom |
| `lua/weapons/mcv_binoculars/shared.lua` | 119 | "Gun base, nothing to fire" template |
| `reference/mcv/weapon_list.md` | 344 | The 244-class inventory (categories) |
| `reference/mcv/AGENTS.md` | 77 | Upstream house rules (nested-table rule, generator discipline) |
