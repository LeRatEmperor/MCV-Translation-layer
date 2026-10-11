# MCV Base — Animation System (Exhaustive Audit)

> Audited from `reference/mcv/lua/` @ upstream commit `06f4a24b4db99666c3ac28c7b28f9c44242a48e5` (tacrp/Military-Conflict--Vietnam-SWEPs).
> All file:line citations are relative to `reference/mcv/`.
>
> **Purpose of this document**: the MCV-Translation-layer must let SWEPs whose models animate
> through **activity calls and sequence-name calls** run flawlessly on the MCV base. This
> document maps every place MCV consumes or produces model animation, so the translation layer
> knows exactly which seams to hook.

---

## 1. Architecture Overview

MCV's animation is built on **two and a half channels**:

| Channel | Mechanism | Drives | Realm |
|---|---|---|---|
| **Discrete actions** | Viewmodel sequences played via `SWEP:PlayAnimation(act, ...)` / `SWEP:PlaySequence(name, ...)` → `Entity:SendViewModelMatchingSequence(seq)` | draw, holster, fire, reload, cycle, firemode switch, bayonet, bipod, bash | Shared (predicted) |
| **Continuous state** | Viewmodel **pose parameters** + bodygroups written every tick/frame by `SWEP:DoBodygroups` | movement blend, sight blend, ammo counters, hammer, bolt lock-back, akimbo recoil | Shared (Think) + client (visual) |
| **Third person** | Player **gesture slots** (`GESTURE_SLOT_ATTACK_AND_RELOAD`) driven by `DoAnimationEvent` with millisecond timing payloads | shoot/reload gestures on the player model | Shared |

The defining characteristic (confirming the earlier audit): **activities are used only to
*select* a sequence** — `PlayAnimation` immediately resolves the activity to a sequence index
via `Entity:SelectWeightedSequence(act)` and then drives that sequence manually. There is
**no reliance on the engine's activity state machine**: no `SendWeaponAnim`, no
`SetAnimation`, exactly one `ResetSequence`-family call in the whole codebase (it is in a
dev harness, not the base). Weapon *state* — walking, aiming, ammo level, hammer position —
is expressed entirely through pose parameters that the ported models blend internally with
their own layering (walklayer / runlayer / walklayerironsight / SlidePosition /
BoltshootMovement etc.).

### 1.1 Why this matters for the translation layer

A traditional SWEP model animates through activities the *engine* plays
(`SendWeaponAnim(ACT_VM_PRIMARYATTACK)` → engine picks sequence, engine advances cycle,
engine fires anim events on its own clock). On MCV:

1. The **sequence is selected in Lua** (`PlayAnimation`/`PlaySequence`) — so a translated
   weapon's activity calls can be intercepted at exactly one API pair.
2. The **cycle is advanced in Lua on a predicted timeline**
   (`UpdateViewModelAnimation` reconstructs cycle from `AnimationStart`/`AnimationDuration`
   networked floats) — not by the engine's internal anim time.
3. The **model must carry MCV pose parameters** (`player_movement`, `ironsight`,
   `ammo_fraction`, `empty`, `hammerpos`, ...) or the continuous state silently does nothing.
   A model without them will still play sequences, but will not walk-blend, show ammo, or
   lock its bolt back.
4. Sound foley is expected to ride **native model animation events** (soundscript names
   baked into the MDL event list), with only eject handled in Lua.

---

## 2. The Playback API — `mcv/weapon_common/sh_anim.lua`

This 151-line file is the **single entry point for all viewmodel sequence playback**. Every
base (guns, melee, throwable, placeable, equipment) plays animations through it.

### 2.1 `SWEP:PlayAnimation(act, mult, lock, noidle)` — sh_anim.lua:84

```lua
function SWEP:PlayAnimation(act, mult, lock, noidle)
    mult = mult or 1
    lock = lock or false
    noidle = noidle or false
    local vm = self:GetOwner():GetViewModel()
    if !IsValid(vm) then return end
    local seq = vm:SelectWeightedSequence(act)
    if seq == -1 then print("INVALID ACT " .. act) return end
    return applySequence(self, vm, seq, mult, lock, noidle)
end
```

