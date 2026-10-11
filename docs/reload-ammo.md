# MCV Base — Reload & Ammo (Exhaustive Audit)

Everything the Military Conflict: Vietnam base does to put rounds into a weapon, take them
out again, show them on the model, and hand them back through supply boxes. The core logic
is tiny and lives in one file — `weapons/mcv_base/sh_reload.lua` (257 lines, shared, fully
predicted) — but it is fed by the animation lock system, the deferred-action scheduler, the
third-person gesture scheme and the pose-parameter display pipeline, so this doc walks all
of them. Everything here is **shared-realm predicted code** unless noted; NPC reloads are
the deliberate exception (server-only, engine-owned). Cross-references:
`docs/animation-system.md` (playback API §2, prediction §3, reload matrices §7.6, timed
gestures §8.2), `docs/gun-core.md`, `docs/shooting-ballistics.md` (consumption),
`docs/weapon-definitions.md` (field catalogue), `docs/special-weapon-bases.md` (M79/UBGL),
`docs/support-systems.md` (harnesses), `docs/sound-system.md` (foley dispatch).

Upstream context: this repo is **Part 1** (Eastern + shared bases); Part 2 (Western
content) is a sibling pack (`reference/mcv/AGENTS.md:6-9`). Several base features — the
dual single-action revolver reload, the true pump shotguns, the M72 LAW infinite-ammo
weapon — have their users in Part 2 and appear here only as base-side machinery plus
BUGLIST history.

---

## 1. Architecture Overview

### 1.1 What a reload touches

A reload is **not** a timed Lua coroutine. It is a small set of networked booleans plus the
animation lock, re-driven every tick by `Think_Reload`:

| Concern | Mechanism | Defined |
|---|---|---|
| Reload in progress | `Reloading` NetworkVar (Bool 0) | `mcv/weapon_common/shared.lua:254` |
| Player asked to stop | `EndReload` NetworkVar (Bool 1) | `mcv/weapon_common/shared.lua:255` |
| Reload started on empty | `EmptyReload` NetworkVar (Bool 4) | `mcv/weapon_common/shared.lua:258` |
| Clip snapshot at start | `LastClip` NetworkVar (Int 1) | `mcv/weapon_common/shared.lua:231` |
| Which revolver hand loads | `ReloadHand` NetworkVar (Int 6) | `mcv/weapon_common/shared.lua:238` |
| Stage timing | `AnimLockTime` NetworkVar (Float 0) set by every locked `PlayAnimation` | `mcv/weapon_common/sh_anim.lua` (anim doc §2.1/§3) |
| Delayed round credit | `Defer("ReloadInsert", t)` — index 6 of `DeferredActions` | `mcv/weapon_common/sh_timers.lua:19-33`, `mcv_base/shared.lua:153` |
| Ammo transfer | `SetClip1` + `Player:SetAmmo` (both replayable predicted writes) | `sh_reload.lua:142-147` |
| Third person | `PlayReloadGesture` → `PLAYERANIMEVENT_RELOAD*` with ms timing | `sh_reload.lua:8-13`, `mcv/shared/sh_animevents.lua` |
| Sounds | viewmodel animation events (first person), `SoundReloadThirdPerson` / `SoundReloadLoopThirdPerson` (everyone else) | `mcv_base/shared.lua:189-192` |
| Ammo *display* | `ammo_fraction` pose params + `MagInTime` family + bullet bodygroups | `mcv_base/sh_vm.lua:12-155` |

The shared datatable is fixed for all derived bases ("All networked state lives here so
every derived base shares one layout… Derived bases must not redefine SetupDataTables",
`mcv/weapon_common/shared.lua:194-196`) — a translation layer cannot add NetworkVars to a
weapon that inherits this layout (anim doc §3.3).

### 1.2 Realm split and prediction posture

- `sh_reload.lua` is included on both realms (`MCV.IncludeWeaponModules("weapons/mcv_base")`,
  `mcv_base/shared.lua:226`). `SWEP:Reload` is the engine's predicted hook: it runs on the
  server and on the owning client inside prediction.
- The only `IsFirstTimePredicted()` gate in the reload path is inside `PlayReloadGesture`
  (`sh_reload.lua:9`) — third-person gesture/sound side effects. Everything else is
  **idempotent state**: NetworkVar writes, `SetClip1`, `SetAmmo`, and `PlayAnimation`
  itself, which re-sends the sequence on every replay and reconstructs the cycle from the
  networked `AnimationStart`/`AnimationDuration` stamps (anim doc §2.3, §3).
- `Think_Reload` deliberately carries no first-time gate; the same policy is stated at
  `mcv_base/sh_think.lua:109-111` (*"state left out of the commands the client re-simulates
  is state the client and the server stop agreeing on"*).
- Closures cannot predict, so the delayed round credit is a **named deferred action**, not
  a timer (`mcv/weapon_common/sh_timers.lua:1-15`): the action index and deadline travel in
  the datatable and every stage is replayable.
- NPC reloads are exempt: no user commands, no viewmodel, no reserve pool — the engine's
  own reload event refills the clip (`mcv_base/sh_npc.lua:1-3`, `sh_npc.lua:163-166`).

### 1.3 The engine inheritance layer

`mcv_base` derives from `weapon_base` (`mcv_base/shared.lua:4`), so four reload-relevant
helpers come from GMod's base gamemode Lua (verified against the glua reference dump,
`skills/glua/references/hooks/SWEP.md`):

- `SWEP:Ammo1() → number` / `SWEP:Ammo2() → number` — reserve count of the weapon's
  primary/secondary ammo type (`owner:GetAmmoCount(self.Primary.Ammo)`).
- `SWEP:TakePrimaryAmmo(num)` / `SWEP:TakeSecondaryAmmo(num)` — subtract from `Clip1`/`Clip2`;
  when the clip is already empty they subtract from the reserve instead.
- `Weapon:Clip1/Clip2/SetClip1/SetClip2/GetMaxClip1/GetPrimaryAmmoType/GetSecondaryAmmoType`
  — engine, shared.
- `Player:SetAmmo(count, type)` / `Player:GetAmmoCount(type)` / `Player:RemoveAmmo` —
  shared; `Player:GiveAmmo` — **server only**. MCV never calls `GiveAmmo` in a predicted
  path; the M79 comment states the rule outright: *"SetAmmo (not GiveAmmo) and Clip1 are
  replayable predicted writes; a switch cannot transmute ammo"*
  (`weapons/mcv_m79_base/shared.lua:76-77`).

`mcv_m79_base` is the only override point: it redefines `Ammo1()` and
`GetPrimaryAmmoType()` so the reserve follows the selected cartridge (§6.5).

### 1.4 Call graph (who calls what)

```
engine IN_RELOAD ──► SWEP:Reload(automatic)            sh_reload.lua:28
                        ├─ NPC? ──► SWEP:NPC_Reload()   sh_npc.lua:163 (no-op)
                        ├─ USE held ──► ChangeFiremode  (sh_shoot.lua:743+; M79 overrides)
                        ├─ UBGL mode ──► SWEP:Reload2() sh_reload.lua:113
                        └─ PlayAnimation(...) lock=true
                           SetLastClip / sounds / gesture / EmptyReload / SetReloading
Think (every tick) ──► weapon_common Think ──► ThinkWeapon   sh_think.lua:49
                        ├─ Think_Reload                   sh_reload.lua:185
                        │    ├─ RestoreClip / RestoreClip2   sh_reload.lua:137/152
                        │    ├─ RestoreReloadInsert ── Defer("ReloadInsert")
                        │    └─ Deferred_ReloadInsert         sh_reload.lua:179
                        └─ Think_AutoReload               sh_reload.lua:15
ProcessDeferred (every tick, weapon_common/sh_think.lua:19) ──► Deferred_ReloadInsert
dry fire (Clip1<1 in PrimaryAttack, sh_shoot.lua:43-47) ──► self:Reload()
RifleGrenadeAttack with empty tube (sh_ubgl.lua:54) ──► self:Reload()
attack cancel (IN_ATTACK during ShotgunReload, sh_think.lua:80-84) ──► SetEndReload(true)
```

---

## 2. `sh_reload.lua` — Function by Function

All functions are shared-realm, defined on `mcv_base` (available to every gun SWEP and, for
the generic ones, inherited by nothing else — the melee/throwable/placeable/equipment bases
have their own `Reload` stubs, e.g. the equipment box's empty one at
`weapons/mcv_equipment_box/sh_box.lua:216-217`).

### 2.1 `SWEP:PlayReloadGesture(t, event)` — sh_reload.lua:8-13

```lua
// weapons/mcv_base/sh_reload.lua:8-13
function SWEP:PlayReloadGesture(t, event)
    if !IsFirstTimePredicted() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    owner:DoCustomAnimEvent(event or PLAYERANIMEVENT_RELOAD, math.max(1, math.floor((t or 0) * 1000)))
end
```

- **Purpose**: fire the third-person reload gesture with the first-person animation's own
  remaining time (seconds → integer milliseconds) as the event data. `t` is normally the
  value just returned by `PlayAnimation` (the remaining lock), or
  `GetAnimLockTime() - CurTime()` at reload start (`sh_reload.lua:95`).
