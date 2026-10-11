# MCV Base — Gun Core Runtime (Exhaustive Audit)

> Audited from `reference/mcv/lua/` @ upstream commit `06f4a24b4db99666c3ac28c7b28f9c44242a48e5` (tacrp/Military-Conflict--Vietnam-SWEPs).
> All file:line citations are relative to `reference/mcv/lua/`.
>
> **Scope**: everything about being a *held firearm* except shooting internals
> (→ `docs/shooting-ballistics.md`), reload/ammo logic (→ `docs/reload-ammo.md`), sounds
> (→ `docs/sound-system.md`), effects (→ `docs/effects.md`), HUD (→ `docs/hud-settings.md`)
> and NPC behavior (→ `docs/support-systems.md`). Animation *playback* is exhaustively
> covered by `docs/animation-system.md` — this document cross-references it as
> **anim §N.M** instead of re-documenting, and covers the **gameplay** side of every
> animation-adjacent state machine.
>
> **Realm notation**: SH = included on both server and client (predicted on the client);
> SV = server-only include; CL = client-only include. Prediction-safety is first-class
> throughout: MCV runs its weapon logic inside Source's command replay, so nearly every
> state change lives in NetworkVars that the engine restores on rollback.

---

## 1. Architecture Overview

### 1.1 The three layers

| Layer | Files | Role |
|---|---|---|
| **Common composition** | `mcv/weapon_common/*.lua` (13 files) | Deploy/holster lifecycle, Think skeleton, clock/timers, movement blends, hold types, viewmodel pose-parameter driver, camera, bash, world-model drawing. Not a registered SWEP — *composed into* every base. |
| **Gun base** | `weapons/mcv_base/*.lua` (15 files) | The firearm: field defaults (`shared.lua`), gun Think (cycle/burst/DA/UBGL), sights, bipod, akimbo, UBGL, bayonet charge, RT scope, shoot/reload/effects/penetration/NPC modules. Registered, `Spawnable` via derived classes. |
| **Weapon definitions** | `weapons/mcv_*.lua` (244 classes) | Pure data: `SWEP.Base = "mcv_base"` + stat fields, offsets, timing constants, particles, sounds. A handful define small behavior overrides. |

Sibling bases (`mcv_melee`, `mcv_throwable`, `mcv_placeable`, `mcv_flamethrower`, …) are
*peers* of `mcv_base`: each includes `mcv/weapon_common/load.lua` and fills the same hook
contract (§2.4). The M79 break-action launcher derives from `mcv_base` via
`weapons/mcv_m79_base` (see anim §7.9 for its animation flows).

### 1.2 Load order & the composition trick — `mcv/weapon_common/load.lua`

The 33-line loader is the least obvious and most load-bearing file in the base. It has to
answer a GMod constraint: *there is no multiple inheritance for SWEPs*, and registering an
extra "common" base would put it in every player's weapon slot list. MCV's answer is
**composition by table copy**:

