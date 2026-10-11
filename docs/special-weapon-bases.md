# MCV Base — Special Weapon Bases (Exhaustive Audit)

This document audits every non-standard weapon base in Military Conflict: Vietnam — the
equipment bases that are **not** plain guns (melee, throwable, placeable, flamethrower,
underbarrel flame, chainsaw, crossbow, binoculars, equipment box, M79 grenade launcher,
lunge mine). For each base: purpose, base chain, which `mcv_base`/`weapon_common` systems it
reuses vs overrides vs ignores, unique SWEP fields, lifecycle, input handling, prediction
approach, and worked derivative examples. The playback API, pose parameters, deploy/holster
and per-action animation state machines are already covered exhaustively in
`docs/animation-system.md` and are cross-referenced here rather than restated. Projectile
entity internals live in `docs/projectiles-entities.md`; impact dispatch in
`docs/effects.md`; the gun base itself in `docs/gun-core.md`.

All paths are relative to `reference/mcv/lua/`. Line numbers verified against the audited
commit (06f4a24b).

---

## 1. Architecture Overview

### 1.1 Two ways to be special: compose vs inherit

MCV has **two distinct strategies** for building a non-gun weapon, and the difference is the
single most important architectural fact in this document:

| Base | Registered `SWEP.Base` | Composition | Gets gun systems? |
| --- | --- | --- | --- |
| `mcv_melee` | `weapon_base` | module mix-in (`MCV.IncludeWeaponModules`) | **no** — `weapon_common` only |
| `mcv_throwable` | `weapon_base` | module mix-in | **no** |
| `mcv_placeable` | `weapon_base` | module mix-in | **no** |
| `mcv_equipment_box` | `weapon_base` | module mix-in | **no** |
| `mcv_flamethrower` | `mcv_base` | SWEP inheritance + own file loop | **yes** (sights, reload state, HUD, bash) |
| `mcv_binoculars` | `mcv_base` | SWEP inheritance | **yes** (aim path reused as zoom) |
| `mcv_m79_base` | `mcv_base` | SWEP inheritance | **yes** (full gun fire/reload path) |
| `mcv_underbarrel_flame` | `mcv_base` | SWEP inheritance | **yes** (UBGL toggle path reused) |
| `mcv_chainsaw` | `mcv_melee` | SWEP inheritance from a special base | melee only |
| `mcv_lunge_mine` | `mcv_melee` | SWEP inheritance from a special base | melee only |
| `mcv_crossbow` | `mcv_base` | **pure definition** — zero code | yes (untouched) |

The module mix-in is the mechanism from `mcv/weapon_common/load.lua`:

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

Each mixing base does `include("mcv/weapon_common/load.lua")` (which builds/caches the common
table **once** and copies it into the base being defined), then runs
`MCV.IncludeWeaponModules("weapons/<base>")` to layer its own modules on top. Consequences:

- The four equipment bases carry **no gun code at all**: no `sh_shoot`, `sh_reload`,
  `sh_sights`, `sh_gun`, `sh_bipod`, `sh_ubgl`, `sh_akimbo`. They cannot fire bullets,
  cannot aim down sights (their `GetSightAmount` stays the `weapon_common` stub returning 0,
  mcv/weapon_common/shared.lua:292), never reload. What they *do* get from the common layer:
  deploy/holster (sh_deploy), the predicted `Think` pipeline, deferred timers, playback API,
  movement/hold-type blending, bash, HUD hooks, third-person world model drawing.
- Mix-in order means a base's own module functions **overwrite** the copied common ones
  (e.g. `mcv_placeable`'s client `OnRemove` replaces `cl_worldmodel`'s, sh_place.lua:482 vs
  cl_worldmodel.lua:290).
- `mcv_flamethrower` instead uses real SWEP inheritance with its own directory scan:

```lua
-- weapons/mcv_flamethrower/shared.lua:58-73
local searchdir = "weapons/mcv_flamethrower"

for _, filename in pairs(file.Find(searchdir .. "/*.lua", "LUA")) do
    if filename == "shared.lua" then continue end
    local luatype = string.sub(filename, 1, 2)

    if luatype == "sv" then
        if SERVER then include(searchdir .. "/" .. filename) end
    elseif luatype == "cl" then
        AddCSLuaFile(searchdir .. "/" .. filename)
        if CLIENT then include(searchdir .. "/" .. filename) end
    else
        AddCSLuaFile(searchdir .. "/" .. filename)
        include(searchdir .. "/" .. filename)
    end
end
```

This is why `sh_flame.lua` may call `self:Bash()`, `self:Think_Sights()`, `PlayAnimation` and
the whole reload/HUD surface: they are inherited from `mcv_base`, and the flamethrower
*replaces* `ThinkWeapon`/`PrimaryAttack`/`Holster` surgically (§5).

`mcv_chainsaw` and `mcv_lunge_mine` are the proof that the special bases are themselves
inheritable: both set `SWEP.Base = "mcv_melee"` and override individual attack functions
(§7, §12).

### 1.2 The shared contract every special base relies on

The common `Think` (from `weapon_common`, mixed or inherited into every base):

```lua
-- mcv/weapon_common/sh_think.lua:1-26
function SWEP:Think()
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    // In singleplayer this hook also runs on the client, but the client is NOT predicting
    // there: anything it writes to a NetworkVar is overwritten by the next server update.
    if CLIENT and game.SinglePlayer() then return end

    self:SyncViewModel()
    self:Think_Speed()
    self:Think_HoldType()
    self:Think_Bayonet()

    self:DoBodygroups(nil, false)

    self:ProcessDeferred()

    if self:GetNextIdle() <= CurTime() then
        self:Idle()
    end

    self:ThinkWeapon()
end
```

`ThinkWeapon` is the single extension hook each special base implements (the default is a
no-op, mcv/weapon_common/shared.lua:337). Everything above it — movement blend integration,
hold types, deferred action processing, idle restart — is common and must not be re-implemented.

Other common systems the special bases lean on:

- **Deploy/Holster** (`sh_deploy.lua`): `Deploy` resets action state
  (`SetActionState(0)`, `SetActionStart(0)`, sh_deploy.lua:57-58), cancels pending defers,
  plays `ACT_VM_READY`/`ACT_VM_DRAW`, and calls the base's `OnDeploy()`. Holster defers the
  actual switch through `HolsterTime`/`HolsterCommand` (animation-system.md §7.1-7.2).
- **Fixed datatable**: `SetupDataTables` is defined once in
  mcv/weapon_common/shared.lua:196-285; *"Derived bases must not redefine SetupDataTables"*
  (shared.lua:195). Every special base stores its state in pre-allocated slots.
- **Playback** (`sh_anim.lua`): `PlayAnimation(act, mult, lock, noidle)` /
  `PlaySequence(name, ...)` (animation-system.md §2). Note for equipment bases specifically:

  > *The game's equipment models use activities GMod does not define (ACT_VM_SLASH,
  > ACT_VM_PLANT, ACT_VM_GIVE...), but their sequence names are consistent per weapon type,
  > so the equipment bases address them directly.* — sh_anim.lua:100-102

  **The four mixed-in equipment bases are 100% sequence-name driven** (except
  deploy/holster/idle, which use `ACT_VM_DRAW`/`ACT_VM_HOLSTER`/`ACT_VM_IDLE` from the common
  layer). This is the reverse of the gun base, which is activity-driven.
- **Ammo helpers**: `GetRoundsLeft()`/`TakeRound(n)` — clip-less weapons (grenades, mines,
  boxes) count their rounds directly in the reserve (mcv/weapon_common/shared.lua:382-400).
- **Bash**: `weapon_common/sh_bash.lua:19-41` — USE+attack melee swing available to
  throwable, placeable, flamethrower, binoculars (each base routes its own input to it).
- **Stat multipliers**: `SWEP:StatMult(stat)` reads the server's per-category convar dials
  (mcv/shared/sh_categories.lua; AGENTS.md). Equipment bases multiply `firerate`, `damage`,
  `explosion_damage`, `explosion_radius`, `projectile_speed` through it.
- **World model drawing**: `cl_worldmodel.lua` bone-merged clientside copy, PVS retirement,
  `GetWorldModelFor` — the flamethrower's world stream attaches to it.

### 1.3 The equipment action pattern: `ActionState` + `DeferredActions`

All four mixed-in bases (and the underbarrel flame) run their multi-stage actions through one
shared shape, documented at the top of `sh_timers.lua`:

```lua
-- mcv/weapon_common/sh_timers.lua:1-16 (comment) and 19-33 (code)
// A queued closure cannot predict. ... What replaces it is the shape NextPrimaryFire already
// has: a deadline in a networked float, compared against CurTime in the predicted think.
// Because a closure cannot travel, a class lists the actions it can defer in
// SWEP.DeferredActions in a fixed order; the index into that list is what is networked, so
// both realms read the same name out of the same number, and the handler is the method named
// Deferred_<name>.
//
// One stage is pending at a time. Multi-stage actions keep ActionEnd and their arguments in
// NetworkVars, then schedule the next stage from the handler. Every stage can be replayed.

function SWEP:Defer(name, delay)
    local id = 0

    for i, n in ipairs(self.DeferredActions) do
        if n == name then
            id = i
            break
        end
    end

    if id == 0 then return end

    self:SetDeferredAction(id)
    self:SetDeferredTime(CurTime() + delay)
end
```

`ProcessDeferred` (sh_timers.lua:46-57) runs from `Think` on both realms, fires
`Deferred_<name>` once when due, and `CancelDeferred` (sh_timers.lua:41-44) wipes it (used
when a hold state is aborted).

Per-base action lists (the index order travels between realms — **append, never insert**,
per mcv_base/shared.lua:151-153):

| Base | `SWEP.DeferredActions` | Defined at |
| --- | --- | --- |
| `mcv_base` (for contrast) | `BayonetOff, AkimboSwap, LauncherSwap, BayonetLoop, BayonetHit, ReloadInsert` | weapons/mcv_base/shared.lua:153 |
| `mcv_melee` | `SlashHit, StabHit, ChargeLoop, ChargeHit, ThrowLoop, ThrowBlade, RepairLoop` | weapons/mcv_melee/sh_melee.lua:10 |
| `mcv_throwable` | `ThrowRelease, ThrowEnd` | weapons/mcv_throwable/sh_throw.lua:6 |
| `mcv_placeable` | `Place, PlaceEnd, ThrowLit` | weapons/mcv_placeable/sh_place.lua:6 |
| `mcv_equipment_box` | `BoxUse, BoxEnd, BoxDrop` | weapons/mcv_equipment_box/sh_box.lua:1 |
| `mcv_underbarrel_flame` | `FlamePulse` (see §6.4 — **replaces** the inherited list) | weapons/mcv_underbarrel_flame/shared.lua:11 |

The NetworkVar slots the special bases draw from the fixed shared datatable
(mcv/weapon_common/shared.lua:196-285):

| Accessor | Slot | Used by |
| --- | --- | --- |
| `ActionState` (Int 3) | equipment state machine | melee, throwable, placeable, box, chainsaw, lunge mine |
| `ActionStart` (Float 9) | when the current hold/charge/plant began | melee (charge/throw/repair), throwable (cook start), chainsaw |
| `ActionEnd` (Float 11) | when the current stage finishes | throwable, placeable, box, underbarrel flame |
| `ActionVariant` (Int 7) | stage argument (kind/roll/stake/self) | throwable, placeable, box |
| `ActionTarget` (Entity 2) | box give target | equipment box |
| `DeferredAction`/`DeferredTime` (Int 5 / Float 10) | pending stage | all |
| `NextRepairTime` (Float 12) | wrench repair tick gate | melee |
| `WindupEnd` (Float 13) | pin-pull animation end | throwable |
| `SlashCount` (Int 8) | swing variant cycle | melee |
| `SupplyCursor` (Int 12) | ammo pool rotation | equipment box |
| `PrimedAttack` (Bool 12) | reused as "flaming"/"sawing" flag | flamethrower, chainsaw |
| `LastClip` (Int 1), `AmmoSwitchFrom` (Int 14) | cartridge swap bookkeeping | M79 |
| `Firemode` (Int 2) | fuse preset / cartridge select | throwable, M79 |
| `ScopeLevel` (Int 0) | zoom step | binoculars |
| `WasRunning` (Bool 14) | run transition edge | melee |

One deliberate exception: the placeable's mine handle is **not** a NetworkVar — *"Slot 1 was
the server-created mine handle; it now uses a non-predicted NWEntity"*
(mcv/weapon_common/shared.lua:279), read via `SWEP:GetPlacedMine()`
(weapons/mcv_placeable/sh_place.lua:10-12). A server entity created mid-prediction has no
client-predictable handle, so the authoritative reference stays outside the datatable while
the placement stage itself remains predicted.

### 1.4 House conventions across the family

- **Input chording**: USE+attack is bash everywhere; USE+reload is "cycle a setting" (fuse
  preset, flamethrower firemode, binoculars magnification — see §9.3 for a hint/code
  mismatch); sprint+attack is the melee charge; walk+use is the UBGL toggle (gun base).
- **Empty depletion**: throwable, placeable and equipment box all end with the same
  `timer.Simple(0)` → `StripWeapon` → `SelectWeapon(other)` snippet when the last round is
  used (sh_throw.lua:251-260, sh_place.lua:288-296, sh_box.lua:178-185), except the C4 which
  stays as a detonator (§4.8).
- **Entity hand-off**: every base writes its tuned numbers onto a freshly created entity
  *before* `Spawn()` (model, damage, attacker/inflictor, fuse), because the projectile
  entities are dumb defaults and the weapon owns the category multipliers (AGENTS.md:42-46;
  docs/projectiles-entities.md).
- **`GetControlHints`**: each base implements it for the HUD's control legend
  (mcv/weapon_common/cl_hud.lua:299, 335-336).

---

## 2. Melee Base — `weapons/mcv_melee`

### 2.1 Purpose and files

Knives, bayonets, machetes, shovels, fists, wrench — and, through inheritance, the chainsaw
and lunge mine. Left click slashes, right click stabs, sprint+attack charges, USE+attack
throws the blade (models that have a throw animation), and the wrench repairs vehicles with
right click (weapons/mcv_melee/shared.lua:3-5). Two files:

- `shared.lua` (76 lines) — defaults + `MCV.IncludeWeaponModules`
- `sh_melee.lua` (498 lines) — all logic

It keeps an explicit dependency include for live Lua refresh at the top of both its own file
and the chainsaw's: `if !MCV.MeleeBloodColor ... include("mcv/shared/sh_melee_effects.lua")`
(sh_melee.lua:1-2).