- **Callers**: `Reload` (:95), `Think_Reload` (:204, 214, 220, 231, 233, 241),
  `mcv_m79_base/shared.lua:95`.
- **Side effects**: none directly; the `DoAnimationEvent` gamemode hook
  (`mcv/shared/sh_animevents.lua:28-64`) catches `PLAYERANIMEVENT_RELOAD` (3),
  `_RELOAD_LOOP` (4) and `_RELOAD_END` (5), restarts the hold type's reload gesture in
  `GESTURE_SLOT_ATTACK_AND_RELOAD`, and **stretches it to the supplied time** —
  `SetLayerDuration(slot, t)`, or `t / offset` with `SetLayerCycle(slot, offset)` for the
  per-round loops so *"every insert shows the hands loading"*. The per-gesture start points
  live in `MCV.ReloadAnimOffsets` (revolver 0.6/0.6/0.7, shotgun 0.25/0.31/0.5,
  `sh_animevents.lua:11-24`). Full analysis: anim doc §8.2.
- **Prediction**: first-time gate because the gesture is a cosmetic side effect with no
  replayable state.

### 2.2 `SWEP:Think_AutoReload()` — sh_reload.lua:15-26

```lua
// weapons/mcv_base/sh_reload.lua:15-26
function SWEP:Think_AutoReload()
    if self:GetReloading() or self:StillWaiting() or self:GetHolsterTime() != 0 then return end
    if self:GetSafe() or self:GetNeedCycle() or self:GetPrimedAttack() or self:IsBayonetCharging() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() or owner:GetInfoNum("mcv_auto_reload", 1) == 0 then return end
    if self:GetGrenadeLauncher() then
        if self:Clip2() != 0 or self:GetClip2Capacity() <= 0 or self:Ammo2() <= 0 then return end
    else
        if self:Clip1() != 0 or self:GetClip1Capacity() <= 0 or self:Ammo1() <= 0 then return end
    end
    self:Reload(true)
end
```

- **Purpose**: automatic reload of a fully empty magazine/launcher once the player stops
  doing anything that owns the weapon. Client preference `mcv_auto_reload` (archived
  userinfo convar, default 1 — `mcv/client/cl_controls.lua:4`, menu entry
  `cl_settings.lua:41`; BUGLIST line 10).
- **Caller**: tail of `ThinkWeapon` (`mcv_base/sh_think.lua:139`) — every tick, both realms.
- **Blocked by**: already reloading, anim lock / next-fire cooldown (`StillWaiting`,
  `weapon_common/shared.lua:356-361`), a holster in progress, safety, pending bolt/pump
  cycle, primed double-action attack, bayonet charge.
- **Keyed on `Reload(true)`**: the `automatic` flag bypasses the `KeyPressed(IN_RELOAD)`
  requirement and the USE+RELOAD firemode diversion (§2.3) — "automatic requests bypass
  manual reload/use-key input without switching firemode" (BUGLIST:10).
- **Prediction-safe**: reads only predicted state + the owner's userinfo.

### 2.3 `SWEP:Reload(automatic)` — sh_reload.lua:28-111 — the entry point

Entry conditions, in order (each `return` is silent — no dry-fire click, see §4.3):

| # | Gate | Line | Notes |
|---|---|---|---|
| 1 | owner is NPC | :29 | diverts to `NPC_Reload()` (no-op; engine refills) |
| 2 | `StillWaiting()` | :30 | anim lock or shot cooldown active |
| 3 | `GetReloading()` | :31 | already in a reload |
| 4 | `!automatic and !KeyPressed(IN_RELOAD)` | :33 | engine calls `Reload` every tick the key is held; only the press edge starts one |
| 5 | USE held (manual only) | :35-38 | diverts to `ChangeFiremode()` — "fire mode" is USE+RELOAD |
| 6 | UBGL mode | :40-43 | diverts to `Reload2()` |
| 7 | `Ammo1() == 0` | :45 | no reserve |
| 8 | `Clip1() >= GetClip1Capacity()` | :46 | magazine already full (chamber included) |

Then the **activity selection matrix** (all `PlayAnimation(act, 1, true[, noidle])` —
locked; `noidle=true` on the shotgun/dual start stages so the final frame is held and the
idle cannot restart mid-reload; anim doc §2.1, §7.6):

| Weapon shape | Activity | Line |
|---|---|---|
| ShotgunReload, empty, `ShotgunReloadEmptyStartAnimation` | `ACT_VM_RELOAD_INSERT_EMPTY` (locked, noidle) | :50-53 |
| ShotgunReload otherwise | `ACT_SHOTGUN_RELOAD_START` (locked, noidle) | :55 |
| Akimbo, clip 0 | `ACT_VM_RELOADEMPTY` | :60-61 |
| Akimbo, clip 1 | `ACT_VM_MISSRIGHT2` → fallback `ACT_VM_MISSRIGHT` → `ACT_VM_RELOAD` via `HasAnimation` | :62-63, 69-71 |
| Akimbo, clip ≥ `(ClipSize+Chamber)*2 - 1` | `ACT_VM_MISSRIGHT` | :64-65 |
| Akimbo default | `ACT_VM_RELOAD` | :59 |
| clip 0 and `HasEmptyReload`, bipod | `ACT_VM_DEPLOYED_RELOAD_EMPTY` | :75-76 |
| clip 0 and `HasEmptyReload` | `ACT_VM_RELOADEMPTY` | :78 |
| bipod | `ACT_VM_RELOAD_DEPLOYED` | :82 |
| default | `ACT_VM_RELOAD` | :84 |

Note the **locked start for the shotgun empty variant** — the comment explains it: unlocked,
*"the first insert cut it off on its first frame"* (Gyrojet, Vz.24 — BUGLIST:262, fixed
Sep 6 2026). The akimbo `HasAnimation` fallback exists because *"the dual revolvers have no
empty / right-only-empty reload of their own"* (BUGLIST:344).

After the animation, the start effects (sh_reload.lua:90-110):

1. `SetLastClip(Clip1())` — the predicted baseline for the shotgun attack-cancel (§7.1) and
   the dual-revolver half-way split (§2.10).
2. `EmitThirdPersonSound(self.SoundReloadThirdPerson)` — one sound for everyone but the
   holder (`weapon_common/shared.lua:43-78`; the holder's own foley rides the viewmodel's
   animation events, which nobody else receives — `mcv_base/shared.lua:189-192`).
3. `PlayReloadGesture(self:GetAnimLockTime() - CurTime(), PLAYERANIMEVENT_RELOAD)` — the
   gesture is timed to the animation just started (§2.1).
4. Empty-reload classification: dual single-action revolvers force `EmptyReload=true` and
   `ReloadHand=0` ("the right gun loads first"); everything else
   `SetEmptyReload(Clip1() == 0)` (:100-105).
5. `ScopeToggle(false)` — drop the sights (blocked from re-entering while reloading,
   `mcv_base/sh_sights.lua:89`).
6. `SetReloading(true)`, `SetEndReload(false)` (:109-110).

**Prediction**: every write is either a NetworkVar or an engine predicted field; the
activity pick reads only `Clip1`/mode flags, which are identical on both realms at command
replay. No first-time gate needed.

### 2.4 `SWEP:Reload2()` — sh_reload.lua:113-123

Launcher reload: returns unless `Ammo2() > 0` and `Clip2() < GetClip2Capacity()`; plays
`ACT_VM_RELOAD_M203` (locked, normal idle handling — single stage, no loop), drops sights,
`SetReloading(true)`, `SetEndReload(false)`. Called only from `Reload` when
`GetGrenadeLauncher()` (§6). The ammo transfer happens later in `Think_Reload`'s grenade
branch (§2.10). No third-person sound or gesture is fired here (the gesture would come from
`PlayReloadGesture` — not called on this path; the launcher models carry their own foley).

### 2.5 `SWEP:GetClip2Capacity()` / `SWEP:GetClip1Capacity()` — sh_reload.lua:125-135

```lua
// weapons/mcv_base/sh_reload.lua:129-135
function SWEP:GetClip1Capacity()
    if self:GetAkimbo() then
        return (self.Primary.ClipSize + self.Primary.Chamber) * 2
    else
        return self.Primary.ClipSize + self.Primary.Chamber
    end
end
```

- `GetClip2Capacity` is just `self.Secondary.ClipSize` (:125-127).
- **This is the chambering model**: `ClipSize` is the magazine; `Chamber` is the extra
  round on the feed path. Capacity = magazine + chamber (×2 dual-wielded). Every
  full/top-up check in the base uses capacity, not `ClipSize`.
- Callers: `Reload` (:21, :23, :46), `Think_Reload` (:198), `Think_AutoReload`,
  `ClampNPCAmmo` (`sh_npc.lua:94-95`), `sh_vm.lua:52, 98, 121`, `Deferred_AkimboSwap`
  indirectly.

### 2.6 `SWEP:RestoreClip(amt)` — sh_reload.lua:137-150

```lua
// weapons/mcv_base/sh_reload.lua:137-150
function SWEP:RestoreClip(amt)
    local reserve = self:GetInfiniteAmmo() and math.huge or (self:Clip1() + self:Ammo1())

    local lastclip1 = self:Clip1()

    self:SetClip1(math.min(self:Clip1() + amt, self:GetClip1Capacity(), reserve))

    if !self:GetInfiniteAmmo() then
        reserve = reserve - self:Clip1()
        self:GetOwner():SetAmmo(reserve, self.Primary.Ammo)
    end

    return self:Clip1() - lastclip1
end
```