- **`act`** — a GMod `ACT_VM_*` activity. Resolved to a sequence index with
  `Entity:SelectWeightedSequence` (sh_anim.lua:93). If the model lacks the activity, the
  call **prints `INVALID ACT <n>` to console and returns nil** — callers must tolerate a nil
  duration (sh_shoot.lua:126-128: *"PlayAnimation returns nothing when the model lacks the
  activity; never let that stall or error the fire loop"*).
- **`mult`** — playback-rate multiplier. `mult < 0` **plays the sequence in reverse**
  (sh_anim.lua:4-7). Used e.g. by `ChangeFiremode` to play the selector animation backwards
  when wrapping to firemode 1 (sh_shoot.lua:789-791), and by scope adjustment
  (ACT_VM_FIDGET at -1, sh_shoot.lua:752).
- **`lock`** — when true, sets `AnimLockTime = CurTime() + duration`; `SWEP:StillWaiting()`
  (weapon_common/shared.lua:356) then blocks attacks/reloads until the animation finishes.
- **`noidle`** — when true, sets `NextIdle = math.huge` so the idle loop does not restart
  when the animation ends; the final frame is held instead (used for shotgun reload start,
  akimbo holster swap, bayonet charge loop).
- **Returns** the sequence duration in seconds (already scaled by `mult`), or nil.

### 2.2 `SWEP:PlaySequence(name, mult, lock, noidle)` — sh_anim.lua:103

Identical, but resolves a **sequence by name** through `MCV.CachedSequence(vm, name)`
(`Entity:LookupSequence` behind a per-model cache — see §6.2). Fails with
`INVALID SEQUENCE <name>` and returns nil.

The comment at sh_anim.lua:100-102 is directly relevant to the translation layer:

> *Same, by sequence name. The game's equipment models use activities GMod does not define
> (ACT_VM_SLASH, ACT_VM_PLANT, ACT_VM_GIVE...), but their sequence names are consistent per
> weapon type, so the equipment bases address them directly.*

So **sequence-name addressing is already a first-class citizen** on the equipment bases
(melee/throwable/placeable), and the bayonet/charge sequences on the gun base use it too
(§8.8).

### 2.3 `applySequence` — the shared core (sh_anim.lua:1-39)

```lua
local function applySequence(self, vm, seq, mult, lock, noidle)
    local reverse = false
    if mult < 0 then reverse = true mult = -mult end
    local time = vm:SequenceDuration(seq) * mult
    if self.SetAnimationStart then
        self:SetAnimationStart(CurTime())
        self:SetAnimationDuration(reverse and -time or time)
    end
    if self.ScheduleHammerRelease then
        self:ScheduleHammerRelease(vm, seq, time, reverse)
    end
    vm:SendViewModelMatchingSequence(seq)
    vm:SetPlaybackRate((reverse and -1 or 1) / mult)
    vm:SetCycle(reverse and 1 or 0)
    if lock then self:SetAnimLockTime(CurTime() + time)
    else self:SetAnimLockTime(0) end
    if !noidle then self:SetNextIdle(CurTime() + time)
    else self:SetNextIdle(math.huge) end
    return time
end
```

Step by step:

1. **Duration** = `vm:SequenceDuration(seq) * mult` (sh_anim.lua:9).
2. **Networked timeline stamps**: `AnimationStart = CurTime()` and
   `AnimationDuration = ±time` (negative = reverse). These two NetworkVars are what the
   client's render path later reconstructs the visual cycle from (§3). The `if
   self.SetAnimationStart` guard exists because *Lua refresh cannot add datatable accessors
   to weapons that already exist* (sh_anim.lua:10-11) — a live-reload survival check.
3. **Hammer release scheduling** (§5.6) — only if the weapon defines it.
4. **`vm:SendViewModelMatchingSequence(seq)`** — the actual sequence switch. This is the
   prediction-safe variant of `ResetSequence` for viewmodels: it matches the sequence on
   both realms during prediction and (per the comment at sh_anim.lua:20-21) *"reconstructs
   animation state on every prediction pass. The render path recovers the final command's
   timeline after packet/sequence processing."*
5. **`vm:SetPlaybackRate(±1/mult)`** and **`vm:SetCycle(reverse and 1 or 0)`** — playback
   rate is set so the *sequence itself* runs at the requested speed; cycle starts at 0
   (forward) or 1 (reverse).
6. **`AnimLockTime` / `NextIdle`** — action lockout and idle-restart bookkeeping.

### 2.4 Idle — `SWEP:Idle()` (sh_anim.lua:119-129)

```lua
function SWEP:Idle()
    local seq = self:IdleSequence()
    if seq and self:HasSequence(seq) then
        self:PlaySequence(seq, 1, false, false)
    else
        self:PlayAnimation(self:IdleActivity(), 1, false, false)
    end
    self:SetReady(true)
end
```

Called from `Think` whenever `GetNextIdle() <= CurTime()` (weapon_common/sh_think.lua:21-23).
`IdleSequence()` takes **precedence** over `IdleActivity()` when it returns a non-nil name
the model has — this is how the bayonet charge holds its loop pose (§8.8).

Gun-base `IdleActivity()` state selection (mcv_base/sh_gun.lua:11-25):

| State | Idle activity |
|---|---|
| Safety on | `ACT_VM_IDLE_LOWERED` |
| Grenade launcher mode | `ACT_VM_IIDLE_M203` (UBGL) or `ACT_VM_IDLE_M203` (rifle grenade) |
| Bipod deployed | `ACT_VM_DEPLOY` |
| Normal | `ACT_VM_IDLE` |

### 2.5 Capability queries — sh_anim.lua:131-151

| Function | Definition | Notes |
|---|---|---|
| `SWEP:HasAnimation(act)` | `vm:SelectWeightedSequence(act) != -1` | `nil` act → false. The canonical "does the model have it" check, used before optional animations (e.g. `ACT_VM_READY` at deploy, sh_deploy.lua:48; revolver firemode anims, sh_shoot.lua:728-741; bayonet attach/detach, sh_bash.lua:144/155) |
| `SWEP:HasSequence(name)` | `MCV.CachedSequence(vm, name) != -1` | Sequence-name capability check |
| `SWEP:SequenceLength(name)` | `vm:SequenceDuration(seq)` | 0 when missing |

Both capability checks **must** be used by the translation layer's fallback logic: MCV's own
pattern is always *check → play → tolerate nil*.

---

## 3. Timing & Prediction Model

The hardest part of MCV's animation system is that the viewmodel cycle is **reconstructed,
not engine-driven**, so that it survives Source's prediction (command replay, tick-base
correction) without visual glitches.

### 3.1 `SWEP:GetViewModelTime()` — sh_anim.lua:43-49

```lua
function SWEP:GetViewModelTime()
    if CLIENT and !game.SinglePlayer() and self:GetOwner() == LocalPlayer()
       and GetPredictionPlayer() != self:GetOwner() then
        local tick = engine.TickInterval()
        return self:GetOwner():GetInternalVariable("m_nTickBase") * tick + CurTime() % tick
    end
    return CurTime()
end
```

Outside prediction, the local viewmodel runs on **the final predicted tick plus the
fractional render tick** — i.e. the client's viewmodel leads/lags `CurTime` by the
in-flight fraction of a tick. This is the clock all visual-only animation math uses
(`DoBodygroupsWeapon` visual mode, §5).

### 3.2 `SWEP:UpdateViewModelAnimation(vm)` — sh_anim.lua:51-79

Runs **outside prediction** (guarded by `GetPredictionPlayer() != owner`), from
`GetViewModelPosition` just before the viewmodel's bones are built (§10.2):

```lua
local duration = self:GetAnimationDuration()
if duration == 0 then return end
local start = self:GetAnimationStart()
local progress = math.max(self:GetViewModelTime() - start, 0) / math.abs(duration)
local sequence = vm:GetSequence()
-- (monotonic-progress guard for clock correction, see below)
if MCV.SequenceLoops(vm, sequence) and self:GetNextIdle() != math.huge then
    progress = progress % 1
else
    progress = math.min(progress, 0.999)
end
vm:SetSaveValue("m_flAnimTime", start)
vm:SetCycle(duration < 0 and 1 - progress or progress)
```

Key behaviors:

- **Progress** = elapsed-viewmodel-time ÷ |duration|, clamped ≥ 0. Reverse animations
  (`duration < 0`) map to `cycle = 1 - progress`.
- **Looping sequences** (`MCV.SequenceLoops`, §6.3) wrap `progress % 1` — but only when the
  idle timer is live (`NextIdle != math.huge`); a looping no-idle stage (bayonet charge
  loop, shotgun reload start) *holds its end frame* instead of wrapping.
- **Monotonic guard** (sh_anim.lua:59-67): if the same (vm, sequence, start, duration) is
  already being drawn, the new progress is `max(new, previous)` — *"Clock correction can
  move tick base back without changing the animation. Hold the visual until it catches up;
  never replay frames already shown."* Stored in `self.VisualAnimation`.
- **`vm:SetSaveValue("m_flAnimTime", start)`** — overrides the engine's sequence-receive
  proxy timestamp, because *"the engine's sequence receive proxy can replace its timestamp
  after the shot, skipping its first frames"* (sh_anim.lua:73-76).

This is the machinery a translation layer must not fight: **any code that manually sets
viewmodel cycle or anim time will be overwritten here every frame.**

### 3.3 The animation NetworkVars (weapon_common/shared.lua:196-228)

```lua
self:NetworkVar("Float", 17, "AnimationStart")
self:NetworkVar("Float", 18, "AnimationDuration") // negative for reverse playback
self:NetworkVar("Float", 0,  "AnimLockTime")
self:NetworkVar("Float", 1,  "NextIdle")
self:NetworkVar("Float", 7,  "LastShotTimeR")   -- akimbo pose-recoil clocks
self:NetworkVar("Float", 8,  "LastShotTimeL")
self:NetworkVar("Float", 14, "HammerReleaseTime")
self:NetworkVar("Float", 9,  "ActionStart")     -- cycle clip pose / equipment state
self:NetworkVar("Float", 10, "DeferredTime")    -- deferred action deadline
```

All weapon bases share **one** datatable layout (weapon_common/shared.lua:194-195: *"All
networked state lives here so every derived base shares one layout... Derived bases must not
redefine SetupDataTables"*). The translation layer inherits this by deriving from `mcv_base`
(or the equipment bases) — it **cannot add its own NetworkVars** without colliding, and
should instead use plain Lua state or NW2 vars.

### 3.4 Clock resets — `mcv/weapon_common/sh_clock.lua`

Map transitions / Source saves replace the clock while retaining weapons.
`ResetWeaponClock` (sh_clock.lua:29-79) clears all pending animation state
(`AnimLockTime=0`, `NextIdle=now`, `AnimationStart=now`, `AnimationDuration=0`,
`VisualAnimation=nil`, ...). Triggers:

- `SWEP:OnRestore` (sh_clock.lua:81-83),
- `InitPostEntity` (all entities, sh_clock.lua:90),
- `PlayerSpawn` with `transition` (server, sh_clock.lua:93-98),
- server-side **clock rollback watchdog**: server `Think` sampling global `CurTime`; a jump
  backwards of more than 2 ticks resets everything (sh_clock.lua:101-106). The comment is
  explicit that predicted SWEP CurTime must never trigger it.
- A `ClockResetSerial` NetworkVar + client-side `NetworkVarNotify` (shared.lua:248-252)
  makes the client clear its visual caches (`ResetClockVisuals`, sh_clock.lua:3-27) when the
  server resets — this is the escape hatch that keeps `VisualSpeed`, `VisualSightRaw`,
  `VisualAnimation` etc. from fighting a reset server.

### 3.5 Deferred actions — `mcv/weapon_common/sh_timers.lua`

Delayed follow-ups (ammo transfer on reload insert, bayonet detach at end of animation,
akimbo/launcher model swap mid-holster, bayonet charge loop/hit) run through a
**prediction-safe deferred system** instead of `timer.Simple`:

- A class declares `SWEP.DeferredActions = {"BayonetOff", "AkimboSwap", ...}` (fixed order,
  append-only — mcv_base/shared.lua:151-153). The **index** into that list is networked
  (`DeferredAction` Int), the deadline in `DeferredTime` (Float).
- `SWEP:Defer(name, delay)` queues one action (one pending at a time; multi-stage actions
  re-queue from their handler).
- `SWEP:ProcessDeferred()` runs in `Think` (weapon_common/sh_think.lua:19) and calls
  `self["Deferred_" .. name]` when due.
- The file's header comment (sh_timers.lua:1-15) explains why: queued closures cannot
  predict; this shape ("a deadline in a networked float... the index is what is networked")
  replays correctly on both realms.

---

## 4. The Pose Parameter Engine

`SWEP:DoBodygroups` is the **heart of the continuous-state channel** and the reason MCV
models "barely use activity calls". It runs from two places (weapon_common/sh_vm.lua:1-10):

1. **`Think`** (server + predicting client, weapon_common/sh_think.lua:17) with deterministic
   gameplay values. The header comment explains why the server must write them:
   *"Viewmodel bodygroups and pose parameters are networked from the server, so if the
   server never wrote them the client would keep receiving zeros that fight what it draws
   (visible as a flickering 'ghost' viewmodel, worst in singleplayer where the client does
   not predict)."*
2. **`GetViewModelPosition`** (non-predicted client, weapon_common/sh_vm.lua:205-211) with
   `visual = true`, before bone setup — because *"Pose changes in PreDrawViewModel can
   arrive after bone setup."*

```lua
function SWEP:DoBodygroups(vm, visual)
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    vm = vm or owner:GetViewModel()
    if !IsValid(vm) then return end
    local sa, speed
    if visual then
        sa = self:GetSightAmountVisual()
        speed = self:GetSpeedVisual()
    else
        sa = self:GetSightAmount()
        speed = self:GetSpeed()
    end
    vm:SetBodyGroups(self.BodyGroups)
    vm:SetPoseParameter("player_movement", self:GetMovementPose(speed, sa))
    self:DoBodygroupsWeapon(vm, visual, sa, speed)
end
```

`DoBodygroupsWeapon` is a per-base hook (weapon_common/shared.lua:339); the gun base
implements it in `mcv_base/sh_vm.lua:12` (§5). Equipment bases extend or replace it (e.g.
M79 adds `ammo_fraction` override + "ammo" bodygroup, m79_base/shared.lua:45-59).

### 4.1 Complete pose-parameter catalogue

Every pose parameter MCV writes to the viewmodel, ever:

| Pose parameter | Writer | Value semantics | Model layers that consume it |
|---|---|---|---|
| `player_movement` | `DoBodygroups` (weapon_common/sh_vm.lua:32) | game speed units, ~0 (still) → ~245 (sprint); sighted walking uses a reduced swing (§4.2) | walklayer / runlayer / nearwall locomotion layers on **every** game viewmodel |
| `ironsight` | `DoBodygroupsWeapon` (mcv_base/sh_vm.lua:179) | `sa ^ 3` — cubed sight blend | aim layers, walklayerironsight (sighted walk), sight transitions |
| `ammo_fraction` | `DoBodygroupsWeapon` (mcv_base/sh_vm.lua:87-109) | `MagFraction(shown, clipsize)` — magazine fill fraction, **chambered round excluded** | magazine bullet-counter knots (the PPK "counter"), clip-fed hand rounds |
| `ammo_fraction1` | akimbo branch (mcv_base/sh_vm.lua:132) | right gun's magazine fraction | dual models' right-gun counter |
| `ammo_fraction2` | akimbo branch (mcv_base/sh_vm.lua:133) + `CycleAmmoPose2` (mcv_base/sh_vm.lua:79-81) | left gun's fraction; on single guns with `CycleAmmoPose2`, the cycle-variant selector set from clip at bolt pull frame 1 | dual left-gun counter; cycle animation variant selection |
| `empty` | `DoBodygroupsWeapon` (mcv_base/sh_vm.lua:170-177) | 0 = rounds left, 1 = empty (akimbo: 0 / 0.5 right-empty / 1 both-empty) | **SlidePosition / BoltshootMovement** layers blend 0.6→1 toward locked-back bolt |
| `hammerpos` | `DoBodygroupsWeapon` (mcv_base/sh_vm.lua:157-163) | `shouldhammer and 0 or 1` (0 = hammer back); `InvertAnimationHammer` flips | hammer/locking-layer pose |
| `recoil_r` / `recoil_l` | akimbo pose recoil (mcv_base/sh_vm.lua:181-186) | 0 = frame 0 of the hand's shoot animation, 1 = at rest; `(now - LastShotTimeR/L) / AkimboRecoilTime` clamped | dual-wield per-hand recoil layers |
| `revolver_firemode_pose` | `DoBodygroupsWeapon` (mcv_base/sh_vm.lua:209-227) | 0 = single action, 0.5 = double action, 1 = fan fire (akimbo: 0/1 for SA/DA) | revolver hammer/grip pose for firemode |
| `ammo_fraction` (M79) | m79 override (m79_base/shared.lua:56) | during cartridge switch reload: `LastClip > 0 and 1 or 0` | break-action cartridge presence |

`MagFraction` (mcv_base/sh_vm.lua:6-10):

```lua
function SWEP:MagFraction(count, per)
    per = per or self.Primary.ClipSize
    if per <= 0 then return 0 end
    return math.Clamp(count - self.Primary.Chamber, 0, per) / per
end
```

The chambered round is excluded from the magazine fraction on purpose (the comment cites the
PPK's knot pair per magazine round).

### 4.2 `GetMovementPose(speed, sa)` — weapon_common/sh_think.lua:63-86

The single most important continuous function — converts predicted movement speed into the
game's own pose units:

```lua
SWEP.SpeedSprint = 273;  SWEP.SpeedRun = 100;  SWEP.SpeedWalk = 25
SWEP.SpeedSprintThreshold = 150;  SWEP.SpeedAcceleration = 750
SWEP.MovementPoseWalk = 148   -- run-layer blend start, per class (rifles 148, M60 106, PK 99, LPO-50 80)
SWEP.MovementPoseSprint = 245 -- model's top
SWEP.MovementPoseWalkMax = 0.95
SWEP.MovementPoseSighted = 130
SWEP.SightedSwayFraction = 0.2
```

- Walking: `pose = speed / SpeedRun * min(SpeedRun, MovementPoseWalk * 0.95)` — capped
  *just under* the model's run-layer start so *"nothing in between blends into the run layer
  while merely walking"* (the comment at sh_think.lua:45-53 documents the PK/flamethrower
  bug this fixed).
- Sprinting: lerps from the walk value up to `MovementPoseSprint`.
- Sighted: `sighted = min(speed/SpeedRun, 1) * MovementPoseSighted * SightedSwayFraction`
  — the models' walklayerironsight fades in on `ironsight` while walklayer/runlayer fade to
  their idle row.
- **Safe movement clamp** (sh_think.lua:77-84): if the safe-movement convar is on and the
  model is not in `MCV.SafeMovementModels` (grip-corrected nearwall locomotion),
  `pose = Clamp(pose, 0, 86)`.
- Final: `Lerp(sa, pose, sighted)` — the sight amount crossfades hip pose to sighted pose.
- Per-weapon overrides: `MovementPoseWalk` / `MovementPoseSprint` / `MovementPoseSighted`
  (e.g. M38: 141 / 236 / 130, mcv_m38.lua:75-77). These are read off the model's runlayer
  blend by the porting pipeline (`port_weapon.anim_timing`).

The speed that feeds this comes from `Think_Speed` (sh_think.lua:145-152): the blend is the
predicted state itself, integrated one tick at a time into the `Speed` NetworkVar
(`SpeedAcceleration` units/sec) — never a stamped curve, so prediction errors heal in one
tick (comment at sh_think.lua:104-110). The client's drawn value chases it at a bounded
rate (`GetSpeedVisual`, sh_think.lua:112-143, `VisualSpeedCatchUp = 0.08`).

### 4.3 The sight blend — mcv_base/sh_sights.lua

Mirror-image design to speed:

- `SightAmountRaw` (NetworkVar Float 5) is integrated one tick at a time by `Think_Sights`
  (sh_sights.lua:101-147) toward 0/1 at `TickInterval() / GetSightTime()` where
  `GetSightTime() = 0.2 / IronsightSpeedScale`.
- `GetSightAmount()` = eased raw (`SightEase = "InOutSine"`, any [0,1]→[0,1] function or
  `math.ease` name, sh_sights.lua:6-21) — the **gameplay** value (spread, recoil, hold type).
- `GetSightAmountVisual()` (client, sh_sights.lua:40-81) — a frame-advanced visual copy with
  `VisualSightCatchUp = 0.08`, used for the viewmodel/pose params/HUD. On the server it is
  the same as the gameplay value.
- `ironsight` pose param receives `sa ^ 3` (cubed — snappier into the aim pose).
- Intent vs state: `Ironsight` = player input (ScopeToggle), `Sighted` = actually up
  (not sprinting, bipod rules met). Think_Sights resolves intent → state, plays the
  ironsights foley sound on transitions.

### 4.4 `DoBodygroupsWeapon` — the gun implementation (mcv_base/sh_vm.lua:12-228)

This 215-line function is the full continuous-state renderer. Ordered logic:

1. **Snapshot only this invocation** (line 13-15) — everything is re-derived from restored
   engine state; nothing lives in an ordinary Lua cache across calls.
2. **Reload-progress math** (lines 17-36): `reloadprogress = vm:SequenceDuration() -
   (GetAnimLockTime() - now)`; `displayRoundsToLoad` once past `MagInTime`/`MagInTimeEmpty`;
   `magOut` between `MagOutTime` and mag-in. Shotgun (round-at-a-time) reloads show simply
   what is loaded and only go up.
3. **Shown-rounds adjustments** (lines 38-75):
   - `pendingInsert` (clip-fed rifle): while `Deferred "ReloadInsert"` is pending, the hand
     shows the rounds it is carrying (`shown + ShotgunReloadRounds`, capped).
   - `CycleClipPoseTime` (harmonica-magazine guns): after a shot the counter holds the old
     count until the cycle animation's own refresh point (`ActionStart + CycleClipPoseTime`,
     the game's `AE_WPN_CLIP_TO_POSEPARAM` event); `ActionStart` is networked precisely so
     both realms agree (comment at lines 54-63).
   - Shotgun insert: if the current sequence is the insert activity and
     `InsertClipPoseTime` has not elapsed, the counter holds the pre-insert count.
4. `ammo_fraction2` from clip when `CycleAmmoPose2` (cycle variant picked by post-shot count).
5. **The ammo_fraction writes** (lines 87-109): magazine-in-transit shows what the new
   magazine carries (`MagInClip` clip-fed vs fresh-mag), mag-out shows 0, otherwise the
   shown count.
6. **Akimbo per-gun counters** (lines 111-134): shared count splits floor/ceil (right gun
   fires on even count); per-gun swap cues from `AkimboMagInTimes[activity]` (times read
   from the dual model's next-clip events per activity).
7. **`BulletBodygroups`** (lines 136-148): numeric keys are round-count thresholds — sparse
   (not a list!) so `pairs` + `isnumber(key)` guard; bodygroup set when `i > shown`.
8. **`BeltBodygroups`** (lines 151-155): belt segments hidden when zero rounds shown.
9. **`hammerpos`** (lines 157-163): `shouldhammer = GetNeedCycle() or GetEmptyReload() or
   ((ShotgunReload or !reloading) and clip == 0)`, flipped by `InvertAnimationHammer`.
10. **`empty`** (lines 165-177): drops the moment the new magazine is in (`MagInTimeEmpty`,
    "as the game does at its NEXTCLIP event"); akimbo three-state.
11. **`ironsight`** = `sa ^ 3` (line 179).
12. **Akimbo pose recoil** (lines 181-186): `recoil_r/l` from `LastShotTimeR/L` clocks.
13. **Bayonet / grenade-launcher / grenade bodygroups** (lines 188-207): bayonet by
    `GetBayonet()`; grenade in the tube when `Clip2() > 0` or reload past `MagInTimeGrenade`.
14. **`revolver_firemode_pose`** (lines 209-227) when `RevolverFiremodePose`.

### 4.5 World-model bodygroups — mcv_base/sh_think.lua:8-48

The **weapon entity's** bodygroups (bayonet / grenade / bipod / belt groups found by name)
are updated in `Think_WorldBodygroups` so the dropped weapon and drawn player copies carry
them (bodygroups are engine-predicted fields — update both realms). `WorldModelBodyGroups`
(weapon_common/shared.lua:84-89) remaps the viewmodel bodygroup string onto the world
model's own bodypart order (written by the porting pipeline by matching bodypart names).

---

## 5. What the Models Must Contain

This is the contract between the Lua base and the ported MDLs — the part a foreign model
will not satisfy without translation.

### 5.1 Activities the base requests (complete inventory)

Grep-verified complete list of `ACT_VM_*` / `ACT_*` activities passed to `PlayAnimation` /
`HasAnimation` / idle selection:

**Lifecycle** — `ACT_VM_READY` (deploy from ready-rack, sh_deploy.lua:48-49),
`ACT_VM_DRAW` (DeployAnimation, mcv_base/sh_gun.lua:32; akimbo swap-in
sh_akimbo.lua:52), `ACT_VM_HOLSTER` (holster sh_deploy.lua:114; akimbo/launcher swap
sh_akimbo.lua:17, sh_ubgl.lua:36), `ACT_VM_IDLE` (default idle),
`ACT_VM_IDLE_LOWERED` (safe idle), `ACT_VM_IDLE_TO_LOWERED` / `ACT_VM_LOWERED_TO_IDLE`
(safety toggle, mcv_base/sh_gun.lua:128/131), `ACT_VM_FIDGET` (scope adjustment).

**Firing** — `ACT_VM_PRIMARYATTACK`, `ACT_VM_SECONDARYATTACK` (akimbo left-hand shot),
`ACT_VM_PRIMARYATTACK_1` (fan fire), `ACT_VM_PRIMARYATTACK_2` / `_3` (delayed DA shot
right/left), `ACT_VM_PRIMARYATTACK_EMPTY`, `ACT_VM_SHOOTLAST` (last-round special),
`ACT_VM_PRIMARYATTACK_DEPLOYED` (bipod), `ACT_VM_RECOIL1` (volley),
`ACT_VM_HAULBACK` (double-action hammer prepare; akimbo right), `ACT_VM_PULLPIN`
(akimbo left DA prepare), `ACT_VM_RELOAD_INSERT_PULL` (**the bolt/pump cycle** —
sh_think.lua:119).

**Reload** — `ACT_VM_RELOAD`, `ACT_VM_RELOADEMPTY`, `ACT_VM_RELOAD_DEPLOYED`,
`ACT_VM_DEPLOYED_RELOAD_EMPTY` (bipod), `ACT_VM_RELOAD_INSERT` / `ACT_VM_RELOAD_INSERT_EMPTY`
(shotgun/clip insert), `ACT_VM_RELOAD_END` (akimbo hand swap), `ACT_VM_RELOAD_END_EMPTY`
(akimbo finish right), `ACT_VM_RELOAD2` (akimbo left-gun insert),
`ACT_SHOTGUN_RELOAD_START` / `ACT_SHOTGUN_RELOAD_FINISH` / `ACT_SHOTGUN_PUMP`,
`ACT_VM_RELOAD_M203` (launcher reload), `ACT_VM_MISSRIGHT` / `ACT_VM_MISSRIGHT2`
(akimbo partial reloads).

**Launcher mode** — `ACT_VM_DRAW_M203`, `ACT_VM_DRAWFULL_M203`, `ACT_VM_IDLE_M203`,
`ACT_VM_IIN_M203` / `ACT_VM_IOUT_M203` (UBGL toggle), `ACT_VM_IIDLE_M203`,
`ACT_VM_ISHOOT_M203`.

**Bipod** — `ACT_VM_DEPLOYED_IN` / `ACT_VM_DEPLOYED_OUT` (deploy/fold),
`ACT_VM_DEPLOY` (deployed idle).

**Firemode** — `ACT_VM_FIREMODE` (also revolver to-fan), `ACT_VM_IFIREMODE` (to DA),
`ACT_VM_DIFIREMODE` (to SA), `ACT_VM_DFIREMODE` (bipod selector).

**Melee-ish** — `ACT_VM_HITCENTER` (bash), `ACT_VM_HITLEFT` (bayonet swing),
`ACT_VM_ATTACH_SILENCER` / `ACT_VM_DETACH_SILENCER` (bayonet fix/remove).

### 5.2 Sequences addressed by name (complete inventory)

| Sequence name | Used by | File |
|---|---|---|
| `ChargeStart` / `ChargeLoop` / `ChargeStab` | bayonet charge state machine | mcv_base/sh_bayonet_charge.lua:8-10 |
| `bash_bayonet`, `slash_bayonet` | bayonet bash swings (shared-random pick) | mcv_base/sh_bash.lua:6 |
| `reload_live` | M79 cartridge switch with a round loaded | m79_base/shared.lua:90 |
| equipment sequences (`ACT_VM_SLASH` etc. don't exist in GMod — melee/throwable/placeable address by name) | equipment bases | sh_anim.lua:100-102 comment |

### 5.3 Pose parameters & bodygroups the models must carry

See §4.1. Additionally the models carry **named bodygroups**: `bayonet`, `grenade`,
`bipod`, `belt` (world models, mcv_base/sh_think.lua:13-16), `ammo` (M79), arbitrary
bullet-counter groups (`BulletBodygroups` indices).

### 5.4 Attachments

- `muzzle` — muzzle flash particles/light, physical-muzzle projection (harness tracks
  `muzzle`, `eject`, `cam` screen positions).
- `eject` / `eject2` — the custom Lua animation events for shell ejection
  (`FireAnimationEvent`, sh_shoot.lua:201-205 → `DoEject`).
- `Wick` — lit-particle attachment (molotov rag / dynamite fuse,
  weapon_common/shared.lua:332).

### 5.5 Native model animation events

The ported MDLs bake Source animation events: **foley soundscript names** (the ~16K lines
of `sound.Add` registrations in `sh_soundscript_foley.lua` / `sh_soundscript_weapons.lua`
exist to be referenced by the models' own event tracks), and the game's
`AE_WPN_CLIP_TO_POSEPARAM` clip-refresh points (extracted at port time into
`CycleClipPoseTime` / `InsertClipPoseTime`). **Only `eject`/`eject2` are handled in Lua.**

The harness probe `mcv_harness/deploy_layers.lua` documents the layering invariant:
**draw/deploy sequences must not respond to `player_movement`** (asserted < 0.001 bone
delta across the pose range), while **idle must** (> 0.01, positive control). Deploy
layers are subtractive/overlay tracks independent of locomotion.

### 5.6 Hammer events — `mcv/shared/sh_hammer_events.lua`

`MCV.HammerEvents` is a generated table (by `work/build_hammer_events.py` from the shipped
MDLs): normalized event cycles keyed `[model][sequence_name][hammer_position 0|1]`. Only 8
models are listed (the manually-cycled ones: M1897, M37, M38, M38_s, M91, Type 67, Vz.54,
Vz.54s).

`SWEP:ScheduleHammerRelease(vm, seq, duration, reverse)` (sh_shoot.lua:210-215) runs from
`applySequence` on **every** played animation of a `AnimationHandlesHammer` weapon: it
looks up the event cycle and stamps `HammerReleaseTime = CurTime() + duration * cycle`
(reverse-aware). `Think_HammerRelease` (sh_shoot.lua:217-223) then clears `NeedCycle` /
`EmptyReload` at that instant — i.e. **the bolt stays back until the model's own event
says the hammer dropped**. `InvertAnimationHammer` selects the opposite hammer position's
event (e.g. the M38's closed-bolt extractor vs hammer).

---

## 6. Model-Lookup Caches — `mcv/shared/sh_modelcache.lua`

### 6.1 Design

A weak-keyed `entities[ent]` cache, keyed by `ent:GetModel()` (invalidated by entity
identity or model change — never caches poses or predicted state). Failed lookups are
retried because *"an entity can be networked before its model is ready"*.

```lua
function MCV.CachedAttachment(ent, name) -- LookupAttachment, min 1
function MCV.CachedBone(ent, name)       -- LookupBone,     min 0
function MCV.CachedSequence(ent, name)   -- LookupSequence, min 0
function MCV.SequenceLoops(ent, sequence) -- GetSequenceInfo flags bit 0
```

### 6.2 Why it matters for the translation layer

`PlaySequence` and every `HasSequence` check go through `MCV.CachedSequence` — **the cache
is keyed by model path**, so a translation layer that swaps the viewmodel (foreign model in
place of an MCV one) automatically gets fresh, correct lookups. But note
`HasPoseRecoil`'s own `PoseRecoilModel` guard (sh_shoot.lua:186-198) caches
`PoseRecoilAvailable` per model path — same pattern.

### 6.3 `MCV.SequenceLoops`

Reads `GetSequenceInfo(seq).flags & 1` — used by `UpdateViewModelAnimation` to decide
wrap-vs-hold (§3.2). A translated model's looping flags are respected automatically.

---

## 7. Per-Action Animation State Machine

### 7.1 Deploy — `mcv/weapon_common/sh_deploy.lua:30-64`

```lua
self:SyncViewModel(true)
self:GetOwner():SetSaveValue("m_flNextAttack", SERVER and 0 or CurTime())
if self:ViewModelHidden() then
    self:SetReady(true)
elseif !self:GetReady() and !self:GetGrenadeLauncher() and self:HasAnimation(ACT_VM_READY) then
    self:PlayAnimation(ACT_VM_READY, 1, true)     -- ready-rack draw, once per pickup
    self:SetReady(true)
else
    self:DeployAnimation()                        -- ACT_VM_DRAW (or M203 variant)
    self:SetReady(true)
end
```

- **`ACT_VM_READY` plays only on the first deploy of a fresh weapon** (`!GetReady()`),
  giving the "chamber/ready the gun" first-draw; subsequent deploys use
  `DeployAnimation()` → `ACT_VM_DRAW` (mcv_base/sh_gun.lua:27-33), or the launcher draws
  when in launcher mode.
- `SyncViewModel(changeModel=true)` (sh_deploy.lua:3-28) re-points `self.ViewModel`
  (akimbo vs single), resets bodygroups to the 64-zero string on model/VM identity change,
  `vm:SetModel(model)` (restoring collision bounds around the hull quirk:
  *"Client SetModel takes the MDL hull; the server retains the VM hull"*), and re-syncs
  `m_iViewModelIndex` via SetSaveValue on the client.
- `SetSaveValue("m_flNextAttack", ...)` — *"the save-value interface is relative on the
  server and absolute on the client"* (comment, sh_deploy.lua:42-43).
- NPC deploys route to `NPC_Deploy` if present.
- `Initialize` (sh_deploy.lua:143-187) dedupes the inherited `Firemodes` list, calls
  `SetHoldType` (*"builds the engine's activity translations for NPC aiming / firing"*)
  and precaches particles + the akimbo viewmodel.

### 7.2 Holster — sh_deploy.lua:81-141

Two-phase, prediction-safe:

1. **First call** (no pending holster): plays `ACT_VM_HOLSTER` (locked, noidle), records
   `HolsterTime`, and — the clever part — computes a **command number**
   `HolsterCommand = cmd:CommandNumber() + ceil(duration / TickInterval())` plus
   `HolsterEntity`. A `StartCommand` hook (sh_deploy.lua:128-141) then performs the actual
   `ucmd:SelectWeapon(holsterEntity)` when the due command arrives — *"Command numbers,
   including the command selected here, are identical on both sides"*, so client and server
   switch in lockstep through the same predicted path instead of fighting over
   `m_hActiveWeapon`.
2. **Final call** (forced, due, or switching to NULL): clears state, resets viewmodel
   bodygroups, calls `ClientHolster` (client cleanup: `SetSubMaterial()`, `SetMaterial()`,
   `StopParticles()`, `VMLit = false`), returns true.
- Also fires the third-person put-away gesture
   `DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM)` and cancels ironsight/action
   state. Guarded against the engine's non-predicted client Holster calls
   (sh_deploy.lua:83-88).

### 7.3 Fire — `mcv_base/sh_shoot.lua:7-171`

Animation selection by firemode / akimbo / bipod (full table):

| Condition | Activity | Rate | Lock |
|---|---|---|---|
| Akimbo + VOLLEY w/ enough rounds | `ACT_VM_RECOIL1` | `ShootAnimRate` | no |
| Akimbo + DA, even count (right prepare) | `ACT_VM_HAULBACK` | `ShootAnimRate` | **yes** |
| Akimbo + DA, odd (left prepare) | `ACT_VM_PULLPIN` | `ShootAnimRate` | **yes** |
| Akimbo + last round & `LastShotAnimation` | `ACT_VM_SHOOTLAST` | rate | no |
| Akimbo + 2 rounds & `LastShotAnimation` | `ACT_VM_PRIMARYATTACK_EMPTY` | rate | no |
| Akimbo + `HasPoseRecoil()` | **no sequence** — pose-driven (§7.4) | — | — |
| Akimbo + right (even count) | `ACT_VM_PRIMARYATTACK` | rate | no |
| Akimbo + left | `ACT_VM_SECONDARYATTACK` | rate | no |
| VOLLEY w/ enough rounds | `ACT_VM_RECOIL1` | rate | no |
| DA (single) | `ACT_VM_HAULBACK` | rate | yes |
| FAN | `ACT_VM_PRIMARYATTACK_1` | rate | no |
| last round & `LastShotAnimation` | `ACT_VM_SHOOTLAST` | rate | no |
| bipod deployed | `ACT_VM_PRIMARYATTACK_DEPLOYED` | rate | no |
| default | `ACT_VM_PRIMARYATTACK` | rate | no |

- **`ShootAnimRate`** (default **0.5**, mcv_base/shared.lua:163-165): *"Models ported with
  the 60-frame idle base (the default of work/port_qc.py) need 0.5; models ported with
  --base-len match need 1."* This is a **porting-pipeline coupling** — fire animations play
  at half speed by default because the sequences were compiled at double length.
- DA fire is two-stage: prepare (`ACT_VM_HAULBACK`, locked) on trigger press, then the
  shot itself plays **on release** in `ThinkWeapon` (sh_think.lua:90-105):
  `ACT_VM_PRIMARYATTACK_2` (akimbo right) / `ACT_VM_PRIMARYATTACK_3` (akimbo left) at
  rate 0.5, after `TriggerDelayTime`.
- Burst fire overrides `t = 60 / (FireRate * 1.25)`.
- Fire cooldown: SA fires at `t * 0.8` (akimbo `t * 0.4`); everything else
  `60 / GetFiremodeRate(fm) * fmmult`.
- The anim duration `t` **falls back to `60 / FireRate`** if the activity is missing
  (sh_shoot.lua:126-128) — gameplay never depends on the model.
- `AttackEffects` (sh_shoot.lua:405-478) does the visual/recoil side: ViewPunch (two modes:
  realistic random-jump vs the game's fixed slide), `IsFirstTimePredicted`-gated
  `DoEject`/`DoMuzzle`, the **shoot gesture** `owner:DoAnimationEvent(GetShootGesture())`
  (§8), burst count increment, ammo take, shot sounds (4-slot channel rotation +
  "Distant" second layer, sh_shoot.lua:484-553), and `QueueRecoilImpulse`
  (weapon_common/sh_movement.lua:4-27 — velocity kick applied in `SetupMove` on the same
  command number on both realms).

### 7.4 Pose-driven recoil (akimbo) — sh_shoot.lua:173-199

`HasPoseRecoil()` returns true when `AkimboPoseRecoil` is set **and** the current viewmodel
has a `recoil_r` pose parameter (per-model cache `PoseRecoilModel`/`PoseRecoilAvailable`).
When true, firing does **not change the sequence at all**: it stamps
`LastShotTimeR/L = CurTime()` and `DoBodygroupsWeapon` scrubs the model's recoil layers from
`recoil_r` / `recoil_l` = elapsed / `AkimboRecoilTime` (0 = shoot frame, 1 = rest). The
comment (shared.lua:167-171): *"Both hands recoil independently and the idle, walk and run
layers keep playing underneath."* Models are ported with `port_qc.py --pose-recoil`.

### 7.5 Cycle (bolt / pump) — mcv_base/sh_think.lua:107-132

After a shot on a `PlayCycleAnimation` weapon (bolt/pump actions):

```lua
if !self:StillWaiting() and (!owner:KeyDown(IN_ATTACK) or self.SlamFire) and self:GetNeedCycle() then
    local t = self:PlayAnimation(ACT_VM_RELOAD_INSERT_PULL, 1, false)
    self:EmitThirdPersonSound(self.SoundCycleThirdPerson)
    if t then
        self:SetNextPrimaryFire(CurTime() + t * self.CyclePostDelay)
        self:SetActionStart(CurTime())   -- networked, for CycleClipPoseTime
    end
    if t == nil or !self.AnimationHandlesHammer then
        self:SetNeedCycle(false)
    end