Local state constants (sh_melee.lua:4-8):

```lua
local STATE_IDLE = 0
local STATE_CHARGE = 1
local STATE_THROW_HOLD = 2
local STATE_REPAIR = 3
local STATE_RUNNING = 4 // only marks that the run transition was played
```

(`STATE_RUNNING` is never set — `WasRunning` (Bool 14) carries the run edge instead; the
constant documents the original intent.)

HUD stubs: `GetFiremodeName() -> ""` and `GetHUDAmmo() -> nil, nil` (sh_melee.lua:12-13) hide
the firemode/ammo readouts guns show.

### 2.2 Field catalogue

| Field | Type | Default | Set at | Consumed at |
| --- | --- | --- | --- | --- |
| `DamageGeneric` | number | 42 | shared.lua:21 | slash damage (`Deferred_SlashHit`, :452) |
| `DamageGenericAlt` | number | 63 | shared.lua:22 | stab/charge/throw damage via `GetStabDamage` (:26-28) |
| `MeleeRange` | number | 56 | shared.lua:23 | slash trace reach |
| `MeleeRangeAlt` | number | 64 | shared.lua:24 | stab/charge/repair trace reach |
| `ChargeDamageMultiplier` | number | 2 | shared.lua:25 | `Deferred_ChargeHit` (:460) |
| `MeleeHullSize` | number | 12 | shared.lua:26 | `MeleeTrace` hull half-extent (:38-43) |
| `SlashRate` / `StabRate` | number / nil | 150 / nil | shared.lua:28-29 | `SwingDelay` cadence (:102-106) |
| `HitDelay` / `StabHitDelay` | number | 0.12 / 0.2 | shared.lua:30-31 | hit deferral into the swing (:123, :137) |
| `CanThrow` | bool | true | shared.lua:33 | `CanThrowNow` (:180-182) |
| `ThrowForce` | number | 1600 | shared.lua:34 | `LaunchBlade` velocity (:241) |
| `ThrowDamage` | number | nil | shared.lua:35 | thrown blade damage (:229) |
| `ThrownEntity` | string | `"mcv_thrown_melee"` | shared.lua:36 | `LaunchBlade` (:223) |
| `CanRepair` | bool | false | shared.lua:38 | `SecondaryAttack` repair gate (:435) |
| `RepairPerSecond` | number | 40 | shared.lua:39 | `RepairTick` (:333) |
| `SoundHitFlesh/World`, `SoundThrustFlesh/World`, `SoundSwing` | string | M1942 set / `""` | shared.lua:43-47 | `MeleeHit` (:86-89), `Slash` (:120) |
| `SequencesSlash` | table | `{"slash","slash2","swing_a","swing_b","swing_c"}` | shared.lua:50 | `Slash` (:114) |
| `SequencesMiss` | table | `{"miss","miss2"}` | shared.lua:51 | `Slash` (:114) |
| `SequencesStab` | table | `{"stab","swing_hard"}` | shared.lua:52 | `Stab` (:131) |
| `SequenceChargeStart/Loop` | string | `"stab_charge"` / `"stab_charge_loop"` | shared.lua:53-54 | charge (:146, :150, :464) |
| `SequencesChargeAttack` | table | `{"stab_charge_attack","stab","swing_hard"}` | shared.lua:55 | `ChargeAttack` (:158) |
| `SequenceThrow/ThrowStart/ThrowLoop/ThrowCancel` | string | `"throw"` etc. | shared.lua:56-59 | blade throw (:181-215, :469-473) |
| `SequenceRun` / `SequenceIdleToRun` / `SequenceRunToIdle` | string | `"run"` / `"idletorun"` / `"runtoidle"` | shared.lua:60-62 | `IdleSequence` (:356-358), run transitions (:372-375) |
| `SequenceRepairStart/Loop/End` | string | `"idletorepair"` / `"repair"` / `"repairtoidle"` | shared.lua:63-65 | repair (:310-322, :479-483) |
| `ShootGesture` | activity | `ACT_HL2MP_GESTURE_RANGE_ATTACK_KNIFE` | shared.lua:17 | `Slash`/`Stab` third person (:118, :135) |
| `ChargeGesture` | activity | `ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND` | shared.lua:18 | `ChargeAttack` (:160) |

Note the base sets `SWEP.Base = "weapon_base"` (shared.lua:7) — it is a sibling of `mcv_base`,
not a child (§1.1).

### 2.3 Hit detection: `MeleeTrace` and `MeleeHit`

```lua
-- weapons/mcv_melee/sh_melee.lua:34-47
function SWEP:MeleeTrace(range)
    local owner = self:GetOwner()
    local dir = self:GetAimVector()
    local src = owner:GetShootPos()
    local dim = self.MeleeHullSize

    local tr = util.TraceLine({start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT})
    if !tr.Hit then
        tr = util.TraceHull({start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT_HULL,
                             mins = Vector(-dim, -dim, -dim), maxs = Vector(dim, dim, dim)})
    end

    return tr
end
```

A cheap line first (exact hit point for effects), a cube hull (`MeleeHullSize`) as the
fallback so near misses still connect. `GetAimVector` includes view punch
(mcv/weapon_common/shared.lua:363-371). The lunge mine and chainsaw wrap calls to
`MeleeTrace` in `owner:LagCompensation(true/false)` (mcv_lunge_mine.lua:61-63,
mcv_chainsaw.lua:68-70) — the base itself does **not** lag-compensate (see §2.15).

`MeleeHit(range, damage, thrust)` (sh_melee.lua:53-94) is the single damage path:

- **Damage**: `DamageInfo` with `SetDamageType(thrust and DMG_SLASH or (DMG_SLASH + DMG_CLUB))`
  and force `dir * damage * 400` (:66-67) — a thrust runs the blade in, a swing knocks. Applied
  **server only** (`if SERVER then ent:TakeDamageInfo(dmginfo)` :71-74).
- **Blood**: `MCV.MeleeBloodColor(ent)` / `MCV.MeleeBloodImpact(tr, blood)`
  (mcv/shared/sh_melee_effects.lua:16-34) — custom red/green/orange PCF systems avoiding
  Source's `blood_impact_red_01` name collision, dispatched once from the server including
  delivery to the predicting shooter (`util.Effect(..., true, true)`, sh_melee_effects.lua:33).
- **Surface impact**: *"One authoritative surface impact, using the actual melee hull contact.
  Client replay must not fire cosmetic bullets or receive a second local effect"* (:77-83) —
  `MCV.SurfaceImpact(tr, damage)` (docs/effects.md) and only the stock fallback
  zero-damage `FireBullets` when custom impacts are off.
- **Sounds** chosen by flesh vs world and thrust vs swing (:85-89); **view punch**
  `Angle(thrust and 4 or 2, ...)` (:91).

`isFlesh` (sh_melee.lua:49-51) = player / NPC / NextBot / `prop_ragdoll`.

### 2.4 Attack cadence — `SwingDelay`

```lua
-- weapons/mcv_melee/sh_melee.lua:100-106
// Seconds between one attack and the next. A melee weapon's cadence is its rate: the
// animations are as long as they are, and waiting on them made even a quick knife feel slow.
function SWEP:SwingDelay(rate)
    rate = math.max((rate or self.SlashRate or 150) * self:StatMult("firerate"), 1)

    return 60 / rate
end
```

Cadence is **rate-driven, not animation-driven**: a swing is not locked to its animation
length (`Slash` plays unlocked). 150 RPM default → 0.4 s between swings.

### 2.5 `Slash` — the primary attack

```lua
-- weapons/mcv_melee/sh_melee.lua:108-127
function SWEP:Slash()
    local owner = self:GetOwner()
    self:SetSlashCount(self:GetSlashCount() + 1)

    // decide hit / miss up front so the right animation plays
    local tr = self:MeleeTrace(self.MeleeRange)
    local seq = tr.Hit and self:PickSequence(self.SequencesSlash, self:GetSlashCount()) or self:PickSequence(self.SequencesMiss, self:GetSlashCount())
    seq = seq or self:PickSequence(self.SequencesSlash, self:GetSlashCount())

    local t = seq and self:PlaySequence(seq, 1, false) or 0.5
    owner:DoAnimationEvent(self.ShootGesture)

    if self.SoundSwing != "" then self:EmitSound(self.SoundSwing) end

    if tr.Hit then
        self:Defer("SlashHit", math.min(self.HitDelay, t))
    end

    self:SetNextPrimaryFire(CurTime() + self:SwingDelay(self.SlashRate))
end
```

Key behaviors:

- **Hit/miss decided up front** — the trace runs *before* the animation so the miss variant
  (`SequencesMiss`) plays when nothing is in reach; if the model has no miss sequences the
  slash list is used (:115).
- `PickSequence(list, index)` (:16-24) returns the first sequence of a list the model has,
  cycling by `index` — the shared-random variant picker, driven by the networked
  `SlashCount`.
- The hit lands later, at `min(HitDelay, animLength)` into the swing, through the deferred
  `SlashHit` → `MeleeHit(self.MeleeRange, self.DamageGeneric, false)` (:451-453).
- Only `NextPrimaryFire` is pushed (stabs push both, §2.6).

### 2.6 `Stab` — the secondary attack

`Stab` (sh_melee.lua:129-142) requires a stab sequence or falls back to `Slash` (:132); plays
unlocked, defers `StabHit` at `min(StabHitDelay, t)`, and gates **both** `NextPrimaryFire`
and `NextSecondaryFire` by `SwingDelay(self.StabRate)` — `StabRate` defaults to nil, i.e. the
slash rate (shared.lua:29). Damage = `GetStabDamage()` = `DamageGenericAlt or DamageGeneric
* 1.5` (:26-28) at `MeleeRangeAlt` with `thrust = true` (:455-457).

### 2.7 Charge — sprint attack state machine

```lua
-- weapons/mcv_melee/sh_melee.lua:144-152
// Sprint + attack: wind up, run with the blade forward, hit whatever comes in reach.
function SWEP:StartCharge()
    if !self:HasSequence(self.SequenceChargeStart) then return self:Stab() end

    self:SetActionState(STATE_CHARGE)
    self:SetActionStart(CurTime())
    local t = self:PlaySequence(self.SequenceChargeStart, 1, true) or 0.4
    self:Defer("ChargeLoop", t)
end
```

Driven from `ThinkWeapon` (sh_melee.lua:379-389): charging continues only while IN_ATTACK is
held **and** the player still sprints (`GetIsSprinting` = movement keys + IN_SPEED,
mcv/weapon_common/sh_think.lua:32-36); after 0.3 s of wind-up a `MeleeTrace(MeleeRangeAlt)`
runs every tick and any valid contact triggers `ChargeAttack()`; the charge times out after
4 s. `ChargeAttack` (:154-167) plays a `SequencesChargeAttack` entry unlocked, gestures with
`ChargeGesture`, and defers `ChargeHit` at `min(0.1, t)` — damage
`GetStabDamage() * ChargeDamageMultiplier` at `MeleeRangeAlt`, thrust (:459-461). This is the
melee twin of the gun base's bayonet charge (animation-system.md §7.10,
sh_bayonet_charge.lua). `EndCharge` (:169-174) cancels defers, resets state, and applies a
0.3 s primary cooldown.

`Deferred_ChargeLoop` (:463-467) then plays `SequenceChargeLoop` **unlocked with noidle**
(`PlaySequence(seq, 1, false, true)`) — a looping sequence keeps cycling engine-side while
`NextIdle = math.huge` stops the idle restart (animation-system.md §2.1).

### 2.8 Throwing the blade

Gated by `CanThrowNow()` = `self.CanThrow and self:HasSequence(self.SequenceThrow)`
(:180-182). The gesture is **USE+attack to wind up, and the attack released while USE is
still held throws**:

- `BeginThrow` (:184-193): if the model has `SequenceThrowStart` → `STATE_THROW_HOLD`,
  locked wind-up, `Defer("ThrowLoop", t)` (loop played unlocked+noidle by
  `Deferred_ThrowLoop`, :469-473). Otherwise it throws immediately.
- `ThinkWeapon` STATE_THROW_HOLD (:390-397): when IN_ATTACK is released — still holding USE →
  `ThrowBlade()`; without USE → `CancelThrow()` (plays `SequenceThrowCancel` locked or just
  re-arms idle, :195-203).
- `ThrowBlade` (:205-215): plays `SequenceThrow` locked, grenade throw gesture, defers
  `ThrowBlade` at `min(0.15, t)`, `NextPrimaryFire = now + t`.