- **The single ammo-in function for Clip1.** Moves up to `amt` rounds from the reserve into
  the clip, clamped by capacity and by *total* ammunition (clip + reserve — a reload can
  never create rounds), then writes the remainder back with `Player:SetAmmo` (replayable
  predicted write, §1.3). Returns the number actually added (used by nobody in the base —
  informational).
- `GetInfiniteAmmo()` (§2.8) swaps the clamps for `math.huge`, so an infinite-ammo weapon
  fills to capacity without touching the reserve.
- Callers: `Think_Reload` magazine branch (:250-252), `Deferred_ReloadInsert` (:181),
  `RestoreReloadInsert` (:175), `Deferred_AkimboSwap` (`sh_akimbo.lua:43` — with 0, a
  no-op clamp used when dropping dual mode), M79 override (§6.5).

### 2.7 `SWEP:RestoreClip2(amt)` — sh_reload.lua:152-165

Same shape for the launcher tube: clamps to `GetClip2Capacity()` and `Clip2() + Ammo2()`,
writes back with `SetAmmo(reserve, self.Secondary.Ammo)`. Callers: `Think_Reload` grenade
branch (:189) and `Deferred_LauncherSwap` (`sh_ubgl.lua:5` — entering launcher mode
re-fills the tube from reserve as part of the swap).

### 2.8 `SWEP:GetInfiniteAmmo()` — sh_reload.lua:167-169

Base implementation returns `false`. No weapon in Part 1 overrides it; the M72 LAW
(Part 2) does — *"Retains replacement-ammo and infinite-ammo behavior"* (BUGLIST:155).
Every reserve clamp consults it (`sh_reload.lua:138, 144, 153, 159, 202, 227`;
`sh_vm.lua:51, 97, 120`), so it is the **single intended override point** for
infinite-ammo semantics.

### 2.9 `SWEP:RestoreReloadInsert()` / `SWEP:Deferred_ReloadInsert()` — sh_reload.lua:171-183

```lua
// weapons/mcv_base/sh_reload.lua:171-183
function SWEP:RestoreReloadInsert()
    if self.ReloadInsertTime then
        self:Defer("ReloadInsert", self.ReloadInsertTime)
    else
        self:RestoreClip(self.ShotgunReloadRounds)
    end
end

function SWEP:Deferred_ReloadInsert()
    if self:GetReloading() then
        self:RestoreClip(self.ShotgunReloadRounds)
    end
end
```

- Round-by-round inserts credit ammo either **immediately** (no `ReloadInsertTime`) or at
  a model-authored point inside the insert animation (`ReloadInsertTime`, e.g. the Shanxi
  Type 17's `14/30` — "rounds leave the stripper clip at frame 14",
  `mcv_shanxi_type17.lua:52`; BUGLIST:137: *"using the predicted deferred-action scheduler
  rather than granting rounds when the insert starts"*).
- `Defer("ReloadInsert", delay)` stores the index (6 in `DeferredActions`,
  `mcv_base/shared.lua:153` — the list order is networked contract, *"append, never
  insert"*) and a CurTime deadline; `ProcessDeferred` (run every tick from
  `weapon_common/sh_think.lua:19`) fires `Deferred_ReloadInsert` when due
  (`sh_timers.lua:46-57`).
- The `GetReloading()` re-check makes the deferred credit a no-op if the reload was
  cancelled in between (holster clears `Reloading`).
- `sh_vm.lua:49` consults `DeferPending("ReloadInsert")` so the *displayed* count includes
  the pending round while it is still "in the hand" (§5.3).

### 2.10 `SWEP:Think_Reload()` — sh_reload.lua:185-257 — the state machine

Runs every tick from `ThinkWeapon` (`mcv_base/sh_think.lua:54`). The outer condition is
`GetReloading() and !StillWaiting()` — **the reload advances exactly when the current
locked stage's animation has finished** (or, for the `noidle` stages, when its lock
expires). Four branches:

**(a) Grenade launcher** (:187-190): finish immediately — `SetReloading(false)` and
`RestoreClip2(self.Secondary.ClipSize)` (a full tube, clamped by §2.7). Single stage.

**(b) `AkimboDualSingleActionReload` + akimbo** (:191-225) — dual revolvers loading one
round at a time, right gun first:

```lua
// weapons/mcv_base/sh_reload.lua:198-211
local capacity = self:GetClip1Capacity()
local half = self:GetLastClip() + (capacity - self:GetLastClip()) / 2
local hand = self:GetReloadHand()

if self:GetEndReload() or self:Clip1() >= capacity or (!self:GetInfiniteAmmo() and self:Ammo1() == 0) then
    // the guns go back down from whichever hand is loading
    self:PlayReloadGesture(self:PlayAnimation(
        hand >= 2 and ACT_SHOTGUN_RELOAD_FINISH or ACT_VM_RELOAD_END_EMPTY, 1, true),
        PLAYERANIMEVENT_RELOAD_END)

    self:SetReloading(false)
    if !self.AnimationHandlesHammer then
        self:SetEmptyReload(false)
    end
```

- **Finish**: end requested, full, or reserve dry → put-away animation chosen by hand
  (`ACT_SHOTGUN_RELOAD_FINISH` left / `ACT_VM_RELOAD_END_EMPTY` right), gesture
  `RELOAD_END`, `Reloading=false`.
- **Hand swap** (:212-218): when the right gun holds its share (`Clip1 >= half`, computed
  from the `LastClip` baseline) → `ACT_VM_RELOAD_END` (noidle) + `RELOAD_LOOP` gesture +
  `SetReloadHand(2)`.
- **Insert** (:219-225): `ACT_VM_RELOAD2` (left) / `ACT_VM_RELOAD` (right), noidle,
  `RELOAD_LOOP` gesture, `SoundReloadLoopThirdPerson`, `RestoreReloadInsert()`.
- The `ReloadHand` NetworkVar doc: "0 the right, 1 the right one just closed (the hands
  swap next), 2 the left" (`weapon_common/shared.lua:236-238`). No Part 1 weapon sets
  `AkimboDualSingleActionReload` — the dual revolvers are Part 2 (BUGLIST:344).

**(c) `ShotgunReload`** (:226-245) — round-by-round (shotguns, stripper clips):

```lua
// weapons/mcv_base/sh_reload.lua:227-241
if self:GetEndReload() or self:Clip1() >= (self:GetEmptyReload() and self.Primary.ClipSize or self:GetClip1Capacity()) or (!self:GetInfiniteAmmo() and self:Ammo1() == 0) then
    // a reload that started empty ends by chambering (the model's ACT_SHOTGUN_PUMP:
    // reload_endpump) when it has one; the plain finish otherwise
    if self:GetEmptyReload() and self:Clip1() != self:GetLastClip() and self:HasAnimation(ACT_SHOTGUN_PUMP) then
        self:PlayReloadGesture(self:PlayAnimation(ACT_SHOTGUN_PUMP, 1, true), PLAYERANIMEVENT_RELOAD_END)
    else
        self:PlayReloadGesture(self:PlayAnimation(ACT_SHOTGUN_RELOAD_FINISH, 1, true), PLAYERANIMEVENT_RELOAD_END)
    end

    self:SetReloading(false)
    if !self.AnimationHandlesHammer then
        self:SetEmptyReload(false)
    end
else
    self:PlayReloadGesture(self:PlayAnimation(self.ShotgunAltReload and ACT_VM_RELOAD_INSERT or ACT_VM_RELOAD, 1, true, true), PLAYERANIMEVENT_RELOAD_LOOP)

    self:EmitThirdPersonSound(self.SoundReloadLoopThirdPerson)
    self:RestoreReloadInsert()
end
```

- **Stop target**: a reload that *started empty* stops at `Primary.ClipSize` (the chamber
  round is what the closing pump chambers — no extra round is granted); a top-up stops at
  full capacity. `Ammo1() == 0` also stops it (reserve dry).