end
```

- The cycle waits for **trigger release** (except slam-fire shotguns).
- `NeedCycle` blocks the next shot until cleared — by the hammer event
  (`Think_HammerRelease`, §5.6) on `AnimationHandlesHammer` weapons, or immediately
  otherwise.
- Dual models may have **no cycle sequence** (the dual Type 67 works its bolts inside the
  shot animations): the cycle *state* still runs; only the animation is absent —
  `PlayAnimation` returns nil and the lock falls back (comment, sh_think.lua:112-118).

### 7.6 Reload — `mcv_base/sh_reload.lua`

Selection matrix (`SWEP:Reload`, sh_reload.lua:28-111):

| Weapon shape | Animation |
|---|---|
| Shotgun, empty & `ShotgunReloadEmptyStartAnimation` | `ACT_VM_RELOAD_INSERT_EMPTY` (locked, noidle) |
| Shotgun | `ACT_SHOTGUN_RELOAD_START` (locked, noidle) |
| Akimbo, empty | `ACT_VM_RELOADEMPTY` |
| Akimbo, 1 round | `ACT_VM_MISSRIGHT2` (fallback `ACT_VM_MISSRIGHT` → `ACT_VM_RELOAD`) |
| Akimbo, nearly full | `ACT_VM_MISSRIGHT` |
| Akimbo default | `ACT_VM_RELOAD` |
| Empty & `HasEmptyReload`, bipod | `ACT_VM_DEPLOYED_RELOAD_EMPTY` |
| Empty & `HasEmptyReload` | `ACT_VM_RELOADEMPTY` |
| Bipod | `ACT_VM_RELOAD_DEPLOYED` |
| Default | `ACT_VM_RELOAD` |
| Launcher (`Reload2`) | `ACT_VM_RELOAD_M203` |

All locked (`lock=true`), which is what `Think_Reload` keys its progress off. On start:
`LastClip` snapshot, third-person reload sound, the **reload gesture** with the animation's
own remaining time (§8.2), `EmptyReload` classification, ironsight dropped, `Reloading=true`.

`Think_Reload` (sh_reload.lua:185-257) drives the loop stages when the lock expires:

- **`AkimboDualSingleActionReload`** (dual revolvers): insert per round
  (`ACT_VM_RELOAD` right / `ACT_VM_RELOAD2` left, noidle) with
  `PLAYERANIMEVENT_RELOAD_LOOP` gestures per insert; hand swap at half capacity
  (`ACT_VM_RELOAD_END` noidle + `ReloadHand` 0→2); finish
  (`ACT_SHOTGUN_RELOAD_FINISH` or `ACT_VM_RELOAD_END_EMPTY` by hand) with
  `PLAYERANIMEVENT_RELOAD_END`.
- **`ShotgunReload`**: insert loop (`ACT_VM_RELOAD_INSERT`, or `ACT_VM_RELOAD` when
  `ShotgunAltReload` clip-loading) noidle; finish: empty-reload chambers via
  `ACT_SHOTGUN_PUMP` (reload_endpump) when it has one, else `ACT_SHOTGUN_RELOAD_FINISH`;
  attack-cancel requires ammo actually added (`LastClip` baseline, sh_think.lua:82-84).
- **Magazine guns**: single stage — clip restored when the lock ends.
- Ammo transfer for round-by-round: `Defer("ReloadInsert", ReloadInsertTime)` (or immediate
  `RestoreClip(ShotgunReloadRounds)` when `ReloadInsertTime` is nil).
- `AnimationHandlesHammer` gates whether `EmptyReload` clears immediately or waits for the
  model's event (§5.6).
- `Think_AutoReload` (sh_reload.lua:15-26): client-preference auto reload on empty
  (skips locked/cycling/safety/holstering/primed/charging states).

### 7.7 Safety / at-ease — mcv_base/sh_gun.lua:115-132

`ToggleSafe` plays `ACT_VM_IDLE_TO_LOWERED` (lowering) / `ACT_VM_LOWERED_TO_IDLE`
(readying), locked, and the idle swaps to `ACT_VM_IDLE_LOWERED`. Sprint hold type and
"at ease" hint follow the same flag.

### 7.8 Bipod — mcv_base/sh_bipod.lua

Deploy on USE press at cover (`CanBipod` traces): `ACT_VM_DEPLOYED_IN` (locked) +
`Bipod=true`; fold on movement/surface loss: `ACT_VM_DEPLOYED_OUT`. Deployed idle =
`ACT_VM_DEPLOY`; deployed fire/reload variants per §7.3/§7.6.

### 7.9 Firemode & scope adjustment — sh_shoot.lua:743-820

- `AdjustableScopes` weapons: `ACT_VM_FIDGET` forward/backward (`SetScopeLevel` 1↔2).
- Selector: `ACT_VM_FIREMODE` (default, **reversed when wrapping to mode 1**),
  `ACT_VM_IFIREMODE` (→DA), `ACT_VM_DIFIREMODE` (→SA), bipod `ACT_VM_DFIREMODE`.
- `FiremodeAvailable` (sh_shoot.lua:728-741) filters modes by **model capability**
  (`HasAnimation`) — the dual models animate fewer modes; a mode without its animation is
  skipped, and akimbo swap re-runs `ChangeFiremode` if the current mode vanished
  (sh_akimbo.lua:36-38).
- Fallback when the selector animation is missing: 0.25 s plain lock + click sound.
- M79 cartridge switch (m79_base/shared.lua:71-100) is its own flow: unload →
  `PlaySequence("reload_live")` (round still in) or `ACT_VM_RELOAD`, eject suppressed
  before frame 50/30, `ammo_fraction` overridden, `AmmoSwitchFrom` remembers the outgoing
  cartridge for the bodygroup.

### 7.10 Bayonet & bash — sh_bash.lua, sh_bayonet_charge.lua

- `Bash()` (USE+attack): named sequences `bash_bayonet`/`slash_bayonet` (shared-random
  pick of the ones the model has) → `ACT_VM_HITLEFT` → `ACT_VM_HITCENTER` fallback chain
  — **a missing animation must never become an unlocked damage attack**
  (sh_bash.lua:31-34, the vz.52/57 bug in BUGLIST). Third-person `BashGesture`
  (`ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND`).
- Bayonet fix/remove: `ACT_VM_ATTACH_SILENCER` / `ACT_VM_DETACH_SILENCER` when the model
  has them; bodygroup toggles directly otherwise (the second BUGLIST fix). Removal defers
  the bodygroup change to the end of the detach animation (`Defer("BayonetOff", t)`).
- **Charge** (sprint + trigger with bayonet): sequence-name state machine —
  `ChargeStart` (locked) → `Deferred_BayonetLoop` plays `ChargeLoop` (unlocked, **noidle**)
  → thrust `ChargeStab`/`bash_bayonet` on contact/trigger/max-time, with
  `Defer("BayonetHit", ...)` for the damage timing. `IdleSequence()` returns
  `ChargeLoop` while charging — the only gun-base idle-by-name.

### 7.11 UBGL toggle — sh_ubgl.lua

`ToggleUBGL` (WALK+USE): rifle-grenade mode plays `ACT_VM_HOLSTER` at 0.75 speed (locked,
noidle) then `Deferred_LauncherSwap` mid-holster → `ACT_VM_DRAWFULL_M203` (round in tube)
/ `ACT_VM_DRAW_M203`; back → `ACT_VM_READY`. True UBGLs toggle in place:
`ACT_VM_IIN_M203` / `ACT_VM_IOUT_M203`. Launcher shot: `ACT_VM_ISHOOT_M203` at 0.5.

### 7.12 Akimbo swap — sh_akimbo.lua

`ACT_VM_HOLSTER` (locked, noidle) + extended `AnimLockTime` (+0.75) +
`Defer("AkimboSwap", t + 0.5)` → swap `ViewModel` (SyncViewModel true) → draw with
`ACT_VM_READY` (both slides racked) or `ACT_VM_DRAW` (one-side-empty SlidePosition pose).

---

## 8. Third-Person Animation

### 8.1 Gestures by hold type — weapon_common/shared.lua:98-126

`GetShootGesture` / `GetReloadGesture` map the **current networked hold type** to
`ACT_HL2MP_GESTURE_RANGE_ATTACK_*` / `ACT_HL2MP_GESTURE_RELOAD_*` (ar2, smg, pistol,
revolver, duel, shotgun, rpg, crossbow, melee, grenade, slam tables), with per-weapon
`ShootGesture` / `ReloadGesture` overrides. `Think_HoldType`
(weapon_common/sh_think.lua:154-179) picks `HoldType` / `SprintHoldType` ("passive") /
`AimHoldType` ("rpg") / "duel" (akimbo) / "rpg" (bipod) — calling `SetHoldType` only on
change, asking the weapon for its current value so prediction errors self-heal.

### 8.2 Timed gestures — `mcv/shared/sh_animevents.lua` + sh_reload.lua:8-13

TacRP-inherited scheme ("the weapon fires the player animation events with the animation
time in milliseconds as the data"):

```lua
owner:DoCustomAnimEvent(PLAYERANIMEVENT_RELOAD, math.max(1, math.floor(t * 1000)))
```

The `DoAnimationEvent` hook (sh_animevents.lua:28-64) catches RELOAD / RELOAD_LOOP /
RELOAD_END for `MilitaryConflictVietnam` weapons, restarts the reload gesture of the hold
type in `GESTURE_SLOT_ATTACK_AND_RELOAD`, and **stretches it to the first-person time**:
`SetLayerDuration(slot, t)`, or `t / offset` with `SetLayerCycle(slot, offset)` for the
per-round loops — `MCV.ReloadAnimOffsets` holds the per-gesture start points (revolver
0.6/0.6/0.7, shotgun 0.25/0.31/0.5) so *"every insert shows the hands loading"*.

The shoot gesture is plain `owner:DoAnimationEvent(GetShootGesture())` (no timing data).

### 8.3 Player model layering

`cl_worldmodel.lua` draws the carried world models on the player (bone-merged, second
pistol on the left hand for "duel"), taking bodygroups from the weapon entity (§4.5) —
detailed in the upcoming world-model/HUD audit doc.

---

## 9. Viewmodel Render Pipeline — `mcv/weapon_common/sh_vm.lua`

### 9.1 `PreDrawViewModel` (sh_vm.lua:51-77)

- Skips hidden viewmodels (returns true = don't draw), skips shadow-depth passes.
- Runs `PreDrawViewModelWeapon` (gun: RT scope setup via `DoRTScope` when not holstering,
  muzzle light update — mcv_base/sh_vm.lua:250-257) and `UpdateLitParticle` (lit
  molotov/dynamite: `ParticleEffectAttach` on the `Wick` attachment, sh_vm.lua:104-116).
- Opens a **custom camera** `cam.Start3D(nil, nil, MCV.ViewmodelFOV(self, sa^3))` with
  optional `ViewModelZNear` near-plane override (scoped eyepieces), `cam.IgnoreZ(true)`,
  and remembers `VMCamOpen` so PostDraw closes it even if a weapon hook errored.
- `MCV.ViewmodelFOV` (cl_viewsettings.lua:21-25) lerps `ViewModelFOV` (80) →
  `SightedViewModelFOV` (40) by the sight amount, plus client convar offsets
  (`mcv_viewmodel_fov_offset` etc.).

### 9.2 `ViewModelDrawn` (sh_vm.lua:83-100)

Runs **inside** the viewmodel's render pass: in-flight shell effects (`ActiveEffects`,
TacRP's system — *"a shell lives here until it hits something"*), physical-muzzle capture.
Nothing in depth passes.

### 9.3 `PostDrawViewModel` (sh_vm.lua:136-203)

Closes the camera; draws the manual PCF particle set (`self.PCFs` — muzzle flash/smoke,
shell puffs) **inside the gun's camera** so particles sit on the gun's attachments at its
FOV and depth-test against it (the comment documents the old off-muzzle-flash bug); world
PCFs (flamethrower jet) re-open a world `cam.Start3D`; refraction texture
save/restore for Contact Shadows compatibility; scope overlay capture;
`PostDrawViewModelWeapon` (OEG composite, scope cleanup).

### 9.4 `GetViewModelPosition` (sh_vm.lua:205-267)

1. Outside prediction: `UpdateViewModelAnimation(vm)` (§3.2) + `DoBodygroups(vm, true)` +
   `InvalidateBoneCache` — this is where per-frame pose params get applied before bones.
2. **Offset blend**: `LerpVector(aim_delta, CustomPos, ironsightPos)` (akimbo/launcher
   variants of the aim offset), plus client hip-position sliders
   (`MCV.ViewmodelPositionOffset`, fading out with aim).
3. **Aim sway** (realistic mode): rotates the whole viewmodel by the sway angle.
4. **Recoil reprojection** (sh_vm.lua:242-250): when aiming, camera-relative pitch/yaw is
   reprojected through `MCV.ViewmodelRecoilProjection` (cl_viewsettings.lua:34-45) so a
   kick rises proportionally in the *narrower viewmodel FOV* — *"animation-local recoil
   remains part of the model's animation"* (only the camera-relative component is
   reprojected; the model's own recoil tracks stay untouched).
5. Position offsets applied on the viewmodel's right/forward/up axes; angle offsets
   (`CustomAng` → `IronsightAng`) rotated around right (pitch), up (yaw), forward (roll).

### 9.5 OEG scope composite (mcv_base/sh_vm.lua:259-304)

Occluded-eye-gunsight drawing: copies the pre-viewmodel frame into a private RT
(`mcv_oeg_scene`) before the gun draws, then composites it over the finished viewmodel at
`OEGSceneAlpha` (0.5) so the gun reads as one half-transparent plane.

---

## 10. Animation-Related SWEP Fields (definition surface)

Everything a weapon definition can set that touches animation (defaults from
`mcv_base/shared.lua` unless noted):

**Model & offsets** — `ViewModel`, `ViewModelAkimbo`, `WorldModel`, `BodyGroups` (string),
`WorldModelBodyGroups`, `CustomPos/CustomAng` (hip), `IronsightPos/IronsightAng` (aim),
`IronsightPosAkimbo/AngAkimbo`, `IronsightPosLauncher/AngLauncher`, `ViewModelFOV`,
`SightedViewModelFOV`, `ViewModelZNear`, `IronsightSpeedScale`, `SightEase`,
`IronsightWalkBobbingStrength`.

**Locomotion** — `MovementPoseWalk` (148), `MovementPoseSprint` (245),
`MovementPoseSighted` (130), `MovementPoseWalkMax` (0.95), `SightedSwayFraction` (0.2),
`SpeedRun` (100), `SpeedSprint` (273), `SpeedWalk` (25), `SpeedAcceleration` (750),
`SpeedSprintThreshold` (150), `SafeMovementAnimations` (model list opt-out), `HoldType`,
`SprintHoldType`, `AimHoldType`.

**Playback** — `ShootAnimRate` (0.5 — porting pipeline coupling), `CyclePostDelay` (0.65),
`TriggerDelayTime` (0.25).

**Behaviour flags** — `PlayCycleAnimation`, `AnimationHandlesHammer`, `InvertAnimationHammer`,
`LastShotAnimation`, `ShotgunReload`, `ShotgunAltReload`, `ShotgunReloadRounds`,
`ShotgunReloadEmptyStartAnimation`, `HasEmptyReload`, `AkimboDualSingleActionReload`,
`RevolverFiremodePose`, `SlamFire`, `AkimboPoseRecoil`, `AkimboRecoilTime` (0.8),
`AkimboMagInTimes`.

**Reload timing** — `MagInTime`, `MagInTimeEmpty`, `MagOutTime`, `MagOutTimeEmpty`,
`MagInClip`, `MagInTimeGrenade`, `ReloadInsertTime`, `InsertClipPoseTime`,
`CycleClipPoseTime`, `CycleAmmoPose2`.

**Bodygroups** — `BayonetBodygroup`, `GrenadeLauncherBodygroup`, `GrenadeBodygroup`,
`BulletBodygroups` (sparse round-threshold map), `BeltBodygroups`, world counterparts.

**Gestures** — `ShootGesture`, `ReloadGesture`, `BashGesture`.

**Effects** — `MuzzleParticle*` (4 + 3rd-person), `EjectBrassType/Trail/Particle`,
`NoEjectOnShoot`, `TracerParticle/2`, `TracerRandomness/Frequency`,
`MuzzleFlashLightTexture`, `GetPrecacheParticles()`.

**Sound** — `SoundSingleShot`, `SoundDoubleShot`, `SoundEmpty`, `SoundNearlyEmpty`,
`SoundReload*ThirdPerson`, `SoundCycleThirdPerson`, `SoundGrenadeShot`, `SoundFireLoop`.

---

## 11. Translation-Layer Implications

The seams a foreign-model translation layer should hook, ranked by leverage:

1. **`SWEP:PlayAnimation` / `SWEP:PlaySequence`** (sh_anim.lua) — *the* choke point for
   discrete actions. Both funnel into `applySequence`, so an override that maps a missing
   activity/sequence to an equivalent the foreign model has (and returns the duration)
   integrates with locks, idle timing, gestures and the predicted timeline for free.
   Follow the base's own conventions: `HasAnimation`/`HasSequence` check first, tolerate
   nil, never let a missing animation unlock gameplay (sh_bash.lua:31-34).
2. **`IdleActivity()` / `IdleSequence()`** — override pair for idle selection; already
   supports sequence-name precedence.
3. **`DoBodygroups` / `DoBodygroupsWeapon`** — the pose-parameter writers. A foreign model
   lacking `player_movement` etc. simply ignores `SetPoseParameter` (engine no-ops on
   unknown names) — harmless but inert. To emulate, a translation layer could drive
   approximation layers here, or map state onto whatever pose params the foreign model
   does have.
4. **`FireAnimationEvent`** — foreign models that fire sound events through Lua-visible
   events (or activities whose events must be replayed) can be caught here; MCV only
   handles `eject`/`eject2`.
5. **`GetShootGesture` / `GetReloadGesture` / `PlayReloadGesture`** — third-person side is
   fully hold-type driven and model-independent; no translation needed.
6. **`SyncViewModel` / `ViewModelHidden` / `DeployAnimation`** — model swap points.
7. **NetworkVar ceiling** — the shared datatable is fixed (§3.3); translation state must be
   plain Lua fields (per-instance, set in Initialize like `self.PCFs = {}`) or NW2.
8. **Timeline ownership** — never set viewmodel cycle/playback rate/`m_flAnimTime`
   outside `applySequence`/`UpdateViewModelAnimation`; they are overwritten every frame
   (§3.2).
9. **Duration honesty** — every caller uses the returned duration for locks and follow-ups;
   a translated sequence whose real length differs from the original activity's must
   return its own true duration (`vm:SequenceDuration`), or reload ammo-transfer timing
   (`MagInTime` etc. is in *sequence-relative seconds*) will drift.
10. **`ShootAnimRate`** — ported models run fire anims at 0.5×; a foreign model compiled
    normally will want 1.
11. **Hammer events** — only 8 hand-cycled models are in `MCV.HammerEvents`; a translated
    bolt-action without an entry needs `AnimationHandlesHammer = false` (cycle clears
    immediately) or a generated entry.
12. **Foley** — MCV models carry their foley in the MDL event tracks referencing
    `MCV_*` soundscripts. A foreign model's own events keep working natively; any
    Lua-dispatched events need `FireAnimationEvent` handling.

---

## 12. Animation File Map

| File | Lines | Role |
|---|---|---|
| `lua/mcv/weapon_common/sh_anim.lua` | 151 | Playback API, timeline reconstruction, capability queries |
| `lua/mcv/weapon_common/sh_vm.lua` | 267 | DoBodygroups driver, render pipeline, GetViewModelPosition |
| `lua/mcv/weapon_common/sh_think.lua` | 179 | Think order, movement pose math, speed blend, hold types |
| `lua/mcv/weapon_common/sh_deploy.lua` | 187 | Deploy/holster/Initialize/SyncViewModel |
| `lua/mcv/weapon_common/sh_clock.lua` | 107 | Clock-reset machinery |
| `lua/mcv/weapon_common/sh_timers.lua` | 57 | Prediction-safe deferred actions |
| `lua/mcv/weapon_common/sh_movement.lua` | 65 | Recoil impulse queue, movement sampling |
| `lua/mcv/weapon_common/shared.lua` | 400 | NetworkVar layout, hook contract, gestures |
| `lua/weapons/mcv_base/sh_vm.lua` | 304 | Gun pose-parameter engine, muzzle light, OEG |
| `lua/weapons/mcv_base/sh_think.lua` | 140 | Gun think: cycle, DA release, burst, world bodygroups |
| `lua/weapons/mcv_base/sh_sights.lua` | 147 | Sight blend (raw/visual/eased) |
| `lua/weapons/mcv_base/sh_shoot.lua` | 820 | Fire anim selection, pose recoil, hammer scheduling, sounds |
| `lua/weapons/mcv_base/sh_reload.lua` | 257 | Reload state machine + gestures |
| `lua/weapons/mcv_base/sh_gun.lua` | 132 | Idle/deploy activity selection, safety, hints |
| `lua/weapons/mcv_base/sh_bash.lua` | 160 | Bash/bayonet swings |
| `lua/weapons/mcv_base/sh_bayonet_charge.lua` | 126 | Charge state machine (named sequences) |
| `lua/weapons/mcv_base/sh_bipod.lua` | 55 | Bipod deploy/fold |
| `lua/weapons/mcv_base/sh_akimbo.lua` | 54 | Dual-wield swap |
| `lua/weapons/mcv_base/sh_ubgl.lua` | 89 | Launcher toggle/attack |
| `lua/weapons/mcv_base/shared.lua` | 226 | Gun SWEP field defaults |
| `lua/weapons/mcv_m79_base/shared.lua` | 112 | Break-action cartridge system |
| `lua/mcv/shared/sh_animevents.lua` | 64 | Timed third-person reload gestures |
| `lua/mcv/shared/sh_hammer_events.lua` | 71 | Generated hammer-event cycle table |
| `lua/mcv/shared/sh_modelcache.lua` | 54 | Sequence/attachment/bone caches, loop detection |
| `lua/mcv/client/cl_viewsettings.lua` | 45 | Viewmodel FOV/offset convars, recoil reprojection |
| `lua/mcv/client/cl_worldmodel.lua` | 292 | Bone-merged player world models (see HUD doc) |
| `lua/mcv_harness/deploy_layers.lua` | 85 | Deploy-layer/movement independence regression probe |
| `lua/mcv_harness/bolt.lua` | 251 | Bolt-cycle timing probe (see harness doc) |
| `lua/autorun/sh_mcv_harness.lua` | 558 | Dev harness: WeaponState reports pose params/sequences/cycles — ideal for translation-layer verification |