- `LaunchBlade` (:217-253) — **server only** (`if CLIENT then return end`, :218): spawns
  `ThrownEntity` with `Model`/`WeaponClass`/`Inflictor` (*"the kill icon is the weapon's, not
  the blade in flight"*, :228)/`Damage` (`ThrowDamage or GetStabDamage()`)/`SoundFlesh`/
  `SoundWorld`/`Attacker`, positioned at `shootpos + fwd * 8`, velocity
  `fwd * ThrowForce + owner velocity`, spin `(0, 1500, 0)`; then, next tick,
  `StripWeapon(class)` and auto-select the first remaining weapon (:245-252).

The projectile (`entities/mcv_thrown_melee.lua`) sticks where it lands
(`ENT.Sticky = true`, mcv_thrown_melee.lua:12), deals its `Damage` once on impact with
`DMG_SLASH` (:27-45), and **USE picks it back up** — `Use(ply)` gives `WeaponClass` and
selects it, *"fetching a thrown blade is a deliberate walk over to it, so it is what you
meant to be holding"* (:52-62). Full entity detail: docs/projectiles-entities.md.

### 2.9 Repair — the wrench subsystem

Two globals plus three methods:

- `MCV_VehicleHealth(ent)` (sh_melee.lua:262-274): understands LVS (`GetHP/GetMaxHP/SetHP`,
  the same interface as LVS's own `weapon_lvsrepair`), simfphys
  (`IsSimfphyscar + GetCurHealth/GetMaxHealth`), and plain vehicles / Glide vehicles with
  health. Returns current, max or nil.
- `MCV_VehicleRepair(ent, amount)` (:276-294): refuses full-health non-destroyed vehicles,
  clamps to max, un-destroys (`SetDestroyed(false)`), fires `OnRepaired()`, returns whether
  anything was healed.
- `GetRepairTarget` (:296-305): 96-unit eye trace; if the hit entity itself is not repairable
  but its **parent** is (LVS engine/armor plate), targets the parent.
- `StartRepair` (:307-313): `STATE_REPAIR`, locked `SequenceRepairStart`, sets
  `NextRepairTime` (NetworkVar Float 12) and defers `RepairLoop`.
- `RepairTick` (:325-345): every 0.25 s while IN_ATTACK2 is held; drops out entirely if the
  target or the repair fails; server side applies
  `MCV_VehicleRepair(ent, RepairPerSecond * 0.25)` and a `Sparks` `util.Effect` at the eye
  trace; emits `metal_box_impact_soft1-3` on both realms.
- `EndRepair` (:315-323) cancels and plays `SequenceRepairEnd` or re-arms idle;
  `Deferred_RepairLoop` (:479-483) plays the loop **without** noidle, so idle restarts it —
  unlike charge/throw loops.

Entry: `SecondaryAttack` (:428-441) — requires a fresh IN_ATTACK2 press; if `CanRepair` and a
repair target is in reach, repairs instead of stabbing.

### 2.10 Idle, run transitions

`IdleSequence` (sh_melee.lua:351-361) is the base's idle override: charge/throw-hold/repair
loops by name, then — uniquely for melee — a **run idle** (`SequenceRun`) whenever
`GetSpeed() >= SpeedSprintThreshold` (150 u/s). `ThinkWeapon` also plays one-shot
`SequenceIdleToRun`/`SequenceRunToIdle` transitions on the running edge, only from IDLE and
only when not `StillWaiting()` (:367-377).

### 2.11 `ThinkWeapon` and input routing

`ThinkWeapon` (:363-405) is purely the state-machine ticker described above (run edges,
charge, throw hold, repair). Input entry points:

- `PrimaryAttack` (:407-426): blocked by `StillWaiting()` or non-IDLE state; USE held →
  `BeginThrow` (if possible) and return; sprinting → `StartCharge`; otherwise `Slash`.
- `SecondaryAttack` (:428-441): same gates plus `KeyPressed(IN_ATTACK2)`; repair if
  applicable, else `Stab`.
- `Reload` (:443-444): empty — nothing to reload.
- `OnDeploy` (:446-449): reset `ActionState` and `WasRunning` (deploy itself already resets
  state, sh_deploy.lua:57).

Because `PrimaryAttack` still fires every tick while the button is held
(`Primary.Automatic = true`, shared.lua:70), the cadence gate is `NextPrimaryFire` via
`StillWaiting()`.

### 2.12 Derivatives

All ten melee weapons in this snapshot are field-only definitions
(`SWEP.Base = "mcv_melee"`, no code):

| Weapon | File | Notable fields |
| --- | --- | --- |
| Crowbar | mcv_crowbar.lua | `DamageGeneric 25`, range 48/64, `CanThrow false`, melee holdtype |
| Fists | mcv_fists.lua | `DamageGeneric 20`, range 32/42, fist holdtype, custom hints "Jab/Hook/Charge" (:40-46) |
| Katana | mcv_katana.lua | `DamageGenericAlt 90`, range 64/72, `SlashRate 120` |
| Sickle | mcv_sickle.lua | base stats; `CanThrow true` (the only thrower of the plain six) |
| ChiCom Shovel | mcv_shovel_vc.lua | `DamageGeneric 30`, `BodyGroups "1"`, shovel sounds |
| Wrench | mcv_wrench.lua | `CanRepair true`, `SlashRate 75`, `WeaponWeight 5` |
| 6H2 Bayonet | mcv_ak47_bayonet.lua | `SWEP.IsBayonet = true` — carrying it lets rifles fix bayonets (sh_bash.lua:112-119); `CanThrow true` |
| Type 30 Bayonet | mcv_type30_bayonet.lua | `IsBayonet true`, `DamageGenericAlt 75`, `CanThrow true` |
| Chainsaw | mcv_chainsaw.lua | code-heavy, §7 |
| Lunge Mine | mcv_lunge_mine.lua | code-heavy, §12 |

A derivative needs only: models, `MovementPose*` (walk/sprint layer endpoints, §4.2 of the
animation doc), damage/range/rate, sounds, and the optional booleans. **Everything else is
auto-detected from the model** by `PickSequence`/`HasSequence` — a model with no `miss`
sequences still works, a model with no `stab_charge` charges via `Stab()` instead, etc.

### 2.13 Prediction & realm notes

- Damage, blood and surface impacts are **server-only**; the swing animation, gesture, swing
  sound and view punch run on both realms (predicted; `EmitSound` on the weapon dedupes).
- `MeleeHit`'s zero-damage `FireBullets` fallback is server-only — *"Client replay must not
  fire cosmetic bullets"* (sh_melee.lua:77-83).
- All stage timing rides the networked deferred action (§1.3), so a rollback replays it.
- The base does **not** call `LagCompensation` itself; only the chainsaw and lunge mine
  derivatives add it around their trace calls. Fast-moving melee combat against strafing
  players is therefore uncompensated on the plain melee base (observable as edge-of-range
  misses; upstream accepts this).
- `SlashCount` is networked (Int 8) so the server and predicting client pick the same swing
  variant.

### 2.14 Upstream notes (BUGLIST)

- *"Damage-scaled impact particles ... Melee/bashes now dispatch their custom impact once on
  the server from the contact trace, using strike damage"* (BUGLIST.md:147).
- Melee/bayonet prediction rollback work: *"Grenade releases, melee hits, bayonet charges,
  placement and supply-box actions could lose or repeat their pending work after prediction
  rollback. Their stages, deadlines and arguments now live in NetworkVars"* (BUGLIST.md:326).
- The custom blood PCF work: BUGLIST.md:51.

---

## 3. Throwable Base — `weapons/mcv_throwable`

### 3.1 Purpose and files

Hand grenades, smoke, gas, incendiaries (weapons/mcv_throwable/shared.lua:3-5). Left click
winds up an overhand throw, right click an underhand lob (a roll when crouched); the grenade
leaves the hand when the button is released; USE+reload cycles fuse presets; USE+attack
bashes. Files: `shared.lua` (64) + `sh_throw.lua` (337).

States (sh_throw.lua:1-4): `STATE_IDLE 0`, `STATE_WINDUP_HIGH 1`, `STATE_WINDUP_LOW 2`,
`STATE_THROWING 3`.

### 3.2 Field catalogue

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `ThrowEntity` | string | `"mcv_grenade_frag"` | projectile class (shared.lua:20) |
| `ThrowModel` | string | nil | world model override for the projectile (defaults to `WorldModel`) |
| `ThrowForceOverhand/Underhand/Roll` | number | 1250 / 600 / 450 | shared.lua:22-24 |
| `ThrowSpin` | number | 400 | random tumble angular velocity (:25) |
| `ThrowReleaseTime` / `ThrowReleaseTimeUnderhand` | number | 0.22 / 0.3 | seconds into the throw anim when it leaves the hand (:27-28) |
| `FuseModes` | table | `{3, 5}` | seconds; USE+reload cycles (:31) |
| `FuseImpact` | bool | false | explodes on first touch instead (molotov); no cooking, one mode (:32) |
| `ExplosionDamage` / `ExplosionRadius` | number | 150 / 350 | passed to the projectile with category multipliers (:35-36) |
| `IgniteRadius` | number | 0 | incendiary fire pool (:37) |
| `SmokeColor` | Vector | nil | coloured smoke (:38) |
| `EffectDuration` | number | 25 | smoke/gas/fire duration (:39) |
| `HasUnderhand` | bool | true | right-click underhand (:41) |
| `RemoveWhenEmpty` | bool | true | strip the weapon after the last grenade (:42) |
| `SequenceWindupHigh/ThrowHigh/WindupLow/ThrowLow/Roll/Firemode` | string | `"drawbackhigh"/"throw"/"drawbacklow"/"lob"/"roll"/"firemode"` | shared.lua:45-50 |
| `ModelSkin` | number | nil | skin for viewmodel + projectile (Part 2 M18/M6A1 separation; used at sh_throw.lua:10, :215) |
| `BashDamage` / `BashRange` | number | 30 / 72 | shared.lua:57-58 |
| `Primary.Ammo` | string | `"mcv_grenade"` | MCV-registered reserve-counted ammo (mcv/shared/sh_common.lua:66-67) |

`Initialize` (sh_throw.lua:8-11) calls `MCV.WeaponCommon.Initialize(self)` then applies
`ModelSkin`; `DoBodygroupsWeapon` (sh_throw.lua:13-17) keeps the viewmodel skin in sync.

### 3.3 Hold types follow the state

The base overrides the common `Think_HoldType` so **a pulled grenade is never hidden by the
sprint pose**, including for remote players (state is networked):

```lua
-- weapons/mcv_throwable/sh_throw.lua:19-30
// Derive this from predicted/networked action state, including for remote players.
// Sprinting must not hide a pulled grenade. Both releases use the grenade throw gesture.
function SWEP:Think_HoldType()
    local state = self:GetActionState()
    local hold = "slam"
    if state == STATE_WINDUP_LOW then
        hold = "melee2"
    elseif state == STATE_WINDUP_HIGH or state == STATE_THROWING then
        hold = "grenade"
    end
    if self:GetHoldType() != hold then self:SetHoldType(hold) end
end
```

Called directly from `Windup`/`Throw`/`Deferred_ThrowEnd`/`OnDeploy` as well as the common
Think (upstream BUGLIST.md:205).

### 3.4 Windup and pin timing

```lua
-- weapons/mcv_throwable/sh_throw.lua:93-104
function SWEP:Windup(low)
    self:SetActionState(low and STATE_WINDUP_LOW or STATE_WINDUP_HIGH)
    self:Think_HoldType()
    self:SetActionStart(CurTime())

    local seq = low and self.SequenceWindupLow or self.SequenceWindupHigh
    if !self:HasSequence(seq) then seq = self.SequenceWindupHigh end

    // hold the last frame until the button is released
    local t = self:PlaySequence(seq, 1, false, true) or 0.5
    self:SetWindupEnd(CurTime() + t)
end
```

The windup is **unlocked but noidle** — the last frame is held for as long as the button
stays down. `WindupEnd` (Float 13) marks when the pin-pull animation is over; the grenade
cannot leave the hand before that (BUGLIST.md:348: *"Grenades can be thrown before the
pin-pull animation finishes"* — fixed). A model without the underhand windup falls back to
the overhand animation while keeping the low state (:98-99).

### 3.5 Cooking and overcook

`GetCookTime()` (sh_throw.lua:86-91): 0 when idle; otherwise `CurTime() - GetActionStart()` —
**the fuse runs from the pin pull** (comment :84-85). In `ThinkWeapon`
(sh_throw.lua:290-298):

- cook time ≥ fuse → `Throw(low, true)` — the overcooked path: the throw is forced and the
  grenade detonates as/before it leaves the hand;
- button released and `CurTime() >= GetWindupEnd()` → `Throw(low)`.

Impact-fused throwables (`FuseImpact`) never cook — `GetCookTime` returns 0
(:87) and `GetFuseModes` collapses to `{0}` (:35-38, the nested-table inheritance guard —
BUGLIST.md:405).

### 3.6 Throw and release deferral

```lua
-- weapons/mcv_throwable/sh_throw.lua:107-138 (excerpt)
function SWEP:Throw(low, overcooked)
    local owner = self:GetOwner()
    local roll = low and owner:Crouching() and self:HasSequence(self.SequenceRoll)
    ...
    self:SetActionState(STATE_THROWING)
    self:Think_HoldType()

    local t = self:PlaySequence(seq, 1, true) or 0.5
    local release = math.min(low and self.ThrowReleaseTimeUnderhand or self.ThrowReleaseTime, t)
    self:SetActionEnd(CurTime() + t)
    self:SetActionVariant(roll and 2 or (low and 1 or 0))
    ...
    owner:DoAnimationEvent(self.ShootGesture)

    if overcooked then
        self:LaunchThrowable(kind, fuse, cookstart)
        self:Defer("ThrowEnd", t)
    else
        self:Defer("ThrowRelease", release)
    end

    self:SetNextPrimaryFire(CurTime() + t)
end
```

- An underhand throw becomes a **roll** when crouched and the model has the `roll` sequence.
- The throw animation itself is locked; `ActionVariant` stores the kind (2 roll / 1 low / 0
  high) so the deferred release can reconstruct it without a closure.
- `Deferred_ThrowRelease` (:140-145) calls `LaunchThrowable` and chains
  `Defer("ThrowEnd", remaining)`; `Deferred_ThrowEnd` (:147-151) returns to IDLE and calls
  `AfterThrow`.

### 3.7 `LaunchThrowable` — geometry and the entity contract

```lua
-- weapons/mcv_throwable/sh_throw.lua:155-191 (excerpt)
function SWEP:LaunchThrowable(kind, fuse, cookstart)
    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    self:TakeRound(1)

    if CLIENT then return end

    local remaining = fuse
    if !self.FuseImpact and cookstart then
        remaining = math.max(fuse - (CurTime() - cookstart), 0)
    end

    local ang = self:GetAimAngle()
    local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()

    local pos = owner:GetShootPos() + fwd * 12 + right * 6
    local force = self.ThrowForceOverhand
    local dir = (fwd + up * 0.12):GetNormalized()

    if kind == "low" then
        pos = pos - up * 12
        force = self.ThrowForceUnderhand
        dir = (fwd + up * 0.25):GetNormalized()
    elseif kind == "roll" then
        // Keep the cylinder axle horizontal even when aiming up/down. Local Z
        // points to the player's right, perpendicular to the roll direction.
        ang = Angle(0, ang.y, 90)
        fwd = ang:Forward()
        pos = owner:GetShootPos() + fwd * 12 + ang:Up() * 6 - vector_up * 20
        force = self.ThrowForceRoll
        dir = (fwd - vector_up * 0.15):GetNormalized()
    end

    // do not spawn inside a wall
    local tr = util.TraceLine({start = owner:GetShootPos(), endpos = pos, filter = owner, mask = MASK_SOLID})
    if tr.Hit then pos = tr.HitPos - fwd * 2 end
```

Then (:193-238): creates `ThrowEntity`, writes `Model` (`ThrowModel or WorldModel`),
`Delay = remaining`, `ImpactFuse`/`ExplodeOnImpact`/`TimeFuse = false` when `FuseImpact`,
`ExplosionDamage/Radius` scaled by `StatMult("explosion_damage"/"explosion_radius")`,
`IgniteRadius`, `EffectDuration`, `SmokeColor`, `Attacker`, `Inflictor`; `SetSkin`; and:

- **Overcook in-hand**: `remaining <= 0 and !FuseImpact` → `ArmTime = CurTime()`,
  `Armed = true`, `ent:PreDetonate()` — it goes off in the hand (:218-224).
- Physics: `SetVelocityInstantaneous(dir * force + owner:GetVelocity())`; a roll gets
  matching forward spin (`math.deg(velocity:Dot(fwd) / ent.RollRadius)` — angular velocity is
  local degrees/sec, :230-234), anything else `VectorRand() * ThrowSpin` (:236).

The entity fields consumed here (`Delay`, `ArmTime`, `Armed`, `ImpactFuse`,
`ExplodeOnImpact`, `TimeFuse`, `PreDetonate`) are the projectile base's interface —
entities/mcv_grenade_base.lua and mcv_proj_base.lua, documented in
docs/projectiles-entities.md. The roll axis trick pairs with the grenade base's fitted
64-sided convex cylinder collision (mcv_grenade_base.lua:33-60; BUGLIST.md:203).

### 3.8 After the throw

`AfterThrow` (sh_throw.lua:241-261): more grenades (or `RemoveWhenEmpty false`) → play
`ACT_VM_DRAW` locked (the next one comes up); otherwise the server strips the weapon next
tick and selects the survivor (:246-260).

### 3.9 Fuse modes

`GetFuseTime` (sh_throw.lua:40-45) = `FuseModes[Clamp(Firemode, 1, #modes)]`.
`ChangeFuseMode` (:263-276, USE+reload): only when more than one mode exists and IDLE; cycles
the networked `Firemode`, plays `SequenceFiremode` locked or applies a 0.25 s
`AnimLockTime`. HUD: `GetFiremodeName` reports `"Impact"` / `"Fuse 3g"` / `""`
(:47-52); `GetHUDAmmo` shows `GetRoundsLeft()` (:54-56).

### 3.10 Lit particles (molotov rag)

The common viewmodel flame hook (mcv/weapon_common/sh_vm.lua:104-116,
`UpdateLitParticle`) consumes `GetLitParticle`/`IsLit` on the `LitAttachment` (default
`"Wick"`, mcv/weapon_common/shared.lua:332). The throwable base defines them (:60-69): lit only for
`FuseImpact` throwables (molotov), from the trigger pull until the bottle leaves the hand —
including the THROWING state while `ThrowRelease` is still pending. Precached via
`GetPrecacheParticles` (:71-74). BUGLIST.md:400 documents the intent.

### 3.11 Input summary and derivatives

- `ThinkWeapon` (:278-299): IDLE + USE held → nothing (bash owns USE+attack, :283); fresh
  IN_ATTACK → `Windup(false)`; fresh IN_ATTACK2 → `Windup(HasUnderhand and
  HasSequence(SequenceWindupLow))`; windup states handled per §3.5.
- `PrimaryAttack` (:301-308): USE+attack from IDLE → `Bash()` + 0.6 s cooldown.
- `SecondaryAttack` (:310-311) and Reload-without-USE: nothing (fuse cycling is in `Reload`,
  :313-320, USE+reload only).
- `OnDeploy` (:322-325): IDLE + hold type refresh.

Derivatives in this snapshot — `mcv_rgd5` (RGD-5), `mcv_vcgrenade` (homemade),
`mcv_csg` (ChiCom frag), `mcv_csg2` (Type 67 HE), `mcv_css` (RGD-1 smoke — note
`ThrowModel = "w_css_ignited.mdl"` and `SmokeColor`, mcv_css.lua:22, :30) — are all pure
field sets over `mcv_grenade_frag`/`mcv_grenade_smoke`. The molotov, M26, M34, V-40, etc.
(weapon_list.md:141-158) live in Part 2 (`../mcv-2`, AGENTS.md:6-7) and are not in this
reference tree.

### 3.12 Prediction notes

`TakeRound(1)` runs on **both** realms before the client bails (:159-161) — the ammo count
is a predicted write that the server confirms; the entity spawn is server-only. All stage
deadlines (`ActionStart`, `ActionEnd`, `ActionVariant`, `WindupEnd`, deferred action index)
are networked, which is exactly the BUGLIST.md:326 rollback fix. Hold-type changes are made
through `SetHoldType` only on change (§3.3) so prediction errors self-heal.

---

## 4. Placeable Base — `weapons/mcv_placeable`

### 4.1 Purpose and files

Planted explosives (weapons/mcv_placeable/shared.lua:3-5): C4 (plant, right-click detonate),
dynamite (plant lit, or throw lit) and tripwire mines placed in two steps — the mine first,
then the stake the wire runs to. A translucent ghost shows where the piece will go. Files:
`shared.lua` (61) + `sh_place.lua` (511).

States (sh_place.lua:1-4): `STATE_IDLE 0`, `STATE_WINDUP 1` (dynamite held lit),
`STATE_BUSY 2` (an animation owns the weapon), `STATE_STAKE 3` (mine placed, waiting for the
stake).

### 4.2 Field catalogue

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `PlaceKind` | string | `"c4"` | `"c4"` / `"dynamite"` / `"mine"` — routes the whole input map (shared.lua:18) |
| `PlacedEntityClass` | string | `"mcv_placed_c4"` | shared.lua:19 |
| `StakeEntityClass` | string | `"mcv_mine_stake"` | shared.lua:20 |
| `PlaceRange` | number | 72 | trace reach (shared.lua:21) |
| `PlaceDelay` | number | 0.5 | seconds into the plant anim when the charge appears (shared.lua:22) |
| `ThrowForce` | number | 700 | dynamite throw (shared.lua:23) |
| `FuseTime` | number | 6 | dynamite fuse (shared.lua:24) |
| `WireLength` | number | 256 | max mine→stake distance (shared.lua:25) |
| `ExplosionDamage` / `ExplosionRadius` | number | 500 / 500 | shared.lua:27-28 |
| `SequencePlant/PlaceMine/PlaceStick/Windup/Throw` | string | `"plant"` etc. | shared.lua:30-34 |
| `PlacedModel` / `StakeModel` | string | nil | placed piece / stake world models (shared.lua:37-38) |
| `MineBodygroups` | table | `{mine = 0, stick = 1}` | bodygroup indices on the mine world model (shared.lua:39) |
| `PlacedAngleOffset` | Angle | nil | creator-side placement rotation (shared.lua:43) |
| `StakeAngleOffset` | Angle | `Angle(0, 0, 180)` | rolls the point-up stake mesh over (shared.lua:44) |
| `StakeRaise` | number | 6 | lifts the stake origin off the surface (shared.lua:45) |
| `SoundFuseLoop` | string | `""` | dynamite's burning fuse (shared.lua:55) |
| `RemoveWhenEmpty` | bool | true | shared.lua:57 |
| `Primary.Ammo` | string | `"mcv_explosive_charge"` | reserve-counted (sh_common.lua:66) |

### 4.3 Placement math — `PlaceAngle`

```lua
-- weapons/mcv_placeable/sh_place.lua:33-49
function SWEP:PlaceAngle(normal, facing, offset)
    local ang = normal:Angle()
    ang:RotateAroundAxis(ang:Right(), -90)
    if isvector(facing) then
        // Project the mine's direction into the stake's mounting plane. World
        // yaw alone cannot aim a wall-mounted stake up/down along that wall.
        facing = math.deg(math.atan2(-facing:Dot(ang:Right()), facing:Dot(ang:Forward())))
    end
    ang:RotateAroundAxis(ang:Up(), facing or self:GetOwner():EyeAngles().y)
    offset = offset or self.PlacedAngleOffset
    if offset then
        ang:RotateAroundAxis(ang:Up(), offset.y)
        ang:RotateAroundAxis(ang:Right(), offset.p)
        ang:RotateAroundAxis(ang:Forward(), offset.r)
    end
    return ang
end
```

Model-up along the surface normal, facing the player's yaw (or projected toward the mine for
the stake), then the creator-authored `PlacedAngleOffset`. This is what lets mines, stakes
and charges mount on walls, slopes and ceilings (BUGLIST.md:59).

### 4.4 Placement trace and validation

`PlacementTrace` (sh_place.lua:52-64): an eye line up to `PlaceRange`; if it hits nothing, a
second line drops to the floor 96 units below a point 75% of the range ahead — *"drop to the
ground in front of the player"*.

`CanPlaceAt(tr)` (:66-82): rejects sky, StartSolid, and players/NPCs/bots as the surface.
The stake stage adds: the mine must still exist, distance 24..`WireLength`, and **the wire
must not pass through walls**:

```lua
-- weapons/mcv_placeable/sh_place.lua:75-78
// the wire must not pass through walls
local wtr = util.TraceLine({start = mine:GetWireStart(),
    endpos = tr.HitPos + tr.HitNormal * self.StakeRaise, mask = MASK_SOLID_BRUSHONLY})
if wtr.Hit or wtr.StartSolid then return false end
```

### 4.5 The plant pipeline

```lua
-- weapons/mcv_placeable/sh_place.lua:122-146
function SWEP:Plant()
    local tr = self:PlacementTrace()
    if !self:CanPlaceAt(tr) then return false end

    local seq = self.SequencePlant
    if self.PlaceKind == "mine" then
        seq = self:GetActionState() == STATE_STAKE and self.SequencePlaceStick or self.SequencePlaceMine
    end

    local stake = self.PlaceKind == "mine" and self:GetActionState() == STATE_STAKE
    self:SetActionState(STATE_BUSY)
    local t = self:HasSequence(seq) and self:PlaySequence(seq, 1, true) or 0.8
    self:SetNextPrimaryFire(CurTime() + t)
    self:GetOwner():DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM)

    local pos, normal = tr.HitPos, tr.HitNormal
    local parent = IsValid(tr.Entity) and !tr.Entity:IsWorld() and tr.Entity or nil
    // Only entity creation reads this trace; the server does not replay Lua state.
    if SERVER then self.PendingPlacement = {pos = pos, normal = normal, parent = parent} end
    self:SetActionVariant(stake and 1 or 0)
    self:SetActionEnd(CurTime() + t)
    self:Defer("Place", math.min(self.PlaceDelay, t))

    return true
end
```

- The plant animation is locked; the charge appears `PlaceDelay` in, via `Deferred_Place`
  (:148-156) which branches to `SpawnStake`/`SpawnPlaced` on `ActionVariant` and chains
  `Defer("PlaceEnd", remaining)`.
- `Deferred_PlaceEnd` (:158-165): a non-stake mine goes to `STATE_STAKE`; everything else
  returns to IDLE and calls `CheckEmpty`.
- The server stashes the trace result in the plain field `PendingPlacement` — the accepted
  split between a predicted stage machine and unpredicated entity creation (§4.13).

### 4.6 `SpawnPlaced` / `SpawnStake`

`SpawnPlaced` (sh_place.lua:178-202): `TakeRound(1)` — **except for mines**, whose round is
taken later at the stake (:179-181); client returns after that; server creates
`PlacedEntityClass`, `ConfigurePlaced(ent)` (:167-176 — explosion stats with category
multipliers, Attacker/Inflictor, model, and `Delay = FuseTime` for dynamite), sets
`PlacedNormal` (*"the explosion goes off normal to the surface it sits on"*, :189; BUGLIST.md:409),
places at `pos + normal * 0.5` with `PlaceAngle(normal)`, calls `ent:PlantOn(parent)` —
which freezes the physics and parents to moving props (entities/mcv_placed_mine.lua:28-38,
mcv_placed_c4.lua:23). A mine additionally gets its `MineBodygroups`, blanks the stick
bodygroup (`blank_of`, :25-27 — *"the blank option of a bodygroup is its last one"*), and is
stored on the weapon via `SetNWEntity("MCVPlacedMine", ent)` (:200).

`SpawnStake` (:204-224): `TakeRound(1)` (this consumes the mine's charge); creates
`StakeEntityClass` at `pos + normal * StakeRaise`, angled with
`PlaceAngle(normal, mine:GetPos() - pos, StakeAngleOffset)`, parents to the surface entity,
then `mine:SetStakeEntity(stake)` — which starts the mine's wire-arm countdown
(`LiveTime = CurTime() + ArmDelay`, mcv_placed_mine.lua:43-48) — and clears the NWEntity
handle.

### 4.7 Dynamite — throw it lit

`Windup(key)` (sh_place.lua:227-233): `STATE_WINDUP` with `ActionVariant` = the button
(`IN_ATTACK` or `IN_ATTACK2`); plays `SequenceWindup` unlocked+noidle if present.
`ThinkWeapon` releases on `!KeyDown(ActionVariant)` → `ThrowLit` (:235-243): `STATE_BUSY`,
`SequenceThrow` locked, grenade gesture, `ActionVariant = 2`, `Defer("ThrowLit", min(0.2, t))`.
`Deferred_ThrowLit` (:245-266) chains `PlaceEnd`, takes the round, and on the server creates
the placed entity with `Thrown = true`, calls `ent:Light()` (starts the fuse), and throws it
with `(fwd + up * 0.15) * ThrowForce + velocity` and spin 300. Note the windup watches **the
button that started it** (:328, BUGLIST.md:403's fix).

Primary for dynamite: if `Plant()` fails and the model has a windup sequence, wind up
instead of spam-failing (:364-369). Secondary: wind up with IN_ATTACK2 or throw immediately.

### 4.8 C4 detonator mode

```lua
-- weapons/mcv_placeable/sh_place.lua:84-87
// The C4 with every charge planted stays as the detonator: empty hands, nothing to draw
function SWEP:ViewModelHidden()
    return self.PlaceKind == "c4" and self:GetRoundsLeft() <= 0 and self:GetActionState() == STATE_IDLE
end
```

`ViewModelHidden` is a common hook (mcv/weapon_common/shared.lua:328) — `Deploy` skips the
draw animation for it (sh_deploy.lua:46-47) and `PreDrawViewModel` culls the viewmodel
(mcv/weapon_common/sh_vm.lua:53). The base also suppresses the world model
(`DrawWorldModel`, sh_place.lua:89-91). `Detonate()` (:268-281, right click) calls
`RemoteDetonate()` on every planted charge of this class whose `GetPlanter()` is the owner
and which is `RemoteFuse` and not yet `Detonated`, with a `buttons/button17.wav` click.
`CountPlanted()` (:109-116) counts the same set for the HUD (`"Right click: detonate"`,
:16) and for `CheckEmpty` — the weapon only strips when the last charge has **gone off**
(:283-297).

### 4.9 Fuse sound

`Think_Fuse` (sh_place.lua:306-320) — server only, from `ThinkWeapon`: the
`SoundFuseLoop` loop is emitted on the weapon (not the viewmodel) while `IsLit()`, so
bystanders hear it and it stops the moment the stick leaves the hand or the weapon is put
away. `OnDeploy` makes sure a fresh draw starts unlit (:394-398).

### 4.10 `ThinkWeapon` and input

`ThinkWeapon` (:322-341): fuse sound; windup release (§4.7); C4 out-of-charges detonate
check; and — server only — the mine step is abandoned if the placed mine vanished
(:338-340). Input:

- `PrimaryAttack` (:343-371): `StillWaiting` gate; USE → bash (when not hidden); STATE_STAKE
  → plant the stake (0.2 s cooldown on failure); IDLE + rounds → `Plant()`, else dynamite
  windup or cooldown.
- `SecondaryAttack` (:373-384): fresh press gate; C4 → `Detonate()` (0.5 s cooldown);
  dynamite → windup/throw.
- `OnDeploy` (:389-399): reset state unless mid-stake; stop any fuse sound.

### 4.11 Client ghost preview

```lua
-- weapons/mcv_placeable/sh_place.lua:472-480
hook.Add("PostDrawTranslucentRenderables", "MCV_PlaceableGhost", function(depth, sky)
    if sky or depth then return end
    local ply = LocalPlayer()
    if !IsValid(ply) then return end
    local wep = ply:GetActiveWeapon()
    if IsValid(wep) and wep.PlaceKind and wep.DrawGhost then
        wep:DrawGhost()
    end
end)
```

`DrawGhost` (:416-470) runs only for the local player's active weapon, only in IDLE/STAKE
states, only with rounds left (or in the stake stage). It maintains a `ClientsideModel`
tracked through `MCV.TrackClientModel(self, "Ghost", ghost)` (mcv/client/cl_modelgc.lua:22),
positions it exactly like the real placement (`PlacementTrace` + `PlaceAngle` + the same
bodygroup blanking and `StakeRaise`), tints it green `Color(120, 255, 120, 110)` when
`CanPlaceAt` passes and red `Color(255, 90, 90, 110)` when not, and in the stake stage also
draws the would-be wire with `render.DrawBeam` on `cable/rope` (:463-469). The stake-stage
bodygroup logic mirrors `SpawnStake`/`SpawnPlaced` exactly (:443-450).
`SWEP:OnRemove` (client) removes the ghost and the world models (:482-485), replacing the
common `OnRemove` (cl_worldmodel.lua:290-292).

### 4.12 Derivatives

- `mcv_dynamite` (weapons/mcv_dynamite.lua): `PlaceKind "dynamite"`,
  `PlacedEntityClass "mcv_placed_dynamite"`, `PlacedAngleOffset Angle(90, 0, 90)` (:34),
  500/550 blast, and
  `SoundFuseLoop "MCV_Weapon_C4.FuseBurningLoop"` (*"the game ships one burning-fuse loop,
  under the C4's name"*, :36-38).
- `mcv_rg42` "OZM-4 Mine" (weapons/mcv_rg42.lua): `PlaceKind "mine"`,
  `PlacedEntityClass "mcv_placed_mine"`, `Primary.Ammo "mcv_mine"`, 175/250 blast,
  `BodyGroups "10"`. (The M16 Mine and C4 itself are Part 2 / not in this tree;
  weapon_list.md:125-132.)

### 4.13 Prediction notes

- The placement **stage machine is fully predicted** (networked state, variant, end time,
  deferred index — BUGLIST.md:326, :330). Entity creation is server-only; the server's
  `PendingPlacement` trace cache is a plain field, safe because the server never rolls back.
- The mine handle is deliberately a non-predicted `NWEntity` (§1.3) — a freshly `ents.Create`d
  server entity has no predictable client handle.
- `TakeRound` runs on both realms; the ghost is purely client-side and reads the same
  networked state.

### 4.14 Upstream notes (BUGLIST)

- :59 — walls/slopes/ceilings mounting, projected stake facing, preview/obstruction parity.
- :61 — mines self-destruct after five minutes including unfinished placements.
- :143 — timed/remote explosions follow current entity position (planted charges keep their
  explicit orientation).
- :393 — stake bodygroup blank option and the point-up stake mesh (`StakeRaise` 6).
- :400-410 — lit dynamite fuse particle/sound, C4 empty-hands detonator, `PlacedNormal`.

---

## 5. Flamethrower Base — `weapons/mcv_flamethrower`

### 5.1 Architecture

`SWEP.Base = "mcv_base"` (weapons/mcv_flamethrower/shared.lua:5) — full gun inheritance
(sights, reload state machine, HUD, bash, world model) with its own directory scan loader
(§1.1). It replaces `ThinkWeapon`, `PrimaryAttack`, `Reload`, `Holster`, `OnRemove` and
adds the flame system; `Think_Reload` is stubbed empty (sh_flame.lua:21) because fuel lives
in the reserve and nothing ever reloads. `NPCUsable = false` — *"The continuous flame needs
its own AI, not the gun firing path"* (shared.lua:7; BUGLIST.md:223).

### 5.2 Field catalogue

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `FireRate` | number | 600 | **ticks per minute** of the flame, not rounds (shared.lua:18) |
| `DamageGeneric` | number | 15 | damage per tick (shared.lua:19) |
| `FlameRange` | number | 420 | stream reach (shared.lua:20) |
| `FlameHull` | number | 24 | hull half-extent (shared.lua:21) |
| `IgniteTime` | number | 6 | seconds a target keeps burning (shared.lua:22) |
| `BurnDamagePerSecond` | number | 10 | MCV.Burn dps (shared.lua:23) |
| `FuelPerTick` | number | 1 | reserve ammo per tick (shared.lua:24) |
| `FlameParticle` | string | `"lpo50_flame"` | the stream PCF (shared.lua:26) |
| `PilotParticle` | string | `"lpo50_flame_pilot"` | precached (sh_flame.lua:1-3) |
| `FlameAttachment` | string | (default `"muzzle"` at use) | sh_flame.lua:167 |
| `SoundFireStart/Loop/Stop` | string | LPO50 set | shared.lua:37-39 |
| `TankExplodes` | bool | true | shared.lua:42 |
| `TankExplosionDamage` / `TankExplosionRadius` | number | 150 / 250 | shared.lua:43-44 |
| `Primary.Ammo` | string | `"mcv_flamethrower_fuel"` | reserve-only (`ClipSize = -1`) |
| `CrosshairCircle` | bool | true | circular crosshair that expands while flaming (shared.lua:10; BUGLIST.md:139) |

All gun particle/brass fields are blanked (`MuzzleParticle ""`, `NoEjectOnShoot true`,
`EjectBrassType 0`, shared.lua:28-35).

### 5.3 Continuous-fire state

The flame is a **hold state in `ThinkWeapon`**, not a `PrimaryAttack` (which is an empty
stub, sh_flame.lua:103-105):

```lua
-- weapons/mcv_flamethrower/sh_flame.lua:107-130
function SWEP:ThinkWeapon()
    local owner = self:GetOwner()

    self:Think_Sights()

    local wants = owner:KeyDown(IN_ATTACK) and !owner:KeyDown(IN_USE) and self:GetRoundsLeft() > 0
        and self:GetAnimLockTime() <= CurTime() and self:GetHolsterTime() == 0 and !self:GetIsSprinting()

    if wants and !self:IsFlaming() then
        self:StartFlame()
    elseif !wants and self:IsFlaming() then
        self:StopFlame()
    end

    if self:IsFlaming() and self:GetNextPrimaryFire() <= CurTime() then
        self:FlameTick()
        self:SetLastRecoilTime(CurTime())
    end

    if owner:KeyPressed(IN_ATTACK) and owner:KeyDown(IN_USE) and !self:StillWaiting() then
        self:Bash()
        self:SetNextPrimaryFire(CurTime() + 0.6)
    end
end
```

`IsFlaming()` is the networked `PrimedAttack` bool (:23-25) — the gun base's
trigger-primed slot reused as the flame state, visible to every client. The `wants`
conjunction explicitly forbids sprinting (BUGLIST.md:355's fix) and requires fuel. Note this
`ThinkWeapon` **replaces** the gun base's (mcv_base/sh_think.lua:49) — no burst logic, no
cycle, no UBGL toggle, no hammer release run on a flamethrower.

### 5.4 Start / stop

`StartFlame` (sh_flame.lua:27-33): sets `PrimedAttack`, stamps `LastTriggerTime`, plays
`ACT_VM_PRIMARYATTACK` **unlocked with noidle** (the firing pose is held), starts the
start+loop sounds. `StopFlame` (:35-45): stops the loop, plays the stop sound, and plays
`ACT_VM_RECOIL1` (if the model has it) or re-arms idle — the wind-down.

### 5.5 `FlameTick` — the damage model

```lua
-- weapons/mcv_flamethrower/sh_flame.lua:48-85 (excerpt)
function SWEP:FlameTick()
    local owner = self:GetOwner()
    self:TakeRound(self.FuelPerTick)
    self:SetNextPrimaryFire(CurTime() + 60 / self.FireRate)

    if CLIENT then return end
    ...
    // a few staggered hull traces so the whole stream width burns
    for i = 0, 2 do
        local off = (i - 1) * hull * 0.8
        local right = self:GetAimAngle():Right() * off
        local tr = util.TraceHull({
            start = src + right,
            endpos = src + right + dir * self.FlameRange,
            filter = owner,
            mask = MASK_SHOT_HULL,
            mins = Vector(-hull, -hull, -hull),
            maxs = Vector(hull, hull, hull),
        })
        local ent = tr.Entity
        if IsValid(ent) and !hit[ent] then
            hit[ent] = true
            local dmg = DamageInfo()
            dmg:SetDamage(self.DamageGeneric)
            dmg:SetDamageType(DMG_BURN)
            ...
            ent:TakeDamageInfo(dmg)
            MCV.Burn(ent, self.IgniteTime, owner, self, self.BurnDamagePerSecond)
        end
    end
```

Three hulls staggered left/center/right at ±0.8 × hull; per hit: `DamageGeneric` DMG_BURN
with force `dir * 200`, plus `MCV.Burn` — MCV's own burn-over-time (never
`Entity:Ignite()`, whose entity_flame steals damage attribution; mcv/shared/sh_burn.lua:1-5,
ticking `BurnTickRate 0.25` with the `burning_character` particle). A second pass
(:88-100) damages and half-burns players/NPCs/bots standing in a `hull * 3` sphere where
the stream lands. Fuel (`TakeRound`) is consumed on both realms; damage is server-only.

### 5.6 The client stream

```lua
-- weapons/mcv_flamethrower/sh_flame.lua:155-161, 163-182 (excerpt)
function SWEP:FlameEmitter()
    local owner = self:GetOwner()
    if owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
        return owner:GetViewModel()
    end
    return self:GetWorldModelFor(false)
end
...
function SWEP:StartFlameEffect()
    self:StopFlameEffect()
    local ent = self:FlameEmitter()
    if !IsValid(ent) then return end
    local att = MCV.CachedAttachment(ent, self.FlameAttachment or "muzzle")
    if att <= 0 then att = 1 end
    local ps = CreateParticleSystem(ent, self.FlameParticle, PATTACH_POINT_FOLLOW, att)
    local owner = self:GetOwner()
    if IsValid(ps) and owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
        // viewmodel particles are drawn from PostDrawViewModel; the jet reaches into the
        // world, so it keeps the world's projection rather than the viewmodel's
        ps:StartEmission()
        ps:SetShouldDraw(false)
        table.insert(self.PCFs, ps)
        self.WorldPCFs = self.WorldPCFs or {}
        self.WorldPCFs[ps] = true // a particle handle cannot carry a field of its own
    end
    self.FlamePS = ps
    self.FlamePSEnt = ent
end
```

- The emitter is the **viewmodel** for the local player (first-person), the bone-merged
  clientside world model for everyone else (`GetWorldModelFor`, cl_worldmodel.lua:256-261).
- A local player's jet is registered in `self.PCFs` **and** flagged `WorldPCFs` so
  `PostDrawViewModel` renders it in a fresh `cam.Start3D()` at the world projection —
  *"systems that reach out into the world ... keep the world's projection, or they would not
  land where they burn"* (mcv/weapon_common/sh_vm.lua:188-197). This is the pattern
  BUGLIST.md:411 describes.
- `UpdateFlameControlPoints` (:194-212) aims control point 1 at the surface the player
  points at every frame (a reused trace table, BUGLIST.md:77) and fixes the orientation
  basis so a straight-on surface can't produce a degenerate cross product; CP2 is the
  max-range target.
- `Think_ClientFlame` (:227-239) is the **one place** the client effect starts/stops for
  everyone: *"Think does not run on the client in singleplayer and other players' weapons
  never think here"* — it follows the networked `PrimedAttack`, handles dormancy and emitter
  swaps. It is called from `PreDrawViewModelWeapon` (:214-222, local player, alongside the
  RT scope and muzzle light) and from `DrawWorldModel` (:241-245, others).
- `GetCrosshairKick` (:149-151) returns 1 while flaming — the shared HUD smooths the
  circular crosshair open/closed independently of damage ticks.

### 5.7 Fuel, reload, firemode

`GetHUDAmmo` returns `Ammo1(), nil` (:5-7) with `GetFiremodeName() = "Fuel"` (:9-11).
`Reload` (:14-19) only handles USE+reload → `ChangeFiremode` (the gun base's firemode
cycling, harmless on a single AUTO mode); plain reload does nothing. `Think_Reload` stubbed
(:21).

### 5.8 The tank on the back

```lua
-- weapons/mcv_flamethrower/sh_flame.lua:249-272 (excerpt)
hook.Add("EntityTakeDamage", "MCV_FlamethrowerTank", function(ent, dmginfo)
    if !ent:IsPlayer() then return end
    local wep = ent:GetActiveWeapon()
    if !IsValid(wep) or !wep.TankExplodes or !wep.MilitaryConflictVietnam then return end
    if !dmginfo:IsBulletDamage() then return end
    if (wep.NextTankCheck or 0) > CurTime() then return end
    wep.NextTankCheck = CurTime() + 0.1
    ...
    local from = dmginfo:GetDamagePosition()
    local back = -ent:GetAimVector()
    back.z = 0
    if (from - ent:GetPos()):GetNormalized():Dot(back) < 0.55 then return end
    if math.random() > 0.35 then return end

    local pos = ent:GetPos() + Vector(0, 0, 48) + back * 10
    ParticleEffect("Vietnam_Explosion_Flamethrower_BackPack", pos, angle_zero)
    util.BlastDamage(wep, dmginfo:GetAttacker(), pos, wep.TankExplosionRadius, wep.TankExplosionDamage)
    ...
    ent:SetAmmo(0, wep:GetPrimaryAmmoType())
end)
```

A bullet into the wearer's back (dot ≥ 0.55 with the flattened back vector), throttled to
0.1 s and a 35 % chance, detonates the pack: blast, burn (10 s), and the fuel reserve
zeroed.

### 5.9 Holster and lifecycle

```lua
-- weapons/mcv_flamethrower/sh_flame.lua:132-139
function SWEP:Holster(wep)
    if self:IsFlaming() then
        self:StopFlame()
    end
    // Not self.BaseClass: for an LPO-50 (Base = mcv_flamethrower) that is this very class, so
    // the tail call looped forever and froze the game on every weapon switch after firing.
    return baseclass.Get("mcv_base").Holster(self, wep)
end
```

A textbook inheritance trap: `self.BaseClass` for a *derivative* of `mcv_flamethrower`
resolves to `mcv_flamethrower` itself, so a `BaseClass` tail call self-recurses; the base is
addressed explicitly. `OnRemove` (:141-144) stops the client effect/world models and the
loop sound. The derivative `mcv_lpo50` (weapons/mcv_lpo50.lua) is fields only — the LPO-50's
per-class numbers, `MovementPoseWalk 80` (the run-layer fix, BUGLIST.md:373), TODO-tuned
sights.

### 5.10 Prediction notes

Flame state is one networked bool; `FlameTick`'s ammo burn is predicted (`TakeRound` on both
realms) while damage and burn are server-only. Client effects derive entirely from
`PrimedAttack` + `Think_ClientFlame`, never from replayed commands (the cl_chainsaw comment
states the same philosophy, §7.5). The control-point aim runs per rendered frame on whoever
draws the weapon.

---

## 6. Underbarrel Flame — `weapons/mcv_underbarrel_flame`

### 6.1 Purpose

A **pulsed** flame cartridge fired from a rifle's underbarrel launcher — the flame
equivalent of `RifleGrenadeAttack` (mcv_base/sh_ubgl.lua:51-89). 93 lines, all in
`shared.lua`; `SWEP.Base = "mcv_base"` (weapons/mcv_underbarrel_flame/shared.lua:2). No
consumer exists in this snapshot — it is the base for the Part 2 "M16 Flamer" kitbash
(BUGLIST.md:187: *"Includes predicted cartridge flame bursts"*); the `mcv_flame_cartridge`
ammo type is already registered (mcv/shared/sh_common.lua:67).

Fields: `FlameParticle "lpo50_flame"`, `FlameAttachment "muzzle2"`, `FlameRange 240`,
`FlameDamage 8`, `FlameDuration 0.8`, `FlameInterval 0.1` (:5-10).

### 6.2 Pulse model

```lua
-- weapons/mcv_underbarrel_flame/shared.lua:13-15, 23-34
function SWEP:IsFlaming()
    return self:GetActionEnd() > CurTime() and self:GetGrenadeLauncher()
end

function SWEP:RifleGrenadeAttack()
    if self:GetSpeed() > 150 or self:GetNeedTriggerPress() then return end
    if self:Clip2() < 1 then self:Reload() return end
    self:TakeSecondaryAmmo(1)
    self:SetNeedTriggerPress(true)
    self:SetActionEnd(CurTime() + self.FlameDuration)
    self:SetNextPrimaryFire(self:GetActionEnd() + 0.2)
    self:PlayAnimation(ACT_VM_ISHOOT_M203, 1, false, true)
    self:SetAnimLockTime(self:GetActionEnd())
    self:EmitSound("MCV_Weapon_LPO50.Primary_Fire_Start")
    self:Deferred_FlamePulse()
end
```

One trigger press consumes a secondary flame cartridge and opens a `FlameDuration` window in
launcher mode (`GetGrenadeLauncher()` — the UBGL toggle state, animation-system.md §7.11).
`Deferred_FlamePulse` (:36-58) is a **self-rescheduling** deferred chain — one
lag-compensated ±12 hull trace per `FlameInterval`, `FlameDamage * StatMult("damage")` +
`MCV.Burn(ent, 3, owner, self, 5)`, until `IsFlaming()` expires, then idle. The pulse rides
the predicted deferred-action machinery, so replays and rollbacks keep the chain coherent.

### 6.3 Client reuse

The client half is forwarded wholesale from the flamethrower base:

```lua
-- weapons/mcv_underbarrel_flame/shared.lua:84-93
if CLIENT then
    // Reuse the established viewmodel/worldmodel/PVS particle lifecycle.
    for _, name in ipairs({"FlameEmitter", "StartFlameEffect", "StopFlameEffect",
        "UpdateFlameControlPoints", "Think_ClientFlame", "PreDrawViewModelWeapon", "DrawWorldModel"}) do
        local method = name
        SWEP[method] = function(self, ...)
            return baseclass.Get("mcv_flamethrower")[method](self, ...)
        end
    end
end
```

i.e. the underbarrel flame draws with the full flamethrower stream machinery, keyed on its
own `IsFlaming` (time-window + launcher mode) instead of the held trigger. `Deploy` resets
`ActionEnd` (:60-63); `Holster` refuses to switch while flaming (:75-78); `GetFiremodeName`
reports "Flame cartridge" in launcher mode (:70-73); the control hint is
`"+use +walk", "Rifle / flamer"` (:65-68).

### 6.4 Sharp edges

- `SWEP.DeferredActions = {"FlamePulse"}` (:11) **replaces** the inherited mcv_base list
  (`BayonetOff, AkimboSwap, LauncherSwap, BayonetLoop, BayonetHit, ReloadInsert` — flat
  field override, no merge). Any inherited deferred feature would silently stop working;
  acceptable here only because the weapon is not a shotgun and carries no bayonet toggle
  through defers. A translation layer must treat `DeferredActions` as
  **full-list-per-class**, not additive.
- `OnRemove` (:80-82) calls `StopFlameEffect`/`RemoveWorldModels` without the base's
  sound-stop loop — the loop sound never started, since only the start sound is used.

---

## 7. Chainsaw — `weapons/mcv_chainsaw.lua` + `mcv/client/cl_chainsaw.lua`

### 7.1 Architecture

A spawnable weapon (not a reusable base) deriving from `mcv_melee`
(weapons/mcv_chainsaw.lua:6), with `NPCUsable = false`, holdtype `physgun`, and a
custom-model caveat: *"The available model has no refuel, slash, stab or throw animations"*
(:27-28) — so `CanThrow false`, `CanRepair false`, and the whole slash/stab pipeline is
unused. Its `DeferredActions` stay the melee list (inherited, untouched).

### 7.2 Spin state — `ThinkWeapon`

```lua
-- weapons/mcv_chainsaw.lua:95-118 (excerpt)
function SWEP:ThinkWeapon()
    local owner = self:GetOwner()
    local now = CurTime()
    local rate = self.SawRate * self:StatMult("firerate")
    local wants = owner:Alive() and owner:GetActiveWeapon() == self and owner:KeyDown(IN_ATTACK)
        and !owner:KeyDown(IN_USE) and !self:GetIsSprinting() and !self:GetSafe()
        and self:GetHolsterTime() == 0 and self:GetAnimLockTime() <= now and rate > 0

    if wants and !self:GetPrimedAttack() then
        self:SetPrimedAttack(true)
        self:SetActionStart(now)
        self:SetNextPrimaryFire(math.max(self:GetNextPrimaryFire(), now + self.SawSpinUp))
        self:PlaySequence("shootloop", 1, false)
    elseif !wants then
        self:StopSaw(self:GetHolsterTime() == 0 and owner:Alive())
    end

    local skin = self:GetHolsterTime() != 0 and 0 or (self:GetPrimedAttack() and 2 or 1)
    if self:GetSkin() != skin then self:SetSkin(skin) end
    if self:GetPrimedAttack() and self:GetNextPrimaryFire() <= now then
        self:SetNextPrimaryFire(now + 60 / rate)
        self:SawTick()
    end
end
```

Like the flamethrower, held input is serviced from the predicted Think path —
`PrimaryAttack`/`SecondaryAttack`/`Reload` are all empty stubs (*"Held input is serviced by
the predicted Think path."*, :120-122). `PrimedAttack` is the spinning flag;
`SawSpinUp = 0.15` s delays the first damage; the skin is the chain speed — 0 holstered, 1
slow chain, 2 full speed (`SetSkin(1)` in `OnDeploy`, :48-53). `IdleSequence` returns
`"shootloop"` while spinning, `"idle"` otherwise (:55-57).

### 7.3 `SawTick`

Server-only (the client bails at :66): lag-compensated `MeleeTrace(self.MeleeRange)` (128 HU reach,
BUGLIST.md:55), rejects sky/StartSolid, then `DamageGeneric * StatMult("damage")` as
`DMG_SLASH` with force `aim * damage * 30`; blood is captured **before** the potentially
lethal damage (*"a lethal hit can remove the target immediately"*, :75-76) and dispatched
once from the server (`MCV.MeleeBloodImpact` or `MCV.BulletImpact`), with **no** cosmetic
bullet fallback at all (:87-92). Provisional balance: 12 damage × 600/min = 120 DPS
(:27-33).

### 7.4 Client audio — `mcv/client/cl_chainsaw.lua`

A global tracker decoupled from weapon Think, *"Audio follows the final predicted/received
state, never each command replay"* (cl_chainsaw.lua:1-2):

- `MCV.TrackChainsaw(wep)` registers (from the weapon's client `Initialize`, :43-46);
  `MCV.StopChainsawSound`/`MCV.UntrackChainsaw` release handles; `ShutDown`,
  `PostCleanupMap` and `EntityRemoved` hooks guarantee cleanup (:30-34).
- A global `Think` hook (:47-95) manages per-weapon `CreateSound` patches: an idle loop at
  volume 0.35, a cutting loop at 0.7 when `GetPrimedAttack()`, one-shot start/stop
  transitions (`SoundSawStart`/`SoundSawStop`) with the rule *"A rev interrupts the startup
  recording; it must not play under cutting"* (:83). Audibility requires a live, non-dormant
  owner holding it as the active weapon with `GetReady()` and no holster in progress
  (:53-57).
- Handles survive Lua refresh (`hook.GetTable` dance at :3-5, re-registration of existing
  entities at :98).

### 7.5 Lifecycle

`Holster` calls the melee (→ common) holster, then stops the saw **without** the `shootend`
animation and resets the skin — on the server, or on the client when running the owner's
prediction (:124-131). `OwnerChanged` (:133-140) resets state server-side / stops audio
client-side; `OnDrop` forwards to it; `OnRemove` untracks and removes world models
(:142-151). `GetWeaponInfoRows` (:157-165) shows damage/tick, cuts per second and reach in
metres for the spawn-menu info box (cl_hud.lua:557).

### 7.6 Upstream notes

BUGLIST.md:27 (L4D2 audio instead of pitched manhack loop), :45 (blood dependency include
after live refresh), :51 (custom blood PCF), :55 (128 HU reach, blood on flesh), :57 (the
original add: predicted state/cooldowns, authoritative damage, independent looping-audio
cleanup).

---

## 8. Crossbow — `weapons/mcv_crossbow.lua`

### 8.1 A pure definition

160 lines, **zero functions** — the Montagnard Crossbow is entirely `mcv_base` defaults plus
data (weapons/mcv_crossbow.lua:1). This makes it the cleanest existence proof that a
projectile weapon on MCV needs no code at all.

### 8.2 What it exercises

- **Fire**: `ShootEntity = "mcv_proj_bolt"`, `ShootEntityForce = 10393` (:50-51) — the gun
  base's projectile path: `PrimaryAttack` → (sh_shoot.lua:141) `GetProjectileClass()` →
  `RocketAttack`/`LaunchProjectile` (sh_shoot.lua:643-699) spawns the bolt with
  `SetWeapon(self)`, `Inflictor`, and the weapon's explosion stats where present.
  `Primary.Chamber = 0`, `ClipSize = 1`, `FireRate 600`, `FIREMODE_SEMI` — one bolt, then
  reload.
- **Reload**: a normal magazine reload against `MagInTime = 1.87` (:25-26) — the crank. The
  value is not cosmetic: BUGLIST.md:347 records that with a 0 mag-in time *"its string
  reverted to drawn back after firing empty because the reload's mag-in time was 0 (now
  1.87 s from the animation's ammo event)"*.
- **Ammo**: engine `XBowBolt` (:97) — recovered bolts re-use the pool (BUGLIST.md:123).
  `NoEjectOnShoot`, blank particles/brass (:49, :145-154) — no muzzle flash
  (BUGLIST.md:347), no tracer.
- **Stats**: 4× head / 3× chest-stomach multipliers (:33-36), `Spread 5 / 1` ironsighted,
  stance multipliers all 1 (:106-111) — bolts fly straight.
- NPC-usable by inheritance (`mcv_base/shared.lua:5` `NPCUsable = true`; the crossbow does
  not override it) — the projectile NPC path is shared (BUGLIST.md:223).

The bolt entity itself (`entities/mcv_proj_bolt.lua`) — flight, sticking, pickup — is
covered by docs/projectiles-entities.md; impact effects by BUGLIST.md:67 and
docs/effects.md.

---

## 9. Binoculars — `weapons/mcv_binoculars`

### 9.1 What it is

Right click looks through them, magnification steps with reload; nothing fires
(weapons/mcv_binoculars/shared.lua:1-2). `Base = "mcv_base"` with
`NPCUsable = false` (*"Optical equipment inherits the gun base but cannot fire"*, :6). The
trick: **the gun base's aim path is the zoom** — `ThinkWeapon` is one line,
`self:Think_Sights()` (:82-84), so IN_ATTACK2 drives the standard sight blend
(mcv_base/sh_sights.lua:101-147, animation-system.md §4.3) while the weapon has no
projectile.

### 9.2 Magnification trio

```lua
-- weapons/mcv_binoculars/shared.lua:42-55
function SWEP:GetMagnification()
    local lvl = math.Clamp(self:GetScopeLevel(), 1, #self.ZoomLevels)
    return self.ZoomLevels[lvl]
end

// what the camera code wants is the FOV
function SWEP:GetZoomMagnification()
    return 90 / self:GetMagnification()
end

// mouse sensitivity follows the magnification (it followed the ironsight FOV: full speed at 8x)
function SWEP:GetLookMagnification()
    return self:GetMagnification()
end
```

`ZoomLevels = {4, 8}` (:17) indexed by the networked `ScopeLevel` (Int 0, the scope
adjustment slot guns use — sh_shoot.lua:743-820). `GetZoomMagnification` is the common
camera hook (mcv/weapon_common/shared.lua:299); the camera divides 90 by it. The HUD shows
`"%dx"` (:40).

### 9.3 Input

`Reload` (:65-80): on a fresh IN_RELOAD press (and not `StillWaiting`), steps `ScopeLevel`
wrapping at `#ZoomLevels`; when not sighted and the model has `SequenceFiremode`
(`"firemode"`, :34) plays it locked, otherwise a click sound + 0.2 s `AnimLockTime`.
`PrimaryAttack` (:57-63) is bash-only (USE+attack). `ToggleUBGL`/`ToggleBayonet` are stubbed
(:86-87) so no gun-base binding leaks through the minimal `ThinkWeapon`.

**Observed inconsistency**: the control hint says `{"+use +reload", "Magnification"}`
(:89-95) and the file header says "USE + reload steps the magnification", but `Reload`
triggers on IN_RELOAD **alone** (:67) — plain R zooms. The hint text appears stale relative
to the implementation (flagged for the translation layer: code wins).

### 9.4 Visuals

- `PreDrawViewModelBlend(vm, sa)` (:99-103): fades the viewmodel out as the (cubed) sight
  blend passes 0.3 — *"the model would sit in front of the camera"*.
- `DrawHUDExtra` (client, :105-118): above sight blend 0.5, draws the game's Refract
  binocular mask `effects/screen_overlay_binoculars_01` fullscreen, alpha-ramped — the fix
  for BUGLIST.md:364 (*"Binoculars use full sensitivity and should use the game's
  overlay"*, zoom levels became magnifications).
- `SightedViewModelFOV 60`, `IronsightSpeedScale 0.7`, `DrawCrosshair false`, no ammo.

Derivative: `mcv_binoculars_vc` (weapons/mcv_binoculars_vc.lua) — models and pose endpoints
only.

---

## 10. Equipment Box — `weapons/mcv_equipment_box`

### 10.1 Purpose and fields

Ammo and medic boxes (weapons/mcv_equipment_box/shared.lua:3-4): left click hands the box's
contents to the player you look at, right click uses it on yourself, USE+attack throws it
down for anyone. Files: `shared.lua` (36) + `sh_box.lua` (225). `DeferredActions =
{"BoxUse", "BoxEnd", "BoxDrop"}` (sh_box.lua:1).

| Field | Type | Default | Notes |
| --- | --- | --- | --- |
| `BoxKind` | string | `"ammo"` | or `"medic"` — routes everything (shared.lua:16) |
| `HealAmount` | number | 50 | shared.lua:17 |
| `AmmoMagazines` | number | 1 | magazine-equivalent budget per use (shared.lua:18) |
| `GiveRange` | number | 96 | shared.lua:19 |
| `DroppedEntity` | string | `"mcv_supply_box"` | shared.lua:20 |
| `SequenceGive/Self/Throw/Draw` | string | `"give"/"self"/"throw"/"draw"` | shared.lua:22-25 |
| `GiveDelay` / `ThrowDelay` | number | 0.4 / 0.3 | shared.lua:26-27 |
| `Primary.Ammo` | string | `"mcv_ammobox"` / `"mcv_medicbox"` | reserve-counted uses |

### 10.2 The supply plan — `MCV_AmmoSupplyPlan`

The heart of the base (sh_box.lua:13-72), a **global** (shared by the dropped
`mcv_supply_box` entity):

- One pool per distinct ammo type across the target's weapons (skipping anything with a
  `BoxKind` — *"supplies never replenish supplies"*, :31). `per` = one share = the weapon's
  clip size (min 1 — *"a loose grenade or rocket costs a whole share"*, :20); `cap` =
  `DefaultClip - clip` or `per`, clamped by `game.GetAmmoMax`; duplicate guns merge by taking
  the max, so *"duplicate guns cannot multiply the grant"* (:11-12).
- Candidate pools are those below cap, **sorted by ammo ID** (deterministic) and rotated by
  the `SupplyCursor` NetworkVar (Int 12) — *"Rotating the first pool lets rockets receive a
  full share on later uses"* (:53-55).
- The budget (`AmmoMagazines`) is spent round-robin: pool *i* gets
  `floor(per * budget / pools_left)`; indivisible pools get one round if
  `budget >= 1/per`; leftovers are distributed in a fixed-point loop without exceeding the
  budget (:57-70).

This is the fix for BUGLIST.md:363 (*"Ammo box only resupplies ammo boxes ... a fresh gun
(M16: 320 in reserve) was over the six-magazine cap so got nothing; boxes skip boxes and the
cap is the gun's spawn ammo"*) and the extension of BUGLIST.md:312 (*"Ammo self-supply
serves the player's other weapons, including stock guns and grenade/rocket pools"*).

### 10.3 `MCV_ApplySupply` and prediction gates

```lua
-- weapons/mcv_equipment_box/sh_box.lua:75-97 (excerpt)
function MCV_ApplySupply(kind, target, amount_heal, magazines, cursor)
    if !IsValid(target) or !target:IsPlayer() or !target:Alive() then return false end

    if kind == "medic" then
        if target:Health() >= target:GetMaxHealth() then return false end
        if SERVER or target == LocalPlayer() then
            target:SetHealth(math.min(target:Health() + amount_heal, target:GetMaxHealth()))
        end
        if SERVER then target:Extinguish() end
        return true
    end

    local plan, nextCursor = MCV_AmmoSupplyPlan(target, magazines, cursor)
    local gave = false
    for _, pool in ipairs(plan) do
        if pool.amount <= 0 then continue end
        if SERVER or target == LocalPlayer() then
            target:SetAmmo(pool.have+pool.amount, pool.ammo)
        end
        gave = true
    end
    return gave, gave and nextCursor or cursor
end
```

The write gates are the interesting part: for a **remote** target only the server writes;
for self-use the predicting client (`target == LocalPlayer()`) writes too, so the heal/ammo
is immediate under prediction. `Extinguish` is server-only. The medic branch also puts out
fire (via MCV's own burn system, sh_burn.lua:38-48).

### 10.4 Use pipeline

`GetGiveTarget` (sh_box.lua:99-106): 96-unit eye trace onto a living player.
`UseBox(target, seq, delay)` (:108-117): locked sequence (or 0.6), both attack cooldowns
pushed, `SetActionTarget(target)` (Entity NetworkVar 2), `ActionVariant` 1 for self / 0 for
give, `Defer("BoxUse", min(delay, t))`. `Deferred_BoxUse` (:119-132): chains `BoxEnd`,
re-reads `ActionTarget` (predicted), applies the supply with the cursor — guarded with
`self.GetSupplyCursor and ... or 0` (*"Existing instances acquire the new accessor after a
map change"*, :123) — takes one round and plays the result sound on success.
`Deferred_BoxEnd` (:134-140): after a self-use, plays `SequenceDraw` (*"The self animation
finishes off screen; bring the next box back with a draw"*) and `CheckEmpty`.

Input: `PrimaryAttack` (:188-206) — USE → `DropBox`; else give-or-cooldown.
`SecondaryAttack` (:208-214) — fresh press, self-use.

### 10.5 Drop pipeline and the entity

`DropBox` (:142-151): locked `SequenceThrow`, grenade gesture, `ActionVariant 2`,
`Defer("BoxDrop", min(ThrowDelay, t))`. `Deferred_BoxDrop` (:153-173): chains `BoxEnd`,
takes a round, server spawns `DroppedEntity` with `Model/BoxKind/HealAmount/AmmoMagazines`
copied, at `shootpos + fwd * 16`, `Angle(0, yaw, 0)`, velocity `fwd * 350 + (0,0,80) + vel`.
The `mcv_supply_box` entity (entities/mcv_supply_box.lua) is a 120-second, 3-use physics
prop that serves anyone within a 48-unit polled radius every 3 s through the same
`MCV_ApplySupply` (:43-57), tracking its own `SupplyCursor` — the rotation survives being
dropped.

Derivatives: `mcv_ammobox_vc` / `mcv_medicbox_vc` — `BoxKind` and ammo name only (the US
boxes are Part 2).

---

## 11. M79 Grenade Launcher Base — `weapons/mcv_m79_base`

### 11.1 Selectable-ammo firemodes

112 lines, `Base = "mcv_base"` (weapons/mcv_m79_base/shared.lua:3). The base turns the
firemode system into a **cartridge selector**: `Firemodes = {MCV.FIREMODE_HE,
MCV.FIREMODE_BUCKSHOT}` (:6, enums at mcv/shared/sh_common.lua:12-13) with
`MCV.FiremodeAmmo` mapping HE → `smg1_grenade`, buckshot → `buckshot` (:22-25). The comment
at :17-18 states the contract: *"The first firemode is each variant's starting cartridge.
All selection state is predicted; never rewrite Primary or other inherited configuration
tables."* The HUD shows the selected ammo pool
(`self.SelectableGrenadeAmmo and self:GetSelectedAmmo()`, cl_hud.lua:565).

No weapon in this snapshot derives from it — the M79 and M79 SOG are Part 2
(weapon_list.md:14-15); the base was placed in Part 1 deliberately (*"Shared launcher base
lives in Part 1"*, BUGLIST.md:119).

### 11.2 Ammo virtualization

```lua
-- weapons/mcv_m79_base/shared.lua:27-34
function SWEP:GetPrimaryAmmoType()
    return game.GetAmmoID(self:GetSelectedAmmo())
end

function SWEP:Ammo1()
    local owner = self:GetOwner()
    return IsValid(owner) and owner:GetAmmoCount(self:GetSelectedAmmo()) or 0
end
```

`GetPrimaryAmmoType` and `Ammo1` are overridden **as functions**, so every inherited
consumer (clip transfer, HUD, `GetRoundsLeft`) transparently reads the currently selected
reserve. `GetBulletCount` (:36-38) = 12 pellets for buckshot; `GetProjectileClass`
(:40-43) = nil for buckshot (falls to the hitscan path) or `ShootEntity "mcv_proj_40mm"`.

### 11.3 `ChangeFiremode` = swap the cartridge

```lua
-- weapons/mcv_m79_base/shared.lua:71-100 (excerpt)
function SWEP:ChangeFiremode()
    if self:StillWaiting() or self:GetReloading() then return end
    ...
    // Unload before selecting the other cartridge. SetAmmo (not GiveAmmo) and
    // Clip1 are replayable predicted writes; a switch cannot transmute ammo.
    local loaded = math.max(self:Clip1(), 0)
    self:SetAmmoSwitchFrom(self:GetFiremodeValue())
    if loaded > 0 then
        owner:SetAmmo(self:Ammo1() + loaded, self:GetSelectedAmmo())
        self:SetClip1(0)
    end
    self:SetFiremode(self:GetFiremode() % #self.Firemodes + 1)
    self:SetLastClip(loaded)
    self:SetBurstCount(0)
    self:ScopeToggle(false)
    local duration
    if loaded > 0 then
        duration = self:PlaySequence("reload_live", 1, true)
    else
        duration = self:PlayAnimation(ACT_VM_RELOAD, 1, true)
    end
    ...
    // The normal reload completion transfers the selected reserve into Clip1.
end
```

A switch **unloads the live round back into its original reserve first** (both writes are
replayable predicted ops — the comment is the invariant), then runs a real reload animation
so the normal reload completion loads the new cartridge. `RestoreClip` (:102-112) is
overridden to draw from `GetSelectedAmmo()`.

### 11.4 Viewmodel choreography

`DoBodygroupsWeapon` (:45-59) calls the base then flips the model's `"ammo"` bodygroup
(0 = HE cartridge, 1 = buckshot) — but during an ammo-switch reload it keeps the **outgoing**
cartridge visible until frame 50/30 of the animation (*"Both models eject at frame 50,
before inserting the new round at frame 63"*, :53-54) and drives the `ammo_fraction` pose
parameter from `LastClip`. `DoEject` (:61-64) suppresses the shell ejection when switching
with a live round (*"ShellTip stays attached to the live round"*, BUGLIST.md:113).
`Think_Reload` (:66-69) clears `AmmoSwitchFrom` once the reload finishes.

### 11.5 Upstream notes

BUGLIST.md:253 lists the open *"M79 lacks its ammo switching feature"* (superseded by the
implemented :117/:119 entries — selection via USE+reload through the new firemode enums,
unloading a live round, and the `reload_live` sequence rebuild).

---

## 12. Lunge Mine — `weapons/mcv_lunge_mine.lua`

### 12.1 Design

A single-use suicide anti-tank contact mine on the melee base (`SWEP.Base = "mcv_melee"`,
weapons/mcv_lunge_mine.lua:2). 88 lines. Throwing is disabled (*"Throw animations are
unfinished; contact attacks only"*, :25; BUGLIST.md:181), so every attack path ends in
detonation.

The derivative introduces a private action state **5** past the base's 0-4 (§2.1) as the
"gone" latch: `PrimaryAttack`/`SecondaryAttack` return early when `GetActionState() == 5`
(:33-40).

### 12.2 Overrides

```lua
-- weapons/mcv_lunge_mine.lua:58-73
function SWEP:MeleeHit(range)
    if self:GetActionState() == 5 then return false end
    local owner = self:GetOwner()
    if SERVER then owner:LagCompensation(true) end
    local tr = self:MeleeTrace(range)
    if SERVER then owner:LagCompensation(false) end
    if !tr.Hit or tr.HitSky or tr.StartSolid then return false end
    self:SetActionState(5)
    self:CancelDeferred()
    if SERVER then
        local mine = self:CreateMine(tr.HitPos + tr.HitNormal * 4, self:GetAimAngle())
        if IsValid(mine) then mine:Detonate() end
        self:Remove()
    end
    return true
end
```

Because every deferred hit (`Deferred_SlashHit`, `Deferred_StabHit`, `Deferred_ChargeHit`)
funnels into `MeleeHit`, overriding it converts **all** melee attacks into contact
detonation: state 5 latches, pending defers cancel, the server spawns the mine at the
contact point and detonates it immediately, and the weapon removes itself. `LaunchBlade`
(:75-88) — the throw path, kept reachable only through the base's USE+attack flow — is
similarly repurposed: spawn, velocity `ThrowForce * StatMult("projectile_speed") + vel`,
spin, remove. `CreateMine` (:42-56) spawns `ThrownEntity "mcv_proj_lunge_mine"` with the
explosion stats scaled by the category multipliers and `SetWeapon(self)`.

### 12.3 Entity

`mcv_proj_lunge_mine` (entities/mcv_proj_lunge_mine.lua) is a 14-line config on
`mcv_proj_40mm`: `ImpactFuse`/`ExplodeOnImpact` true, 250 damage / 160 radius, no trail —
so a thrown one detonates on first touch even though `LaunchBlade` normally just yeets it.
Stats and entity internals: docs/projectiles-entities.md.

---

## 13. Translation-Layer Surface (ranked)

How foreign SWEPs (built for activity-driven bases like ArcCW / TacRP / HL2) map onto these
bases, and what a converter must emit. Ranked by expected traffic.

### 13.1 Ranked mapping

| Rank | Foreign weapon type | MCV target | Effort | Notes |
| --- | --- | --- | --- | --- |
| 1 | Melee (knives, crowbars, fists) | `mcv_melee` derivative | low | field-only if the model has the named sequences; code override otherwise (§13.2) |
| 2 | Grenades / throwables | `mcv_throwable` derivative | low | field-only; behavior contract differs (hold-to-windup) (§13.3) |
| 3 | Placeables (C4, mines) | `mcv_placeable` derivative | medium | `PlaceKind` routing + entity (§13.4) |
| 4 | Continuous-fire (flamethrowers) | `mcv_flamethrower` derivative | medium | input model inversion (§13.5) |
| 5 | Projectile launchers (crossbows, bolt guns) | `mcv_base` derivative, data only | trivial | `ShootEntity` path (§13.6) |
| 6 | Binoculars / spotters | `mcv_binoculars` derivative | trivial | aim-blend reuse (§13.7) |
| 7 | Ammo/heal dispensers | `mcv_equipment_box` derivative | low | plan algorithm is global and free (§13.7) |
| 8 | Selectable-ammo launchers | `mcv_m79_base` derivative | medium | firemode-as-ammo idiom (§11) |
| 9 | Underbarrel exotic (flame cartridge) | `mcv_underbarrel_flame` | rare | deferred-chain pulse (§6) |

### 13.2 Melee conversion contract

A foreign melee weapon animates with `ACT_VM_HITCENTER`/`ACT_VM_PRIMARYATTACK` activities
and damages through its own trace. On MCV:

- **The base is sequence-name driven** (§2): the converter must either (a) verify the model
  carries the expected names — `slash`, `slash2`, `swing_a/b/c`, `miss`, `miss2`, `stab`,
  `swing_hard`, `stab_charge`, `stab_charge_loop`, `stab_charge_attack`, `throw*`, `run`,
  `idletorun`, `runtoidle`, `idletorepair`, `repair`, `repairtoidle`
  (weapons/mcv_melee/shared.lua:50-65) — or (b) emit a derivative overriding
  `Sequences*`/`Sequence*` fields with the model's real names, or (c) override
  `Slash`/`Stab` to call `PlayAnimation` with activities (the `PickSequence` lists make (b)
  sufficient in most cases; `PickSequence` tolerates partial lists).
- Emit: `DamageGeneric` (slash), `DamageGenericAlt` (stab; default 1.5×), `MeleeRange` /
  `MeleeRangeAlt`, `SlashRate`/`StabRate` (RPM — foreign bases usually express this as a
  delay: `delay = 60 / rate`), `HitDelay`/`StabHitDelay`, `MeleeHullSize`, the four hit
  sounds, `CanThrow`.
- The base supplies: hit/miss animation selection, cadence, view punch, third-person
  gesture, blood/surface impacts, charge, run transitions, repair. **Do not** reimplement
  any of these in the converted weapon.
- Sharp edge: if the model has *no* sequence of a list, `Slash` still swings with a 0.5 s
  default duration but **no viewmodel animation** (sh_melee.lua:117) — a converter should
  detect and warn.
- Bayonet-like carried knives should set `SWEP.IsBayonet = true` so MCV rifles can fix them
  (sh_bash.lua:112-119).

### 13.3 Grenade conversion contract

Foreign grenade bases throw on click and animate with `ACT_VM_THROW`/`ACT_VM_PULLPIN`. On
MCV: emit `ThrowEntity` (must be an MCV-compatible projectile — see
docs/projectiles-entities.md for the field contract: `Delay`, `ImpactFuse`,
`ExplosionDamage/Radius`, `Attacker`/`Inflictor`), `ThrowForce*`, `FuseModes`,
`HasUnderhand`, `Explosion*`, `Primary.Ammo`/`DefaultClip`. The **behavior** difference to
bridge: MCV requires press-and-hold windup with release timing (`ThrowReleaseTime`); a
foreign click-to-throw feel can be approximated by shrinking the windup or emitting a
derivative that calls `Windup` and immediately `Throw` — but only by overriding
`ThinkWeapon`'s release condition, never by bypassing the state machine (hold types and
cooking depend on it, §3.3-3.5). Impact-fused weapons set `FuseImpact = true` (single fuse
mode, no cooking, lit rag particle).

### 13.4 Placeable conversion contract

Pick `PlaceKind` (`"c4"`/`"dynamite"`/`"mine"`) — it selects the entire input map
(§4.10). Emit `PlacedEntityClass` (+ `StakeEntityClass` for mines), explosion stats,
`PlacedAngleOffset`, and the sequence names (`plant`, `placemine`, `placestick`,
`drawbackhigh`, `throw`). The placed entity must implement the small surface the base
calls: `PlantOn(parent)`, `GetPlanter()`, `RemoteFuse`/`RemoteDetonate()` (C4), `Light()`
(dynamite), `SetStakeEntity`/`GetWireStart` (mine) — see
entities/mcv_placed_{c4,dynamite,mine}.lua and docs/projectiles-entities.md. Ghost, wire
validation, two-step mine flow and depletion come free.

### 13.5 Continuous-fire conversion contract

A foreign flamethrower's `PrimaryAttack` (and its loop timers) must be **rewritten as a
hold-state in `ThinkWeapon`** following sh_flame.lua:107-130 — gate on
`KeyDown(IN_ATTACK)`, `GetRoundsLeft()`, `GetAnimLockTime()`, `GetHolsterTime()`,
`GetIsSprinting()`; keep the on/off state in `SetPrimedAttack` (networked, drives everyone's
client effects); burn ammo through `TakeRound` per tick; damage server-only. `PrimaryAttack`
must be stubbed empty. The client stream is the flamethrower's PCF contract (§5.6): attach
to `muzzle` on the viewmodel/world model copy, flag world-projection PCFs, aim CP1 with a
per-frame trace. Fuel is reserve-only (`ClipSize = -1`).

### 13.6 Data-only projectile weapons

Crossbow-style weapons (harpoon guns, bolt guns, net launchers): emit an `mcv_base`
derivative with `ShootEntity`, `ShootEntityForce`, `Primary.Chamber = 0`, `ClipSize`,
`MagInTime` (from the reload animation's ammo event — BUGLIST.md:347), blank
particle/brass fields. Zero code. The projectile entity must accept `SetWeapon`/`Inflictor`
and the explosion-stat overrides (sh_shoot.lua:658-699).

### 13.7 Optics and dispensers

- Binocular-like items: `mcv_binoculars` derivative; zoom via `ZoomLevels`, overlay via
  `OverlayMaterial`; nothing else. Beware the §9.3 hint/code mismatch when advertising
  inputs.
- Ammo/heal items: `mcv_equipment_box` derivative with `BoxKind`/`HealAmount`/
  `AmmoMagazines`; `MCV_ApplySupply`/`MCV_AmmoSupplyPlan` are globals and already handle
  stock GMod weapons in the target's inventory.

### 13.8 Hard constraints (what a converter must never do)

1. **Never redefine `SetupDataTables`** — the shared layout is fixed; use the existing
   accessors (mcv/weapon_common/shared.lua:194-195).
2. **`DeferredActions` is a full per-class list**: override = replace (see the underbarrel
   flame, §6.4); extend = copy the parent's entries and append. The order travels between
   realms.
3. **No closures/timers for gameplay stages** — only `Defer`/`Deferred_<name>` +
   `ActionStart/End/Variant/Target` NetworkVars (sh_timers.lua:1-16).
4. Entity creation and damage are **server-only**; predicted writes are limited to
   `TakeRound`, `SetClip*`, `SetAmmo`, the state NetworkVars, and viewmodel playback.
5. When overriding an inherited method that itself must still run, call
   `baseclass.Get("<base>").Method(self, ...)` — **not** `self.BaseClass` (the flamethrower
   holster freeze, §5.9).
6. Aim/sight behavior belongs to `Think_Sights`; if you replace `ThinkWeapon` on an
   `mcv_base` child you must forward it (flamethrower and binoculars both do).
7. Nested-table inheritance is index-by-index in GMod — shorter derived lists still see the
   base's later entries (the `FuseModes` guard, sh_throw.lua:32-38; AGENTS.md:57-60).
8. Equipment bases do **not** have gun systems — a converted weapon that needs sights +
   melee-style attack must sit on `mcv_base` (or duplicate what it needs), not on
   `mcv_melee`/`mcv_throwable`.
9. Client effects for networked states must follow the state (like `Think_ClientFlame`),
   never the command replay, or they desync in singleplayer/remote views.
10. Register any new ammo type in `MCV.AmmoTypes` (mcv/shared/sh_common.lua:66-80) or use
    engine types; category stat multipliers only reach weapons, never entities
    (AGENTS.md:42-46).

### 13.9 Emitted-field checklist per target base

- **`mcv_melee`**: models, `MovementPoseWalk/Sprint/Sighted`, `HoldType` set,
  `DamageGeneric(Alt)`, `MeleeRange(Alt)`, `SlashRate`/`StabRate`, `HitDelay`/
  `StabHitDelay`, `MeleeHullSize`, 4 hit sounds, `CanThrow`, optional `IsBayonet`,
  `CanRepair`+`RepairPerSecond`, sequence-name overrides as needed.
- **`mcv_throwable`**: models + poses, `ThrowEntity`, `ThrowForce*`, `ThrowReleaseTime*`,
  `FuseModes`/`FuseImpact`, `Explosion*`, `IgniteRadius`/`EffectDuration`/`SmokeColor`,
  `HasUnderhand`, `RemoveWhenEmpty`, `Primary.Ammo`/`DefaultClip`, optional `ThrowModel`,
  `ModelSkin`, `LitParticle`.
- **`mcv_placeable`**: models + poses, `PlaceKind`, `PlacedEntityClass` (+stake fields),
  `PlaceRange`/`PlaceDelay`, `Explosion*`, `FuseTime`/`ThrowForce` (dynamite),
  `PlacedAngleOffset`, `MineBodygroups`, `SoundFuseLoop`, `Primary.Ammo`/`DefaultClip`.
- **`mcv_flamethrower`**: models + poses, `FireRate` (ticks/min), `DamageGeneric`,
  `FlameRange`/`FlameHull`, `IgniteTime`/`BurnDamagePerSecond`, `FuelPerTick`,
  `FlameParticle`/`FlameAttachment`, fire sounds, tank fields, fuel ammo.
- **`mcv_base` data-only projectile**: §13.6 list.
- **`mcv_binoculars`**: models, `ZoomLevels`, `OverlayMaterial`, `SightedViewModelFOV`,
  `IronsightSpeedScale`.
- **`mcv_equipment_box`**: models, `BoxKind`, `HealAmount`, `AmmoMagazines`,
  `Primary.Ammo`/`DefaultClip`.

---

## 14. File Map

| File | Lines | Contents |
| --- | --- | --- |
| `weapons/mcv_melee/shared.lua` | 76 | melee defaults, sequence-name tables, module loader |
| `weapons/mcv_melee/sh_melee.lua` | 498 | trace/damage, slash/stab/charge, blade throw, wrench repair, input, deferred handlers |
| `weapons/mcv_throwable/shared.lua` | 64 | grenade defaults, sequence names, fuse modes |
| `weapons/mcv_throwable/sh_throw.lua` | 337 | windup/throw state machine, cooking, `LaunchThrowable`, fuse modes |
| `weapons/mcv_placeable/shared.lua` | 61 | placeable defaults, `PlaceKind`, stake/angle fields |
| `weapons/mcv_placeable/sh_place.lua` | 511 | placement math/validation, plant pipeline, dynamite, C4 detonator, client ghost |
| `weapons/mcv_flamethrower/shared.lua` | 73 | flamethrower defaults + own directory loader |
| `weapons/mcv_flamethrower/sh_flame.lua` | 280 | flame state/tick, client stream, tank hook, lifecycle |
| `weapons/mcv_underbarrel_flame/shared.lua` | 93 | pulsed flame cartridge on the UBGL path |
| `weapons/mcv_chainsaw.lua` | 165 | chainsaw weapon (spin state, `SawTick`, lifecycle) |
| `mcv/client/cl_chainsaw.lua` | 98 | chainsaw audio tracker (loops/transitions, cleanup) |
| `weapons/mcv_crossbow.lua` | 160 | pure data definition (bolt projectile via `mcv_base`) |
| `weapons/mcv_binoculars/shared.lua` | 119 | zoom optics on the sight blend |
| `weapons/mcv_equipment_box/shared.lua` | 36 | box defaults |
| `weapons/mcv_equipment_box/sh_box.lua` | 225 | supply plan/apply, use/drop pipelines |
| `weapons/mcv_m79_base/shared.lua` | 112 | selectable-cartridge firemode/ammo virtualization |
| `weapons/mcv_lunge_mine.lua` | 88 | single-use contact-detonation melee |

Supporting shared code (cross-referenced, owned by other docs):
`mcv/weapon_common/load.lua` (composition), `shared.lua` (defaults + datatable + hooks),
`sh_think.lua` (Think pipeline, movement), `sh_deploy.lua` (deploy/holster/Initialize),
`sh_timers.lua` (deferred actions), `sh_anim.lua` (playback), `sh_vm.lua` (viewmodel
render + lit particle), `sh_bash.lua` (bash), `cl_worldmodel.lua` (third person),
`mcv/shared/sh_melee_effects.lua` (blood), `sh_burn.lua` (burn-over-time),
`sh_common.lua` (firemode enums, ammo types), `sh_modelcache.lua` /
`mcv/client/cl_modelgc.lua` (caches + client model tracking). Derivative definitions read
for this audit: `mcv_crowbar/fists/katana/sickle/shovel_vc/wrench/ak47_bayonet/
type30_bayonet`, `mcv_rgd5/vcgrenade/csg/csg2/css`, `mcv_dynamite/rg42`,
`mcv_lpo50`, `mcv_ammobox_vc/medicbox_vc`, `mcv_binoculars_vc`.