- **Empty finish**: if rounds were actually added (`Clip1 != LastClip`) and the model has
  one, the finish is `ACT_SHOTGUN_PUMP` (the model's `reload_endpump`) — BUGLIST:361 fixed
  the Gyrojets this way. Otherwise `ACT_SHOTGUN_RELOAD_FINISH`.
- **Insert stage**: `ACT_VM_RELOAD_INSERT`, or plain `ACT_VM_RELOAD` when
  `ShotgunAltReload` (clip-loading rifles use the ordinary reload activity per insert,
  e.g. `mcv_m38_s.lua:52`), noidle, `RELOAD_LOOP` gesture, loop sound, ammo credit (§2.9).

**(d) Magazine guns** (:246-254): single stage — `SetReloading(false)` then
`RestoreClip(self.Primary.ClipSize)` (×2 when akimbo). **The transfer happens exactly when
the animation lock ends**, so the round count on the model is ahead of the true clip until
then — the display pipeline compensates with `MagInTime` (§5.2).

Common tail in (b)/(c): `EmptyReload` is cleared immediately unless
`AnimationHandlesHammer` — then the model's own predicted hammer event does it
(`Think_HammerRelease`, `mcv_base/sh_shoot.lua:217-223`; anim doc §5.6). The hammer pose
itself is `shouldhammer = GetNeedCycle() or GetEmptyReload() or ((ShotgunReload or
!reloading) and clip == 0)` (`mcv_base/sh_vm.lua:157`).

### 2.11 The state machine on one page

| State (Reloading/stage) | Entered by | Exits when | Ammo effect |
|---|---|---|---|
| Idle | — | `Reload` passes all gates | — |
| Magazine reload | `Reload` → 1 locked anim | lock expires | `RestoreClip(ClipSize[×2])` at exit |
| Launcher reload | `Reload2` | lock expires | `RestoreClip2(Secondary.ClipSize)` at exit |
| Shotgun start | `Reload` (noidle, locked) | lock expires | none |
| Shotgun insert N | `Think_Reload` (noidle, locked) | lock expires | immediate or deferred `RestoreClip(ShotgunReloadRounds)` |
| Shotgun finish | stop condition | lock expires | none (pump chambers nothing extra) |
| Dual-revolver insert/swap/finish | as above per stage | per stage | per insert |
| Cancelled (attack) | `SetEndReload(true)` | next `Think_Reload` pass → finish stage | keeps rounds already credited |

---

## 3. The Ammo Model

### 3.1 Engine primitives and numeric IDs

MCV uses the stock engine model — **no custom magazine abstraction**:

- `Clip1`/`Clip2` (engine DT vars, predicted) are the magazine and the launcher tube.
- The reserve is the player's per-ammo-type pool, addressed by **string name in weapon
  definitions** (`SWEP.Primary.Ammo = "smg1"`, `mcv_sks.lua:99`) and by **numeric ID at
  runtime** (`GetPrimaryAmmoType()` engine call; `game.GetAmmoID(name)` /
  `game.GetAmmoName(id)` / `game.GetAmmoMax(id)` in the supply planner, §8.2).
- Custom ammo *types* are registered once, both realms, at load — ten equipment pools
  (`mcv_grenade`, `mcv_molotov`, `mcv_mine`, `mcv_explosive_charge`,
  `mcv_flamethrower_fuel`, `mcv_crossbowbolt`, `mcv_flareround`, `mcv_ammobox`,
  `mcv_medicbox`, `mcv_flame_cartridge`) via `game.AddAmmoType` with zeroed damage
  (`mcv/shared/sh_common.lua:64-80`). Localization labels for the two box pools at
  `mcv/client/cl_language.lua:11-12`.
- The guns themselves use engine pools: `ar2`, `pistol`, `357`, `smg1`, `buckshot`,
  `smg1_grenade`, `XBowBolt`, `RPG_Round`… — chosen by a cartridge audit
  (BUGLIST:123: *"pistol-calibre carbines use Pistol; semi-auto snipers use AR2 while
  bolt-actions retain .357; LMG pools follow cartridge class"*).

### 3.2 The `Primary` / `Secondary` tables and the chamber

| Field | Default (common) | Default (mcv_base) | Meaning |
|---|---|---|---|
| `Primary.Ammo` | `"none"` (`weapon_common/shared.lua:167`) | `"ar2"` (`mcv_base/shared.lua:136`) | reserve pool name |
| `Primary.ClipSize` | -1 | 10 | magazine size; -1 = clip-less |
| `Primary.Chamber` | 0 | 1 | extra round on the feed path |
| `Primary.DefaultClip` | 0 | 30 | spawn ammo: magazine **plus starting reserve** |
| `Secondary.ClipSize` | -1 | — (per weapon, usually 1) | launcher tube |
| `Secondary.Ammo` | `""` | `"smg1_grenade"` on grenade-capable rifles | launcher pool |
| `Secondary.DefaultClip` | 0 | 1 | free spawn grenade round |

The chamber is *display-excluded* from the magazine fraction — `MagFraction` subtracts it
(`sh_vm.lua:6-10`, §5.1), and capacity everywhere is `ClipSize + Chamber` (§2.5). Fill
semantics: an **empty** reload ends at `ClipSize` rounds (magazine branch restores exactly
`Primary.ClipSize`; shotgun empty loop stops at `ClipSize`); a **top-up** can reach full
capacity because the chambered round survives (`RestoreClip` clamps to capacity, never
empties the chamber). Firing takes exactly one round per shot from the clip
(`TakePrimaryAmmo(1)`, volley takes `min(Clip1, VolleyCount)` —
`mcv_base/sh_shoot.lua:459-463`), so the chamber round is simply the last one fired.

Clip-less weapons (grenades, mines, boxes, flamethrower) set `ClipSize = -1` and count
rounds in the reserve directly — `GetRoundsLeft()`/`TakeRound(n)` pick the right container
(`weapon_common/shared.lua:382-400`). The flamethrower's `Reload` is a stub that only
keeps the USE+RELOAD firemode shortcut ("fuel lives in the reserve; nothing to reload",
`mcv_flamethrower/sh_flame.lua:13-21`).

### 3.3 Consumption path (cross-ref shooting-ballistics)

- Player fire: `AttackEffects` ends with `TakePrimaryAmmo(min(Clip1, VolleyCount))` or
  `TakePrimaryAmmo(1)` (`mcv_base/sh_shoot.lua:455-463`) — the weapon_base helper, always
  the clip branch because `PrimaryAttack` gates on `Clip1() < 1` first and diverts to
  `Reload()` (`sh_shoot.lua:43-47`). **Dry fire = silent auto reload attempt**; there is
  no dry-click (§4.3).
- Launcher fire: `TakeSecondaryAmmo(1)` (`sh_ubgl.lua:63`), preceded by a `Clip2() < 1`
  gate that itself calls `Reload()` (:54).
- NPC fire: server-only `SetClip1(max(0, Clip1 - rounds))` (`sh_npc.lua:159`) — NPCs have
  no reserve pool.
- Flamethrower: `TakeRound(self.FuelPerTick)` per flame tick
  (`mcv_flamethrower/sh_flame.lua:50`).
- Display-only reads: `clip_percentage = Clip1 / Primary.ClipSize`
  (`sh_shoot.lua:471`, feeding the commented-out nearly-empty click); recoil volley
  multiplier `min(Clip1, VolleyCount)` (:413); akimbo even/odd hand parity throughout
  (§5.4).

### 3.4 Conservation — no discarded rounds, no dropped magazines

There is **no round-discard mechanic anywhere in Part 1**: `RestoreClip`/`RestoreClip2`
conserve `clip + reserve` exactly (§2.6-2.7), and nothing else writes `Clip1` during a
reload. The only place ammunition leaves the clip without being fired is the **M79
cartridge switch**, which explicitly returns the live round to its original pool before
reloading the new type (`mcv_m79_base/shared.lua:80-83`, §6.5). Dropped weapons keep their
clip (engine behavior); NPC drops are clamped back to capacity
(`ClampNPCAmmo`, `sh_npc.lua:93-102`; BUGLIST:195).

### 3.5 NPC reloads — deliberately engine-owned

```lua
// weapons/mcv_base/sh_npc.lua:163-166
function SWEP:NPC_Reload()
    // Refilling here would give ammunition before the NPC finishes reloading.
    // The engine performs that transfer when its animation reaches the reload event.
end
```

`Reload` diverts NPCs here (:29). NPC clip depletion schedules `SCHED_RELOAD` /
`SCHED_HIDE_AND_RELOAD` (`sh_npc.lua:131-135`); the engine's reload animation event
refills the clip; `ClampNPCAmmo` caps the result (BUGLIST:195, 223). A translation layer
must **not** route foreign NPC reload logic through the player state machine — the
server-only path is the contract.

### 3.6 HUD

`GetHUDAmmo` (`mcv_base/sh_gun.lua:66-72`) returns `Clip2, Ammo2` in launcher mode,
`Clip1, Ammo1` otherwise; the base default returns `nil, nil` (hidden,
`weapon_common/shared.lua:315`). Equipment boxes show `GetRoundsLeft()` (reserve,
`sh_box.lua:7-9`); the flamethrower shows `Ammo1()` only (`sh_flame.lua:5-7`).

---

## 4. Per-Weapon Reload Configuration Fields

All defaults live in `mcv_base/shared.lua`; per-weapon values in the individual SWEP files
(full catalogue in `docs/weapon-definitions.md`). "Consumed" cites the reader.

### 4.1 Shape selectors

| Field | Type | Default | Where set | Consumed |
|---|---|---|---|---|
| `ShotgunReload` | bool | false | `shared.lua:62` | `Reload` :49; `Think_Reload` :226; `sh_vm.lua:25` (display); cancel gate `sh_think.lua:82`; `sh_animevents.lua:42` (gesture stretch) |
| `ShotgunAltReload` | bool | false | `shared.lua:63` ("clip-loading rifles use this set of anims for bullet loading") | insert activity pick `Think_Reload` :241; insert activity for display `sh_vm.lua:69` |
| `ShotgunReloadEmptyStartAnimation` | bool | false | `shared.lua:53` | `Reload` :50 (empty start uses `ACT_VM_RELOAD_INSERT_EMPTY`) |
| `HasEmptyReload` | bool | true | `shared.lua:71` | `Reload` :74 (empty guns play `ACT_VM_RELOADEMPTY`); false on crossbow/rpg7/rpg2/type97/ptrd/m38_s/vz54s/flamethrower — they have no distinct empty animation |
| `AkimboDualSingleActionReload` | bool | false | `shared.lua:54` | `Reload` :100; `Think_Reload` :191 (dual-revolver per-round state machine; no Part 1 user) |
| `MagInClip` | bool | false | `shared.lua:82` | `sh_vm.lua:35, 91` (clip-fed display: counts *what is left to load*, §5.2) |
| `AnimationHandlesHammer` | bool | false | `shared.lua:55` | `Think_Reload` :209/:237 (EmptyReload cleared by model event instead); anim doc §5.6 |

### 4.2 Timing fields

| Field | Type | Default | Where set | Consumed |
|---|---|---|---|---|
| `ShotgunReloadRounds` | number | 1 | `shared.lua:72` | rounds credited per insert (`RestoreReloadInsert`/`Deferred_ReloadInsert`); Shanxi Type 17 sets 5 (a whole stripper clip, `mcv_shanxi_type17.lua:51`); display pending-count `sh_vm.lua:52, 73` |
| `ReloadInsertTime` | number/nil | nil | per weapon (only `mcv_shanxi_type17.lua:52` = 14/30) | `RestoreReloadInsert` :172 (deferred credit); `sh_vm.lua:49` (pending display) |
| `InsertClipPoseTime` | number/nil | nil | `shared.lua:75` ("off the insert animation's own AE_WPN_CLIP_TO_POSEPARAM"); m38_s/vz54s 0.2 | `sh_vm.lua:68-75` (counter holds pre-insert count until the model's refresh point) |
| `MagInTime` / `MagInTimeEmpty` | number | 0 / 0 | `shared.lua:77-78`; per weapon (AK 1.5, SKS 3.03/0.03, RPD 1.6/2.23, M79 50/30…) | `sh_vm.lua:31, 34` — seconds into the reload when the new magazine/belt is *shown* in |
| `MagOutTime` / `MagOutTimeEmpty` | number | 0 / 0 | `shared.lua:79-80` ("0 = off") | `sh_vm.lua:32, 35` — when the old magazine is *shown* out (counter reads 0 between out and in) |
| `MagInTimeGrenade` | number | 0.5 | `shared.lua:81` | `sh_vm.lua:199` (grenade bodygroup appears mid launcher reload) |
| `AkimboMagInTimes` | table act → {tRight, tLeft} | nil | e.g. `mcv_type67.lua:25`, `mcv_aps.lua:24`, `mcv_pm.lua:23`, `mcv_cz52.lua:25` | `sh_vm.lua:123-127` — per-gun magazine swap cues from the dual model's next-clip events |
| `CycleClipPoseTime` | number/nil | nil | per weapon (homemade pistol) | `sh_vm.lua:54-63` — cycle-driven counter refresh (not reload, but the same display budget) |

`MagInTime` provenance: BUGLIST:374 — *"mag replacement time now comes from the reload
animation's `AE_CL_BODYGROUP_SET_TO_NEXTCLIP` event (`MagInTime`, `MagOutTime` and the
empty pair, all guns)"*; the crossbow's 1.87 s likewise "from the animation's ammo event"
(BUGLIST:347). These are **display** times only — gameplay transfer timing is the
animation lock, never these fields.

### 4.3 Sound fields

| Field | Default | Dispatched | Notes |
|---|---|---|---|
| `SoundReloadThirdPerson` | `""` | `EmitThirdPersonSound` at reload start (`sh_reload.lua:91`; M79 too) | everyone except the holder; holder hears it only if the viewmodel is off screen (`weapon_common/shared.lua:32-41`) |
| `SoundReloadLoopThirdPerson` | `""` | per insert (`sh_reload.lua:223, 243`) | "per round on a shotgun or stripper reload" (`shared.lua:192`) |
| `SoundCycleThirdPerson` | `""` | per bolt/pump cycle (`sh_think.lua:120`) | sibling of the above |
| `SoundReload` | `""` | **nowhere** | dead field — first-person reload foley is carried by the viewmodel's own animation events (`shared.lua:189-192`: *"their own foley rides the viewmodel's animation events, which nobody else gets"*) |
| `SoundEmpty` / `SoundNearlyEmpty` | generic click | **nowhere** | dead fields — the nearly-empty emit is commented out at `sh_shoot.lua:473-475` and dry fire silently starts a reload. Verified: no reader of either field exists anywhere in `reference/mcv/lua/` |
| `SoundSpecial1/2` | `""` | **nowhere** | placeholder fields |

(Verified by exhaustive grep for `self.SoundEmpty` / `SoundNearlyEmpty` / `SoundReload` /
`SoundSpecial` — every hit is a definition, plus the one commented-out play. Cross-ref
`docs/sound-system.md` for the animevent foley pipeline.)

### 4.4 NetworkVar consumers (reload-relevant)

| Var (slot) | Writer | Readers |
|---|---|---|
| `Reloading` (Bool 0) | `Reload`/`Reload2` :109/:121, `Think_Reload` :188/:208/:236/:247, `Holster` (sh_deploy.lua:91), `ResetWeaponClock` (sh_clock.lua:55), `NPC_Deploy` (sh_npc.lua:70) | `Think_AutoReload`, `Think_Reload`, sights :89, sway `sh_shoot.lua:287`, burst gate `sh_think.lua:62`, bayonet charge `sh_bayonet_charge.lua:27, 94`, display `sh_vm.lua:15`, crosshair `cl_hud.lua:415`, M79 ×4, harnesses |
| `EndReload` (Bool 1) | cancel `sh_think.lua:83`; cleared at reload start :110/:122 and clock reset :56 | `Think_Reload` :202/:227 only |
| `EmptyReload` (Bool 4) | `Reload` :101/:104, M79 :96; cleared by `Think_Reload` / `Think_HammerRelease` (sh_shoot.lua:222) | hammer/empty poses `sh_vm.lua:157, 170`; shotgun stop target :227; M79 eject gate :62 |
| `LastClip` (Int 1) | `Reload` :90; M79 :85; clock reset :58 | cancel baseline `sh_think.lua:82`; dual half-way :199; shotgun pump gate :230; M79 eject/pose :56, :62 |
| `ReloadHand` (Int 6) | `Reload` :102, `Think_Reload` :215, clock reset :57 | `Think_Reload` :200-220 |
| `AmmoSwitchFrom` (Int 14) | M79 `ChangeFiremode` :79, cleared :68 | M79 bodygroup/eject :51-62 |

### 4.5 Worked examples (field shapes in practice)

- **Fixed-magazine clip rifle** — SKS (`mcv_sks.lua`): `MagInClip=true`,
  `MagInTime=3.03`, `MagInTimeEmpty=0.03`, `Chamber=0`, `LastShotAnimation=true`. The
  empty reload shows the counter full almost immediately (the fixed magazine is never
  "out"), while a top-up counts down what the stripper clip still holds.
- **Single-round loader** — Mosin M38 (`mcv_m38.lua`): `MagInClip=true`,
  `ShotgunReloadEmptyStartAnimation=false`, no `ShotgunReload` (single integrated reload
  animation), `Chamber=0`, plus a `Secondary` rifle-grenade tube.
- **Stripper-clip loop rifle** — Shanxi Type 17 (`mcv_shanxi_type17.lua:48-56`):
  `ShotgunReload=true`, `ShotgunReloadEmptyStartAnimation=true`,
  `ShotgunReloadRounds=5`, `ReloadInsertTime=14/30`, `MagInTime=0.4`.
- **Hybrid/donor models** — M38 sniper (`mcv_m38_s.lua:50-53`): `ShotgunReload=true`,
  `ShotgunAltReload=true` (borrows the sniper twin's single-round loop; BUGLIST:418).
- **Magazine LMG** — RPD (`mcv_rpd.lua:61-64`): `MagInTime=1.6/2.23`, belt bodygroups.
- **Akimbo pistol** — Type 67 (`mcv_type67.lua:25, 28-31`): `AkimboMagInTimes` keyed by
  activity, `MagInTime=0.73`.
- **Launcher** — AKM GP-25 (`mcv_akm_gp25.lua:171-173`): `Secondary.ClipSize=1`,
  `Secondary.Ammo="smg1_grenade"`, `Secondary.DefaultClip=1`.
- **Clip-less** — RPG-7 (`mcv_rpg7.lua`): `MagInClip=false`, `HasEmptyReload=false`,
  one rocket per tube; crossbow: `ClipSize=1`, `Chamber=0`, `HasEmptyReload=false`.

---

## 5. The Ammo Display Pipeline (`mcv_base/sh_vm.lua`)

Reload writes ammo at lock-end; the *model* must show rounds at the animation's own
mag-in moment. `DoBodygroupsWeapon` (called from the shared `DoBodygroups` both per tick
and before render, `weapon_common/sh_think.lua:17` + anim doc §4.4) reconciles the two.
All of it is snapshot-only — *"none of these values live in an ordinary Lua cache"*
(`sh_vm.lua:13-14`), so prediction replays and render calls re-derive everything.

### 5.1 `SWEP:MagFraction(count, per)` — sh_vm.lua:6-10

`math.Clamp(count - Primary.Chamber, 0, per) / per` — the game's `ammo_fraction` is the
magazine's fraction only; *"the chambered round is not in it"* (:3-5, the PPK counter
knots). Akimbo models carry `ammo_fraction1` (right) / `ammo_fraction2` (left).

### 5.2 Magazine mid-swap states — sh_vm.lua:15-36, 87-109

```lua
// weapons/mcv_base/sh_vm.lua:28-36
elseif displayRoundsToLoad then
    local reloadprogress = vm:SequenceDuration() - (self:GetAnimLockTime() - now)
    local empty = clip == 0
    local tin = empty and self.MagInTimeEmpty or self.MagInTime
    local tout = empty and self.MagOutTimeEmpty or self.MagOutTime

    displayRoundsToLoad = reloadprogress >= tin
    magOut = !displayRoundsToLoad and !self.MagInClip and tout > 0 and reloadprogress >= tout
end
```

- Progress is measured on the **reconstructed viewmodel clock** for visuals
  (`now = visual and self:GetViewModelTime() or CurTime()`, :16; anim doc §3.1) and on
  CurTime in the gameplay pass.
- `ShotgunReload` skips the whole block — a round-at-a-time reload has no magazine to
  swap, and both mid-swap states were being re-entered on every insert ("the rounds
  already in the gun blinked out each time", :20-24 — BUGLIST:310's idle/looping fix
  family).
- When `displayRoundsToLoad`: `MagInClip` guns show `min(clipsize - clip, Ammo1())` (the
  clip emptying as it loads); everything else shows the fresh magazine full —
  `min(clipsize, capacity, clip+Ammo1)` (:87-102). When `magOut`: fraction 0 (:103-105).
- The `empty` pose (bolt hold-open) drops the moment the new magazine is in
  (`MagInTimeEmpty`) — *"held to the end, the layer kept the bolt back while the animation
  closed it"* (:165-169; BUGLIST:259, the M14/XM21/M2/vz.58/MAS-49 fix).

### 5.3 Insert timing — pendingInsert and InsertClipPoseTime — sh_vm.lua:47-75

- `pendingInsert = reloading and ReloadInsertTime and DeferPending("ReloadInsert")` —
  while the deferred credit is queued the counter already shows the incoming round
  (`shown = min(shown + min(ShotgunReloadRounds, reserve), capacity)`, :49-53) and the
  `empty` pose reads the pending count (:170).
- `InsertClipPoseTime` does the opposite for the *counter*: a round is counted the moment
  its animation starts, but the hand is still carrying it — until the model's refresh
  point the counter holds the pre-insert count (:64-75).

### 5.4 Akimbo per-gun counters — sh_vm.lua:111-134

The shared count splits floor/ceil (right gun fires on even); during a reload,
`AkimboMagInTimes[activity]` hands each gun its new count on its own cue
(`progress >= times[1]` right, `times[2]` left), with the reserve-limited totals used
when the table is absent (:116-131).

### 5.5 Bodygroups, hammer, grenade

- `BulletBodygroups` — sparse round-count thresholds → `SetBodygroup(bg[1], bg[2])` above
  the threshold, 0 below (`sh_vm.lua:136-148`; the `isnumber(i)` guard is a house rule —
  inherited tables carry `BaseClass` keys, `AGENTS.md:57-60`).
- `BeltBodygroups` — the "clamped*" belt segments hide with the last round
  (:150-155; BUGLIST:388).
- `hammerpos` — `NeedCycle or EmptyReload or ((ShotgunReload or !reloading) and clip==0)`
  (:157-163), inverted by `InvertAnimationHammer`.
- Grenade bodygroup — visible when `Clip2() > 0` or launcher reload progress passed
  `MagInTimeGrenade` (:194-207).
- World model: the "belt" bodygroup follows `Clip1() > 0` (`mcv_base/sh_think.lua:43-47`);
  engine bodygroups are predicted fields, updated on both realms (:7).

---

## 6. UBGL / Secondary Reload Paths

Cross-ref `docs/gun-core.md` §UBGL and `docs/special-weapon-bases.md`.

### 6.1 The launcher reload itself

`Reload` diverts to `Reload2` whenever `GetGrenadeLauncher()` (§2.3 gate 6). `Reload2`
plays `ACT_VM_RELOAD_M203` locked; when the lock expires, `Think_Reload` branch (a) calls
`RestoreClip2(Secondary.ClipSize)` (§2.10). `RifleGrenadeAttack` with an empty tube calls
`Reload()` — which lands in `Reload2` because the mode flag is already set
(`sh_ubgl.lua:54`). `Think_AutoReload` watches `Clip2`/`Ammo2` in launcher mode.

### 6.2 Tube refill on mode entry — `Deferred_LauncherSwap` (sh_ubgl.lua:3-18)

Swapping onto the launcher defers `RestoreClip2(self.Secondary.ClipSize)` into the
mid-holster swap (the tube is filled from reserve as the launcher comes up), then draws
`ACT_VM_DRAWFULL_M203` (round in tube) or `ACT_VM_DRAW_M203`.

### 6.3 The free spawn grenade round — `mcv_spawn_rifle_grenade_ammo`

Server convar (default 1) — when off, `Initialize` empties the tube of *newly created*
weapons with `Secondary.Ammo == "smg1_grenade"` (`weapon_common/sh_deploy.lua:160-164`,
convar at `mcv/shared/sh_convars.lua:36-40`). "Only the newly created weapon's free round
is affected. Never clear the owner's shared ammo pool" (:160-161; BUGLIST:299-304).

### 6.4 UBGL mode and Clip1

While in launcher mode the primary magazine is untouched: idle, fire and reload all
divert to the M203 variants (`sh_gun.lua:16-19`, `sh_shoot.lua:38-41`, §2.3 gate 6), and
`ToggleUBGL` refuses to leave rifle-grenade mode from an empty rifle only
(`sh_ubgl.lua:31-34`).

### 6.5 M79 cartridge switching — the one ammo-type mutation

`mcv_m79_base` (shared.lua) overrides the ammo accessors so the reserve follows the
selected firemode cartridge (`FIREMODE_HE → "smg1_grenade"`, `FIREMODE_BUCKSHOT →
"buckshot"`, mapping at `mcv/shared/sh_common.lua:22-25`):

- `GetSelectedAmmo` (:23), `GetPrimaryAmmoType() = game.GetAmmoID(selected)` (:27-29),
  `Ammo1() = owner:GetAmmoCount(selected)` (:31-34).
- `ChangeFiremode` (:71-100) is a **reload in disguise**: unload first (`SetAmmo(Ammo1 +
  loaded, selected); SetClip1(0)` — the live round goes back to its pool, §3.4), rotate
  the firemode, then either `PlaySequence("reload_live")` (round was chambered) or
  `ACT_VM_RELOAD`, with the full reload start-effects block (third-person sound, gesture,
  `EmptyReload`, `Reloading`). Completion runs through the ordinary magazine branch.
- `RestoreClip` override (:102-112) — same math as the base but keyed to the *selected*
  ammo pool.
- Visuals: `DoBodygroupsWeapon` (:45-59) keeps the outgoing cartridge bodygroup until
  frame 50 (`50/30` s) of the reload; `DoEject` (:61-64) suppresses the brass eject when a
  live round is being swapped; `Think_Reload` (:66-69) clears `AmmoSwitchFrom` when the
  reload ends. BUGLIST:113/117/119 document the feature's history (the placeholder
  selector click was removed; "M79 lacks its ammo switching feature" at :253 was the
  original open item).

---

## 7. Interrupts, Interactions and Resets

### 7.1 Attack-cancel of a round-by-round reload — sh_think.lua:80-84

```lua
// weapons/mcv_base/sh_think.lua:80-84
// LastClip is the predicted clip count captured when this reload began.
// Existing shells must not let a top-up skip its first insert.
elseif self:GetReloading() and self.ShotgunReload and owner:KeyPressed(IN_ATTACK) and self:Clip1() > self:GetLastClip() then
    self:SetEndReload(true)
end
```

Only `ShotgunReload` weapons, only after ammo was actually added during this reload
(`Clip1 > LastClip` — BUGLIST:49: *"Per-shell reloads require ammo to have been added
during the current reload before attack can request cancellation"*), and it merely
*requests* the end: the current insert/pump animation still finishes, then `Think_Reload`
plays the finish stage (§2.10). Firing itself is impossible during the reload because
every stage holds the animation lock (`StillWaiting`), and the engine's `PrimaryAttack`
call is gated by the same lock (`sh_shoot.lua:9`).

### 7.2 Holster

`Holster` clears `Reloading` immediately (`weapon_common/sh_deploy.lua:90-92`) and
`CancelDeferred()` kills a pending `ReloadInsert` (:103/:113). It does **not** clear
`EndReload`/`EmptyReload`/`ReloadHand` — stale values are harmless (the next reload start
rewrites `EndReload`/`EmptyReload`; `ReloadHand` is only read inside the dual branch which
a fresh start resets at :102) and the clock reset (§7.6) wipes them on transitions.

### 7.3 Aiming, sway, crosshair

- `ScopeToggle(false)` at reload start; re-entry blocked while reloading
  (`mcv_base/sh_sights.lua:89`).
- Hip sway is steadied during a reload (a reload is not aiming at anything):
  `GetSwaySteady` returns 0 when `GetReloading()` (`sh_shoot.lua:283-288`) — networked,
  so shot and crosshair agree.
- Crosshair fades out over the reload and back in after the finishing/pump animation
  (`mcv/weapon_common/cl_hud.lua:413-427`, `CrosshairReloadAlpha` approach at 8×frame
  time; BUGLIST:273).

### 7.4 Burst, cycle, safety interplay

A runaway burst stops if a reload begins (`sh_think.lua:62`); the bolt/pump cycle waits
for trigger release and cannot start while `StillWaiting` holds (:112); safety toggle is
USE+WALK and can run mid-reload only between locked stages (a toggle locks 0.25 s,
`sh_gun.lua:125`).

### 7.5 Deploy

`Deploy` cancels deferred actions and resets latch state (`sh_deploy.lua:35-40`); the
reload flags themselves are left to expire naturally (a half-finished reload does not
resume). `NPC_Deploy` force-clears `Reloading` for NPCs (`sh_npc.lua:70`).

### 7.6 Clock resets — sh_clock.lua

Map transitions / Source saves can retain weapons across a clock replacement;
`ResetWeaponClock` (server-side, plus client visuals) cancels the deferred action, clears
`Reloading`/`EndReload`/`ReloadHand`, and re-derives `LastClip`/`EmptyReload` from the
actual clip (`sh_clock.lua:54-59`). Rollback detection samples only the global server
Think clock — *"Predicted SWEP CurTime moves backwards routinely during command replay
and must never trigger a reset"* (:99-101). The client is notified through the
`ClockResetSerial` NetworkVar (`weapon_common/shared.lua:246-252`).

---

## 8. Resupply — Boxes

### 8.1 The equipment-box weapon base (`mcv_equipment_box`)

Fields (`mcv_equipment_box/shared.lua:16-32`): `BoxKind` ("ammo"/"medic"), `HealAmount`
50, `AmmoMagazines` 1 (*"total magazine-equivalent budget shared across the inventory"*),
`GiveRange` 96, `DroppedEntity` "mcv_supply_box", sequence names
`give`/`self`/`throw`/`draw` (addressed **by name** — equipment models use activities
GMod doesn't define, `sh_anim.lua:100-102`), `GiveDelay` 0.4, `ThrowDelay` 0.3,
`Primary.Ammo "mcv_ammobox"`, `ClipSize -1`, `DefaultClip 3` — the box *is* its reserve
(GetRoundsLeft/TakeRound, §3.2).

Flow (`sh_box.lua`): `PrimaryAttack` (:188-206) — USE+attack drops the box
(`DropBox` :142-151, gesture `ACT_HL2MP_GESTURE_RANGE_ATTACK_GRENADE`, defers
`BoxDrop`); otherwise `GetGiveTarget()` traces 96 units for a living player
(:99-106) and `UseBox(target, "give", GiveDelay)` (:108-117) locks a sequence-length
action and defers `BoxUse`. `SecondaryAttack` self-serves (:208-214). `Reload` is an
empty stub (:216-217). `Deferred_BoxUse` (:119-132) applies the supply, `TakeRound(1)`,
plays `items/ammocrate_close.wav` / `items/medshot4.wav` (or `medshotno1` on refusal).
`Deferred_BoxEnd` (:134-140) draws the next box and `CheckEmpty` (:175-186) strips the
weapon via `timer.Simple(0, StripWeapon)` when the reserve hits zero, selecting the
first remaining weapon. `Deferred_BoxDrop` (:153-173) spawns the
`mcv_supply_box` entity (server) with a 350 u/s toss + 80 up + owner velocity, copying
`BoxKind`/`HealAmount`/`AmmoMagazines` onto it.

### 8.2 The supply planner — `MCV_AmmoSupplyPlan` / `MCV_ApplySupply` (sh_box.lua:13-97)

One shared magazine-equivalent budget, not a full magazine per gun (BUGLIST:312, 363):

1. **Pool discovery** (:14-34): for every carried weapon (skipping other boxes —
   "supplies never replenish supplies", :31; BUGLIST:363 fixed boxes refilling
   themselves), collect primary and secondary pools. Per pool: `per = max(GetMaxClip1(),
   1)` (a loose grenade or rocket costs a whole share), `cap = max(DefaultClip - clip,
   per)` — *the cap is the gun's spawn ammo* (BUGLIST:363) — further clamped by
   `game.GetAmmoMax`. Duplicate guns merge (`math.max`, :25-28).
2. **Candidates & rotation** (:36-47): only pools below their cap; sorted by ammo ID;
   the networked `SupplyCursor` (Int 12) rotates the starting pool so *"rockets receive
   a full share on later uses"* (:53-55).
3. **Budget split** (:50-58): each pool gets `per * budget/(count-i+1)` (rounded down),
   capped by `cap - have`; indivisible leftovers are distributed while the shared budget
   allows (:60-70).
4. **Application** (:75-97): `target:SetAmmo(have + amount, ammo)` per pool — **gated
   `if SERVER or target == LocalPlayer()`** (the owner's client predicts its own
   self-use; other players' grants are server-only). Medic kind: `SetHealth(min(+heal,
   max))` + `Extinguish`, refusing at full health. Returns whether anything was given
   plus the next cursor; the weapon stores it in `SupplyCursor` (:124-126).

### 8.3 The two box SWEPs

`mcv_ammobox_vc.lua` / `mcv_medicbox_vc.lua` — generated ports (26 lines each) setting
models, `BoxKind`, and their own reserve pool (`mcv_ammobox` / `mcv_medicbox`,
§3.1). Slot 4 equipment.

### 8.4 The dropped entity — `entities/mcv_supply_box.lua` (69 lines, server-driven)

`anim` entity on `base_anim`, `SIMPLE_USE`, VPhysics box. Fields: `BoxKind "ammo"`,
`HealAmount 50`, `AmmoMagazines 1`, `Uses 3`, `Lifetime 120` s, `TouchRadius 48`,
`TouchCooldown 3` (:9-15). `Think` (server, every 0.25 s) removes at `DieTime` and runs
`TouchTick` — `ents.FindInSphere` polling because *"trigger bounds on a physics prop
never fired for players"* (:31-32); per-player `NextTouch` cooldowns; each served player
routes into `Use`, which has its own 0.5 s global `NextUse` throttle (:43-57). `Use`
calls `MCV_ApplySupply` with the entity's cursor, plays the crate sound, spends a `Use`,
and `Remove()`s at zero. Sounds are `items/ammocrate_close.wav` / `items/medshot4.wav`
success, `items/medshotno1.wav` refusal — engine files, not the soundscript system.

### 8.5 Prediction notes

The give to *another* player is server-only by construction (§8.2 gate); the box weapon's
own attack/deposit flow is predicted (StillWaiting + deferred actions), and `TakeRound(1)`
is a replayable reserve write. `CheckEmpty`'s `StripWeapon` inside `timer.Simple(0)` is
server-side only (`CLIENT` returns at :176).

---

## 9. The Reload Trace Harness (`mcv_harness/reload_trace.lua`)

Client-only, never included by the addon loader — hard-gated on
`file.Exists("mcv_harness/enable.txt", "DATA")` (:1-2). Output root is per-port
(`mcv_harness/` on 27015, `mcv_harness/p<port>/` otherwise, :5-6). Cross-ref
`docs/support-systems.md` (harness chapter) for the framework this lives in.

- **`H.Start(name, third)`** (:8-43): asserts no active trace; snapshots the local
  player's active weapon and viewmodel; **wraps `wep.PlayAnimation` on the instance**
  (not the class). Every call records: the activity, the current `CUserCmd:CommandNumber`,
  `IsFirstTimePredicted()`, CurTime, FrameNumber, and before/after viewmodel internals —
  sequence, cycle, `m_nAnimationParity`, `m_flAnimTime` — plus the returned duration, the
  resulting `GetAnimLockTime()` and `Clip1()` (:15-29). This is exactly the evidence
  needed to prove the reload stage chain: activity order, per-stage durations/locks,
  prediction first-time-ness, and clip progression through the inserts.
- **Third-person probe** (:30-35): `ShouldDrawLocalPlayer → true` + a `CalcView` camera
  110 u behind / 30 u right — to watch the stretched reload gestures (§2.1) while
  tracing.
- **Sound capture** (:36-42): `EntityEmitSound` hook records any sound whose name
  contains "reload" emitted by the player, weapon or viewmodel, with prediction context.
- **`H.Stop()`** (:45-54): restores the original `PlayAnimation`, removes the hooks, and
  writes `results/<name>.reload.json` (`util.TableToJSON`).

Complementary: the generic prediction trace in `autorun/sh_mcv_harness.lua`
(`H.PtraceRecord`, :174-231) samples `clip1/clip2/ammo1/ammo2` + every NetworkVar after
each `Think`/`PrimaryAttack`/`SecondaryAttack`/`Reload`/`CaptureMovement` phase, matched
by command number — the reload-specific file above is the deep probe, this is the broad
one. Other reload-touching harnesses: `visual_trace.lua` (pose params + clip + reloading
per frame), `garand_m21.lua` (empty-pose/clip through a reload), `type67_timing.lua`
(hammer/EmptyReload timing), `hud_transition_tests.lua` (crosshair reload fade),
`clock_restore_tests.lua` (reload flags across clock resets).

---

## 10. BUGLIST Cross-Reference (reload & ammo items)

Verified-fixed items that shaped the current code (BUGLIST.md line numbers):

- :10 auto-reload preference (`mcv_auto_reload`, §2.2) · :49 per-shell cancel baseline
  (§7.1) · :117/:119/:253 M79 cartridge switching (§6.5) · :137 Shanxi deferred clip
  credit (§2.9) · :155 M72 LAW self-removal + infinite ammo (§2.8) · :189 unscoped vz.54
  stripper reload · :195 NPC ammo clamping (§3.5) · :223 NPC reload via engine events ·
  :259 bolt reopen on empty reload → `empty` pose at mag-in (§5.2) · :262 locked empty
  start (§2.3) · :273 crosshair reload fade (§7.3) · :299-304 spawn grenade convar
  (§6.3) · :310 reload-stage idle suppression (noidle, §2.3) · :312/:363 supply budget,
  cap = spawn ammo, boxes skip boxes (§8.2) · :344 dual-revolver empty reload fallback
  (§2.3) · :347 crossbow mag-in from the ammo event (§4.2) · :361 Gyrojet empty reload
  ends with the pump (§2.10) · :366 vz.24 clip reload not shell path (§4.5) · :367 M72
  full first-deploy reload · :374 MagInTime from `AE_CL_BODYGROUP_SET_TO_NEXTCLIP`
  (§4.2) · :383/:418 hybrid reload convar & donor models (the `mcv_hybrid_reload` convar
  and `INSERT_DONORS` porter machinery do **not** exist in this Part 1 snapshot — the
  current mechanism is the per-weapon `ShotgunReload`/`ShotgunAltReload` fields) · :386
  second-weapon/dual-wield unlock (`sh_akimbo.lua:1-9`). Still open: :193 C96 Carbine
  empty-reload hand/IK drift in the final 13 frames (model-level, no runtime change).

---

## 11. Translation-Layer Surface (ranked)

1. **`SWEP:Reload` is the only public reload entry — make it the adapter boundary.**
   Foreign bases call `self:Reload()`, `self:DefaultReload(ACT_VM_RELOAD)`, or play reload
   sequences directly. On MCV the whole contract is: gate → pick activity → locked
   `PlayAnimation` → state writes (§2.3). A translation layer should override `Reload` to
   translate foreign semantics into one call of the *original* MCV `Reload` flow, and
   **must intercept `DefaultReload`/`SendWeaponAnim`** — the engine's reload activity
   handling is completely unused and would fight `AnimLockTime`.
2. **No reload-duration fields exist.** Durations come from the model
   (`SequenceDuration`) and only `ShootAnimRate`-style multipliers could be mapped
   (`PlayAnimation`'s `mult`). Foreign `ReloadTime`/`ReloadAnimTime` configs cannot be
   honored except by scaling `mult` — which also scales the visual.
3. **The chamber model differs from most foreign bases.** Capacity = `ClipSize +
   Chamber`; empty reloads end at `ClipSize`, top-ups keep the chambered round (§3.2).
   Foreign "clipsize includes chamber" weapons must set `Chamber=0` and adjust
   `ClipSize`, or their counts drift by one.
4. **Round-by-round vs magazine is a static field, not a code path.** `ShotgunReload`
   selects the loop state machine; `ShotgunReloadRounds` sizes the credit;
   `ReloadInsertTime` defers it (§2.9). A foreign shotgun/Looper-reload SWEP should set
   these fields, never reimplement the loop.
5. **Ammo display is a model contract.** `ammo_fraction`(/1/2) pose params, the
   `MagInTime` family, `BulletBodygroups`/`BeltBodygroups` (§5). A foreign weapon that
   only writes `Clip1` will display correctly only if its model carries the pose
   parameters; the timing fields must be filled from the model's events or the counter
   visibly desyncs from the hands (BUGLIST:374).
6. **Third-person reload must go through `PlayReloadGesture`.** Calling
   `owner:DoReloadEvent()` or a plain gesture leaves it unstretched and un-looped; the
   timing data (ms) and the `RELOAD_LOOP`/`RELOAD_END` events are what the
   `DoAnimationEvent` hook stretches (§2.1). Foreign reload code that animates the
   *player* rather than the viewmodel needs its durations converted to the event scheme.
7. **First-person reload foley is not Lua.** It rides the viewmodel's animation events;
   `SoundReload`/`SoundEmpty`/`SoundNearlyEmpty`/`SoundSpecial*` are dead fields (§4.3).
   A translation layer must not promise `EmitSound`-based reload audio; it can only set
   `SoundReloadThirdPerson`/`SoundReloadLoopThirdPerson` and rely on the model's events.
8. **Cancel/interrupt semantics are narrow.** Only `ShotgunReload` + rounds-actually-added
   attack-cancel (§7.1); holster clears `Reloading` but leaves `EndReload`/`EmptyReload`
   stale-but-harmless (§7.2). Foreign "reload cancel" buttons should write
   `SetEndReload(true)` — never clear `Reloading` mid-stage, or the finish animation is
   skipped and `EmptyReload` may never clear.
9. **`DeferredActions` is append-only and networked by index.** `ReloadInsert` is index 6
   (`mcv_base/shared.lua:153`); a derived base adding deferred actions must append, or
   both realms read different names from the same number (`sh_timers.lua:9-12`).
10. **Reserve writes must be `SetAmmo`, never `GiveAmmo`, in predicted paths** (§1.3);
    `GetInfiniteAmmo()` is the sanctioned infinite-ammo override (§2.8). NPCs must stay
    on the engine's server-side reload event (§3.5).
11. **The UBGL tube is `Clip2` + `Secondary`**; launcher reloads are `Reload2`, auto-topped
    on mode entry (§6). Foreign underbarrel implementations should map onto the
    `Secondary` table rather than custom NW vars.
12. **Dry fire is silent**: `Clip1()<1` in `PrimaryAttack` just calls `Reload()` (§3.3).
    Foreign bases that play a dry-click will need to add it themselves before calling
    through — nothing in MCV will do it.

---

## 12. File Map

| File | Lines | Role |
|---|---|---|
| `weapons/mcv_base/sh_reload.lua` | 257 | the entire player reload state machine + ammo restore (§2) |
| `weapons/mcv_base/shared.lua` | 227 | reload/ammo field defaults, `DeferredActions` list (§4) |
| `weapons/mcv_base/sh_think.lua` | 141 | `ThinkWeapon`: calls `Think_Reload`/`Think_AutoReload`; attack-cancel (§1.4, §7.1) |
| `weapons/mcv_base/sh_vm.lua` | 305 | ammo display pipeline (§5) |
| `weapons/mcv_base/sh_shoot.lua` | 821 | dry-fire→reload, `TakePrimaryAmmo`, `EmptyReload` clearing via hammer (§3.3) |
| `weapons/mcv_base/sh_gun.lua` | 133 | `GetHUDAmmo` (§3.6) |
| `weapons/mcv_base/sh_ubgl.lua` | 90 | launcher reload paths (§6) |
| `weapons/mcv_base/sh_npc.lua` | 167 | NPC ammo clamp + no-op `NPC_Reload` (§3.5) |
| `weapons/mcv_base/sh_akimbo.lua` | 54 | dual-wield swap (capacity math consumer) |
| `weapons/mcv_m79_base/shared.lua` | 113 | cartridge-switch reload + ammo accessors (§6.5) |
| `mcv/weapon_common/shared.lua` | 401 | reload NetworkVars, `Primary/Secondary` defaults, `StillWaiting`, `TakeRound`, third-person sound dispatch (§1, §3) |
| `mcv/weapon_common/sh_anim.lua` | 152 | `PlayAnimation`/`PlaySequence` (anim doc §2) |
| `mcv/weapon_common/sh_timers.lua` | 57 | `Defer`/`DeferPending`/`ProcessDeferred` (§2.9) |
| `mcv/weapon_common/sh_think.lua` | 179 | Think pipeline: deferred processing, idle (§1.4) |
| `mcv/weapon_common/sh_deploy.lua` | 188 | holster clears reload; spawn grenade convar (§7.2, §6.3) |
| `mcv/weapon_common/sh_clock.lua` | 108 | clock resets clear reload state (§7.6) |
| `mcv/weapon_common/cl_hud.lua` | 726 | crosshair reload fade (§7.3) |
| `mcv/shared/sh_animevents.lua` | 65 | timed reload gestures + `MCV.ReloadAnimOffsets` (§2.1) |
| `mcv/shared/sh_common.lua` | 176 | firemode→ammo mapping, registered ammo types (§3.1, §6.5) |
| `weapons/mcv_equipment_box/shared.lua` + `sh_box.lua` | 37 + 226 | supply boxes: budget planner and application (§8) |
| `weapons/mcv_ammobox_vc.lua`, `weapons/mcv_medicbox_vc.lua` | 26 each | the two box SWEPs (§8.3) |
| `entities/mcv_supply_box.lua` | 69 | dropped supply entity (§8.4) |
| `mcv_harness/reload_trace.lua` | 54 | reload instrumentation probe (§9) |
| `autorun/sh_mcv_harness.lua` | 559 | generic prediction trace incl. clip/ammo sampling (§9) |