```lua
// mcv/weapon_common/load.lua:1-33
// Compose common weapon behavior once, without an extra registered SWEP base.
// Functions (and module hooks) are shared; mutable default tables belong to each base.
AddCSLuaFile()
if !MCV.IncludeWeaponModules then
    function MCV.IncludeWeaponModules(dir)
        local files, dirs = file.Find(dir .. "/*.lua", "LUA")
        for _, filename in ipairs(files) do
            if filename != "shared.lua" and filename != "load.lua" then
                local realm = string.sub(filename, 1, 2)
                local path = dir .. "/" .. filename
                if realm != "sv" then AddCSLuaFile(path) end
                if realm != "cl" and realm != "sv" or realm == "cl" and CLIENT or realm == "sv" and SERVER then
                    include(path)
                end
            end
        end
        for _, folder in ipairs(dirs) do MCV.IncludeWeaponModules(dir .. "/" .. folder) end
    end
end

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

Step by step:

1. **`MCV.IncludeWeaponModules(dir)`** (load.lua:5-18) — walks a directory of modules,
   skipping `shared.lua` and `load.lua`, dispatching by filename prefix: `sv_*` is included
   on the server only (and never sent to the client), `cl_*` is sent to and included on the
   client only, everything else is sent and included on both realms. It recurses into
   subdirectories. `file.Find` returns names alphabetically, so the effective include order
   in `mcv/weapon_common/` is: `cl_camera`, `cl_hud`, `cl_worldmodel` (client), then
   `sh_anim`, `sh_bash`, `sh_clock`, `sh_deploy`, `sh_movement`, `sh_think`, `sh_timers`,
   `sh_vm` (both realms). Order is cosmetic — these files only assign functions/fields.
2. **The sandbox include** (load.lua:21-29) — the first base to load swaps the *global*
   `SWEP` for a scratch table and runs `mcv/weapon_common/shared.lua` against it. That file
   assigns defaults and calls `MCV.IncludeWeaponModules("mcv/weapon_common")`
   (shared.lua:191), pulling in the whole common layer **onto the scratch table**. The
   result is cached as `MCV.WeaponCommon` and only built once per Lua state.
3. **The copy** (load.lua:31-33) — every base that includes `load.lua` gets a shallow
   `table.Copy` of each *table* value (so `SWEP.Firemodes`, `SWEP.DeferredActions`,
   `BulletBodygroups` etc. are per-base, not shared references) and a direct reference for
   functions (functions are shared — one closure instance per realm, which is fine because
   they hold no per-weapon state).

`weapons/mcv_base/shared.lua:1` is `include("mcv/weapon_common/load.lua")` — this is how
the gun base receives the common layer — and `weapons/mcv_base/shared.lua:224-226` ends
with `AddCSLuaFile()` + `MCV.IncludeWeaponModules("weapons/mcv_base")`, which pulls in
the directory's other 14 files (`cl_pipscope` on the client, then `sh_akimbo`,
`sh_bayonet_charge`, `sh_bipod`, `sh_effects`, `sh_gun`, `sh_npc`, `sh_penetration`,
`sh_reload`, `sh_shoot`, `sh_sights`, `sh_think`, `sh_ubgl`, `sh_vm` on both realms;
bash itself lives in `weapon_common`, §12).

The global `MCV` table itself is built by `autorun/sh_mcv_load.lua`: it forces
`mcv/shared/sh_convars.lua` first (convar registration order — see
`reference/mcv/AGENTS.md` "Convars"), then the rest of `mcv/shared/*`, then
`mcv/client/*` (client), then `mcv/server/*` (server). Weapons register afterwards
through GMod's normal weapon scan.

### 1.3 `SWEP.Base` chain resolution

- `weapon_common` sets `SWEP.Base = "weapon_base"` (shared.lua:10) — the *engine* base,
  giving MCV weapons the standard predicted-weapon plumbing (`PrimaryAttack`,
  `NextPrimaryFire`, clip networking) and nothing else.
- `mcv_base/shared.lua:4` re-sets `SWEP.Base = "weapon_base"` (it does **not** derive from
  another MCV class; the common layer arrives by composition, §1.2).
- A weapon definition sets `SWEP.Base = "mcv_base"` (e.g. `weapons/mcv_vz54s.lua:1`) and
  receives, through GMod's nested-table inheritance: the base's copied defaults, the
  composed common functions, and the gun modules. GMod merges nested *lists* on
  inheritance — the reason `Initialize` de-duplicates `Firemodes` (§3.1) and
  `BulletBodygroups` iteration needs an `isnumber(key)` guard (anim §4.4 step 7; also a
  house rule in `reference/mcv/AGENTS.md`).
- Because the common functions were *copied into each base's table*, a definition that
  overrides `SWEP:ThinkWeapon` on `mcv_base` shadows only the gun implementation; the
  common `Think` still runs and calls it. To call "up", use `self.BaseClass.ThinkWeapon`
  — GMod populates `BaseClass` chains.

**Translation consequence**: a foreign-base SWEP cannot run on MCV by setting
`SWEP.Base = "mcv_base"` alone with foreign fields — the foreign *runtime* (its own
Think/Holster/PrimaryAttack) must be neutralized or mapped onto the MCV hooks catalogued
in §2.4. Conversely, any code that wants to patch MCV behavior globally must patch after
composition (an `include` of `load.lua` re-copies `MCV.WeaponCommon` into that base only).

### 1.4 Marker flag

`SWEP.MilitaryConflictVietnam = true` (weapon_common/shared.lua:184) is the marker every
global hook tests to decide an entity is an MCV weapon: `StartCommand` holster switching
(sh_deploy.lua:131), recoil impulses (sh_movement.lua:21), movement sampling
(sh_movement.lua:60), world-model bone restore (cl_worldmodel.lua:85), PVS retirement
(cl_worldmodel.lua:269), scope screen capture (cl_rendertarget.lua:11), viewmodel render
bounds (cl_rendertarget.lua:45). A translation layer must preserve this flag or all
global support machinery silently detaches.

---

## 2. `mcv/weapon_common/shared.lua` — the Common Contract (400 lines)

This file defines the SWEP table that every base copies (§1.2). Its contents fall into
five groups: data defaults, sound routing, the datatable, the derived-base hook contract,
and shared helpers.

### 2.1 SWEP table defaults (field catalogue)

| Field | Default | Set at | Consumed by |
|---|---|---|---|
| `Spawnable` / `AdminOnly` / `Category` | `false` / `false` / `"Military Conflict: Vietnam"` | shared.lua:7-9 | spawn menu |
| `Base` | `"weapon_base"` | shared.lua:10 | inheritance (§1.3) |
| `NPCUsable` | `false` | shared.lua:11 | `CanBePickedUpByNPCs` (shared.lua:13-15); overridden `true` on `mcv_base` (shared.lua:5) → NPC support doc |
| `PrintName` / `Country` / `SubCategory` / `Caliber` | `""` | shared.lua:18-21 | HUD/selection info; `SubCategory` also keys `StatMult` |
| `ViewModel` / `WorldModel` | `v_sks` / `w_sks` placeholder | shared.lua:23-24 | every weapon overrides |
| `BodyGroups` | `""` | shared.lua:84 | `DoBodygroups` → `vm:SetBodyGroups` (sh_vm.lua:29) |
| `WorldModelBodyGroups` | `nil` | shared.lua:89 | `Initialize` SV: `self:SetBodyGroups` (sh_deploy.lua:184-186); remaps VM bodygroup string onto world-model bodypart order (comment: the M14 is the M21's model with the scope off) |
| `ViewModelFOV` / `SightedViewModelFOV` | `80` / `40` | shared.lua:91-92 | `MCV.ViewmodelFOV` (cl_viewsettings.lua:21-25), anim §9.1 |
| `HoldType` / `SprintHoldType` / `AimHoldType` | `"ar2"` / `"passive"` / `"rpg"` | shared.lua:94-96 | `Think_HoldType` (§4.3), gestures (§2.1b) |
| `ShootGesture` / `ReloadGesture` | `false` | shared.lua:98-99 | gesture getters |
| `BashGesture` | `ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND` | shared.lua:126 | `Bash`/`BayonetChargeAttack` third-person |
| `DamageGeneric`…`ViewSlideRecoil*` | generic stat defaults | shared.lua:128-139 | overridden by every gun; → shooting doc |
| `CustomPos` / `CustomAng` | `vector_origin` / `angle_zero` | shared.lua:142-143 | hip viewmodel offset, anim §9.4 |
| `IronsightPos` / `IronsightAng` | `0` | shared.lua:144-145 | aim offset, anim §9.4 |
| `IronsightFov` | `75` | shared.lua:146 | `GetScopeWorldFov` fallback (sh_gun.lua:43) |
| `ViewModelZNear` | `false` | shared.lua:147 | near-plane override in `PreDrawViewModel` (sh_vm.lua:66-72) |
| `IronsightWalkBobbingStrength` | `-0.25` | shared.lua:148 | walk bob while aimed (HUD/view doc) |
| `ShakeScale` / `ShakeFreq` / `ShakeDuration` | `1` / `45.0` / `0.4` | shared.lua:150-153 | `CalcView` roll shake (§13.1) |
| `HasBayonet` / `BashDamage` / `BashRange` / `BayonetDamage` / `BayonetRange` | `false` / `50` / `96` / `100` / `128` | shared.lua:155-160 | §11, §12 |
| `CrosshairMinDistance` / `CrosshairDeltaDistance` | `8` / `4` | shared.lua:162-163 | HUD doc |
| `WeaponWeight` | `3.85` | shared.lua:165 | movement speed scaling (support doc) |
| `Primary.*` / `Secondary.*` | engine-style ammo tables | shared.lua:167-176 | clip/ammo system → reload doc |
| `DrawCrosshair` / `AccurateCrosshair` / `DrawWeaponInfoBox` / `UseHands` | `true` / `false` / `true` / `true` | shared.lua:179-182 | engine boilerplate |
| `MilitaryConflictVietnam` | `true` | shared.lua:184 | marker flag (§1.4) |
| `BobScale` / `SwayScale` | `0` / `0.1` | shared.lua:186-187 | engine viewmodel bob disabled — MCV's own sway owns the viewmodel |
| `LitAttachment` | `"Wick"` | shared.lua:332 | `UpdateLitParticle` (sh_vm.lua:104-116) |

#### 2.1b Gestures by hold type — shared.lua:98-126

`GetShootGesture()` / `GetReloadGesture()` (shared.lua:117-125) map the *current networked
hold type* (`self:GetHoldType()` — engine DT) through the `GESTURES` table (ar2, smg,
pistol, revolver, duel, shotgun, rpg, crossbow, melee, grenade, slam →
`ACT_HL2MP_GESTURE_RANGE_ATTACK_*` / `ACT_HL2MP_GESTURE_RELOAD_*`), with per-weapon
`ShootGesture` / `ReloadGesture` overriding and `ACT_HL2MP_GESTURE_RANGE_ATTACK_AR2` as
final fallback. The gun base pins both to AR2 explicitly
(mcv_base/shared.lua:37-38). Full third-person behavior → anim §8.

### 2.2 Third-person sound routing

MCV's foley design: the *holder* hears their weapon through the viewmodel's own animation
events; everyone else hears explicit third-person sounds. Two functions implement the
split:

**`SWEP:PlayOwnThirdPersonSound(name)`** — CL, shared.lua:32-41. Skips silently when
called on the server, when the sound is empty, when a non-first prediction pass runs it in
multiplayer, or when the caller's owner is not the local player. Emits from the *player*
only when `owner:ShouldDrawLocalPlayer()` (third-person camera / the viewmodel off
screen) — otherwise the first-person viewmodel events already carry the sound and this
would double it.

**`SWEP:EmitThirdPersonSound(name)`** — SH, shared.lua:43-78. On the client it simply
forwards to `PlayOwnThirdPersonSound` (the holder's own predicted client is the one that
knows whether the viewmodel is on screen). On the server it builds a `RecipientFilter`
from the owner's PVS, removes the owner, and — in singleplayer, where the client runs
none of the weapon — asks the client outright via `self:CallOnClient(
"PlayOwnThirdPersonSound", name)` (shared.lua:68-70; "This is how the muzzle light gets
there too"). Emits from the *player entity*, not the weapon ("a carried weapon is not
where the player is as far as sound is concerned"), with no level/pitch/volume overrides
("the soundscript carries all four"). Callers in this audit's scope: the bolt cycle
(sh_think.lua:120), reload start/loop (→ reload doc).

**`SWEP:StatMult(stat, category)`** — SH, shared.lua:80-82. Delegates to
`MCV.CategoryMult(category or self.SubCategory, stat)` (per-category server convar
multipliers — support doc). Used by e.g. `DoImpactEffect` (shared.lua:306).

### 2.3 `SetupDataTables` — the complete fixed datatable

The single most important structural fact (anim §3.3): **all networked state for every
MCV base lives in this one layout**, defined once in `weapon_common/shared.lua:196-285`.
The comment is a contract:

```lua
// mcv/weapon_common/shared.lua:194-195
// All networked state lives here so every derived base shares one layout. Unused slots
// cost nothing. Derived bases must not redefine SetupDataTables.
```

Full field-by-field catalogue (accessor names are `Get<Name>` / `Set<Name>`):

**Floats** (shared.lua:197-228)

| Slot | Accessor | Meaning | Written by | Read by |
|---|---|---|---|---|
| 0 | `AnimLockTime` | action lockout deadline (0 = free) | `applySequence` (anim §2.3) | `StillWaiting`, all gating |
| 1 | `NextIdle` | when `Idle()` may restart (`math.huge` = hold frame) | `applySequence`, reload stages | `Think` (sh_think.lua:21) |
| 2 | `LastRecoilTime` | last shot's time (shake clock) | fire paths → shooting doc | `CalcView` shake (§13.1) |
| 3 | `LastTriggerTime` | last trigger press (DA delay) | `PrimaryAttack` → shooting doc | DA release (§4.4) |
| 4 | `HolsterTime` | pending holster's due time | `Holster` (§3.4) | `Holster`, `PreDrawViewModelWeapon` (scope off while holstering) |
| 5 | `SightAmountRaw` | integrated sight blend 0..1 | `Think_Sights` (§7.1) | sight getters, spread/recoil |
| 6 | `Speed` | integrated movement blend | `Think_Speed` (§4.2) | pose, hold type, sprint gating |
| 7 / 8 | `LastShotTimeR` / `LastShotTimeL` | akimbo per-hand recoil clocks | fire paths (sh_shoot.lua) | pose recoil (anim §4.1) |
| 9 | `ActionStart` | when the current action began (cycle clip pose / equipment state machine) | cycle (§4.6), bayonet charge (§11), equipment bases | `DoBodygroupsWeapon` `CycleClipPoseTime`, charge Think |
| 10 | `DeferredTime` | the pending deferred action's deadline (§5.3) | `Defer` | `ProcessDeferred` |
| 11 | `ActionEnd` | current action's end (charge wind-up / equipment) | `StartBayonetCharge` etc. | `Think_BayonetCharge` |
| 12 | `NextRepairTime` | (equipment) | placeable base | — |
| 13 | `WindupEnd` | (equipment throw wind-up) | throwable base | — |
| 14 | `HammerReleaseTime` | when the model's own event drops the hammer | `ScheduleHammerRelease` (anim §5.6) | `Think_HammerRelease` (§4.4) |
| 15 / 16 | `MoveSpeed` / `LastMoveSpeed` | completed-command movement samples | `CaptureMovement` (§6.1) | `GetWeaponMovement` |
| 17 / 18 | `AnimationStart` / `AnimationDuration` | viewmodel timeline stamps (negative = reverse) | `applySequence` (anim §2.3) | `UpdateViewModelAnimation` (anim §3.2) |

**Ints** (shared.lua:230-247)

| Slot | Accessor | Meaning |
|---|---|---|
| 0 | `ScopeLevel` | 1 or 2 (`AdjustableScopes` magnification step) |
| 1 | `LastClip` | clip snapshot at reload start (shotgun cancel logic, §4.4) |
| 2 | `Firemode` | index into `SWEP.Firemodes` |
| 3 | `ActionState` | equipment state machine; guns: `STATE_CHARGE` for bayonet charge (§11) |
| 4 | `BurstCount` | rounds fired this trigger pull (runaway bursts, §4.4) |
| 5 | `DeferredAction` | index into `SWEP.DeferredActions`, 0 = none (§5.3) |
| 6 | `ReloadHand` | dual-revolver round-by-round reload hand (0 right / 1 right-closing / 2 left) → reload doc |
| 7 | `ActionVariant` | (equipment) |
| 8 | `SlashCount` | (melee) |
| 9 | `RecoilCommand` | command number the queued recoil impulse belongs to (§6.2) |
| 10 | `HolsterCommand` | command number the pending holster fires on (§3.4) |
| 11 | `MoveCommand` | command number of the last movement sample (§6.1) |
| 12 | `SupplyCursor` | (supply box) |
| 13 | `ClockResetSerial` | incrementing reset serial (§5.2) |
| 14 | `AmmoSwitchFrom` | outgoing cartridge during ammo-change reload (M79) |

**Bools** (shared.lua:254-273): `Reloading`, `EndReload`, `Ready`, `Bipod`, `EmptyReload`,
`NeedTriggerPress`, `Ironsight` (input intent), `Sighted` (actually up), `Bayonet`,
`GrenadeLauncher`, `NeedCycle`, `Akimbo`, `PrimedAttack`, `HasSecond`, `WasRunning`
(consumed by the melee base's charge, sh_melee.lua:369-370), `MoveGrounded`,
`LastMoveGrounded`, `MoveCrouched`, `LastMoveCrouched`, `Safe`.

**Vector** 0 `RecoilImpulse` (queued recoil, §6.2); **Entity** 0 `HolsterEntity`
(switch target, §3.4), 2 `ActionTarget` (equipment).

Two details with prediction weight:

- `ClockResetSerial` carries a client-side `NetworkVarNotify` (shared.lua:248-252) that
  invokes `ResetClockVisuals` when the server increments it — the client's visual caches
  (§5.1) follow a server clock reset without a full state resync.
- The tail of `SetupDataTables` (shared.lua:281-284) **re-seeds only zero-initialized
  slots** (`Firemode`, `ScopeLevel`): "Setup runs again for retained entities on a Source
  map transition... keep the existing mode and bolt state" — matching BUGLIST
  ("Retained weapons clear stale CurTime deadlines... Repeated datatable setup also
  preserves selected modes and bolt/pump readiness").

**Translation constraint** (anim §3.3, repeated because it is the #1 porting trap): a
class deriving from `mcv_base` **cannot add NetworkVars** — the layout is fixed and shared
by every base. Foreign state must be plain per-instance Lua fields (created in
`Initialize`, like `self.PCFs = {}` at sh_deploy.lua:173) or NW2 vars.

### 2.4 The derived-base hook contract — shared.lua:287-350

These no-op defaults are the *entire* extension surface the common layer offers. A
translation layer implements behavior by overriding exactly these:

| Hook | Default | Called from | Gun implementation |
|---|---|---|---|
| `GetSightAmount/Raw/Visual/RawVisual` | `0` | everything aiming | sh_sights.lua (§7.2) |
| `ScopeToggle(on)` | no-op | input layer | sh_sights.lua:85 (§7.1) |
| `GetZoomMagnification()` | `1` | `CalcView` (§13.1) | sh_gun.lua:47 (§7.3) |
| `DoImpactEffect(tr, dmgtype)` | `MCV.SurfaceImpact(...)` | engine bullet path | shared (impact doc) |
| `GetFiremodeName()` | `""` | HUD | sh_gun.lua:60-64 |
| `GetBulletCount()` / `GetProjectileClass()` / `GetHUDAmmo()` | `Num` / `ShootEntity` / `nil` | fire/HUD | sh_gun.lua:66-72 |
| `IdleActivity()` / `IdleSequence()` | `ACT_VM_IDLE` / `nil` | idle loop | sh_gun.lua:11-25 + charge override §11 |
| `DeployAnimation()` | `PlayAnimation(ACT_VM_DRAW,1,true)` | `Deploy` (§3.3) | sh_gun.lua:27-33 |
| `OnDeploy()` | no-op | `Deploy` tail (§3.3) | equipment bases |
| `GetPrecacheParticles()` | `{}` | `Initialize` | sh_gun.lua:3-9 |
| `ViewModelHidden()` | `false` | deploy/render gates | C4 detonator case |
| `GetLitParticle()` / `IsLit()` | `nil`/`false` | `UpdateLitParticle` | molotov/dynamite |
| `ThinkWeapon()` | no-op | `Think` tail (§4.1) | mcv_base/sh_think.lua:49 (§4.4) |
| `DoBodygroupsWeapon(vm, visual, sa, speed)` | no-op | `DoBodygroups` | mcv_base/sh_vm.lua:12 (anim §4.4) |
| `PreDrawViewModelWeapon(vm)` | no-op | `PreDrawViewModel` | mcv_base/sh_vm.lua:250 (RT scope + muzzle light) |
| `PreDrawViewModelBlend(vm, sa)` | no-op | after `cam.Start3D` | mcv_base/sh_vm.lua:275 (OEG frame copy) |
| `PostDrawViewModelWeapon(vm)` | no-op | `PostDrawViewModel` tail | mcv_base/sh_vm.lua:286 (scope depth reset, OEG composite) |
| `DrawHUDExtra()` | no-op | HUD pass | HUD doc |
| `SecondaryAttack()` | no-op | engine | **guns: bayonet toggle only** (sh_gun.lua:74-80); aiming is Think-driven (§7.1) |

### 2.5 Shared helpers — shared.lua:352-400

**`SWEP:StillWaiting()`** (shared.lua:356-361) — *the* universal action gate:

```lua
function SWEP:StillWaiting()
    if self:GetNextPrimaryFire() > CurTime() then return true end
    if self:GetAnimLockTime() > CurTime() then return true end
    return false
end
```

Every gameplay entry point tests it: reload, bash, bayonet toggle, akimbo, UBGL, bipod,
aim entry (indirectly, see §7.1), fire (via `PrimaryAttack`, sh_shoot.lua:9). A translated
action that wants to respect MCV's lockouts must call this; one that wants to *create* a
lockout sets `NextPrimaryFire` and/or plays a locked animation.

- **`GetAimAngle()` / `GetAimVector()`** (shared.lua:363-371) — `EyeAngles() +
  GetViewPunchAngles()` forward: where the recoiling gun actually points. Used by bash
  traces (§12), the scope axis (§7.5), recoil impulse direction (§6.2).
- **`RandomSpread(spread, seed)`** (shared.lua:373-380) — cone via two
  `util.SharedRandom` draws seeded by `EntIndex + TickCount` — same on both realms.
- **`GetRoundsLeft()` / `TakeRound(n)`** (shared.lua:382-400) — clip-vs-reserve
  abstraction for clipless weapons (grenades count in the reserve).

---

## 3. Lifecycle & State — `mcv/weapon_common/sh_deploy.lua`

### 3.1 `SWEP:Initialize()` — sh_deploy.lua:143-187

Runs SH (once per entity creation; *again* for retained entities across Source map
transitions — see the datatable re-seed note in §2.3):

1. **Firemodes de-duplication** (143-157): GMod's inheritance merges nested lists, so a
   one-mode derived gun can inherit a duplicated mode. Builds a private dense list of
   distinct numeric modes, re-mapping the selected index.
2. **`SetHoldType(self.HoldType or "ar2")`** (158-159) — "also builds the engine's activity
   translations for NPC aiming / firing / reloads" (NPC doc).
3. **Rifle-grenade starting ammo policy** (160-164, SV): if
   `Secondary.Ammo == "smg1_grenade"` and `!MCV.SpawnRifleGrenadeAmmo()` (server convar
   `mcv_spawn_rifle_grenade_ammo`, default 1 — sh_convars.lua:36-41), zero the secondary
   clip. Only the newly created weapon is affected.
4. **Akimbo model precache** (166-170): `util.PrecacheModel(self.ViewModelAkimbo)` — "a
   model first precached at the mid-animation swap has no network model index on the
   predicting client yet".
5. **Per-instance state** (171-174): `self.PCFs = {}` (manual particle effects), 
   `self.ActiveEffects = {}` (in-flight shells) — the class-level tables on
   sh_vm.lua:38-39 are shared by every weapon of the class and must not be mutated.
6. **Particle precache** (176-180) from `GetPrecacheParticles()`.
7. **World-model bodygroups** (182-186, SV): `self:SetBodyGroups(self.WorldModelBodyGroups)`
   so the dropped weapon and drawn copies carry the right parts (§13.2).

### 3.2 `SWEP:SyncViewModel(changeModel)` — sh_deploy.lua:3-28

Rebuilds the engine-facing viewmodel alias from the *restored mode* — called every Think
(sh_think.lua:11) without arguments, and with `changeModel = true` from `Deploy` and the
akimbo/launcher swaps:

```lua
// mcv/weapon_common/sh_deploy.lua:3-28 (excerpt)
function SWEP:SyncViewModel(changeModel)
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    self.SingleViewModel = self.SingleViewModel or weapons.Get(self:GetClass()).ViewModel
    local model = self.HasAkimbo and self:GetAkimbo() and self.ViewModelAkimbo or self.SingleViewModel
    self.ViewModel = model
    local vm = self:GetOwner():GetViewModel()
    if !IsValid(vm) then return end

    // If we don't do this, it can sometimes carry the last weapon's bodygroups over.
    if changeModel or self.MCVBodygroupVM != vm or self.MCVBodygroupModel != model then
        vm:SetBodyGroups("0000000000000000000000000000000000000000000000000000000000000")
        self.MCVBodygroupVM, self.MCVBodygroupModel = vm, model
    end

    if changeModel then
        // GetModel's cached string can agree while the engine still has the old MDL.
        local mins, maxs = vm:GetCollisionBounds()
        vm:SetModel(model)
        // Client SetModel takes the MDL hull; the server retains the VM hull.
        vm:SetCollisionBounds(mins, maxs)
    elseif CLIENT then
        // Match the server's cache update before Think, not during a deferred swap.
        self:SetSaveValue("m_iViewModelIndex", vm:GetInternalVariable("m_nModelIndex"))
    end
end
```

Key contracts:

- `self.SingleViewModel` is snapshotted from `weapons.Get(class).ViewModel` — the
  *original* single model — so akimbo swaps can always swap back even after `self.ViewModel`
  has been repointed (BUGLIST: "Deploy explicitly sets the appropriate model for every
  weapon, preserving the viewmodel hull, dual-wield choice and active launcher mode").
- The 64-zero bodygroup reset fires when the VM entity or model identity changes — "it can
  sometimes carry the last weapon's bodygroups over".
- `SetModel` on the client replaces collision bounds with the MDL's hull; bounds are
  restored around the quirk.
- The client re-syncs `m_iViewModelIndex` by save-value every Think so the engine's
  cached index tracks mid-game model swaps (BUGLIST: "the model alias/cache... now follow
  restored state").

Prediction note: `SyncViewModel` runs inside predicted `Think` on the client and on the
server; because it derives everything from networked mode (`GetAkimbo`) and the class
table, replay is idempotent.

### 3.3 `SWEP:Deploy()` — sh_deploy.lua:30-64

```lua
// mcv/weapon_common/sh_deploy.lua:30-64
function SWEP:Deploy()
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then
        if self.NPC_Deploy then self:NPC_Deploy() end
        return true
    end
    self:CancelDeferred()
    self:SetHolsterCommand(0)
    self:SetHolsterTime(0)
    self:SetHolsterEntity(NULL)
    self:SetRecoilImpulse(vector_origin)
    self:SetRecoilCommand(0)
    self:SyncViewModel(true)
    // The save-value interface is relative on the server and absolute on the client.
    // Both writes mean ready now; CurTime on the server would double the deadline.
    self:GetOwner():SetSaveValue("m_flNextAttack", SERVER and 0 or CurTime())

    if self:ViewModelHidden() then
        self:SetReady(true)
    elseif !self:GetReady() and !self:GetGrenadeLauncher() and self:HasAnimation(ACT_VM_READY) then
        self:PlayAnimation(ACT_VM_READY, 1, true)
        self:SetReady(true)
    else
        self:DeployAnimation()
        self:SetReady(true)
    end

    self:SetIronsight(false)
    self:SetActionState(0)
    self:SetActionStart(0)

    self:SetBurstCount(0)
    self:OnDeploy()

    return true
end
```

Behavior notes:

- **NPC deploys** branch to `NPC_Deploy` (support doc).
- **State hygiene on entry**: any pending holster/deferred/recoil from a previous life is
  cleared *before* anything else — this is what makes a mid-holster weapon switch
  re-deployable.
- **`m_flNextAttack`**: the save-value interface is *relative on the server and absolute
  on the client*; writing `0` server-side and `CurTime()` client-side both mean "ready
  now" (comment 42-43; BUGLIST: "Deploy accounts for the server's relative next-attack
  save value"). Naive `SetSaveValue("m_flNextAttack", CurTime())` on the server would
  double the deadline.
- **First-draw selection**: `ACT_VM_READY` (the ready-rack/chambering draw) plays only
  while `!GetReady()` — once per pickup — and never in launcher mode. Afterwards
  `DeployAnimation()` runs; the gun base picks the launcher draw when in launcher mode
  (sh_gun.lua:27-33). `Ready` is never reset except by... nothing in the base — it is a
  once-per-entity flag (holster does not clear it; see BUGLIST "force-ready is
  idempotent").
- **Aim state reset**: `Ironsight=false`, `ActionState=0`, `ActionStart=0`,
  `BurstCount=0`. `SightAmountRaw` is *not* stamped — the blend integrates down over the
  draw (§7.2).
- Returns `true` always (player path) — a false return would make the engine skip the
  switch.

Animation-side detail (timing, hull, bodygroup interplay) → anim §7.1.

### 3.4 `SWEP:Holster(wep)` & the two-phase switch — sh_deploy.lua:81-141

MCV never lets the engine rip the weapon out mid-animation. `Holster` is a two-phase
state machine synchronized by **command numbers**:

**Phase guards** (81-88): NPCs holster immediately (`return true`). In singleplayer the
client returns early (`game.SinglePlayer() and CLIENT`); on a multiplayer client, Holster
runs only for the local player's weapon and only *inside prediction*
(`GetPredictionPlayer() != self:GetOwner() then return true`) — "the engine also calls
Holster clientside outside prediction when applying a weapon switch. It must not start
another delayed switch or mutate restored data" (BUGLIST: "extra client Holster callbacks
cannot restart the switch").

**Decision** (90-97): a reload is cancelled (`SetReloading(false)`); `forced` is true when
the *server* calls Holster outside the owner's prediction (scripted switches); an
in-progress holster that is not yet due returns `false` (keep holding).

**Phase 1 — start the holster** (112-124): play `ACT_VM_HOLSTER` (locked, **noidle** —
the final frame holds), stamp `HolsterTime = CurTime() + t`, compute

```lua
local cmd = self:GetOwner():GetCurrentCommand()
self:SetHolsterCommand(cmd and cmd:CommandNumber() + math.ceil((t or 0) / engine.TickInterval()) or 0)
self:SetHolsterEntity(wep)
self:SetIronsight(false)
self:SetActionState(0)
self:GetOwner():DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM)
return false
```

and fire the third-person put-away gesture (`ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM`).

**The switch itself** rides a global `StartCommand` hook (sh_deploy.lua:128-141):

```lua
hook.Add("StartCommand", "MCV_Holster", function(ply, ucmd)
    local wep = ply:GetActiveWeapon()
    if IsValid(wep) and wep.MilitaryConflictVietnam then
        // StartCommand does not supply the weapon's predicted CurTime. Command
        // numbers, including the command selected here, are identical on both sides.
        local due = wep:GetHolsterCommand()
        if due > 0 and ucmd:CommandNumber() >= due then
            if IsValid(wep:GetHolsterEntity()) then
                ucmd:SelectWeapon(wep:GetHolsterEntity()) -- Call the final holster request
            end
        end
    end
end)
```

When the due command arrives, the hook issues `ucmd:SelectWeapon(target)`, which drives
the *same predicted weapon-switch path* on both realms — client and server switch in
lockstep instead of fighting over `m_hActiveWeapon` (BUGLIST: "delayed selection uses
command numbers... identical on both sides").

**Phase 2 — final holster** (97-111): on the forced call, the due call, or a switch to
`NULL` ("picking up props try to switch to NULL, by the way"): clear the pending-switch
state, `CancelDeferred()`, reset the viewmodel bodygroups
(`vm:SetBodyGroups("000000000000000000")` — note the shorter 18-group string vs the
64-zero one in `SyncViewModel`; both zero every group a model actually has),
`ClientHolster()`, return `true`.

### 3.5 `SWEP:ClientHolster()`, `OnRemove`, dormant lifecycle

- **`ClientHolster`** (sh_deploy.lua:66-79): in singleplayer the server relays it via
  `CallOnClient`; on the client it clears the viewmodel's sub-materials/material
  (`SetSubMaterial()` / `SetMaterial()` — undoes the RT-scope lens swap, §7.5), stops
  particles, and clears `VMLit` (§2.4 lit-particle flag).
- **`OnRemove`** (cl_worldmodel.lua:290-292, CL): removes the drawn world models (§13.2).
  Client-model ownership/collection is hardened separately in `cl_modelgc.lua` (§13.3)
  because `OnRemove` "can be missed during transmission/owner changes".
- **PVS loss** (cl_worldmodel.lua:265-272): `NotifyShouldTransmit(ent, false)` retires the
  world-model copies for the weapon (or its owner) — "never keep an orphaned model at an
  old world position" (BUGLIST "Weapon PVS lifecycle").
- There is **no `OwnerChanged`** on the gun base (only the chainsaw defines one,
  mcv_chainsaw.lua:133); ownership changes are absorbed by `Deploy`/`Holster` state
  hygiene and the model-GC sweep.

### 3.6 The deploy/holster gameplay state machine (summary)

```
spawn ──Initialize──► holstered-in-slot
                        │ engine SelectWeapon
                        ▼
   Deploy: clear pending switch/deferred/recoil ► SyncViewModel(true) ►
   m_flNextAttack ready ► [READY (1st) | DRAW | launcher-draw | hidden] ►
   Ironsight=false, ActionState=0, BurstCount=0 ► OnDeploy()
                        │ player switches / script forces
                        ▼
   Holster phase 1: ACT_VM_HOLSTER (locked,noidle) ► HolsterTime, HolsterCommand(+ticks),
                    HolsterEntity, ironsight down, put-away gesture ── return false
                        │ StartCommand sees due command ► ucmd:SelectWeapon
                        ▼
   Holster phase 2 (next Holster call): clear state ► bodygroups reset ►
   ClientHolster (client materials/particles) ── return true ► engine switches
```

Interrupts at any point: a *forced* (server, non-predicted) Holster skips straight to
phase 2; `Deploy` on the way back clears any half-finished switch (§3.3).

---

## 4. The Think Loops

### 4.1 `SWEP:Think()` — the common skeleton (weapon_common/sh_think.lua:1-26)

```lua
// mcv/weapon_common/sh_think.lua:1-26
function SWEP:Think()
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    // In singleplayer this hook also runs on the client, but the client is NOT predicting
    // there: anything it writes to a NetworkVar is overwritten by the next server update.
    // Advancing the sight/speed blends here would fight the server's state on each packet.
    // Everything the client needs in singleplayer is driven from the server's values via
    // GetViewModelPosition / CalcView, so the client has nothing to do in Think.
    if CLIENT and game.SinglePlayer() then return end

    self:SyncViewModel()
    self:Think_Speed()
    self:Think_HoldType()
    self:Think_Bayonet()

    // Keep the networked viewmodel state in step with what the client draws (see sh_vm.lua).
    self:DoBodygroups(nil, false)

    self:ProcessDeferred()

    if self:GetNextIdle() <= CurTime() then
        self:Idle()
    end

    self:ThinkWeapon()
end
```

**Ordering is the contract** (derived bases rely on it):

1. `SyncViewModel()` — model alias restored *first* so everything after reads the right
   model context (§3.2).
2. `Think_Speed()` — integrate the movement blend (§4.2).
3. `Think_HoldType()` — hold type follows the fresh speed (§4.3).
4. `Think_Bayonet()` — inventory consistency for the fixed blade (§12.4).
5. `DoBodygroups(nil, false)` — server/predicting-client writes of the networked pose
   parameters (why the server must write them: the ghost-viewmodel comment, anim §4).
6. `ProcessDeferred()` — run due deferred actions (§5.3).
7. `Idle()` when `NextIdle` has passed (anim §2.4).
8. `ThinkWeapon()` — the per-base work, always last (§4.4).

Realm rule: **the singleplayer client does nothing here** — it is not predicting, and any
NetworkVar it wrote would be overwritten by the next server update ("advancing the
sight/speed blends here would fight the server's state on each packet"). In multiplayer
the local client runs Think inside prediction for its own weapon. A translated Think that
ignores this rule will visibly jitter in singleplayer.

### 4.2 The speed blend — `Think_Speed` / `GetTargetSpeed` / `GetSpeedVisual`

`Think_Speed` (sh_think.lua:145-152) integrates the `Speed` NetworkVar one tick at a time
toward the target — never a stamped curve:

```lua
function SWEP:Think_Speed()
    local target = self:GetTargetSpeed()
    local cur = self:GetSpeed()
    if cur == target then return end
    self:SetSpeed(math.Approach(cur, target, engine.TickInterval() * self.SpeedAcceleration))
end
```

`GetTargetSpeed()` (sh_think.lua:88-102) is the intent side, built entirely from
*completed-command* movement state (`GetWeaponMovement`, §6.1) and keys:

```lua
function SWEP:GetTargetSpeed()
    local owner = self:GetOwner()
    local _, grounded = self:GetWeaponMovement()
    if !grounded then return 0 end
    if !wantsMove(owner) then return 0 end
    if owner:KeyDown(IN_SPEED) then return self.SpeedSprint
    elseif owner:KeyDown(IN_WALK) then return self.SpeedWalk end
    return self.SpeedRun
end
```

- Airborne → 0 (jump/landing drop the blend; BUGLIST: "Completed speed, ground and crouch
  samples now live in NetworkVars; command numbers select the same prior movement on both
  realms and restore it on replay").
- `wantsMove` (sh_think.lua:28-30) = any of `IN_FORWARD/BACK/MOVELEFT/MOVERIGHT`.
- Targets: `SpeedSprint` 273, `SpeedRun` 100, `SpeedWalk` 25 (sh_think.lua:39-41);
  acceleration `SpeedAcceleration` 750 units/s of blend per second (line 43).

The integrating-not-stamping rationale (comment block, sh_think.lua:104-110): a stamped
start-time/start-value curve turns any disagreement about *when* into a step; an
integrated amount heals in one tick of travel on prediction error.

**Client visual copy** — `GetSpeedVisual` (CL, sh_think.lua:112-143): outside prediction,
`VisualSpeed` chases the networked `Speed` at a bounded rate
(`VisualSpeedCatchUp = 0.08`, line 116) — "at least as fast as the blend itself... fast
enough to close any gap within CatchUp seconds so a correction is absorbed over a few
frames". Cached per frame (`VisualSpeedFrame`). On the server `GetSpeedVisual` is
literally `GetSpeed` (line 142). Consumers: `DoBodygroups(visual)` (anim §4),
`RifleGrenadeAttack`'s speed gate uses the *networked* `GetSpeed` (sh_ubgl.lua:55).

`GetIsSprinting()` (sh_think.lua:32-36) is the *input* predicate (moving + `IN_SPEED`) —
distinct from the blended `Speed` used for hold types.

### 4.3 Hold types — `Think_HoldType` (sh_think.lua:154-179)

Priority ladder, evaluated every tick:

| Priority | Condition | Hold type |
|---|---|---|
| 1 | `GetSpeed() >= SpeedSprintThreshold` (150) | `SprintHoldType` ("passive") |
| 2 | `GetAkimbo()` | `"duel"` |
| 3 | `GetBipod()` | `"rpg"` |
| 4 | `GetSightAmount() >= 1` | `AimHoldType` ("rpg") |
| else | — | `HoldType` ("ar2") |
| override | `GetSafe()` (at-ease) | `SprintHoldType` |

`SetHoldType` is called **only on change** (176-178), and the current value is *asked from
the weapon* (`self:GetHoldType()`) rather than memoized in a plain field — "a field is
never put back, so it would claim to have set a hold type the server had since replaced"
(prediction self-healing). Networked hold type also drives the gesture tables (§2.1b) and
the player model's aim layers.

### 4.4 `SWEP:ThinkWeapon()` — the gun's per-tick work (mcv_base/sh_think.lua:49-140)

Called last from common `Think`. Order within:

```lua
// weapons/mcv_base/sh_think.lua:49-58
function SWEP:ThinkWeapon()
    local owner = self:GetOwner()
    self:Think_HammerRelease()
    self:Think_Sights()
    self:Think_Reload()
    self:Think_Bipod()
    self:Think_BayonetCharge()
    self:Think_WorldBodygroups()
    ...
```

1. **`Think_HammerRelease`** (sh_shoot.lua:217-223, → anim §5.6) — clears
   `NeedCycle`/`EmptyReload` when the compiled model's own hammer event says so.
2. **`Think_Sights`** (§7.1) — aim intent → state → blend integration.
3. **`Think_Reload`** (→ reload doc; anim §7.6) — reload stage machine.
4. **`Think_Bipod`** (§8.2).
5. **`Think_BayonetCharge`** (§11.2).
6. **`Think_WorldBodygroups`** (§4.5).

Then the trigger-driven state (59-105):

- **Runaway burst** (60-67): while `IsBursting()` and not `StillWaiting()`, keep calling
  `PrimaryAttack()` until clip or burst runs out ("the remaining rounds go out on their
  own, trigger or not"). `BurstRounds`/`BurstRecovery` semantics are documented at
  mcv_base/shared.lua:46-50; fire timing → shooting doc.
- **Trigger release** (69-79): clears `NeedTriggerPress`; resets `BurstCount` when no
  burst is in progress; if a double-action `PrimedAttack` was held, cancels it back to
  the idle activity (`PlayAnimation(self:IdleActivity())`).
- **Shotgun reload cancel** (80-84): pressing attack mid shell-insert ends the reload
  *only if ammo was actually added* — `LastClip` is "the predicted clip count captured
  when this reload began. Existing shells must not let a top-up skip its first insert".
- **UBGL toggle input** (86-88): `KeyPressed(IN_USE) and KeyDown(IN_WALK)` →
  `ToggleUBGL()` (§10.1). Note the key *pattern* differs from the safety toggle below —
  USE pressed while WALK held, vs WALK pressed while USE held.
- **Double-action release fire** (90-105): with `PrimedAttack` and the trigger still down
  past `TriggerDelayTime`, the shot goes off here (not in `PrimaryAttack`) —
  `AttackEffects()` + `BulletAttack`/`RocketAttack`, then the DA shot animation
  (`ACT_VM_PRIMARYATTACK_2`, or `_3` on akimbo even-count, at rate 0.5). Gated
  `SERVER or !game.SinglePlayer()` (singleplayer client is not predicting, §4.1).
- **Bolt/pump cycle** (107-132) — see §4.6.
- **Safety toggle input** (136-138): `KeyDown(IN_USE) and KeyPressed(IN_WALK)` →
  `ToggleSafe()` (§7/anim §7.7).
- **`Think_AutoReload`** (139) — client-preference auto reload on empty (→ reload doc;
  BUGLIST "Automatic reload preference... Skips reload, safety, holster, primed attacks
  and bayonet charge").

### 4.5 World-model bodygroups — `Think_WorldBodygroups` (mcv_base/sh_think.lua:8-48)

Cross-ref anim §4.5. Gameplay summary: the **weapon entity's** bodygroups (not the
viewmodel's) are updated every tick so the dropped weapon and the bone-merged player
copies (§13.2) show the same parts. Bodygroup indices are looked up *by name* once per
model and cached on the entity (`MCVWorldBodygroups`, keyed by `self:GetModel()`):

```lua
groups = {
    bayonet = self:FindBodygroupByName("bayonet"),
    grenade = self:FindBodygroupByName("grenade"),
    bipod   = self:FindBodygroupByName("bipod"),
    belt    = self:FindBodygroupByName("belt"),
}
```

- `bayonet` group → 1 when `GetBayonet()` (only if `HasBayonet`).
- `grenade` group → 1 when `GetGrenadeLauncher()` (only if `HasRifleGrenade`).
- `bipod` group → 1 when `GetBipod()` ("option 1 is the deployed one on every game
  model").
- `belt` group → 1 (blank) when `Clip1() <= 0` — the long belt "goes away with the last
  round".

"Bodygroups are engine predicted fields, so update both realms" — the write is gated by
`GetBodygroup(b) != want` to avoid network churn (and the cache is why — BUGLIST —
"Cached world bodygroup indices by model").

### 4.6 The bolt/pump cycle gate (mcv_base/sh_think.lua:107-132)

The gameplay half of anim §7.5 — a `PlayCycleAnimation` weapon must be re-worked between
shots, and the *state*, not the animation, is what enforces it:

```lua
// weapons/mcv_base/sh_think.lua:112-131
if !self:StillWaiting() and (!owner:KeyDown(IN_ATTACK) or self.SlamFire) and self:GetNeedCycle() then
    local t = self:PlayAnimation(ACT_VM_RELOAD_INSERT_PULL, 1, false)
    self:EmitThirdPersonSound(self.SoundCycleThirdPerson)
    if t then
        self:SetNextPrimaryFire(CurTime() + t * self.CyclePostDelay)
        // networked so both realms show the same rounds through the cycle
        // (CycleClipPoseTime); guns have no other use for ActionStart
        self:SetActionStart(CurTime())
    end
    if t == nil or !self.AnimationHandlesHammer then
        self:SetNeedCycle(false)
    end
end
```

- The cycle waits for **trigger release** (except `SlamFire` shotguns: "pump with the
  trigger held and fire the moment the action closes").
- `NeedCycle` blocks the next shot (`PrimaryAttack` early-out, sh_shoot.lua:10) until
  cleared — by the model's own hammer event (`AnimationHandlesHammer`, anim §5.6) or
  immediately when the model doesn't handle it or lacks the animation (`t == nil`).
- `CyclePostDelay` (default 0.65, mcv_base/shared.lua:131) scales the *post-cycle* fire
  lockout relative to the animation's own duration.
- A dual model may have no separate cycle animation (the dual Type 67 works its bolts
  inside the shot animations): the state machine still runs; only the animation is absent
  (comment 113-118).
- The deliberate `// No IsFirstTimePredicted gate here` comment (109-111): "everything
  below is state, and state left out of the commands the client re-simulates is state the
  client and the server stop agreeing on."

---

## 5. Clock & Timers

### 5.1 The clock problem — `sh_clock.lua:1-27`

Map transitions and Source saves can retain weapons while replacing the clock, leaving
`CurTime`-relative deadlines in the datatable pointing into the past or future. Two reset
functions:

- **`SWEP:ResetClockVisuals()`** (sh_clock.lua:3-27, SH but client-effect only): nils every
  ordinary-Lua visual cache — `VisualAnimation`, the HUD crosshair/bob caches, 
  `VisualSpeed`, `VisualSightRaw`, `VisualStance`, `VisualSteady`, `SmoothedMagnification`
  (reset to 1), `MuzzleLightEnd`, `NextTankCheck` — and stops a live flame effect. These
  are the *client* half-lives that a server clock reset would otherwise leave stale.
- **`SWEP:ResetWeaponClock()`** (sh_clock.lua:29-79, SV-only past line 31): the full
  pending-action clear — deferred actions cancelled; `NextPrimaryFire`/`NextSecondaryFire`
  = now; `AnimLockTime=0`; `NextIdle=now`; `AnimationStart=now`, `AnimationDuration=0`;
  recoil/shot clocks pushed 60 s into the past; holster switch state cleared; the whole
  action/charge/reload state machine reset (`Reloading`, `EmptyReload` recomputed from
  `Clip1()`, `BurstCount`, `PrimedAttack`, `NeedTriggerPress`, `Ironsight`, `Sighted`,
  `SightAmountRaw=0`, movement samples zeroed); loop sounds stopped; and finally
  `ClockResetSerial` incremented (which notifies the client, §2.3) and, if the weapon is
  active, `m_flNextAttack` zeroed through the relative server save-value interface.

What it deliberately does **not** touch: ammunition, the selected firemode/scope level
(their zero-init re-seed in `SetupDataTables` preserves them, §2.3), `Ready`, `Bayonet`,
`GrenadeLauncher`, `Akimbo` — inventory and mode state survive the reset.

### 5.2 Reset triggers & the rollback watchdog — sh_clock.lua:81-107

| Trigger | Hook | Scope |
|---|---|---|
| Source save restore | `SWEP:OnRestore` (81-83) | that weapon |
| Entity (re)creation after load | `InitPostEntity` (90) | **every** MCV entity (`resetAll`, 85-89) |
| Player spawn from a level transition | `PlayerSpawn` with `transition` (93-98, SV) | the player's weapons |
| Server clock rollback | global `Think` watchdog (101-106, SV) | every MCV entity |

The watchdog samples only the *global server* `CurTime`; a backwards jump of more than two
tick intervals (`now < previous - engine.TickInterval()*2`) triggers `resetAll()`. The
comment is explicit that **predicted SWEP CurTime must never trigger it** — inside
prediction `CurTime` moves backwards routinely during command replay.

BUGLIST ties this to the fix that introduced it: "Retained weapons clear stale CurTime
deadlines and unfinished actions at map/restore boundaries. The reset runs outside
prediction replay and preserves ammunition."

### 5.3 Deferred actions — `mcv/weapon_common/sh_timers.lua`

The prediction-safe replacement for `timer.Simple` (design rationale in the file header,
sh_timers.lua:1-16; anim §3.5). API:

- **`SWEP.DeferredActions`** — fixed-order class list of action names. The gun base's list
  (mcv_base/shared.lua:151-153) with a hard contract comment: *"The order is what travels
  between the realms, so it is fixed: append, never insert."*

  ```lua
  SWEP.DeferredActions = {"BayonetOff", "AkimboSwap", "LauncherSwap", "BayonetLoop", "BayonetHit", "ReloadInsert"}
  ```

- **`SWEP:Defer(name, delay)`** (19-33) — looks up the index (unknown name = silent
  no-op) and stamps `DeferredAction = id`, `DeferredTime = CurTime() + delay`. One action
  pending at a time.
- **`SWEP:DeferPending(name)`** (35-39) — query, with optional name match (used by the
  clip-pose logic, anim §4.4).
- **`SWEP:CancelDeferred()`** (41-44) — zero both slots.
- **`SWEP:ProcessDeferred()`** (46-57) — runs from `Think` (§4.1); when due, cancels first
  (so the handler may re-queue), then calls `self["Deferred_" .. name]`.

Gun-core users (all in this audit's scope):

| Action | Queued by | Handler | Purpose |
|---|---|---|---|
| `BayonetOff` | `ToggleBayonet` (sh_bash.lua:148) | `Deferred_BayonetOff` (sh_bash.lua:132-134) | blade bodygroup off at end of detach anim |
| `AkimboSwap` | `ToggleAkimbo` (sh_akimbo.lua:20) | `Deferred_AkimboSwap` (sh_akimbo.lua:24-54) | mid-holster dual swap (§9.2) |
| `LauncherSwap` | `ToggleUBGL` (sh_ubgl.lua:38) | `Deferred_LauncherSwap` (sh_ubgl.lua:3-18) | mid-holster launcher swap (§10.2) |
| `BayonetLoop` | `StartBayonetCharge` (sh_bayonet_charge.lua:48) | `Deferred_BayonetLoop` (118-122) | charge loop pose (§11) |
| `BayonetHit` | `BayonetChargeAttack` (sh_bayonet_charge.lua:65) | `Deferred_BayonetHit` (124-126) | thrust damage timing (§11.3) |
| `ReloadInsert` | reload stages (→ reload doc) | `Deferred_ReloadInsert` | round-in-gun transfer |

Cancellation points: `Deploy` (sh_deploy.lua:35), final `Holster` (103) and start-Holster
(113), `ResetWeaponClock` (sh_clock.lua:33), `EndBayonetCharge`
(sh_bayonet_charge.lua:75).

### 5.4 Non-animation clock consumers

Beyond the animation timeline (anim §3), the same clocks gate gameplay: `AnimLockTime`
via `StillWaiting` everywhere; `LastRecoilTime + ShakeDuration` drives the camera roll
shake (§13.1); `LastShotTimeR/L` scrub akimbo pose recoil (anim §4.1); `ActionStart`/
`ActionEnd` carry the charge state machine (§11). All are networked floats so a rollback
restores them exactly.

---

## 6. Movement — `mcv/weapon_common/sh_movement.lua`

### 6.1 The movement-sample pipeline

The problem (comment, sh_movement.lua:29-31): *"Weapon Think runs before movement on the
client and afterwards on the server; both must read command N-1. A plain Lua 'last
velocity' survives rollback and instead supplies a future value."* MCV stores completed
movement in NetworkVars:

- **`SWEP:CaptureMovement(command, speed, grounded, crouched)`** (32-42) — on a new
  command number, first rotates the current sample into the `Last*` slots
  (`LastMoveSpeed`, `LastMoveGrounded`, `LastMoveCrouched`), then stores the new sample.
- **`SWEP:GetWeaponMovement()`** (44-56) — returns `speed, grounded, crouched`. NPCs (no
  player commands) and pre-datatable weapons (Lua auto-refresh survival) fall back to live
  `owner:GetVelocity():Length() / IsOnGround() / Crouching()`. For players: if the
  *current* command is the sampled one (`cmd:CommandNumber() == GetMoveCommand()`), the
  `Last*` slots are the answer (the current sample is mid-simulation); otherwise the
  completed sample.
- **`FinishMove` hook** (58-65, SH, prediction-gated): after the engine finishes a
  command, `CaptureMovement(cmd:CommandNumber(), mv:GetVelocity():Length(),
  ply:IsOnGround(), ply:Crouching())`.

Consumers: `GetTargetSpeed` (§4.2 — airborne drops the blend), spread stance multipliers
(`CrouchMoveSpreadMultiplier` etc., → shooting doc), jump spread, and the
`MoveCrouched`/`MoveGrounded` bools feeding stance visual caches.

### 6.2 Recoil impulse queue — velocity kick on the shared movement phase

```lua
// mcv/weapon_common/sh_movement.lua:4-27
function SWEP:QueueRecoilImpulse(amount)
    local owner = self:GetOwner()
    local cmd = owner:IsPlayer() and GetPredictionPlayer() == owner and owner:GetCurrentCommand()
    // View punch has native prediction tolerances. Feeding it into a strict Vector
    // NetworkVar turns harmless camera differences into movement prediction errors.
    local direction = cmd and cmd:GetViewAngles():Forward() or self:GetAimVector()
    local impulse = direction * -amount
    if !cmd then
        if SERVER then owner:SetVelocity(impulse) end // NPC / non-predicted caller
        return
    end
    self:SetRecoilImpulse(self:GetRecoilImpulse() + impulse)
    self:SetRecoilCommand(cmd:CommandNumber())
end

hook.Add("SetupMove", "MCV_RecoilImpulse", function(ply, mv, cmd)
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam then return end
    local impulse = wep:GetRecoilImpulse()
    if impulse:IsZero() or cmd:CommandNumber() <= wep:GetRecoilCommand() then return end
    mv:SetVelocity(mv:GetVelocity() + impulse)
    wep:SetRecoilImpulse(vector_origin)
    wep:SetRecoilCommand(0)
end)
```

Firing queues a backwards impulse tagged with the firing command; a global `SetupMove`
applies it **on the next command's movement phase**, identically on both realms (BUGLIST:
"Weapon recoil changed player velocity at different movement phases on the client and
server. It now queues an impulse for the next command's shared movement phase, using that
input's aim direction so tiny camera corrections do not become movement errors"). Note
the direction subtlety: while predicting, the *command's* view angles are used (not
`GetAimVector`'s punch-augmented angle) because "view punch has native prediction
tolerances" that a strict Vector NetworkVar would turn into prediction errors.

Gun-base callers: `AttackEffects` (sh_shoot.lua — the per-shot `RecoilPushbackValue`
kick) and `RifleGrenadeAttack` (sh_ubgl.lua:70).

### 6.3 Speed → pose

`GetMovementPose(speed, sa)` (sh_think.lua:63-86) maps the blend into the models'
`player_movement` units, with the safe-movement clamp (`GetSafe()` → pose capped at 86
unless the model is in `MCV.SafeMovementModels`, sh_safe_movement.lua, or opts in via
`SafeMovementAnimations`). Fully documented in anim §4.2 — the gameplay inputs are
`Speed`/`SpeedVisual` from §4.2 and the sight amount from §7.2.

### 6.4 Sprint / walk / crouch / jump effects on weapon state (summary table)

| Movement input | Effect on gun runtime |
|---|---|
| Sprint (`IN_SPEED` + move) | `Speed` → 273 → `SprintHoldType`; `Sighted` drops (§7.1); `PrimaryAttack` speed-gated off (`GetSpeed() > 150`, sh_shoot.lua:48); **sprint + trigger with bayonet = charge** (sh_shoot.lua:31-34, §11) |
| Walk (`IN_WALK`) | `Speed` → 25 (reduced pose); WALK+USE toggles UBGL/akimbo (§4.4); USE-then-WALK toggles safety |
| Crouch | `MoveCrouched` sample → `CrouchSpreadMultiplier` (shooting doc); crouched visual stance caches |
| Jump/airborne | `grounded == false` → `Speed → 0` (blend drops); `JumpSpreadMultiplier`; bipod folds (§8.2) |
| Moving while bipodded | any move key (incl. `IN_JUMP`) folds the bipod (sh_bipod.lua:48-50) |

---

## 7. Sights & Optics

### 7.1 Intent vs state vs blend — `Think_Sights` (mcv_base/sh_sights.lua:101-147)

Aiming on MCV is **Think-driven, not SecondaryAttack-driven**. The engine's
`SecondaryAttack` on the gun base is only the bayonet toggle (sh_gun.lua:74-80); aim
input is sampled in `Think_Sights` so it can be resolved against weapon state every tick:

```lua
// weapons/mcv_base/sh_sights.lua:101-134 (excerpt)
function SWEP:Think_Sights()
    local owner = self:GetOwner()
    // Shot cooldowns must not swallow aim input during automatic fire. Only locked
    // actions block entry here; ScopeToggle also checks reload and bipod requirements.
    local aimUnlocked = self:GetAnimLockTime() <= CurTime()

    // Ironsight is already a predicted NetworkVar: replay the press against its restored
    // value, never a plain Lua latch or an IsFirstTimePredicted-only state change.
    if self:GetSafe() then
        if self:GetIronsight() then self:ScopeToggle(false) end
    elseif self:UsesToggleAim() then
        if owner:KeyPressed(IN_ATTACK2) and !owner:KeyDown(IN_USE) then
            if self:GetIronsight() then
                self:ScopeToggle(false)
            elseif aimUnlocked then
                self:ScopeToggle(true)
            end
        end
    elseif owner:KeyDown(IN_ATTACK2) then
        if !self:GetIronsight() and !owner:KeyDown(IN_USE) and aimUnlocked then
            self:ScopeToggle(true)
        end
    elseif self:GetIronsight() then
        self:ScopeToggle(false)
    end

    local sighted = self:GetIronsight() and !self:GetIsSprinting() and (!self.MustBipod or self:GetBipod())

    if sighted != self:GetSighted() then
        self:SetSighted(sighted)
        self:EmitSound(sighted and "MCV_Weapon_Foley_Ironsights.In" or "MCV_Weapon_Foley_Ironsights.Out")
    end
    ...
```

- **Aim entry checks the animation lock, not `StillWaiting`** — BUGLIST: "Toggle aim
  could exit but not enter ADS during automatic fire: aim entry now checks the animation
  lock instead of StillWaiting's shot cooldown, for both toggle and hold modes."
- **`UsesToggleAim()`** (96-99) reads the per-player client convar `mcv_toggle_aim`
  (cl_controls.lua:2, archived userinfo) — toggle mode uses `KeyPressed(IN_ATTACK2)`;
  hold mode uses `KeyDown`.
- **`IN_USE` guard**: attack2+USE belongs to the bayonet toggle (§12.4), so it never aims.
- **`Sighted`** (the resolved state) = `Ironsight and not sprinting and (bipod ok)`. The
  ironsight foley plays on transitions only.
- **`ScopeToggle(on)`** (85-94) sets the *intent* with its own gates: `self.Ironsight`
  flag (a weapon *feature* flag, mcv_base/shared.lua:101 — guns that cannot aim reject
  entry), reloading blocks entry, `MustBipod` weapons (PTRD) cannot aim undeployed.

The blend integration (136-146):

```lua
    // Advance the blend by exactly one tick toward the target, the same step on both realms.
    local target = sighted and 1 or 0
    local cur = self:GetSightAmountRaw()
    if cur != target then
        self:SetSightAmountRaw(math.Approach(cur, target, engine.TickInterval() / self:GetSightTime()))
    end
```

`GetSightTime()` (2-4) = `0.2 / IronsightSpeedScale` (default 0.85 → ~0.235 s). Same
integrating-not-stamping design as `Speed` (§4.2), with the same healing property.

### 7.2 Raw / eased / visual getters

- **`GetSightAmount()`** (36-38, SH) — `applyEase(GetSightAmountRaw())`: the *gameplay*
  value (spread, recoil, hold type ladder §4.3). `applyEase` (27-32) is exact 0/1 at the
  ends; the ease is `SightEase = "InOutSine"` (line 8) resolved by `GetSightEase`
  (14-21): any `[0,1]→[0,1]` function, or a `math.ease` library name, or a `smoothstep`
  fallback.
- **`GetSightAmountRawVisual()` / `GetSightAmountVisual()`** (CL, 48-77) — a per-frame
  visual copy chasing the networked raw at `VisualSightCatchUp = 0.08` (line 46),
  frame-cached (`VisualSightFrame`), never advanced inside prediction ("GetViewModelPosition
  also runs while simulating commands. Never let an earlier command consume this rendered
  frame's visual update" — BUGLIST: "Predicted GetViewModelPosition calls consumed the
  render frame's aim cache using an earlier command and a tick's time"). Server aliases
  both to the gameplay getters (79-80).

Consumers: viewmodel offset blend & `ironsight` pose param (anim §4.3), viewmodel FOV
(§7.8), camera zoom & sensitivity (§13.1), RT scope activation threshold (§7.5), HUD.

### 7.3 The zoom model

Three nested FOV concepts (all defined on the gun base):

- **`IronsightFov`** (default `90-15` = 75): the world FOV divisor while aiming a
  non-scoped weapon.
- **`ScopeFOV` / `ScopeFOV2`** (defaults 8 / 4): the lens FOV at scope level 1 / 2;
  `GetScopeFOV()` (cl_pipscope.lua:33-38) selects by `GetScopeLevel()` (the
  `AdjustableScopes` step cycled via `ACT_VM_FIDGET`, anim §7.9).
- **`GetScopeWorldFov()`** (sh_gun.lua:41-45): the *screen* FOV while aiming:

  ```lua
  function SWEP:GetScopeWorldFov()
      if CLIENT and !self.HasScope and MCV.IronsightNoZoom() then return 90 end
      if !self.HasScope or self.OEGScope then return self.IronsightFov end
      return math.Clamp(self:GetScopeFOV() * self.ScopeScreenZoom, 30, self.IronsightFov)
  end
  ```

  With a real scope the screen zooms part-way (`ScopeScreenZoom` = 2, line 39) so the
  lens shader gets more pixels; "the rest of the magnification happens in the lens"
  (§7.5). `mcv_ironsight_nozoom` (client preference) removes iron-sight zoom entirely
  with matching sensitivity (BUGLIST).
- **`GetZoomMagnification()`** (47-49) returns `GetScopeWorldFov()` — the common-layer
  hook the camera divides by (§13.1).
- **`GetLookMagnification()`** (52-58): the magnification the *player looks through* —
  `90 / ScopeFOV` for scoped non-OEG, `90 / IronsightFov` otherwise — used by
  `AdjustMouseSensitivity` (§13.1). Note the gun base **overrides** the common
  `GetLookMagnification` (weapon_common/cl_camera.lua:44-46 defines a simpler version
  that the equipment bases use).

### 7.4 Sensitivity

`SWEP:AdjustMouseSensitivity()` (cl_camera.lua:48-51): `1 / Lerp(sight^3, 1,
GetLookMagnification())` — sensitivity scales down exactly with the visual aim blend. A
translation layer that changes zoom must keep these two consistent or the aim feels
wrong.

### 7.5 The RT scope — `weapons/mcv_base/cl_pipscope.lua` (CL)

The scope picture is **screen reprojection inside the lens material's shader**, not a
second world render. While aiming, the lens sub-material is swapped for
`materials/mcv/scope_lens.vmt` (pixel shader `work/shaders/mcv_scope_ps3x.hlsl`), which
samples the frame captured *before* the viewmodel was drawn and magnifies it around the
scope axis point.

Constants pushed into the shared lens material by **`ApplyScopeMaterial`** (76-99):
`$c0_x` = `GetScopeFOV() / GetScopeWorldFov()` (lens magnification), `$c3_w`
`ScopeLensSize` 0.75, shadow size/strength/softness (`$c0_z/$c0_w/$c1_w`,
`ScopeShadowStrength` 1 / `ScopeShadowSize` 0.84 / `ScopeShadowSoftness` 0.1), distortion
`ScopeDistortion` −0.12, aberration `ScopeAberration` 0.006, edge blur `ScopeEdgeBlur`
0.005, brightness, aspect (`$c2_z`), OEG additive-reticle flag (`$c2_x`), and the reticle
texture — read *off* `ScopeMaterial` via `reticleTexture` (67-72) because the game's
`crosshair_*` VMTs are Refract lens shaders, so the texture (`$refracttinttexture`,
falling back to `$basetexture`) is extracted rather than the material drawn.

- **`ShouldDoScope()`** (45-47): `GetIronsight() and HasScope` — intent, not blend.
- **`DoRTScope()`** (136-165, runs from `PreDrawViewModelWeapon`, sh_vm.lua:250-257):
  activation threshold `GetSightAmountVisual() > 0.5`; swaps
  `model:SetSubMaterial(self.RTScopeMaterialIndex, ...)`; forces
  `render.OverrideDepthEnable(true, true)` ("screenspace_general leaves the depth state
  to chance on a model: on the SVD the scope body, drawn after the lens, painted over
  it"); resets to `ScopeIdleLensMaterial` (or the model's own glass) when not aiming.
  `RTScopeMaterialIndex` (default 1) is the lens sub-material slot, per model
  (vz54s: 8).
- **`UpdateScopeAxis(vm)`** (120-133): the screen point the shader magnifies around —
  `GetAimVector()` (eye angles + view punch, §2.5) projected 4096 units ahead, clamped,
  NaN-guarded to screen center. "The reticle sits where the shot goes... the point moves
  across the lens with each kick and settles as the punch decays."
- **`CaptureScopeScreen()`** (104-113): copies the frame into a private RT
  (`mcv_scope_scene`) — called from the `PreDrawViewModels` hook in cl_rendertarget.lua
  (§7.7). Threshold `> 0.5` and `ShouldDoScope()`.
- **OEG**: `HideOEGGlow` (53-62) finds the model's `lens_singlepoint_glow` material by
  name and blanks it (the shader draws the dot instead); the see-through composite is the
  OEG path in sh_vm.lua (anim §9.5).
- `DoCheapScope` / `RenderScopeView` (168-169) are kept as empty stubs "for callers of
  the old screen-copy path" — API compatibility.

BUGLIST: "Pack is still dependent on ARC9/ArcCW/TacRP for muzzleflashes. ARC9 dependency
for RT scope textures", plus the gShader capture-order saga (§7.7).

### 7.6 Scope overlay preservation — `mcv/client/cl_scopeoverlay.lua` (CL)

The lens pixels must survive screen-space post effects without removing the gun from
their depth buffers. Mechanism (BUGLIST: "a managed bone-merged model that builds a
private lens stencil inside the real VM pass, then fills alpha and restores saved lens
pixels outside that pass at PreDrawHUD"):

- **`MCV.CaptureScopeOverlay(wep, vm)`** (20-101) — called from `PostDrawViewModel` while
  the scope camera is still open (sh_vm.lua:152). Creates/updates a bone-merged
  `ClientsideModel` proxy of the viewmodel (parented to the VM so its bones are valid),
  draws it twice into a private stencil/depth RT (`mcv_scope_overlay_masked`): once with
  color/alpha writes off (depth mask), once with `STENCIL_ALWAYS` replace (lens stencil).
  Translucent sub-materials are overridden to a hidden material so the OEG's glass does
  not become an opaque occluder. "Keep the original shaders: a generic depth material
  changes software skinning on the lens and can cut a diamond out of the mask."
- **`MCV.CaptureScopeOverlayPixels(wep)`** (103-110) — called at `PostDrawViewModel`
  tail (sh_vm.lua:202): copies the *finished* frame (with OEG composite and muzzle
  particles) into `mcv_scope_overlay_pixels`.
- **`PreDrawHUD` hook `MCV_ScopeAbovePostprocessing`** (112-147): same-frame check
  (frame/weapon/render-target all matching, weapon still active, first-person, scope on);
  fills the stencil region with opaque white *outside* the engine viewmodel pass
  ("alpha writes during that pass left the entire lens layer transparent in the live
  renderer"), draws the saved pixel scene into it, then composites the whole layer over
  the screen. Result: post-processing never smears the lens, but the gun still
  participates in depth-based effects.

### 7.7 Frame capture & viewmodel bounds — `mcv/client/cl_rendertarget.lua` (CL)

- **`MCV_CaptureScopeScreen`** on `PreDrawViewModels` (28-30 → `captureScope` 3-14):
  captures after world translucency/effects, immediately before viewmodels — "capturing
  before gShader reconstruction loses particles and translucent objects from the lens".
  Guarded against non-main views (`view.id` 0/4 only) and non-MCV weapons.
- **Migration shim** (18-26): removes the obsolete `PreDrawEffects` capture wrapper whose
  hook order "overwrites the clean world image with the gun and scope itself".
- **`MCV_ViewModelBounds`** (41-48): every frame widens the local viewmodel's render
  bounds to ±96³ — "a box that ends at eye height (the molotov's...) had the whole
  viewmodel culled: nothing drawn, and none of the weapon's PreDrawViewModel hooks run
  for a culled viewmodel".

### 7.8 Client view settings — `mcv/client/cl_viewsettings.lua` (CL)

Six client convars (all archived, in the Q menu per AGENTS.md): hip/sighted viewmodel FOV
offsets (±25°), `mcv_ironsight_nozoom`, and three hip-position sliders (±10 units each).

- **`MCV.ViewmodelPositionOffset(aim)`** (14-19) — the sliders, faded out by the aim
  blend (`1 - aim`), applied to the hip position in `GetViewModelPosition` (anim §9.4);
  "preserving tuned aimed positions" (BUGLIST).
- **`MCV.ViewmodelFOV(weapon, amount)`** (21-25) — `Lerp(amount, ViewModelFOV + hip,
  SightedViewModelFOV + sight)` with clamps; used by `PreDrawViewModel`'s custom camera
  and the recoil reprojection.
- **`MCV.ViewmodelRecoilProjection(pitch, yaw, viewFOV, worldFOV, riseScale)`**
  (34-45) — projects a camera-relative kick from world FOV into viewmodel FOV preserving
  *screen coordinates* (tan-ratio), pitch/yaw coupled (BUGLIST: "including diagonal
  recoil"), optional vertical rise scale (1.5 — the aimed muzzle-rise boost, BUGLIST:
  "Increased aimed camera-relative visual muzzle rise by 50% in screen space after FOV
  compensation"). Called from `GetViewModelPosition` using the camera recorded by
  `CalcView` this frame (§13.1, anim §9.4).

### 7.9 Sight data tables weapons define

From `weapons/mcv_vz54s.lua` (scoped, adjustable) and `weapons/mcv_pm.lua` (akimbo), the
complete optics-relevant definition surface:

| Field | Example | Meaning |
|---|---|---|
| `Ironsight` | `true` | weapon can aim at all (gate in `ScopeToggle`) |
| `IronsightSpeedScale` | `0.85` | transition speed (§7.1) |
| `IronsightFov` | `90-15` | screen divisor while aiming (§7.3) |
| `IronsightPos` / `IronsightAng` | `Vector(0,-3.1,-0.21)` | aimed viewmodel offset |
| `CustomPos` / `CustomAng` | `Vector(0,-2,0)` | hip viewmodel offset |
| `HasScope` | `true` | RT-scope weapon |
| `ScopeMaterial` | `Material(".../crosshair_meopta256")` | reticle source (texture extracted, §7.5) |
| `ScopeFOV` / `ScopeFOV2` | `36.8` / `23.5` | lens FOV at level 1/2 |
| `RTScopeMaterialIndex` | `8` | lens sub-material slot on the viewmodel |
| `ScopeIdleLensMaterial` | `".../lens_meopta"` | non-aiming lens override (vz54s: its lens mesh wears the reticle) |
| `AdjustableScopes` | `true` | level toggle via USE+RELOAD (anim §7.9) |
| `OEGScope` | `true` (XM177) | occluded-eye variant (§7.5, anim §9.5) |
| `IronsightPosAkimbo` / `IronsightAngAkimbo` | `Vector(0,-6,0)` | dual-specific aim offset (BUGLIST: 11 guns) |
| `IronsightPosLauncher` / `IronsightAngLauncher` | — | launcher ladder aim offset |
| `ViewModelZNear` | number | near-plane override (scoped eyepieces) |
| `IronsightWalkBobbingStrength` | `-0.25` | walk bob while aimed |
| Scope look constants | `ScopeLensSize` etc. | §7.5 defaults are per-class |

### 7.10 BUGLIST items for sights/optics (context)

- Rifle-grenade ADS used the rifle's irons at idle then jumped to the ladder for the shot
  → `IdleActivity` now selects `ACT_VM_IDLE_M203` for rifle grenades (BUGLIST Sep 13
  2026; sh_gun.lua:16-19).
- M203/XM148/GP-25 launcher mode was always sighted — a blendlayer with start == end
  plays at full weight; recompiled as ironsight blend rows (BUGLIST; 28 models).
- Fire-mode changes are blocked while the launcher is active (BUGLIST; enforced in
  `ChangeFiremode`, → shooting doc).
- Contact-shadows-over-scopes saga → the §7.6 stencil pipeline
  (`work/GSHADER_COMPATIBILITY.md`).

---

## 8. Bipod — `weapons/mcv_base/sh_bipod.lua`

### 8.1 `SWEP:CanBipod()` — deployment traces (sh_bipod.lua:1-29)

Two traces from the eye position, `MASK_PLAYERSOLID`, owner-filtered:

1. **Clearance line** 64 units forward (`TraceLine`): any hit → cannot deploy (there is
   something in your face).
2. **Surface hull** 24 units forward, hull `Vector(-1,-1,-48)`→`Vector(1,1,1)`
   (`TraceHull`): a hit means a chest-height surface ahead (window sill, sandbag, ground
   when prone).

Deployable = clear line + surface hit.

### 8.2 `SWEP:Think_Bipod()` — the state machine (sh_bipod.lua:31-55)

```lua
function SWEP:Think_Bipod()
    if !self.HasBipod then return end
    if self:StillWaiting() then return end
    local owner = self:GetOwner()
    if !self:GetBipod() then
        // Use + Walk belongs to safety / launcher controls, not bipod deployment.
        if owner:KeyPressed(IN_USE) and !owner:KeyDown(IN_WALK) and self:CanBipod() then
            // Replay both NetworkVars together. Do not play the safety exit
            // animation: the deployment animation takes the weapon into position.
            self:SetSafe(false)
            self:PlayAnimation(ACT_VM_DEPLOYED_IN, 1, true)
            self:SetBipod(true)
        end
    else
        // moving (or jumping) folds it, as does losing the surface
        local moving = owner:KeyDown(IN_FORWARD) or owner:KeyDown(IN_BACK) or owner:KeyDown(IN_MOVELEFT)
            or owner:KeyDown(IN_MOVERIGHT) or owner:KeyDown(IN_JUMP)
        if moving or !self:CanBipod() then
            self:PlayAnimation(ACT_VM_DEPLOYED_OUT, 1, true)
            self:SetBipod(false)
        end
    end
end
```

(Reproduced verbatim from the source; the movement test is sh_bipod.lua:48-49.)

- **Deploy input**: USE *pressed* while WALK is **not** held (the reverse of the
  safety/UBGL pattern) + trace conditions. `SetSafe(false)` and `SetBipod(true)` are
  replayed together — BUGLIST: "Bipod/safety transitions: cannot enter safety while
  deployed; deploying clears safety without a competing ready animation... Use + Walk no
  longer also deploys the bipod, and force-ready is idempotent."
- **Fold**: any movement key or jump, or losing the surface (checked every tick).
- Animation detail → anim §7.8.

### 8.3 State effects of `GetBipod()`

| Consumer | Effect |
|---|---|
| `Think_HoldType` (§4.3) | hold type "rpg" |
| `IdleActivity` (sh_gun.lua:20-21) | idle = `ACT_VM_DEPLOY` |
| Fire animation (anim §7.3) | `ACT_VM_PRIMARYATTACK_DEPLOYED` |
| Reload animation (anim §7.6) | `ACT_VM_RELOAD_DEPLOYED` / `_EMPTY` variants |
| Recoil | bipod retains 25% instead of eliminating it (BUGLIST) |
| `Think_WorldBodygroups` (§4.5) | world "bipod" bodygroup 1 |
| `ToggleSafe` (sh_gun.lua:117) | cannot enter at-ease while deployed |
| `CanBayonetCharge` (§11.1) | blocks charge |
| Bash | blocked while deployed (sh_shoot.lua:20) |

---

## 9. Akimbo Dual-Wield

### 9.1 Unlocking the second weapon — `mcv/server/sv_second_weapon.lua` (SV)

The engine never hands the player a second copy of a weapon they already carry: a touched
pickup is intercepted and removed, and the sandbox spawn menu only gives ammo. All three
paths are caught server-side and flag the **carried** weapon:

```lua
// mcv/server/sv_second_weapon.lua:5-20
local function unlockSecond(ply, class)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    local have = ply:GetWeapon(class)
    if !IsValid(have) or !have.HasAkimbo or !have.SetHasSecond then return end
    if !have:GetHasSecond() then
        have:SetHasSecond(true)
        ply:EmitSound("MCV_Weapon_Foley_AK47.DrawMetal")
    end
end
MCV.UnlockSecondWeapon = unlockSecond

hook.Add("PlayerCanPickupWeapon", "mcv_second_weapon", function(ply, wep)
    if IsValid(wep) and wep.HasAkimbo and ply:HasWeapon(wep:GetClass()) then
        unlockSecond(ply, wep:GetClass())
    end
end)
```

- `PlayerCanPickupWeapon` (16-20): touching a ground copy of a dual-capable weapon you
  already hold → `HasSecond = true` on the *carried* one (the ground copy is consumed by
  the engine as usual ammo pickup).
- `PlayerGiveSWEP` (24-29): the sandbox path — "sandbox passes the list.Get(\"Weapon\")
  entry here (class name, print name, category...), not the weapon table, so the stored
  SWEP table is what says whether the gun can be dual wielded"
  (`weapons.GetStored(class).HasAkimbo`).
- **`SWEP:EquipAmmo(ply)`** (sh_akimbo.lua:5-9, SV): the third path — the engine calls it
  on the copy being picked up; it forwards to `MCV.UnlockSecondWeapon` for `HasAkimbo`
  weapons.

`HasAkimbo` is a *definition* flag (e.g. `mcv_pm.lua:20` area); the dual model is
`ViewModelAkimbo` ("models/weapons/mcv/v_dual_pm.mdl"). BUGLIST: the dual Mk 22 needed its
own suppressed model because bodygroups could not add a suppressor to the shared dual
model; dual PPK was a stale hand-port with `HasAkimbo = false` — both regenerated.

### 9.2 `ToggleAkimbo` & `Deferred_AkimboSwap` (sh_akimbo.lua:11-54)

```lua
function SWEP:ToggleAkimbo()
    if self:StillWaiting() then return end
    if !self:GetHasSecond() and !self:GetAkimbo() then return end // one pistol only

    self:ScopeToggle(false)

    local t = self:PlayAnimation(ACT_VM_HOLSTER, 1, true, true)
    self:SetAnimLockTime(CurTime() + t + 0.75)

    self:Defer("AkimboSwap", t + 0.5)
end
```

- Entry: WALK+USE (routed through `ToggleUBGL`, sh_ubgl.lua:21-23, which delegates when
  `HasAkimbo`); requires the unlock or already being dual.
- The swap *rides a holster*: `ACT_VM_HOLSTER` (locked, noidle), with the lock extended
  0.75 s past the animation so the draw animation that follows cannot be interrupted,
  and the actual model swap deferred to halfway (`t + 0.5`).
- **`Deferred_AkimboSwap`** (24-54): flips `Akimbo`, `SyncViewModel(true)` (model + hull
  + bodygroup reset, §3.2), re-validates the firemode ("the dual model animates fewer
  modes than the single one — no fanning on either revolver, and the dual Blackhawk has
  no double action either": `FiremodeAvailable` check + `ChangeFiremode`, 36-38); on the
  way back to single, `RestoreClip(0)` re-baselines the clip. The redraw picks
  `ACT_VM_READY` ("ready racks both slides") unless one side is empty with
  `LastShotAnimation`, in which case `ACT_VM_DRAW` carries the SlidePosition one-empty
  pose (48-53; BUGLIST: "Dual slide-lock pistols entering akimbo with one round now draw
  using the SlidePosition layer instead of playing the ready/racking animation").
- Prediction: the whole swap is NetworkVar + deferred-action state, so replay reproduces
  it (BUGLIST: "Dual-wield swaps and delayed inventory switches diverged on replay. The
  model alias/cache and collision bounds now follow restored state").

Animation-side → anim §7.12; per-hand counters and pose recoil → anim §4.4.

### 9.3 The off-hand world model (CL)

When `GetAkimbo()`, `UpdateWorldModels` (§13.2) draws a second clientside copy of the
world model on the left hand via `GetWorldModelTransformLeft` (cl_worldmodel.lua:168-198):
the right gun's weapon_bone transform relative to the right hand is mirrored into the
left hand's frame (mirror axis convar `mcv_wm_left_mirror`, default "z", with the gun's
lateral axis flipped back so the mesh is a proper rotation, not a mirrored mesh), plus
`WorldModelOffsetLeft` / the `mcv_wm_left_pos` / `mcv_wm_left_ang` tuning convars. BUGLIST
notes the left-hand placement and tilt sign still want a look ("Third person pass... the
tilt sign and the left-hand placement").

### 9.4 Gameplay effects of `GetAkimbo()`

| Consumer | Effect |
|---|---|
| `SyncViewModel` (§3.2) | viewmodel = `ViewModelAkimbo` |
| `Think_HoldType` (§4.3) | hold type "duel" (left-hand copy drawn, §9.3) |
| Fire selection (anim §7.3) | even count = right hand (`ACT_VM_PRIMARYATTACK`), odd = left (`ACT_VM_SECONDARYATTACK`); volley/DA/last-shot variants |
| Clip splitting | shared count; `ammo_fraction1`/`2` split floor/ceil (right fires on even, anim §4.4) |
| Reload (anim §7.6) | per-hand insert stages, `ReloadHand` state, hand swap at half capacity |
| `empty` pose | three-state (0 / 0.5 right-dry / 1 both dry) |
| `IronsightPosAkimbo` | dual-specific aim offset (§7.9) |
| Third-person tracers | client `mcv_tracer` effect picks the gun that fired (BUGLIST: server used to always fire from the right) |

---

## 10. UBGL / Rifle Grenades — `weapons/mcv_base/sh_ubgl.lua`

### 10.1 `SWEP:ToggleUBGL()` (sh_ubgl.lua:20-48)

Input: USE pressed while WALK held (`ThinkWeapon`, §4.4). Routing:

1. `HasAkimbo` weapons delegate to `ToggleAkimbo` (dual pistols share the WALK+USE slot).
2. `!HasRifleGrenade` → no-op. `StillWaiting()` or a fixed bayonet → no-op.
3. **Rifle-grenade mode** (`!RifleGrenadeIsUBGL` — the launcher is a separate weapon
   swapped to through the holster): blocked when the rifle's primary clip is empty
   (32-34); plays `ACT_VM_HOLSTER` at **0.75 speed** (locked, noidle) and defers
   `LauncherSwap` at `t + 0.5`.
4. **True UBGL** (`RifleGrenadeIsUBGL`, e.g. M203/GP-25): toggles in place —
   `ACT_VM_IIN_M203` / `ACT_VM_IOUT_M203` (locked) with `GrenadeLauncher` flipped
   immediately.

### 10.2 `SWEP:Deferred_LauncherSwap()` (sh_ubgl.lua:3-18)

Entering launcher mode: `RestoreClip2(self.Secondary.ClipSize)` first, then the draw
animation by tube state — `ACT_VM_DRAWFULL_M203` (round in tube) / `ACT_VM_DRAW_M203`
(empty) — then `SetGrenadeLauncher(true)`. Leaving: `ACT_VM_READY` (the ready-rack
re-chamber) then `SetGrenadeLauncher(false)`. (Anim detail → anim §7.11.)

### 10.3 `SWEP:RifleGrenadeAttack()` (sh_ubgl.lua:51-89)

Called from `PrimaryAttack` while `GetGrenadeLauncher()` (sh_shoot.lua:38-41). Gates:
empty tube → `Reload()` instead; moving too fast (`GetSpeed() > 150`) → hold;
`NeedTriggerPress` → needs a fresh trigger. Then, in order: `ACT_VM_ISHOOT_M203` at 0.5
rate (unlocked); `RocketAttack(true)` (projectile → shooting doc); `TakeSecondaryAmmo(1)`;
1 s primary lockout; `LastRecoilTime` stamp (camera shake); grenade-shot sound; recoil
impulse queue (§6.2); tripled view-slide punch with shared-random lateral;
first-time-predicted `DoEject`/`DoMuzzle` (effects doc); `NeedTriggerPress = true`; and
`NeedCycle = true` on `PlayCycleAnimation` weapons (the launcher shot works the action).

### 10.4 State effects of `GetGrenadeLauncher()`

| Consumer | Effect |
|---|---|
| `IdleActivity` (sh_gun.lua:16-19) | `ACT_VM_IIDLE_M203` (UBGL) / `ACT_VM_IDLE_M203` (rifle grenade ladder) |
| `DeployAnimation` (sh_gun.lua:28-30) | launcher draws |
| `PrimaryAttack` (sh_shoot.lua:38-41) | routes to `RifleGrenadeAttack` |
| `GetFiremodeName` / `GetHUDAmmo` (sh_gun.lua:60-72) | "Launcher" + Clip2/Ammo2 |
| `ChangeFiremode` (shooting doc) | blocked entirely (BUGLIST) |
| `DoBodygroupsWeapon` (anim §4.4) | launcher bodygroup; grenade in tube when `Clip2() > 0` or reload past `MagInTimeGrenade` |
| `Think_WorldBodygroups` (§4.5) | world "grenade" bodygroup |
| `ToggleBayonet` (sh_bash.lua:139) | blocked |
| `ScopeToggle` | launcher aim offsets (`IronsightPosLauncher`) apply (§7.9) |
| Reload (reload doc) | `Reload2` → `ACT_VM_RELOAD_M203` |

---

## 11. Bayonet Charge — `weapons/mcv_base/sh_bayonet_charge.lua`

### 11.1 Entry & eligibility

- **Entry**: `PrimaryAttack` — "sprinting on the trigger with a bayonet fixed: charge, the
  same input the melee weapons take it on. A gun will not fire at a sprint anyway, so
  nothing else wants this. Once the charge is up the think loop owns the weapon until it
  lands or the player lets go" (sh_shoot.lua:26-34).
- **`CanBayonetCharge()`** (25-30): fixed bayonet, not bipodded, not reloading, and the
  model has the `ChargeStart` sequence ("the rifles animate it themselves... on 41 of the
  50 viewmodels that take a bayonet").
- **`IsBayonetCharging()`** (21-23): `GetActionState() == STATE_CHARGE` (local enum
  IDLE=0 / CHARGE=1, lines 5-6).
- Models without the wind-up ("nine of the fifty") fall back to `Bash()` — "the input
  still does something rather than nothing" (35-38).

### 11.2 The state machine

```
StartBayonetCharge (32-49):
  ActionState=CHARGE, ActionStart=now, ironsight down,
  PlaySequence("ChargeStart", locked) — duration falls back to 0.4 if the model's is missing
  ActionEnd = now + t            (the wind-up always resolves into the stab)
  Defer("BayonetLoop", t)

Deferred_BayonetLoop (118-122):
  still CHARGE + has "ChargeLoop" -> PlaySequence("ChargeLoop", unlocked, NOIDLE)
  IdleSequence() (81-85) returns "ChargeLoop" while charging -> the idle loop holds the pose

Think_BayonetCharge (87-116), every tick while charging:
  abort:  bayonet lost, or reload started -> EndBayonetCharge (72-78):
            ActionState=IDLE, ActionEnd=0, CancelDeferred, NextIdle=now,
            NextPrimaryFire=now+0.3   (no thrust: nothing left to stab with)
  wait:   CurTime() < ActionEnd  -> wind-up still playing
  end:    BashTrace(BayonetRange) hit an entity
          OR trigger released (!KeyDown(IN_ATTACK))
          OR sprint dropped (!GetIsSprinting())
          OR charge expired (now > ActionStart + BayonetChargeMaxTime, default 4)
       -> BayonetChargeAttack (51-69)

BayonetChargeAttack:
  ActionState=IDLE, ActionEnd=0
  first available of {"ChargeStab", "bash_bayonet"} (unlocked; duration falls back 0.6)
  BashGesture third-person
  Defer("BayonetHit", min(BayonetChargeHitDelay=0.1, t))
  NextPrimaryFire/NextSecondaryFire = now + t
```

The wind-up "always resolves into the stab rather than sliding back to the idle, so a
charge that finds nobody still finishes the move" (comment 104-107). Animation details
(named sequences, idle-by-name) → anim §7.10.

### 11.3 Damage timing — `Deferred_BayonetHit` (124-126)

`BashStrike(BayonetRange, BayonetDamage * BayonetChargeDamageMultiplier, true)` — the
charge lands **0.1 s into the thrust** ("the blade has to travel before it reaches
anything... as the melee weapons' charge does"), with the `thrust` flag switching the
damage type to `DMG_SLASH` (§12.3). `BayonetChargeDamageMultiplier` default 2.

### 11.4 Movement during the charge

There is **no explicit movement lock**: the player keeps sprinting (the charge requires
it); the *weapon* is owned by the think loop — `PrimaryAttack` early-outs while
`IsBayonetCharging()` (sh_shoot.lua:29), reload aborts the charge rather than queueing
(§11.2), and auto-reload skips charging weapons (BUGLIST). Prediction: the state machine
lives entirely in `ActionState`/`ActionStart`/`ActionEnd` NetworkVars plus one deferred
action — the exact shape BUGLIST describes ("Grenade releases, melee hits, bayonet
charges... now live in NetworkVars").

---

## 12. Bash & Bayonet — `mcv/weapon_common/sh_bash.lua`

### 12.1 `SWEP:Bash()` (sh_bash.lua:19-41)

Entry: `PrimaryAttack` with USE held and a *fresh* attack press, not bipodded
(sh_shoot.lua:19-24; BUGLIST: "Manual USE+attack bashes now require a fresh attack
press"). Selection:

```lua
// mcv/weapon_common/sh_bash.lua:19-41 (excerpt)
function SWEP:Bash()
    local bayonet = self:GetBayonet()
    local duration

    if bayonet then
        local seq = self:BayonetSwing()
        if seq then
            duration = self:PlaySequence(seq, 1, true)
        elseif self:HasAnimation(ACT_VM_HITLEFT) then
            duration = self:PlayAnimation(ACT_VM_HITLEFT, 1, true)
        end
    end
    // Some bayonet-capable models (vz. 52/57) only have the ordinary bash.
    // A missing activity must never turn into an unlocked, every-tick damage attack.
    if !duration then duration = self:PlayAnimation(ACT_VM_HITCENTER, 1, true) end
    if !duration or duration <= 0 then return end

    self:GetOwner():DoAnimationEvent(self.BashGesture)
    self:SetIronsight(false)

    self:BashStrike(bayonet and self.BayonetRange or self.BashRange,
                    bayonet and self.BayonetDamage or self.BashDamage)
end
```

The vz. 52/57 BUGLIST item is this rule verbatim: "Fall back to its existing HITCENTER
bash at native duration; failed animation playback cannot deal damage." Damage and
animation are inseparable — the strike only runs with a positive locked duration.

### 12.2 `SWEP:BayonetSwing()` (8-17)

Picks among the sequences the model actually has from `SequencesBayonetSwing =
{"bash_bayonet", "slash_bayonet"}` using `util.SharedRandom("mcv_bayonet_swing", 1, #have+1,
CurTime())` — "a coin toss, drawn from a seed both realms share so the viewmodel the
player sees and the timing the server keeps agree on it."

### 12.3 `BashTrace` / `BashStrike` (45-109)

- **`BashTrace(range)`** (45-60): hull trace, `MASK_SHOT_HULL`, 32-unit cube
  (`BASH_HULL`), start pulled back `BASH_HULL * 1.732` (~55 units) behind the shoot
  position along the aim vector, owner-filtered. Also used every tick by the charge
  (§11.2) — "its own function because the bayonet charge asks the same question every
  tick".
- **`BashStrike(range, damage, thrust)`** (64-109): builds `DamageInfo` (damage;
  force = dir × damage × 500; type `DMG_SLASH` when thrust else `DMG_CLUB` — "either way
  not GENERIC, which TTT leaves no DNA on"; position/attacker/inflictor). Server-side
  only: if the trace hit and `MCV.SurfaceImpact` returns false (stock fallback), a
  zero-damage `FireBullets` cosmetic bullet provides the engine impact — "the server owns
  impact dispatch; predicted bashes must not create a second copy"; then
  `TakeDamageInfo` on a valid entity. Both realms: `ViewPunch(Angle(5, -5, 0))`; hit
  sounds (`MCV_Weapon_AK47_Bayonet.ThrustStab/ThrustHit` vs
  `MCV_Weapon_Fists.PowerPunch/PowerPunchWall`, bayonet vs bash, flesh vs world). Damage
  dispatch is server-authoritative (BUGLIST: "Melee/bashes now dispatch their custom
  impact once on the server from the contact trace, using strike damage").

### 12.4 Bayonet inventory rules

- **`OwnerHasBayonet()`** (112-119): the player must carry one of the bayonet melee
  weapons (`w.IsBayonet`) to fix one.
- **`ToggleBayonet()`** (136-160): USE+attack2 (gun `SecondaryAttack`, sh_gun.lua:74-80).
  Gates: `HasBayonet`, not `StillWaiting`, not launcher mode, and (to fix) a bayonet in
  inventory. Detach: `ACT_VM_DETACH_SILENCER` when the model has it, with the bodygroup
  change deferred to the animation's end (`Defer("BayonetOff", t)`); "only defer removal
  with a positive animation duration" (BUGLIST fix for nil-delay errors). Attach:
  `ACT_VM_ATTACH_SILENCER` if present, then `SetBayonet(true)` — "some models have the
  bayonet bodygroup but no attach/detach activities. Toggle those directly rather than
  requesting an invalid animation" (BUGLIST). The vz. 52/57's bayonet support is disabled
  pending animations (BUGLIST), and "bayonet maintenance clears attached state on weapons
  that no longer support it".
- **`Think_Bayonet()`** (124-129, common Think #4): a fixed bayonet silently comes off if
  the bayonet weapon left the inventory — "drop it, or lose it on a loadout change... no
  animation and no sound, because there is nothing in the player's hands to take it off
  with".
- **`Deferred_BayonetOff`** (132-134): the deferred bodygroup clear.
- Viewmodel/world bodygroup updates ride `DoBodygroupsWeapon` (anim §4.4 step 13) and
  `Think_WorldBodygroups` (§4.5).

---

## 13. Client Camera & World-Model Rendering

### 13.1 `mcv/weapon_common/cl_camera.lua` (CL)

**`SWEP:CalcView(ply, pos, ang, fov)`** (3-42) — the world camera while an MCV weapon is
out:

1. **Recoil roll shake**: `rec = max((LastRecoilTime + ShakeDuration) - CurTime(), 0) *
   ShakeScale`; while > 0, `ang.r += sin(CurTime() * ShakeFreq) * rec` (the recoil clock
   is networked, so both the shake and its end agree).
2. **Zoom**: `mag = Lerp(sight^3, 1, 90 / GetZoomMagnification())`; in realistic mode the
   view "pulls back a little as a burst goes on" (`mag + 0.15/(BurstCount/25 + 1) -
   0.15`). `SmoothedMagnification` (NetworkVar-resettable, §5.1) approaches the target —
   faster when zooming out (×10) than in (×5) — and `fov /= SmoothedMagnification`;
   `fov -= rec` (shake tightens the view).
3. **Realistic punch compensation**: `ang -= ply:GetViewPunchAngles() * 0.75` — "most of
   the punch comes back out of the picture: the kick moves the aim, not the camera".
4. **Camera handoff** (36-40): records `ViewmodelCameraAngle` / `ViewmodelCameraFOV` /
   `ViewmodelCameraFrame` — "GetViewModelPosition needs the actual rendered camera,
   including recoil suppression and the final zoom/shake FOV, rather than the owner's
   base FOV" (consumed by the recoil reprojection, §7.8; BUGLIST: "CalcView records its
   final camera angle/FOV for the current frame; physical muzzle projection uses that FOV
   too").

**`AdjustMouseSensitivity`** (48-51): §7.4. **`GetLookMagnification`** (44-46): the
equipment-bases version; the gun base overrides it (§7.3).

### 13.2 `mcv/weapon_common/cl_worldmodel.lua` (CL) — third-person drawing

The engine's `EF_BONEMERGE` placement is kept; MCV draws its *own* clientside copy so
effects can attach to it:

- **weapon_bone adjustment** (11-45, 49-93): the difference between the game's player
  rig and GMod's is taken out on `ValveBiped.weapon_bone` itself — a shared
  `WorldModelBoneAng/Pos` plus per-weapon `WorldModelOffset` (both overridable live via
  the `mcv_wm_ang` / `mcv_wm_pos` convars, deliberately not in the Q menu per AGENTS.md).
  `adjustOwnerBone` (52-67) manipulates the bone only when the value actually changed
  (model-aware cache); a global `Think` hook (79-93) restores the bone for players whose
  active weapon is no longer MCV ("the engine's own weapon models would inherit it
  otherwise"). BUGLIST: "the previous worldmodel pitch pass rotated around the hand origin
  below the trigger. Corrected the translations of 181 supported worldmodels to preserve
  index-finger contact".
- **`GetWorldModelEntity(left)`** (95-129): lazily creates/repairs the clientside copy
  (parented, `EF_BONEMERGE`, `SetNoDraw(true)`); repairs a PVS-detached parent (100-110,
  BUGLIST "repair detached clientside parents"); validates the world model exists. The
  left-hand copy is *not* parented — it is placed manually (§9.3).
- **`UpdateWorldModels(drawing)`** (202-243): dormancy/owner/rig checks (a custom NPC
  without `Bip01_R_Hand` falls back to the engine renderer); `SetupBones` for NPCs and
  after bone-adjust changes; `copyLook` (138-143) copies skin + all bodygroups from the
  weapon entity (which is why `Think_WorldBodygroups` §4.5 runs on the entity); creates
  the left copy only while akimbo, and removes a stale one otherwise ("a failed left-hand
  transform must not draw an old/default pose").
- **`DrawWorldModel(flags)`** (245-253): draws the copies; falls back to `self:DrawModel()`
  when there is no copy and the weapon is not dormant.
- **`GetWorldModelFor(left)` / `GetWorldModelAttachment(kind, left)`** (256-288): the
  effect-attachment surface — muzzle (`muzzle`) or shell port (`shell_eject`, `eject`,
  `eject2`, `shell_eject2` — first found), on the drawn copy (right or left) so third-person
  muzzle flashes and shells come from where the gun is.
- **PVS retirement** (265-272) + **`RemoveWorldModels`** (131-136) and **`OnRemove`**
  (290-292): see §3.5.

### 13.3 `mcv/client/cl_modelgc.lua` (CL) — clientside-model lifecycle

`MCV.TrackClientModel(weapon, slot, model)` / `MCV.RemoveClientModel(weapon, slot)`
(16-29) keep strong references (Lua GC does not remove engine clientside entities) and
map model→(weapon, slot). A 1-second timer (43-53) releases any model whose weapon,
owner, slot binding, dormancy or active-weapon status broke; `EntityRemoved`,
`NotifyShouldTransmit(false)` and `PostCleanupMap`/`ShutDown` also sweep. BUGLIST:
"Added independent clientside-model ownership/collection for worldmodel copies and
placement ghosts, including missed callbacks, lost slots, owner/PVS changes and
cleanup/reload." Slots used by the gun base: `"WM"`, `"WMLeft"` (§13.2) and
`"ScopeOverlayModel"` (§7.6).

### 13.4 Where the viewmodel render pipeline sits

`weapon_common/sh_vm.lua` (DoBodygroups driver, PreDrawViewModel custom camera,
ViewModelDrawn shells, PostDrawViewModel manual PCFs + Contact-Shadow refraction
preservation, GetViewModelPosition) and `mcv_base/sh_vm.lua` (gun pose parameters, muzzle
light `UpdateMuzzleLight` 232-248, RT scope entry `PreDrawViewModelWeapon` 250-257, OEG
composite 259-304) are fully documented in **anim §9** and **anim §4.4/§9.5** — not
repeated here. The gun-core-relevant boundary hooks are the `PreDrawViewModelWeapon` /
`PreDrawViewModelBlend` / `PostDrawViewModelWeapon` contract (§2.4) and the scope capture
ordering (§7.6-§7.7).

---

## 14. Translation-Layer Surface (ranked)

Concrete seams for porting foreign-base SWEPs onto the MCV gun runtime:

1. **Derive from `mcv_base`, neutralize the foreign runtime** (§1.2-1.3). The foreign
   SWEP's own `Think`/`Holster`/`PrimaryAttack`/`SecondaryAttack` must be removed or
   mapped; MCV's common `Think` is the skeleton and foreign per-tick work belongs in
   `ThinkWeapon()` (last in order, §4.1) or the contract hooks (§2.4). Keep
   `MilitaryConflictVietnam = true` (§1.4) or all global machinery detaches.
2. **Never add NetworkVars** (§2.3). The layout is fixed; foreign state goes into
   per-instance Lua fields created in `Initialize` (the `self.PCFs = {}` pattern) or NW2.
   Re-defining `SetupDataTables` collides with every other base.
3. **`StillWaiting()` is the universal gate** (§2.5). Foreign actions must call it
   (respect locks) and create locks the same way (`NextPrimaryFire` and/or a locked
   `PlayAnimation`). Anything bypassing it will fire during reloads/holsters/cycles.
4. **Aim is Think-driven** (§7.1): foreign bases that aim in `SecondaryAttack` must be
   redirected — IN_ATTACK2 sampling happens in `Think_Sights`; the gun
   `SecondaryAttack` is the bayonet toggle. Toggle-vs-hold per player is handled.
5. **Holster is two-phase and command-number synchronized** (§3.4): a foreign Holster
   returning `true` immediately will cut MCV's put-away animation; returning `false`
   without setting up `HolsterTime/Command/Entity` will never switch. Extra client Holster
   calls are already guarded, but foreign code must not "help" with `SelectWeapon`.
6. **Deferred actions are append-only** (§5.3): foreign delayed work must be added to
   `SWEP.DeferredActions` as *new tail entries* with `Deferred_<name>` handlers — never
   `timer.Simple` (unpredictable) and never inserting/reordering (indices are networked).
7. **Movement state comes from `GetWeaponMovement()`** (§6.1) and speed gating uses the
   blended `GetSpeed()` (fire blocked above 150, §4.4): foreign code reading
   `owner:GetVelocity()` directly will desync between realms and mis-predict.
8. **Missing animations must degrade, never unlock gameplay** (§12.1): the bash rule —
   check `HasAnimation`/`HasSequence`, fall back, tolerate nil, and gate damage on a
   positive locked duration. Applies to every translated action.
9. **`m_flNextAttack` save-value asymmetry** (§3.3): server writes are relative, client
   writes absolute. Deploy/bootstrapping code that writes it naively doubles or zeroes
   deadlines.
10. **Scope pipeline is material-driven** (§7.5-§7.7): a foreign scoped model needs
    `RTScopeMaterialIndex` mapped to its lens sub-material slot and `ScopeMaterial` for
    the reticle; without them set `HasScope = false` and plain ironsight zoom works.
    The lens shader/shader textures are the one external dependency (BUGLIST).
11. **Third-person is clientside copies + weapon_bone manipulation** (§13.2): foreign
    world models need the `ValveBiped.weapon_bone` rig convention (or fall back to engine
    rendering), and `WorldModelBodyGroups` remapping if bodygroups differ from the
    viewmodel's.
12. **Clock resets are system-wide** (§5): any new CurTime-stamped deadline must be
    cleared in a `ResetWeaponClock`-compatible way (networked floats self-restore; plain
    Lua deadlines must be re-derived, or they survive map transitions stale).

---

## 15. File Map

| File | Lines | Role (this audit's scope) |
|---|---|---|
| `lua/mcv/weapon_common/load.lua` | 33 | Composition loader: sandbox include, `MCV.WeaponCommon`, per-base table copy (§1) |
| `lua/mcv/weapon_common/shared.lua` | 400 | Defaults, sound routing, fixed datatable, hook contract, helpers (§2) |
| `lua/mcv/weapon_common/sh_deploy.lua` | 187 | Initialize/SyncViewModel/Deploy/Holster/StartCommand/ClientHolster (§3) |
| `lua/mcv/weapon_common/sh_think.lua` | 179 | Think skeleton, speed blend, hold types (§4) |
| `lua/mcv/weapon_common/sh_clock.lua` | 107 | Clock resets, rollback watchdog (§5) |
| `lua/mcv/weapon_common/sh_timers.lua` | 57 | Prediction-safe deferred actions (§5.3) |
| `lua/mcv/weapon_common/sh_movement.lua` | 65 | Movement samples, recoil impulse queue (§6) |
| `lua/mcv/weapon_common/sh_bash.lua` | 160 | Bash/bayonet gameplay (§12) |
| `lua/mcv/weapon_common/sh_vm.lua` | 267 | Viewmodel render pipeline (→ anim §9), DoBodygroups driver (→ anim §4) |
| `lua/mcv/weapon_common/cl_camera.lua` | 51 | CalcView shake/zoom/punch, sensitivity (§13.1) |
| `lua/mcv/weapon_common/cl_worldmodel.lua` | 292 | Third-person world models, left-hand dual, attachments (§13.2) |
| `lua/weapons/mcv_base/shared.lua` | 226 | Gun field defaults, `DeferredActions` list (§1, §5.3) |
| `lua/weapons/mcv_base/sh_think.lua` | 140 | `ThinkWeapon`, world bodygroups, cycle gate, DA release, burst (§4.4-§4.6) |
| `lua/weapons/mcv_base/sh_sights.lua` | 147 | Sight intent/state/blend (§7.1-§7.2) |
| `lua/weapons/mcv_base/sh_bipod.lua` | 55 | Bipod traces and state (§8) |
| `lua/weapons/mcv_base/sh_akimbo.lua` | 54 | Dual-wield swap, unlock hook (§9) |
| `lua/weapons/mcv_base/sh_ubgl.lua` | 89 | Launcher toggle/swap/attack (§10) |
| `lua/weapons/mcv_base/sh_bayonet_charge.lua` | 126 | Charge state machine (§11) |
| `lua/weapons/mcv_base/cl_pipscope.lua` | 169 | RT scope lens shader plumbing (§7.5) |
| `lua/mcv/client/cl_viewsettings.lua` | 45 | Viewmodel FOV/offset convars, recoil reprojection (§7.8) |
| `lua/mcv/client/cl_scopeoverlay.lua` | 147 | Lens pixel preservation stencil pipeline (§7.6) |
| `lua/mcv/client/cl_rendertarget.lua` | 48 | Scope frame capture, viewmodel render bounds (§7.7) |
| `lua/mcv/server/sv_second_weapon.lua` | 29 | Dual-wield unlock hooks (§9.1) |
| `lua/mcv/client/cl_modelgc.lua` | 61 | Clientside-model lifecycle (§13.3) |
| `lua/mcv/shared/sh_safe_movement.lua` | 231 | Generated list of grip-corrected models (§6.3 / anim §4.2) |
| `lua/weapons/mcv_base/sh_gun.lua` | 132 | Gun hook implementations: idle/deploy selection, zoom model, hints, safety (§4.4, §7.3) |
| `lua/autorun/sh_mcv_load.lua` | 43 | Global MCV namespace loader (§1.2) |

*(Companion docs: `docs/animation-system.md` for all playback/timeline/pose machinery;
`docs/shooting-ballistics.md`, `docs/reload-ammo.md`, `docs/sound-system.md`,
`docs/effects.md`, `docs/hud-settings.md`, `docs/support-systems.md` for the adjacent
systems.)*
