# MCV Base — Shooting & Ballistics (Exhaustive Audit)

This document exhaustively audits the MCV (Military Conflict: Vietnam) **firing & ballistics
pipeline**: everything from the trigger pull through `PrimaryAttack`, fire-mode cadence, spread,
recoil, the hitscan `FireBullets` call, damage/hitgroup computation, the opt-in **physical
(simulated travel-time) bullet** system with its client prediction & networking, the **wall
penetration** model, and the **rocket flight** model. Projectile *entities* (grenades, RPG
rockets as ents) are documented in `docs/projectiles-entities.md`; this doc covers the launch and
flight-math side that lives in the weapon base. Animation selection for firing is already
exhaustively covered in `docs/animation-system.md` §7.3–7.5, §7.9 and is cross-referenced, not
repeated.

Realm split in one line: **the trigger pipeline is shared & predicted** (`weapons/mcv_base/sh_shoot.lua`,
`sh_gun.lua`), **hitscan damage is engine-predicted but effects are first-time-predicted-gated**,
**physical bullets are server-authoritative with cosmetic client prediction**
(`mcv/shared/sh_physbullets.lua` + `mcv/server/sv_physbullets.lua` +
`mcv/client/cl_physbullets.lua`), and **the NPC path is server-only** (`sh_npc.lua` tail).

Companion docs: `docs/gun-core.md` (ThinkWeapon, sights, effects, world models),
`docs/reload-ammo.md` (clip/ammo), `docs/weapon-definitions.md` (SWEP authoring surface),
`docs/projectiles-entities.md`, `docs/effects.md`, `docs/support-systems.md`.

---

## 1. Architecture Overview

### 1.1 Three bullet paths

A trigger pull ends in exactly one of three physical outcomes, chosen at
`weapons/mcv_base/sh_shoot.lua:140-150`:

1. **Hitscan** — `SWEP:BulletAttack()` (sh_shoot.lua:573-641). One `Entity:FireBullets` call per
   shot segment, engine cone spread, lag-compensated, with penetration continuations re-fired as
   follow-up segments. The default path (`mcv_physbullets 0`).
2. **Physical bullets** — `MCV.LaunchPhysicalBullets()` (server) + `MCV.PredictPhysicalBullets()`
   (shooting client). Opt-in via `mcv_physbullets 1`; bullets fly at `MuzzleVelocity`, drop under
   gravity, drag optional, and damage is applied by a per-contact `FireBullets` call when the
   simulated bullet arrives.
3. **Projectile entity** — `SWEP:RocketAttack()` → `SWEP:LaunchProjectile()` (sh_shoot.lua:643-711)
   whenever `SWEP:GetProjectileClass()` is non-nil (`ShootEntity`). The entity owns its own
   behavior (`docs/projectiles-entities.md`); launchers that opt into `RocketGravity` additionally
   get the swept flight model of §9.

### 1.2 Data flow

```
 player IN_ATTACK ──► SWEP:PrimaryAttack()            [SH, predicted]  sh_shoot.lua:7
   ├─ NPC?                     ──► SWEP:NPC_PrimaryAttack()           [SV]  sh_npc.lua:125
   ├─ StillWaiting/NeedCycle/Safe/Speed/NeedTriggerPress gates         (§2)
   ├─ fire-mode anim selection + cooldown        (anim doc §7.3)
   ├─ FIREMODE_DA ─► prime (SetPrimedAttack) ─► ThinkWeapon release    (§3.6)
   └─ else ─┬─ GetProjectileClass() ─► RocketAttack ─► LaunchProjectile [SV] (§9)
            └─ BulletAttack(shootPos, shootDir)                        (§6)
                 ├─ MCV.PhysicalBulletsEnabled() ─► LaunchPhysicalBullets [SV] (§7)
                 │                                          └─ PredictPhysicalBullets [CL]
                 └─ FireBullets(Spread = GetSpread(), …)
                      └─ Callback per pellet:
                           ├─ ApplyBulletDamage(tr, dmg, distance)          (§6.5)
                           │    ├─ DMG_BUCKSHOT flag, range multiplier
                           │    ├─ ArmorPiercing special-casing
                           │    ├─ MCV.CancelBodyDamage (undo engine hitgroup scale) sh_hitgroups.lua
                           │    └─ Damage{Head,Chest,…}Multiplier              (§6.5)
                           ├─ QueuePenetration(tr, state, queue)               (§8)
                           │    └─ FindPenetrationExit probe
                           └─ MCV.HitscanEffects(tr, dmg, tracer, noRicochet)  (§6.7)
                                ├─ util.Effect("mcv_tracer")   (effects doc)
                                └─ MCV.BulletImpact → SurfaceImpact / stock Impact
   then SWEP:AttackEffects()                        [SH]  sh_shoot.lua:405  (§5)
```

### 1.3 Path-switching convars (mcv/shared/sh_convars.lua:29-56)

| Convar | Default | Effect |
|---|---|---|
| `mcv_realistic_shooting` | 0 | 1 = barrel-accurate hip fire + random recoil kick + hip sway (§4.4, §5.1); 0 = the game's cone/fixed slide |
| `mcv_bullet_penetration` | 1 | Master switch for wall penetration (§8) |
| `mcv_physbullets` | 0 | Enable physical bullets (§7) |
| `mcv_physbullets_npcs` | 0 | Physical bullets for NPC shooters |
| `mcv_physbullets_pellets` | 0 | Simulate each shotgun pellet (else multi-pellet guns stay hitscan) |
| `mcv_physbullets_velocity` | 1 | Muzzle-velocity multiplier (m/s scale) |
| `mcv_physbullets_gravity` | 1 | Gravity multiplier (1 = Earth) |
| `mcv_physbullets_drag` | 0 | Linear air drag, inverse seconds |
| `mcv_physbullets_lifetime` | 5 | Max flight time (s) |

All are registered through `MCV.RegisterConVar` (archived + replicated + notify,
sh_convars.lua:9-16) so **predicted weapon code reads the same value on both realms** — a hard
requirement for every gate in §2–§7. `MCV.RealisticShooting()` / `MCV.BulletPenetration()`
(sh_convars.lua:32-34, 46-48) are the accessors.

### 1.4 Prediction philosophy (why this matters for the translation layer)

- **No ordinary Lua fields for shot state.** Burst counters, trigger latches, recoil magnitudes
  and clip parity all live in the shared datatable (`weapon_common/shared.lua:196-285`) or are
  recomputed from networked state. Replay of a user command must reproduce the identical shot.
  Example comment, sh_shoot.lua:429-431: *"BurstCount is the predicted number of earlier shots,
  incremented below. Read it on every replay; never accumulate recoil in an ordinary Lua field."*
- **Randomness is `util.SharedRandom` keyed by stable seeds** (viewpunch side, shot sounds,
  rocket spread, physical-bullet spread) or pure functions of `CurTime()`/`EntIndex()` (hip sway).
  The engine's own `FireBullets` cone RNG is *not* shared — MCV accepts that and treats
  client-side hitscan traces as presentation only (sh_shoot.lua:584-586).
- **Effects and sounds are `IsFirstTimePredicted`-gated**; damage and state are not.

---

## 2. Trigger Pipeline

### 2.1 `SWEP:PrimaryAttack()` — the gate ladder (sh_shoot.lua:7-171)

`PrimaryAttack` is called by the engine whenever `IN_ATTACK` is held and the engine's own
`NextPrimaryFire` allows it — MCV never touches `SWEP.Primary.Automatic` for cadence (it defaults
to `true`, weapon_common/shared.lua:171); **all fire discipline is MCV's own**, via the gates
below and `SetNextPrimaryFire`.

```lua
-- weapons/mcv_base/sh_shoot.lua:7-50
function SWEP:PrimaryAttack()
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then return self:NPC_PrimaryAttack() end
    if self:StillWaiting() then return end
    if self:GetNeedCycle() then return end

    if self:GetSafe() then self:ToggleSafe(true) return end

    local owner = self:GetOwner()
    local bursting = self:IsBursting() // a runaway burst finishing itself (ThinkWeapon)

    // bash with USE + fire; not while deployed on the bipod (the PTRD can bash undeployed
    // even though it only fires deployed)
    if owner:KeyDown(IN_USE) and !bursting then
        if !self:GetBipod() and owner:KeyPressed(IN_ATTACK) then
            self:Bash()
        end
        return
    end

    // Sprinting on the trigger with a bayonet fixed: charge, the same input the melee weapons
    // take it on. A gun will not fire at a sprint anyway, so nothing else wants this. Once the
    // charge is up the think loop owns the weapon until it lands or the player lets go.
    if self:IsBayonetCharging() then return end

    if self:GetIsSprinting() and self:GetBayonet() then
        self:StartBayonetCharge()
        return
    end

    if self.MustBipod and !self:GetBipod() then return end

    if self:GetGrenadeLauncher() then
        self:RifleGrenadeAttack()
        return
    end

    if self:Clip1() < 1 then
        self:SetBurstCount(0)
        self:Reload()
        return
    end
    if self:GetSpeed() > 150 and !bursting then return end

    if self:GetNeedTriggerPress() and !bursting then self:SetBurstCount(0) return end
```

Gate order (each early-returns):

| # | Gate | Meaning |
|---|---|---|
| 1 | owner is NPC | Redirect to the server-only NPC path (§10) |
| 2 | `StillWaiting()` | `NextPrimaryFire > CurTime()` **or** `AnimLockTime > CurTime()` (weapon_common/shared.lua:356-361) |
| 3 | `GetNeedCycle()` | Bolt/pump action not cycled yet (anim doc §7.5) |
| 4 | `GetSafe()` | Safety on: **any trigger press readies the weapon** (`ToggleSafe(true)`) instead of firing |
| 5 | USE+attack | Bash/stab (`sh_bash.lua`, anim doc §7.10); blocked mid-burst |
| 6 | bayonet charging / sprint+bayonet | Bayonet charge state machine (anim doc §7.10) |
| 7 | `MustBipod` | Bipod-only guns (PTRD) |
| 8 | `GetGrenadeLauncher()` | Rifle-grenade/UBGL trigger (§2.6) |
| 9 | `Clip1() < 1` | Empty: reset burst, auto-`Reload()` |
| 10 | `GetSpeed() > 150` | Moving too fast (runaway bursts exempt) |
| 11 | `GetNeedTriggerPress()` | Semi-type latch: trigger must be released first (§3.4); a runaway burst is exempt and resets the count |

`GetSpeed()` is the networked movement blend (NetworkVar Float 6 `Speed`,
weapon_common/shared.lua:212); `GetIsSprinting()` is `weapon_common/sh_think.lua:32` (cross-ref
`docs/gun-core.md`).

### 2.2 Cooldown scheduling

After animation selection (anim doc §7.3) the cadence is stamped at sh_shoot.lua:122-138:

```lua
-- weapons/mcv_base/sh_shoot.lua:122-138
    if fm == MCV.FIREMODE_BURST then
        t = 60 / (self.FireRate * 1.25)
    end

    // PlayAnimation returns nothing when the model lacks the activity; never let that stall
    // or error the fire loop
    t = t or (60 / self.FireRate)

    if fm == MCV.FIREMODE_SA then
        if self:GetAkimbo() then
            self:SetNextPrimaryFire(CurTime() + t * 0.4)
        else
            self:SetNextPrimaryFire(CurTime() + t * 0.8)
        end
    else
        self:SetNextPrimaryFire(CurTime() + (60 / self:GetFiremodeRate(fm)) * fmmult)
    end
```

- `t` is the fire animation's duration (seconds) — **cadence is animation-length-driven first**,
  RPM-driven second. Burst overrides `t = 60 / (FireRate * 1.25)` (25% faster than nominal).
- A missing activity yields `t == nil`; the fallback `60 / FireRate` means *gameplay never
  depends on the model* (same rule as anim doc §7.3).
- Single-action revolvers fire early (`t * 0.8`, akimbo `t * 0.4`) — the hammer anim outlasts
  the mechanical ready time. Everything else: `60 / GetFiremodeRate(fm) * fmmult` where
  `fmmult = 0.5` when akimbo (alternating hands, sh_shoot.lua:61-63).

### 2.3 Safety / at-ease — `SWEP:ToggleSafe(forceoff)` (sh_gun.lua:115-132)

```lua
-- weapons/mcv_base/sh_gun.lua:115-132
function SWEP:ToggleSafe(forceoff)
    // A supported firing stance cannot be lowered into the at-ease pose.
    if self:GetBipod() then return end
    if forceoff and !self:GetSafe() then return end
    self:SetSafe(!forceoff and !self:GetSafe())

    if !forceoff then
        self:EmitSound("MCV_Weapon_Foley_Movement.ProneCrawl")
    end

    self:SetNextPrimaryFire(CurTime() + 0.25)

    if self:GetSafe() then
        self:PlayAnimation(ACT_VM_IDLE_TO_LOWERED, 1, true)
    else
        self:PlayAnimation(ACT_VM_LOWERED_TO_IDLE, 1, true)
    end
end
```

- Realm SH, predicted; toggled by USE+WALK press in `ThinkWeapon` (sh_think.lua:136-138) and by
  any trigger pull while safe (§2.1 gate 4).
- Side effects: 0.25 s `NextPrimaryFire` lock, locked lower/ready animation (anim doc §7.7),
  ProneCrawl foley on user-initiated toggles only.
- Idempotent when force-readying (`forceoff` + already unsafe → no-op, no sound, no anim) — this
  is the BUGLIST.md:169 hardening ("force-ready is idempotent").

### 2.4 `SWEP:SecondaryAttack()` (sh_gun.lua:74-80)

Only one behavior: `IN_ATTACK2` press while `IN_USE` held → `ToggleBayonet()`. Aiming is **not**
handled here at all — it lives in `Think_Sights` (`mcv_base/sh_sights.lua:101-147`, cross-ref
`docs/gun-core.md`). Realm SH, predicted.

### 2.5 Double-action release — the primed attack (sh_think.lua:90-105)

For `FIREMODE_DA`, `PrimaryAttack` only *primes*: `SetLastTriggerTime(CurTime())` +
`SetPrimedAttack(true)` (sh_shoot.lua:147-150) while playing the locked hammer-back animation.
The actual shot fires **on trigger hold** after `TriggerDelayTime` (default 0.25,
mcv_base/shared.lua:60), from `ThinkWeapon`:

```lua
-- weapons/mcv_base/sh_think.lua:90-105
    if owner:KeyDown(IN_ATTACK) and self:GetPrimedAttack() and self:GetLastTriggerTime() + self.TriggerDelayTime < CurTime() then
        if SERVER or !game.SinglePlayer() then
            self:AttackEffects()
            if self:GetProjectileClass() then
                self:RocketAttack()
            else
                self:BulletAttack()
            end
            self:SetPrimedAttack(false)
            if self:GetAkimbo() and self:Clip1() % 2 == 0 then
                self:PlayAnimation(ACT_VM_PRIMARYATTACK_3, 0.5)
            else
                self:PlayAnimation(ACT_VM_PRIMARYATTACK_2, 0.5)
            end
        end
    end
```

Notes:
- `if SERVER or !game.SinglePlayer()` — in singleplayer the *server* runs this (the SP client's
  Think is not authoritative for it); in MP the owning client predicts it. Classic MCV
  SP/MP split, same shape as the hitscan gate in §6.1.
- Releasing the trigger **before** the delay cancels the shot and idles the weapon
  (sh_think.lua:76-79: `KeyReleased(IN_ATTACK)` → `PlayAnimation(IdleActivity())`,
  `SetPrimedAttack(false)`).
- The DA anim (`ACT_VM_PRIMARYATTACK_2`/`_3` at rate 0.5) plays *after* the shot — the prepare
  animation already happened at prime time (anim doc §7.3).

### 2.6 The rifle-grenade branch — `SWEP:RifleGrenadeAttack()` (sh_ubgl.lua:51-89)

When `GetGrenadeLauncher()` is set, the attack becomes a Clip2-consuming launcher shot:
`Clip2() < 1` → `Reload()`; speed gate 150; `NeedTriggerPress` gate; plays
`ACT_VM_ISHOOT_M203` at 0.5; `RocketAttack(true)` (secondary projectile = `RifleGrenadeEntity`
at `RifleGrenadeForce`, §9.2); `TakeSecondaryAmmo(1)`; 1 s `NextPrimaryFire`;
`SetLastRecoilTime`; `SoundGrenadeShot`; `QueueRecoilImpulse`; **3× the slide-recoil values** in
a manual ViewPunch; IsFirstTimePredicted-gated eject/muzzle; `NeedTriggerPress = true`;
`PlayCycleAnimation` weapons also set `NeedCycle`. Cross-ref `docs/gun-core.md` for the UBGL
toggle state machine and anim doc §7.11.

### 2.7 Remaining `sh_gun.lua` surface (implementations of weapon_common hooks)

| Function | Lines | Realm | Purpose |
|---|---|---|---|
| `GetPrecacheParticles()` | 3-9 | SH | Particle list for `Initialize` precache (muzzle variants, brass, tracer) |
| `IdleActivity()` | 11-25 | SH | Safe → `ACT_VM_IDLE_LOWERED`; grenade-launcher → `ACT_VM_IIDLE_M203`/`ACT_VM_IDLE_M203`; bipod → `ACT_VM_DEPLOY`; else `ACT_VM_IDLE` |
| `DeployAnimation()` | 27-33 | SH | `ACT_VM_DRAW` locked (launcher variants when in GL mode) |
| `GetScopeWorldFov()` | 41-45 | SH | Screen FOV while aiming; clamps scope zoom `ScopeFOV * ScopeScreenZoom` to `[30, IronsightFov]` (`ScopeScreenZoom = 2`, line 39) |
| `GetZoomMagnification()` | 47-49 | SH | Alias of the above (camera reads it) |
| `GetLookMagnification()` | 52-58 | SH | Mouse-sensitivity divisor while aimed |
| `GetFiremodeName()` | 60-64 | SH | `MCV.FiremodeNames[GetFiremodeValue()]`, "Launcher" in GL mode (HUD) |
| `GetHUDAmmo()` | 66-72 | SH | Clip/reserve pair; GL mode reports `Clip2/Ammo2` |
| `GetControlHints()` | 83-113 | CL-facing | HUD control table (fire, aim, fire mode, bayonet, bipod, bash, at-ease…) — input-surface documentation for players |
| `ToggleSafe(forceoff)` | 115-132 | SH | §2.3 |

These are consumption-side helpers; the fields they read are catalogued in §11.

---

## 3. Fire Modes

### 3.1 The enum (mcv/shared/sh_common.lua:1-13)

```lua
-- mcv/shared/sh_common.lua:1-13
MCV.FIREMODE_AUTO = 0
MCV.FIREMODE_SEMI = 1
MCV.FIREMODE_BURST = 2
MCV.FIREMODE_SA = 3
MCV.FIREMODE_DA = 4
MCV.FIREMODE_FAN = 5
MCV.FIREMODE_BOLT = 6
MCV.FIREMODE_PUMP = 7
MCV.FIREMODE_FAST = 8
MCV.FIREMODE_SLOW = 9
MCV.FIREMODE_VOLLEY = 10
MCV.FIREMODE_HE = 11
MCV.FIREMODE_BUCKSHOT = 12
```

`sh_common.lua` is shared utilities; only the ballistics-relevant parts are documented here
(modes, shot-sound channels, hitgroup cancel tables, registered ammo types); the shell-type
catalogue and ammo registration are cross-ref `docs/support-systems.md` / `docs/reload-ammo.md`.

Display names (`MCV.FiremodeNames`, sh_common.lua:28-42) and the ammo-type remap
(`MCV.FiremodeAmmo`: HE → `"smg1_grenade"`, BUCKSHOT → `"buckshot"`, sh_common.lua:22-25 —
consumed by the M79 selectable-cartridge system, `docs/weapon-definitions.md`).

### 3.2 `GetFiremodeValue()` / `GetFiremodeRate(fm)` (sh_shoot.lua:713-715, 557-571)

`GetFiremodeValue()` is `self.Firemodes[self:GetFiremode()]` — `Firemode` is a networked Int
(slot 2) indexing into the weapon's `SWEP.Firemodes` list (default `{MCV.FIREMODE_SEMI}`,
mcv_base/shared.lua:31-33). Rate:

```lua
-- weapons/mcv_base/sh_shoot.lua:557-571
function SWEP:GetFiremodeRate(fm)
    local rate = self.FireRate

    if fm == MCV.FIREMODE_FAN and (self.FireRate_Fan or 0) > 0 then
        rate = self.FireRate_Fan
    elseif fm == MCV.FIREMODE_DA and (self.FireRate_DA or 0) > 0 then
        rate = self.FireRate_DA
    elseif fm == MCV.FIREMODE_FAST and (self.FireRate_Fast or 0) > 0 then
        rate = self.FireRate_Fast
    elseif fm == MCV.FIREMODE_SLOW and (self.FireRate_Slow or 0) > 0 then
        rate = self.FireRate_Slow
    end

    return math.max(rate * self:StatMult("firerate"), 1)
end
```

The category multiplier `firerate` is folded in here (never below 1 RPM). BOLT/PUMP guns use
plain `FireRate` for the shot itself; their real cadence is the cycle animation +
`CyclePostDelay` (anim doc §7.5).

### 3.3 Cadence summary (who sets `NextPrimaryFire`)

| Source | Value |
|---|---|
| Fire (SA) | `t * 0.8` (akimbo `t * 0.4`), sh_shoot.lua:130-135 |
| Fire (other) | `60 / GetFiremodeRate(fm) * fmmult`, sh_shoot.lua:137 |
| Burst end | `+ BurstRecovery`, sh_shoot.lua:159-166 |
| Cycle (bolt/pump) | `t_anim * CyclePostDelay`, sh_think.lua:122-123 |
| Safety toggle | `+ 0.25`, sh_gun.lua:125 |
| Rifle grenade | `+ 1`, sh_ubgl.lua:65 |

### 3.4 Semi-type modes & `NeedTriggerPress`

After the shot (sh_shoot.lua:152-157), `SEMI`, `SA`, `DA`, `HE`, `BUCKSHOT` all set
`NeedTriggerPress = true`; `ThinkWeapon` clears it on `KeyReleased(IN_ATTACK)`
(sh_think.lua:69-71). This is the entire semi-auto mechanism — a held trigger produces exactly
one round. `AUTO`, `BURST` (mid-burst), `FAN`, `VOLLEY`, `FAST`, `SLOW` re-fire freely at the
stamped cadence.

### 3.5 Burst — runaway bursts (sh_shoot.lua:717-723 + sh_think.lua:59-67)

```lua
-- weapons/mcv_base/sh_shoot.lua:717-723
function SWEP:IsBursting()
    if self:GetFiremodeValue() != MCV.FIREMODE_BURST then return false end
    local n = self:GetBurstCount()
    return n > 0 and n < self.BurstRounds
end
```

A fresh trigger pull resets `BurstCount = 0` (sh_shoot.lua:57-59); each shot increments it in
`AttackEffects` (sh_shoot.lua:457). While `0 < BurstCount < BurstRounds`, `ThinkWeapon` keeps
calling `PrimaryAttack` on cadence **whether or not the trigger is held** (sh_think.lua:59-67) —
a true runaway burst; the `IsBursting` flag exempts it from the speed/trigger-press gates.
When `BurstCount >= BurstRounds`: `NextPrimaryFire += BurstRecovery` (default 0.2,
mcv_base/shared.lua:50), and if the trigger is still held, `NeedTriggerPress = true` forces a
release first (sh_shoot.lua:159-166). `KeyReleased` mid-burst clears the trigger latch but not
the count (sh_think.lua:69-74) — "a trigger released mid-burst already counts as let go".
Defaults: `BurstRounds = 3`, `BurstRecovery = 0.2` (mcv_base/shared.lua:49-50).

### 3.6 Revolver modes — SA / DA / FAN

Defined by the base (Part 1 has no SA/DA/FAN weapon; they live in Part 2 — e.g. the S&W
revolvers and dual Blackhawk referenced in comments):

- **SA (single action)**: hammer-back per shot; fires at `t*0.8`; spread halved (§4.1).
- **DA (double action)**: two-stage — locked `ACT_VM_HAULBACK` (right hand) / `ACT_VM_PULLPIN`
  (left, akimbo) at prime, shot on sustained hold after `TriggerDelayTime` (§2.5); spread ×0.75.
- **FAN**: `ACT_VM_PRIMARYATTACK_1`, own optional rate `FireRate_Fan`.
- Availability is model-gated — `FiremodeAvailable` (§3.9).

### 3.7 Volley

`FIREMODE_VOLLEY` (Kolos 7-barrel, `VolleyCount = 7`, mcv_kolos.lua:56): with at least
`VolleyCount` rounds in the clip, one trigger pull expends them all at once —
`TakePrimaryAmmo(math.min(Clip1(), VolleyCount))` (sh_shoot.lua:459-460), bullet count ×
volley (§6.1), recoil × volley count (§5.2), `SoundDoubleShot` when >1 remains (§6.9), and for
rockets each round launches with its own spread (§9.1). A clip below `VolleyCount` falls through
to normal fire (sh_shoot.lua:69, 103).

### 3.8 HE / BUCKSHOT (M79)

`Firemodes = {MCV.FIREMODE_HE, MCV.FIREMODE_BUCKSHOT}` (mcv_m79_base/shared.lua:6). The mode
switches *which ammo pool and payload* the gun uses: `GetBulletCount()` returns 12 pellets for
buckshot else 1 (mcv_m79_base/shared.lua:36-38) and `GetProjectileClass()` returns nil for
buckshot (hitscan) else `ShootEntity`. Both are `NeedTriggerPress` modes. The M79 overrides
`ChangeFiremode` into a cartridge-swap reload (unload live round → `reload_live`/`ACT_VM_RELOAD`)
— see anim doc §7.9 and `docs/weapon-definitions.md`. BUGLIST.md:119 documents the design;
BUGLIST.md:117 the reload integration.

### 3.9 `ChangeFiremode()` / `FiremodeAvailable()` (sh_shoot.lua:728-820)

```lua
-- weapons/mcv_base/sh_shoot.lua:728-741
function SWEP:FiremodeAvailable(mode)
    if mode == MCV.FIREMODE_FAN then
        return self:HasAnimation(ACT_VM_PRIMARYATTACK_1)
    elseif mode == MCV.FIREMODE_DA then
        if self:GetAkimbo() then
            // one hand each: the right gun's prepare and the left gun's
            return self:HasAnimation(ACT_VM_HAULBACK) and self:HasAnimation(ACT_VM_PULLPIN)
        end
        return self:HasAnimation(ACT_VM_HAULBACK)
    end
    return true
end
```

`ChangeFiremode` (bound to USE+RELOAD via the common think, cross-ref `docs/gun-core.md`):
- No-op in grenade-launcher mode (preserves the rifle's selected mode, sh_shoot.lua:746).
- `AdjustableScopes` weapons instead cycle `ScopeLevel` 1↔2 with reversed `ACT_VM_FIDGET`
  (sh_shoot.lua:748-765).
- `#Firemodes <= 1` → nothing; else resets `BurstCount`, walks the list **wrapping** and
  skipping modes the current viewmodel cannot animate (sh_shoot.lua:774-782), stamps the
  networked `Firemode`, and plays the per-target selector animation
  (`ACT_VM_FIREMODE`/`_I`/`_D`, bipod `_D`, reversed mult when wrapping to mode 1) —
  animation details in anim doc §7.9. Fallback when the animation is missing: 0.25 s plain
  anim lock + `MCV_Weapon_Foley_AK47.DrawMetal` click (sh_shoot.lua:814-817).
- Prints "Switched to <name>" to chat (sh_shoot.lua:819).
- Akimbo swap re-runs it when the swapped model drops the current mode (sh_akimbo.lua:36-38,
  anim doc §7.9).

---

## 4. Spread & Accuracy Model

### 4.1 `SWEP:GetSpread()` (sh_shoot.lua:361-403) — SH, predicted

```lua
-- weapons/mcv_base/sh_shoot.lua:361-403
function SWEP:GetSpread()
    if self:GetOwner():IsNPC() then return self:GetNPCSpread() end
    local sa = self:GetSightAmount()
    local fm = self:GetFiremodeValue()
    local spread = self.Spread
    local sighted = self.SpreadIronsighted

    // a deployed bipod uses the game's bipod spreads (BulletSpreadDegreesBipod*)
    if self:GetBipod() and self.SpreadBipod then
        spread = self.SpreadBipod
        sighted = self.SpreadBipodIronsighted or self.SpreadBipod
    end

    spread = spread * self:StatMult("spread")
    sighted = sighted * self:StatMult("spread_sights")

    local stance = self:GetStanceSpreadMultiplier()

    if MCV.RealisticShooting() then
        // realistic (mcv_realistic_shooting 1): the bullet leaves the barrel wherever it points.
        // Hip fire misses because the gun is not lined up with the eye, not through a cone, so
        // the gun's own dispersion is all there is from the hip, and on the sights a rifle or
        // pistol reduces dispersion to a quarter. Shotguns and volley fire keep their
        // pattern whatever the sight amount or stance.
        if self:GetBulletCount() > 1 or fm == MCV.FIREMODE_VOLLEY then
            spread = sighted
        else
            spread = sighted * Lerp(sa, 1, 0.25)
        end
    else
        // the game: a hip fire cone that narrows to the sighted spread as the sights come up,
        // widened by stance and movement
        spread = Lerp(sa, spread, sighted) * stance
    end

    if fm == MCV.FIREMODE_SA then
        spread = spread * 0.5
    elseif fm == MCV.FIREMODE_DA then
        spread = spread * 0.75
    end

    return spread / 100
end
```

Key contracts:
- **Units**: authored fields are "spread units"; the return is `units / 100`, fed directly as
  the engine `FireBullets.Spread` vector (radians of cone). Default hip 6.3, sights 1.15
  (mcv_base/shared.lua:121-122) → 0.063 / 0.0115.
- `GetSightAmount()` is the **eased, networked** sight blend (sh_sights.lua:36-38) — identical
  on both realms by construction (integrated one tick at a time; anim doc §4.3 / gun-core).
- Bipod deployed swaps to `SpreadBipod`/`SpreadBipodIronsighted` *before* stance and category
  multipliers (BUGLIST.md:352: "Bipod accuracy should work").
- The realistic mode's shotgun/volley exemption (BUGLIST.md:217): patterns never tighten with
  the sights; single-projectile guns drop to quarter dispersion when fully aimed.
- Consumers: hitscan `BulletAttack` (§6.1), `GetAimSwayAmplitude` (§4.4), the crosshair, NPC
  spread falls through to `GetNPCSpread` (§10.2).

### 4.2 Stance multiplier — `GetStanceSpreadMultiplier()` (sh_shoot.lua:230-243)

```lua
-- weapons/mcv_base/sh_shoot.lua:230-243
function SWEP:GetStanceSpreadMultiplier()
    local owner = self:GetOwner()
    if !IsValid(owner) then return 1 end

    local speed, grounded, crouched = self:GetWeaponMovement()
    local move = math.min(speed / 273, 1)

    if !grounded then
        return Lerp(move, 1, self.JumpSpreadMultiplier)
    elseif crouched then
        return Lerp(move, self.CrouchSpreadMultiplier, self.CrouchMoveSpreadMultiplier)
    end
    return Lerp(move, 1, self.StandMoveSpreadMultiplier)
end
```

`GetWeaponMovement()` (weapon_common/sh_movement.lua:44-56) returns the **completed previous
command's** movement sample (speed, grounded, crouched) from networked storage, so client and
server read the same values despite their different Think/movement ordering — the fix for
BUGLIST.md:320. Field defaults (mcv_base/shared.lua:144-149): `CrouchSpreadMultiplier 0.85`,
`ProneSpreadMultiplier 0.75`, `StandMoveSpreadMultiplier 1.5`, `SneakMoveSpreadMultiplier 1.4`,
`CrouchMoveSpreadMultiplier 1.35`, `JumpSpreadMultiplier 3.0`. 273 HU/s is the run-speed
normalization. The same multiplier also drives the crosshair size and (in realistic mode) the
hip-sway amplitude — one number, three consumers (comment, sh_shoot.lua:225-229).

### 4.3 Client-only visual smoothers (sh_shoot.lua:245-274, 290-314)

`GetStanceSpreadMultiplierVisual` (CL) eases toward the gameplay value at `StanceSmoothRate = 6`
per second, snapping when more than `StanceResyncThreshold = 4` apart; `GetSwaySteadyVisual`
(CL) eases the bipod/reload steadiness at `SwaySteadyRate = 4`. On the server (and inside
prediction for the local player, `GetPredictionPlayer() == owner`) both alias the real
functions. **Shots always read the un-eased values** — the drawn barrel/crosshair may differ
from the true cone for a fraction of a second after a stance change. This mirrors the sight
blend's visual/gameplay split (anim doc §4.3).

### 4.4 Realistic shooting: hip sway (sh_shoot.lua:281-341)

When `MCV.RealisticShooting()` is on, hip inaccuracy is modeled as **barrel wander** instead of
a cone:

- `GetSwaySteady()` (286-288): 0 while bipod-deployed or reloading (both networked → identical
  realms), else 1.
- `GetAimSwayAmplitude(visual)` (317-332): `(Spread or 0) * StatMult("spread") * HipSwayScale *
  (1 - sightAmount)`, halved for multi-pellet guns, × stance × steady.
  `SWEP.HipSwayScale = 0.25` (sh_shoot.lua:281) — peak degrees per axis.
- `GetAimSway(visual)` (334-341): two-tone sines in pitch and yaw:

```lua
-- weapons/mcv_base/sh_shoot.lua:334-341
function SWEP:GetAimSway(visual)
    local amp = self:GetAimSwayAmplitude(visual)
    if amp <= 0.0001 then return angle_zero end
    local t = CurTime() + self:EntIndex() * 7.3
    local p = (math.sin(t * 1.1) * 0.6 + math.sin(t * 2.3 + 1.7) * 0.4) * amp
    local y = (math.sin(t * 0.8 + 0.9) * 0.6 + math.sin(t * 1.9 + 3.1) * 0.4) * amp
    return Angle(p, y, 0)
end
```

Pure function of `CurTime()` + `EntIndex()` → **deterministic across realms with zero
networking**. Consumers: `GetAimAngle` (below), the crosshair, the scope reticle, viewmodel
(§4.5).

### 4.5 The aim contract — `GetAimAngle` / `GetAimVector` (sh_shoot.lua:346-359)

```lua
-- weapons/mcv_base/sh_shoot.lua:343-359
// The direction a shot leaves along: eye angles, twice the view punch the recoil put on the gun,
// and the hip sway. Bullets, projectiles, the crosshair, the scope reticle and the viewmodel all
// read this.
function SWEP:GetAimAngle(visual)
    local owner = self:GetOwner()
    if owner:IsNPC() then return owner:GetAimVector():Angle() end
    if !MCV.RealisticShooting() then
        // the game: the shot goes where the view points. The camera carries the whole punch
        // (cl_camera.lua takes none of it out in this mode), so this is the screen centre
        return owner:EyeAngles() + owner:GetViewPunchAngles()
    end
    return owner:EyeAngles() + owner:GetViewPunchAngles() * 2 + self:GetAimSway(visual)
end
```

This is **the single source of shot direction** for bullets, rockets, crosshair, reticle and
viewmodel. Note the realistic mode's `ViewPunchAngles * 2`: `cl_camera.lua` removes most of the
punch from the *picture* in that mode, so doubling it in the *aim* keeps the kick meaningful
(cross-ref `docs/gun-core.md` for CalcView). The weapon_common base version
(weapon_common/shared.lua:363-371) is just `EyeAngles + ViewPunch` — mcv_base's override adds
NPC and realistic handling.

### 4.6 NPC spread — `GetNPCSpread()` (sh_npc.lua:4-6)

`(self.NPCSpread or self.Spread) * StatMult("spread") / 100` — same unit contract, an authored
override for AI balance. Plus the engine-facing proficiency cone `GetNPCBulletSpread`
(§10.2).

### 4.7 RNG & prediction determinism — the four spread paths

| Path | RNG | Deterministic? |
|---|---|---|
| Hitscan cone | engine `FireBullets` Spread | **No** (engine rolls per realm; MCV treats client traces as cosmetic, sh_shoot.lua:584-586) |
| Rocket/projectile spread | `SWEP:RandomSpread` → `util.SharedRandom("mcv_randomspread"…, seed = EntIndex + TickCount + n)` (weapon_common/shared.lua:373-380) | Yes (server-only anyway, §9) |
| Physical-bullet spread | `MCV.PhysicalBulletHeading` → `util.SharedRandom("MCV_PhysicalSpread:<key>"…, pellet*256 + draw)` (sh_physbullets.lua:96-109) | Yes — keyed by command number so the predicted client and the server roll *identical* headings |
| Hip sway / stance | pure `CurTime()` functions | Yes |

`RandomSpread` (rejection-sampled? no — it is a uniform angle disc): picks a random bearing
`a` via SharedRandom, then offsets `Angle(sin a, cos a, 0) * spread * SharedRandom(0..45) *
1.414` — an octagonal-ish disc in *degrees*, added to the launch angle (used by
`LaunchProjectile`, not by hitscan).

### 4.8 `MCV.PhysicalBulletHeading` (sh_physbullets.lua:96-109) — SH

```lua
-- mcv/shared/sh_physbullets.lua:96-109
function MCV.PhysicalBulletHeading(wep, dir, pellet, key)
    local owner = wep:GetOwner()
    local spread = owner:IsNPC() and wep:GetNPCSpread() or wep:GetSpread()
    local draw = 0
    local function random()
        draw = draw + 1
        if key == "" then return math.Rand(-0.5, 0.5) end
        return util.SharedRandom("MCV_PhysicalSpread:" .. key, -0.5, 0.5, pellet * 256 + draw)
    end
    local x, y
    repeat x, y = random() + random(), random() + random() until x*x + y*y <= 1
    local angle = dir:Angle()
    return (dir + angle:Right() * (x * spread) + angle:Up() * (y * spread)):GetNormalized()
end
```

A **rejection-sampled uniform disc** (sum of two uniforms per axis, reject outside the unit
circle — a true 2-D Gaussian-ish cone with no corner bias), seeded per pellet & draw call.
`key == ""` (NPC / out-of-command fire) degrades to `math.Rand` because there is no command
number to key on — the server is authoritative for those anyway.

---

## 5. Recoil

### 5.1 `SWEP:AttackEffects()` view punch (sh_shoot.lua:405-478) — SH, predicted

`AttackEffects` runs after `BulletAttack`/`RocketAttack` on **every prediction pass** (comment at
584: ammo/recoil updated every pass) and owns: view punch, eject/muzzle (first-time-predicted),
shoot gesture, burst count increment, ammo take, shot sounds, velocity impulse. The recoil core:

```lua
-- weapons/mcv_base/sh_shoot.lua:408-446
    local recoilmult = 1

    local fm = self:GetFiremodeValue()

    if fm == MCV.FIREMODE_VOLLEY then
        recoilmult = math.min(self:Clip1(), self.VolleyCount)
    end

    if self:GetAkimbo() then
        recoilmult = recoilmult * 1.25
    end

    if self:GetBipod() then
        recoilmult = recoilmult * 0.25 // Bipod absorbs 75% of recoil.
    end

    recoilmult = recoilmult * self:StatMult("recoil")

    self:SetLastRecoilTime(CurTime())

    local sa = self:GetSightAmount()
    // BurstCount is the predicted number of earlier shots, incremented below.
    // Read it on every replay; never accumulate recoil in an ordinary Lua field.
    local preceding = self:GetBurstCount()
    local recoilup = (Lerp(sa, self.ViewSlideRecoilUp, self.ViewSlideRecoilIronsightUp)
        + preceding * (self.ProgressiveRecoilUp or 0)) * recoilmult
    local recoilright = (Lerp(sa, self.ViewSlideRecoilRight, self.ViewSlideRecoilIronsightRight)
        + preceding * (self.ProgressiveRecoilRight or 0)) * recoilmult

    if MCV.RealisticShooting() then
        // realistic: from the hip the gun jumps in a random direction and harder; on the sights
        // it climbs by the script's slide. CalcView takes most of the punch back out of the
        // view so the kick moves the aim more than the picture.
        owner:ViewPunch((1 - (sa * 0.5)) * Angle(((sa * recoilup) + ((1 - sa) * recoilright)) * (-sa + (util.SharedRandom("MCVRecoilUpDown", -1, 1) * (util.SharedRandom("MCVRecoilUpDown", 0.5, 1) - sa))), recoilright * util.SharedRandom("MCVRecoilLeftRight", -1, 1), 0))
    else
        // the game's fixed view slide: up by ViewSlideRecoil.Up, sideways by .Right (side at
        // random), the ironsight pair when aiming
        owner:ViewPunch(Angle(-recoilup, recoilright * util.SharedRandom("MCVRecoilLeftRight", -1, 1), 0))
    end
```

- Two models: the game's fixed slide (`ViewPunch(Angle(-up, ±right, 0))`) vs realistic
  (random up/down from the hip, damped by aim, `SharedRandom` seeds make replays identical).
- The camera's handling of the punch differs per mode (§4.5 note; `docs/gun-core.md`).
- BUGLIST.md:169: "Bipod firing now retains 25% recoil instead of eliminating it" — the ×0.25.
- BUGLIST.md:111 added `ProgressiveRecoilUp/Right` (both default 0, mcv_base/shared.lua:96-97);
  first shot of a pull adds zero because `preceding` is read *before* the increment at line 457.

### 5.2 Recoil multiplier stack (order matters)

```
recoilmult = volleyRounds? × (akimbo ? 1.25) × (bipod ? 0.25) × StatMult("recoil")
recoilup   = (Lerp(sa, hipUp, adsUp) + BurstCount × ProgressiveRecoilUp) × recoilmult
```

### 5.3 Velocity kick — `QueueRecoilImpulse` (weapon_common/sh_movement.lua:4-27)

```lua
-- mcv/weapon_common/sh_movement.lua:4-27
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

The pushback (`RecoilPushbackValue`, default 1.5, mcv_base/shared.lua:99) is queued into
networked `RecoilImpulse`/`RecoilCommand` and applied in `SetupMove` of a *later* command so
both realms apply it at the same movement phase — the fix for BUGLIST.md:327. NPCs get a direct
`SetVelocity`. Both impulse and command number restore on command replay.

### 5.4 Pose-parameter recoil (akimbo) — pointer

`HasPoseRecoil()` (sh_shoot.lua:173-199) + `LastShotTimeR/L` stamps drive per-hand recoil
*layers* instead of sequences. Fully documented in anim doc §7.4; the ballistics-relevant part
is only that firing still runs the normal `AttackEffects`/`BulletAttack` — pose recoil changes
no ballistics.

### 5.5 Camera shake fields

`ShakeScale` / `ShakeFreq` / `ShakeDuration` (defaults 1 / 45 / 0.4, weapon_common/shared.lua:151-153)
feed the screen-shake system — cross-ref `docs/gun-core.md` (camera). They are per-weapon tuned
(e.g. vcshotgun 3/30/0.6, mcv_vcshotgun.lua:59-62).

### 5.6 Recoil field catalogue

| Field | Default (file:line) | Meaning |
|---|---|---|
| `ViewSlideRecoilUp` | 1.35 (mcv_base/shared.lua:87) | Hip vertical kick (degrees of punch) |
| `ViewSlideRecoilRight` | 0.48 (:88) | Hip horizontal kick amplitude |
| `ViewSlideRecoilIronsightUp` | 1.35 (:90) | Aimed vertical kick |
| `ViewSlideRecoilIronsightRight` | 0.48 (:91) | Aimed horizontal kick amplitude |
| `ProgressiveRecoilUp` / `…Right` | 0 (:96-97) | Additive per preceding shot in the pull |
| `RecoilPushbackValue` | 1.5 (:99) | Backwards velocity impulse magnitude |
| `ShakeScale/Freq/Duration` | 1/45/0.4 (weapon_common/shared.lua:151-153) | Camera shake |

weapon_common's base defaults zero all of these (shared.lua:136-139) — melee/throwables have no
slide recoil.

---

*Sections 6–13 continue: the hitscan shot, physical bullets, penetration, rockets, the NPC path,
field catalogues, translation surface and the file map.*

---

## 6. The Shot Itself — Hitscan `SWEP:BulletAttack()` (sh_shoot.lua:573-641)

### 6.1 Full walkthrough — SH, predicted

```lua
-- weapons/mcv_base/sh_shoot.lua:573-641
function SWEP:BulletAttack(shootPos, shootDir)
    local owner = self:GetOwner()

    if MCV.PhysicalBulletsEnabled(self) then
        if SERVER then MCV.LaunchPhysicalBullets(self, shootPos, shootDir) end
        if CLIENT and (game.SinglePlayer() or IsFirstTimePredicted()) then
            MCV.PredictPhysicalBullets(self, shootPos, shootDir)
        end
        return
    end

    // Ammo/recoil are updated by the caller on every prediction pass. These
    // client traces exist only for presentation; never replay their effects.
    if CLIENT and (game.SinglePlayer() or !IsFirstTimePredicted()) then return end

    local spread = self:GetSpread()

    if owner:IsPlayer() then owner:LagCompensation(true) end

    local num = self:GetBulletCount()

    if self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY then
        num = num * math.min(self:Clip1(), self.VolleyCount)
    end

    local queue = {}
    local function fireSegment(state, count, cone, tracer)
        if state.exitTrace then
            MCV.HitscanEffects(self, state.exitTrace, state.exitDamage, 0, true)
        end
        owner:FireBullets({
            Damage = state.damage,
            Num = count,
            Src = state.src,
            Dir = state.dir,
            Spread = cone,
            Distance = 56756 - state.distance,
            Attacker = owner,
            Inflictor = self,
            Tracer = 0,
            TracerName = "mcv_tracer",
            Callback = function(attacker, tr, dmginfo)
                local distance = state.distance + (tr.HitPos - tr.StartPos):Length()
                self:ApplyBulletDamage(tr, dmginfo, distance)
                local queued = #queue
                self:QueuePenetration(tr, state, queue)
                MCV.HitscanEffects(self, tr, dmginfo:GetDamage(), tracer, #queue > queued)
                return {effects = false}
            end
        })
    end
    fireSegment({src = shootPos or owner:GetShootPos(), dir = shootDir or self:GetAimVector(),
        damage = self.DamageGeneric * self:StatMult("damage"), distance = 0, budget = 1, layers = 0},
        num, Vector(spread, spread, spread), 1)

    // Finish each FireBullets call before firing its continuations, so nested
    // engine multi-damage accumulation cannot apply a target's damage twice.
    // Client continuations predict effects too; server traces stay inside the
    // original shot's lag-compensation window.
    do
        local index = 1
        while queue[index] do
            fireSegment(queue[index], 1, vector_origin, 0)
            index = index + 1
        end
    end

    if owner:IsPlayer() then owner:LagCompensation(false) end
end
```

Structural notes:

- **Optional `shootPos` / `shootDir` injection** — the NPC path (§10.4) and the harness
  (`mcv_harness/penetration_tests.lua:52-53`) override both origin and direction. A translation
  layer can do the same instead of monkey-patching.
- **Client gating**: physical mode → client predicts visuals only on the first predicted pass
  (SP clients always); hitscan mode → in SP the client never runs the call (server-driven), in
  MP only on `IsFirstTimePredicted()`. The engine itself predicts `FireBullets` damage; MCV's
  own callback effects are what the gate protects.
- **Segment queue**: penetration continuations are *not* fired inside the callback (comment:
  nested engine multi-damage could double-apply). They are drained after the outer
  `FireBullets` returns, still inside the `LagCompensation` window on the server.

### 6.2 `FireBullets` parameter table

| Param | Value | Notes |
|---|---|---|
| `Damage` | `state.damage` | `DamageGeneric * StatMult("damage")`, already range-scaled per segment by `ApplyBulletDamage` |
| `Num` | `num` first segment; `1` for continuations | `GetBulletCount()` (`Num`, default 1; M79 buckshot 12), × volley rounds |
| `Src` / `Dir` | `state.src` / `state.dir` | origin/aim or injected; continuations use the penetration exit point & direction |
| `Spread` | `Vector(spread, spread, spread)` first; `vector_origin` after | radians cone (§4.1); continuations fly straight |
| `Distance` | `56756 - state.distance` | global 56756 HU (~1.44 km) travel cap shared with physical bullets |
| `Attacker`/`Inflictor` | owner / self | attribution contract for hooks |
| `Tracer` / `TracerName` | `0` / `"mcv_tracer"` | `Tracer = 0` means the engine fires **no** tracers — `TracerName` is effectively vestigial; the `mcv_tracer` effect is dispatched by hand from the callback (§6.7) |
| `Callback` | closes over `state`/`queue` | returns `{effects = false}` — engine impact effects/decal suppressed, MCV owns them (§6.7) |

### 6.3 Penetration continuation protocol (hitscan side)

Each callback: (1) `ApplyBulletDamage`, (2) `QueuePenetration` may append a continuation state to
`queue` (§8.3), (3) `HitscanEffects` with `noRicochet = (#queue > queued)` — a hit that
penetrates cannot also spawn a ricochet. After the outer call, each queued state is fired as a
single-bullet, zero-spread segment from the *exit point*, and its pre-attached `exitTrace` first
emits the exit-face impact (`fireSegment` head, sh_shoot.lua:600-602) with `tracer = 0,
noRicochet = true`. Total travelled distance is carried in `state.distance` so range falloff is
never reset after a wall (§8.3).

### 6.4 Lag compensation

`owner:LagCompensation(true/false)` brackets the whole shot *including its continuations*
(sh_shoot.lua:590, 640) — server-side rewind to the firing command. Physical bullets
deliberately have **no** lag compensation (sv_physbullets.lua:143-144: "this bullet hits what
occupies this position now").

### 6.5 `SWEP:ApplyBulletDamage(tr, dmginfo, distance, bulletCount)` (sh_penetration.lua:20-56) — SH

Called from every hitscan segment callback and every physical-bullet contact callback. Order:

```lua
-- weapons/mcv_base/sh_penetration.lua:20-43
function SWEP:ApplyBulletDamage(tr, dmginfo, distance, bulletCount)
    if (bulletCount or self:GetBulletCount()) > 1 then
        dmginfo:SetDamageType(bit.bor(dmginfo:GetDamageType(), DMG_BUCKSHOT))
    end
    dmginfo:SetDamage(dmginfo:GetDamage() * MCV.BulletRangeMultiplier(self, distance))
    if !IsValid(tr.Entity) then return end
    if self.ArmorPiercing then
        local target = tr.Entity
        // Strider limb collisions can be represented by a physics bone follower.
        if target:GetClass() == "phys_bone_follower" and IsValid(target:GetOwner()) then
            target = target:GetOwner()
        end
        local class = target:GetClass()
        if class == "npc_helicopter" then
            dmginfo:SetDamageType(DMG_AIRBOAT)
            return
        elseif class == "npc_strider" or class == "npc_combinegunship" then
            // These NPCs reject ordinary bullets. This is still one direct hit,
            // not a radius explosion; retain the engine's armor/difficulty rules.
            dmginfo:SetDamageType(DMG_BLAST)
            return
        end
    end
    MCV.CancelBodyDamage(tr.Entity, dmginfo, tr.HitGroup)
```

1. **`DMG_BUCKSHOT`** added for multi-pellet shots (physical bullets pass `b.pellets`
   explicitly, sv_physbullets.lua:149).
2. **Range scaling**: `MCV.BulletRangeMultiplier` (§7.4) — `RangeModifier^(distance/500)` or the
   optional damage ramp.
3. World / invalid entity → return (no hitgroup scaling on world).
4. **`ArmorPiercing`** (PTRD, mcv_ptrd.lua:12): helicopter → `DMG_AIRBOAT`; strider/gunship →
   `DMG_BLAST` (retains armor rules); `phys_bone_follower` redirect. Damage amount unchanged —
   only the type.
5. **`MCV.CancelBodyDamage`** then the MCV hitgroup multipliers (§6.6).

Hitgroup multipliers (sh_penetration.lua:44-55): `HITGROUP_HEAD → DamageHeadMultiplier`,
`CHEST → DamageChestMultiplier`, `STOMACH → DamageStomachMultiplier`, arms →
`DamageArmMultiplier`, legs → `DamageLegMultiplier` (all default 1, mcv_base/shared.lua:23-27;
Type 67 silenced puts arms at 4, mcv_type67.lua:40 — an authored oddity).

### 6.6 Hitgroups — `MCV.CancelBodyDamage` (mcv/shared/sh_hitgroups.lua:1-14) — SH

```lua
-- mcv/shared/sh_hitgroups.lua:1-14
function MCV.CancelBodyDamage(ent, dmginfo, hitgroup)
    local tbl = MCV.CancelMultipliers[string.lower(engine.ActiveGamemode())] or MCV.CancelMultipliers[1]

    if IsValid(ent) and (ent:IsNPC() or ent:IsPlayer()) then
        dmginfo:ScaleDamage(1 / (tbl[hitgroup] or 1))
    end

    -- Lambda Players call ScalePlayerDamage and cancel out hitgroup damage... except on the head
    if IsValid(ent) and ent.IsLambdaPlayer and hitgroup == HITGROUP_HEAD then
        dmginfo:ScaleDamage(1 / (tbl[hitgroup] or 1))
    end

    return dmginfo
end
```

The engine/gamemode applies its own hitgroup scaling (`ScalePlayerDamage` etc.) when
`FireBullets` lands; MCV **inverts it** (using the sandbox defaults: head ×2, arms/legs/gear
×0.25; TTT variant: head ×1, limbs ×0.55 — `MCV.CancelMultipliers`, sh_common.lua:44-61) and
then applies its own authored multipliers. Net effect: MCV weapon files fully own hitgroup
damage regardless of gamemode. The Lambda-Player addon quirk is special-cased.

### 6.7 `MCV.HitscanEffects` (mcv/shared/sh_hitscaneffects.lua:2-42) — SH

Routing for tracer + impact effects, called from the firing callback (BUGLIST.md:85: effects
moved into the callback, engine path disabled):

- CL/MP: only on `IsFirstTimePredicted()`.
- Recipients: server sends PVS-based (start **and** hit positions), **excluding the shooter**
  in MP (their client already predicted the effects); SP and NPC shots remain server-driven.
- Tracer: `showTracer = tracer > 0` (first segment only, §6.3) → `util.Effect("mcv_tracer", …)`.
  Silenced tracers (`vietnam_tracer_silenced_primary`) are shooter-only (MP: self-predicted;
  SP: server → owner only; BUGLIST.md:63).
- Ricochet: `!noRicochet and showTracer and MCV.HasTracerStreak(TracerParticle) and
  Clip1() % max(TracerFrequency, 1) == 0` → passed to `MCV.BulletImpact` with the tracer colour.
  Cosmetic only — no damage (BUGLIST.md:37, 29, 33).
- `MCV.BulletImpact` (sh_impacts.lua:27-42) then plays the game's per-surface impact or the
  stock engine `Impact` (worldspawn-safe, BUGLIST.md:4) — full detail in `docs/effects.md`.

**Clip-parity timing subtlety**: the ricochet gate reads `Clip1()` *inside the callback*, i.e.
before `AttackEffects` takes the round; `effects/mcv_tracer.lua:93-94` re-checks
`Clip1() % freq` when the effect inits (after the shot's ammo accounting) — the two sites agree
for `freq == 1` and use the same "count rounds in the magazine" convention otherwise
("both realms reach the same answer without anything being networked for it",
mcv_tracer.lua:89-92). The akimbo left/right convention has the same ±1 offset: server launch
uses pre-shot `Clip1() % 2 == 1` (sv_physbullets.lua:98, cl_physbullets.lua:180) while the
tracer effect uses `% 2 == 0` (mcv_tracer.lua:53) — post-decrement parity. **Any translation
layer that changes when ammo is decremented shifts tracer cadence and left-gun selection.**

### 6.8 Tracer colour (mcv/shared/sh_tracercolor.lua:1-33 + mcv/client/cl_tracercolor.lua:1-3)

- `mcv_tracer_color` is a **userinfo** client convar (CL, cl_tracercolor.lua:2-3): 0 = the gun's
  own colour, 1 = the shooter's player colour, 2 = their physgun colour — "Other players see
  the one you pick."
- `MCV.TracerColorMode(ply)` reads it via `ply:GetInfo` (so the *shooter's* choice is resolved
  on every client); `MCV.TracerColor(owner, tracer)` returns `BrightColor(playerColor)`,
  `BrightColor(weaponColor)`, or the family default (amber `235,175,51`, green `96,235,51` when
  the particle name contains `_green`).
- `MCV.HasTracerStreak(tracer)` (sh_tracercolor.lua:22-26): families with a glowing streak —
  assaultrifle, gyrojet, machinegun, pistol, ptrd, rifle, shotgun, smg, sniperrifle — decided by
  stripping `vietnam_tracer_`, `_primary/_secondary`, `_green` from `TracerParticle`.
- `MCV.BrightColor(v)` normalizes any vector to a full-brightness Color.
- Consumers: `HitscanEffects` (ricochet colour), `sv_physbullets` (networked tracer colour),
  `cl_physbullets` `create()` and the `mcv_tracer` EFFECT (streak tint).

`SWEP.TracerParticle2` (the game's `_secondary` streak) is carried from the scripts but **has no
consumer** (comment, mcv_base/shared.lua:66-70); same for `SWEP.TracerRandomness` (set by every
weapon, e.g. mcv_rpd.lua:179; no reader in the base).

### 6.9 Shot audio — `SWEP:EmitShotSound(name)` (sh_shoot.lua:540-553) + helpers

Every shot is **two recordings** (comment, sh_shoot.lua:480-505): the near report and the same
shot heard from far away (`<name>Distant`, resolved once per name via `sound.GetProperties`,
cached in the file-local `distant_of` table; seven weapons have none). Both are emitted to
everyone — their soundlevels (100 near / 125 distant) do the distance separation.

- `EmitShotSound` is `IsFirstTimePredicted`-gated; rotates a cosmetic slot counter
  `MCVShotSoundSlot % MCV.SHOT_SOUND_SLOTS` (4 slots per layer, sh_common.lua:18-20:
  `CHAN_SHOT = CHAN_USER_BASE`, `CHAN_SHOT_DISTANT = CHAN_USER_BASE + 4`) so fast automatics
  don't cut their own reports (BUGLIST.md:53, 109 — the old CHAN_STATIC stacking bug).
- `emitShotLayer` (518-538) resolves the soundscript to raw sample/volume/pitch because
  `Entity:EmitSound` ignores channel overrides on script names; `pickShotValue` (506-516) picks
  from script tables — **`util.SharedRandom` keyed by sound name when predicted** (player
  owner), `math.Rand` otherwise, so replays don't re-roll the pitch.
- Volley: `SoundDoubleShot` while more than one round remains, else `SoundSingleShot`
  (sh_shoot.lua:465-469). The nearly-empty click (`SoundNearlyEmpty`) is commented out
  (sh_shoot.lua:473-475).

---

## 7. Physical Bullets

### 7.1 Enable gate — `MCV.PhysicalBulletsEnabled(wep)` (sh_physbullets.lua:2-9) — SH

```lua
-- mcv/shared/sh_physbullets.lua:2-9
function MCV.PhysicalBulletsEnabled(wep)
    if !MCV.ConVars.mcv_physbullets:GetBool() or wep:GetProjectileClass() then return false end
    if (wep.MuzzleVelocity or 0) <= 0 then return false end
    local owner = wep:GetOwner()
    if !IsValid(owner) then return false end
    if owner:IsNPC() and !MCV.ConVars.mcv_physbullets_npcs:GetBool() then return false end
    return wep:GetBulletCount() <= 1 or MCV.ConVars.mcv_physbullets_pellets:GetBool()
end
```

Off for projectile weapons, weapons without a `MuzzleVelocity` stat (m/s, e.g.
`SWEP.MuzzleVelocity = 735`, mcv_ak47.lua:43), NPCs (unless opted in), and multi-pellet guns
(unless pellets opted in). Must agree on both realms — it gates the client's `BulletAttack`
branch (§6.1) and the server's launch identically.

### 7.2 `MCV.PhysicalBulletParameters(wep)` (sh_physbullets.lua:64-73) — SH

Returns `speed, gravity, drag, lifetime, acceleration, burn`:

- `speed`: `(BulletBoostTime > 0 ? BulletLaunchVelocity : MuzzleVelocity)`, minimum 1, then ×
  `mcv_physbullets_velocity` (clamped 0.1–3) **÷ 0.0254** — metres/second → Hammer units/second
  (1 unit = 1 inch).
- `gravity`: `9.80665 / 0.0254 × mcv_physbullets_gravity` (0–3) ≈ 386 HU/s² at 1.
- `drag`: `mcv_physbullets_drag` (0–2), inverse seconds.
- `lifetime`: `mcv_physbullets_lifetime` (0.1–10 s).
- `acceleration`/`burn`: the **gyrojet rocket-bullet motor** (Part 2 weapons): a finite boost
  along the launch direction from `BulletLaunchVelocity` up to `MuzzleVelocity` over
  `BulletBoostTime` (BUGLIST.md:73: 40 → 403 m/s over 0.2 s).

### 7.3 The flight integrator — `MCV.BulletFlightStep` (sh_physbullets.lua:13-38) — SH

```lua
-- mcv/shared/sh_physbullets.lua:13-38
// Analytic integration of constant gravity/thrust and linear drag, independent of tick rate.
// Velocity is HU/s, gravity is HU/s^2, drag is inverse seconds.
function MCV.BulletFlightStep(pos, vel, dt, gravity, drag, boost, burnRemaining)
    // Split exactly at motor burnout, including network catch-up steps. Thrust
    // follows the launch direction; gravity still bends the flight normally.
    if boost and burnRemaining > 0 and burnRemaining < dt then
        local p, v = MCV.BulletFlightStep(pos, vel, burnRemaining, gravity, drag, boost, burnRemaining)
        return MCV.BulletFlightStep(p, v, dt - burnRemaining, gravity, drag)
    end
    local ax, ay, az = 0, 0, -gravity
    if boost and burnRemaining > 0 then
        ax, ay, az = boost.x, boost.y, boost.z - gravity
    end
    // Scalar integration creates only the two result vectors. Operator chains
    // allocate intermediate userdata for every bullet's every substep.
    if drag <= 0 then
        local half = 0.5 * dt * dt
        return Vector(pos.x + vel.x * dt + ax * half, pos.y + vel.y * dt + ay * half,
            pos.z + vel.z * dt + az * half),
            Vector(vel.x + ax * dt, vel.y + ay * dt, vel.z + az * dt)
    end
    local decay = math.exp(-drag * dt)
    local factor = (1 - decay) / drag
    local forceFactor = (dt - factor) / drag
    return Vector(pos.x + vel.x * factor + ax * forceFactor, pos.y + vel.y * factor + ay * forceFactor,
        pos.z + vel.z * factor + az * forceFactor),
        Vector(vel.x * decay + ax * factor, vel.y * decay + ay * factor, vel.z * decay + az * factor)
end
```

**Closed-form ballistic integration** — identical results at any dt, which is what lets the
client (frame-rate Think, catch-up steps) and the server (tick steps) agree on a trajectory
without ever networking positions. This one function is the entire flight model for bullets
*and* the client-side visual of the same.

### 7.4 Range/damage — `MCV.BulletRangeMultiplier(wep, distance)` (sh_physbullets.lua:42-49) — SH

```lua
-- mcv/shared/sh_physbullets.lua:42-49
function MCV.BulletRangeMultiplier(wep, distance)
    if (wep.DamageRampDistance or 0) > 0 then
        local t = math.Clamp(distance / wep.DamageRampDistance, 0, 1)
        local start = wep.DamageRampStart or 1
        return start + ((wep.DamageRampEnd or 1) - start) * t
    end
    return math.pow(wep.RangeModifier or 1, math.max(distance / 500, 0))
end
```

Two regimes: the game's
classic `RangeModifier^(distance/500)` (default 0.95/0.9, mcv_base/shared.lua:29) or a capped
linear **damage ramp** (`DamageRampStart → DamageRampEnd` over `DamageRampDistance` HU; the
gyrojets ramp 25% → 150% over 2000 HU, BUGLIST.md:73; the HUD shows both ends,
weapon_common/cl_hud.lua:570-573). Consumed by `ApplyBulletDamage`, the physical exit-effect
damage, client cosmetic impact damage, and the glass pane damage.

### 7.5 `MCV.TracePhysicalBullet(b, from, to)` (sh_physbullets.lua:53-62) — SH

One reused trace request per bullet (`{mask = MASK_SHOT, filter = {owner, wep}}`), start/endpos
mutated per substep — allocation-avoidance (BUGLIST.md:77). Returned traces are independent
tables.

### 7.6 Identity & spread keys (sh_physbullets.lua:75-109) — SH

- `MCV.PhysicalShotKey(wep)`: `""` for non-players or zero command number; else
  `"EntIndex:CommandNumber:Clip1:BurstCount"` — **one key per predicted shot**, shared by all
  its pellets (pellet index distinguishes them).
- `MCV.PhysicalImpactKey(owner, key, pellet, serverID)`: `"server:<id>"` when unkeyed (NPC),
  else `"ownerEntIndex:key:pellet"` — the dedup identity shared by server confirmations and
  client predictions (§7.12).
- `MCV.PhysicalBulletCount(wep)`: `GetBulletCount()`, × volley rounds (mirror of the hitscan
  count, sh_shoot.lua:592-596).
- `MCV.PhysicalBulletHeading`: §4.8.

### 7.7 Server simulation (mcv/server/sv_physbullets.lua) — SV

**`MCV.LaunchPhysicalBullets(wep, pos, dir)` (87-108)**: per pellet, roll the heading (shared
key), assign a wrapping 32-bit serial id, build the bullet record and broadcast the spawn
message:

```lua
-- mcv/server/sv_physbullets.lua:97-104
        local b = {id = serial, key = key, pellet = i, src = pos, vel = heading * speed, owner = owner, wep = wep,
            left = wep.GetAkimbo and wep:GetAkimbo() and wep:Clip1() % 2 == 1 or false,
            gravity = gravity, drag = drag, lifetime = lifetime, age = 0,
            boost = acceleration > 0 and heading * acceleration or nil, boostTime = burn,
            damage = wep.DamageGeneric * wep:StatMult("damage"), distance = 0, budget = 1, layers = 0,
            pellets = wep:GetBulletCount(), tracer = wep.TracerParticle or "",
            color = MCV.TracerColor(owner, wep.TracerParticle),
            glow = wep:Clip1() % math.max(wep.TracerFrequency or 1, 1) == 0}
```

`glow` (tracer visibility) and `left` are **decided server-side from pre-shot clip parity** and
travel in the message — remote clients never re-derive them.

**`advance(b, dt)` (110-168)** — one substep:

1. Age/lifetime/distance/validity kill conditions (`maxDistance = 56756`).
2. `BulletFlightStep` → clamp to remaining global distance → `TracePhysicalBullet` swept trace.
3. `waterSplash` (7-21): separate `MASK_WATER` trace (reverse-traced when starting in water);
   `watersplash` effect scaled by `sqrt(damage/40)`; slime flag — server-only cosmetic.
4. No hit → `PhysicalBulletGlass` (§7.9) → advance position, continue.
5. Sky or embedded-world startsolid → stop at `HitPos`.
6. Solid contact → **one `FireBullets` damage bullet across the full swept segment**:

```lua
-- mcv/server/sv_physbullets.lua:138-155
    local continuation = {}
    // The swept trace finds contact; a tracer-free engine bullet applies
    // normal hitgroups, damage hooks, physics force and stock impact fallback.
    // Retrace the whole swept segment: HitPos is tolerance-offset from the solid,
    // so stopping only 0.1 HU past it can still miss the face at a shallow angle.
    // No lag compensation: this bullet hits what occupies this position now.
    b.owner:FireBullets({Src = b.src, Dir = delta:GetNormalized(),
        Distance = length, Spread = vector_origin,
        Num = 1, Tracer = 0, Damage = b.damage, Attacker = b.owner, Inflictor = b.wep,
        IgnoreEntity = b.wep,
        Callback = function(_, hit, damage)
            b.wep:ApplyBulletDamage(hit, damage, b.distance + (hit.HitPos - b.src):Length(), b.pellets)
            b.wep:QueuePenetration(hit, b, continuation)
            impact(b, hit, damage:GetDamage(), false, continuation[1] != nil)
            // Exactly one effect owner: client flight/confirmation, never this
            // engine bullet plus the SWEP impact hook plus a networked effect.
            return {effects = false}
        end})
```

   The full-segment retrace is the BUGLIST.md:41 shallow-angle fix; the startsolid-entity
   passthrough is the BUGLIST.md:47 point-blank pellet fix (comment at 130-132). Startsolid
   *world* still stops with no probing through cover.
7. Penetration continuation (156-165): emit the exit impact, adopt the continuation's
   src/distance/damage/budget/layers (**flight speed is retained** — `vel = dir *
   velocity:Length()`; damage attenuation is the penetration code's job), `send(b, 1)`, keep
   flying. Else stop at `HitPos`.

**Tick loop (170-182)**: every server tick, `steps = ceil(dt / (1/120))` substeps per bullet —
"short curved segments keep gravity accurate even on low-tick servers". Dead bullets get the
`event 2` end message and are removed. `PostCleanupMap` (184-187) ends and clears everything.

**`impact(b, tr, damage, exit, penetrated)` (67-85)**: broadcast `MCV_PhysicalImpact` with the
impact key, contact index `layers * 2 + (exit and 1 or 0)` (entry/terminal even, exits odd —
"separate contact IDs keep a thin wall's exit from deduplicating its entry"), reconstructed
trace payload (HitPos/StartPos/HitNormal/entity/SurfaceProps/MatType/HitBox), damage, and the
ricochet flag (`!exit and !penetrated and b.glow and HasTracerStreak(tracer)`, with colour).

### 7.8 Network protocol (`MCV_PhysicalBullet` / `MCV_PhysicalImpact`)

`writeFlightVector` (sv_physbullets.lua:23-28) writes **three raw floats** because
`net.WriteVector` truncates components above 16384 and rifle velocities exceed it
(BUGLIST.md:103). `send` (30-65) broadcasts (comment: "A fast bullet can enter another client's
PVS after leaving its shooter. Broadcast compact spawn/transition messages, never a per-tick
position stream"):

| Event | UInt(2) | Payload |
|---|---|---|
| 0 spawn | id, src, vel, age, layers(8) + owner, wep, left, key(string), pellet(16), tracer(string), glow, gravity, drag, lifetime, [boost vec + boostTime] |
| 1 penetration correction | id, src, vel, age, layers(8), distance, damage, budget |
| 2 end | id, src |

Client handling in §7.10.

### 7.9 Glass panes (mcv/server/sv_physbullet_glass.lua) — SV

Fractured `func_breakable_surf` becomes a non-solid trigger that `MASK_SHOT` no longer hits, but
`FireBullets`' `TraceAttackToTriggers` still shatters its panes (comment, lines 1-2). The file
maintains a live set of such surfaces (`InitPostEntity`/`PostCleanupMap` rescans,
`OnEntityCreated`/`EntityRemoved` maintain; 12-15). `MCV.PhysicalBulletGlass(b, from, to)`
(19-35): for each collision-free flight segment, `ents.FindAlongRay` (spatial partition,
clipped to the segment) and, if a trigger-flagged pane is crossed, **one** `FireBullets` call
over the segment with `Callback = noSolidHit` (`{damage = false, effects = false}`) — the
engine shatters all panes on the segment in that one call; damage is the bullet's
range-scaled value. BUGLIST.md:73 documents the addition.

### 7.10 Client: prediction, adoption, correction (mcv/client/cl_physbullets.lua) — CL

**`MCV.PredictPhysicalBullets(wep, pos, dir)` (166-186)**: local player only, first predicted
pass (SP exempt via the gate in `BulletAttack`); rolls the *same* shared-key headings, creates
visual bullets keyed by `token = key .. ":" .. i`, tags them `predicted` with
`impactKey = PhysicalImpactKey(owner, key, i)`, and parks them in `pending` with a
`lifetime + 2` tombstone expiry.

**`net.Receive("MCV_PhysicalBullet")` (188-241)**:
- Event 2 → `remove(id)` (fade the smoke).
- Event 1 (penetration correction): if the local prediction is already at/behind that layer,
  ignore; else adopt distance/damage/budget, **catch the flight up** by `ahead = now - started
  - age` via `BulletFlightStep`, restart the smoke on the corrected path ("a rope must not
  connect the old path to a corrected/penetrated path").
- Event 0 (spawn): if `owner == LocalPlayer()` and the token is pending, **adopt the predicted
  visual** — re-key it to the server id, rebase pos/vel by elapsed time, never replay it at the
  muzzle; the tombstone also suppresses later echoes after the predicted bullet expired.
  Otherwise `create(...)` a fresh remote visual.

**`advanceVisual(b, dt, now)` (243-278)**: steps the same `BulletFlightStep`; **predicted
bullets additionally trace and cosmetically penetrate** — `QueuePenetration` against a
locally-built state, `MCV.PhysicalBulletImpact` with the shared `impactKey` (so the server's
confirmation dedups against it, §7.12), continuation adopts exit/src/dir (never client damage —
"Replicate contact and penetration cosmetically, never client damage", line 247). Terminal
contact hides the visual and fades the smoke.

**Think loop (280-307)**: `UnPredictedCurTime()` clock ("flight runs outside command
prediction"); fading-smoke GC (5 s), pending tombstones, per-bullet expiry; **120 Hz substeps**
matching the server's stepper so predicted contacts land on the same geometry.

**Rendering (309-318)**: `PostDrawTranslucentRenderables` (not depth/sky): additive beam from
`tailPos` to `visualPos` (`render.DrawBeam`, width = family radius × 0.2) + glow sprite (3×).
Family style table (11-15) mirrors `mcv_tracer`'s (§6.8) — tail length & width per tracer
family; standalone rope-smoke PCF systems `mcv_phys_vietnam_tracer_<family>_smoke`
(BUGLIST.md:99) with CP0/CP1 driven to `visualPos` every path (`updateSmoke`, 103-109).

**`create(...)` (139-164)**: resolves family/smoke/color from the packet (family travels even
when the weapon is out of PVS); silenced trails are **never started for remote players**
(146-148, BUGLIST.md:63); damage falls back to 40 when the weapon entity is gone.

### 7.11 Client: muzzle projection (cl_physbullets.lua:39-101)

- `MCV.CapturePhysicalMuzzles(wep, vm)` (48-68): called from `ViewModelDrawn`
  (weapon_common/sh_vm.lua:85) with the *drawn* viewmodel's bones — caches the muzzle /
  muzzleleft / muzzle2 attachment offsets (≤ 256 HU sanity) for 0.1 s, **reprojected from
  viewmodel FOV to world FOV** by `MCV.PhysicalMuzzleOffset` (39-44, the tan-half-angle ratio;
  BUGLIST.md:12, 91).
- `muzzle(wep, owner, left, fallback)` (70-97): local player → cached offset or live VM
  attachment (never rebuilding render bones from prediction, comment at 83); remote players →
  `GetWorldModelAttachment("muzzle", left)` (world-model system, `docs/gun-core.md`); 256 HU
  sanity fallback.
- `MCV.PhysicalBulletVisualPosition(pos, offset, distance)` (99-101):
  `pos + offset * (1 - clamp(distance/1000, 0, 1))` — the visual **blends from the drawn muzzle
  to the true eye-origin trajectory over the first 1000 HU** (BUGLIST.md:101), so what you see
  leave the barrel converges to where the bullet actually flies.

### 7.12 Client: impact registration & dedup (mcv/client/cl_physbullet_impacts.lua) — CL

```lua
-- mcv/client/cl_physbullet_impacts.lua:19-31
// Flight runs outside command prediction. Deduplicate actual contacts, not Think calls.
function MCV.PhysicalBulletImpact(key, contactIndex, tr, damage, ricochet, color)
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    local now = contactTime()
    // Even indices are entry/terminal hits; odd indices are penetration exits.
    local id = key .. ":" .. contactIndex
    local old = contacts[id]
    if old and (old.pos - tr.HitPos):Length() <= 32 then return end
    local contact = {id = id, pos = tr.HitPos, expires = now + 15}
    contacts[id] = contact
    tail = tail + 1
    expirations[tail] = contact
    MCV.BulletImpact(tr, damage, nil, ricochet == true and contactIndex % 2 == 0, color)
end
```

One `id = key:contactIndex` per contact; a predicted contact and its server confirmation
dedup when within 32 HU; entries expire after 15 s through an **ordered ring buffer** with
amortized compaction (Think hook, 44-68: quiet frames inspect only the oldest entry; compact
when `head > 1024 and head > tail/2`). `net.Receive("MCV_PhysicalImpact")` (33-42) reconstructs
the trace table and funnels into the same function. Ricochet only on even (entry/terminal)
contacts. `PostCleanupMap` clears; a backwards `UnPredictedCurTime` (demo/rewind) clears
everything (`contactTime`, 11-16).

### 7.13 BUGLIST items for physical bullets (all marked fixed upstream)

:103 (system added, float networking), :87 (client-side penetration prediction),
:85 (hitscan effects in the callback), :89/:91/:99/:101 (smoke/beam/muzzle-blend refinements),
:41 (shallow-angle retrace), :47 (point-blank startsolid), :73 (glass + gyrojet ramp),
:63 (silenced trails), :29/:31/:33/:37 (cosmetic ricochets), :43 (exit-face decals), :4
(worldspawn stock impacts). See `work/PHYSICAL_BULLETS.md`, `work/RICOCHETS.md` upstream.


---

## 8. Penetration System — `weapons/mcv_base/sh_penetration.lua`

All continuation state belongs to one pellet, never to the weapon's Lua table (file header,
lines 1-2) — the queue entries built here are plain per-shot state, replay-safe by construction.

### 8.1 Materials & stats — `SWEP:GetPenetrationStats(mat)` (sh_penetration.lua:3-16) — SH

`MAT_METAL/GRATE/VENT → "Metal"`, `MAT_GLASS → "Glass"`, `MAT_CONCRETE/TILE → "Concrete"`,
`MAT_WOOD → "Wood"`, everything else `"Other"`. Returns
`depth = max(<Mat>PenetrationDepth or 0, 0) × StatMult("penetration")` and
`modifier = max(<Mat>DamageModifier or 1, 1)` (the third return, the name, is unused by
callers). Defaults (mcv_base/shared.lua:173-184):

| Material | Depth (HU) | DamageModifier |
|---|---|---|
| Metal | 8 | 1.55 |
| Glass | 14 | 1.15 |
| Concrete | 10 | 1.75 |
| Wood | 18 | 1.25 |
| Other | 12 | 1.25 |

The category stat `penetration` (sh_categories.lua:37-38, "Multiplies how far bullets can travel
through each material. 0 stops penetration") scales depth only — BUGLIST.md:277-278 added the
sliders (All × category combine).

### 8.2 `SWEP:FindPenetrationExit(tr, dir, limit)` (sh_penetration.lua:61-93) — SH

Terminal-hit guards: no hit / sky / startsolid / allsolid; `**displacement**` textures ("not
closed volumes"); players/NPCs/nextbots ("no arm/torso double hits"); flesh materials; tiny
limits or directions. Worldspawn is explicitly allowed (comment, line 67).

```lua
-- weapons/mcv_base/sh_penetration.lua:75-92
    // Probe outward, then trace back from the first point outside the collision
    // volume. The reverse hit is its real exit face, not an AABB approximation.
    // Incremental probes avoid skipping a second wall further down the ray.
    local td = {endpos = tr.HitPos - dir * epsilon, mask = MASK_SHOT}
    if tr.HitWorld then
        td.filter = self:GetOwner()
    else
        td.filter = {ent}
        td.whitelist = true
    end
    for i = 1, math.ceil(limit) do
        td.start = tr.HitPos + dir * (math.min(i, limit) + epsilon)
        local back = util.TraceLine(td)
        if back.Hit and !back.StartSolid and !back.AllSolid and back.Entity == ent
                and back.HitNormal:Dot(dir) > 0 then
            local thickness = (back.HitPos - tr.HitPos):Dot(dir)
            if thickness > epsilon and thickness < limit then
                return back.HitPos + dir * epsilon, thickness, back
            end
        end
    end
```

Outward incremental probes (1 HU steps up to the material's depth budget), each reverse-traced
back to the entry entity; a valid exit needs an outward-facing normal (`Dot(dir) > 0`) and
`epsilon < thickness < limit`. Returns the exit point (nudged by `epsilon = 0.03125`), the
thickness, and the reverse trace — the reverse trace's far-face material/normal later drives the
exit decal (BUGLIST.md:43). `maxLayers = 4` caps the chain.

### 8.3 `SWEP:QueuePenetration(tr, state, queue)` (sh_penetration.lua:95-113) — SH

```lua
-- weapons/mcv_base/sh_penetration.lua:95-113
function SWEP:QueuePenetration(tr, state, queue)
    if !MCV.BulletPenetration() or state.layers >= maxLayers then return end
    local depth, modifier = self:GetPenetrationStats(tr.MatType)
    local dir = (tr.HitPos - tr.StartPos):GetNormalized()
    local exit, thickness, back = self:FindPenetrationExit(tr, dir, depth * state.budget)
    if !exit then return end
    local budget = state.budget - thickness / depth
    // First-pass loss curve: higher script modifiers lose more damage, and
    // spending the entire depth budget stops the bullet. The original C++ loss
    // formula is not supplied with the scripts, so this is an explicit port rule.
    local damage = state.damage * math.pow(budget / state.budget, modifier)
    local distance = state.distance + (tr.HitPos - tr.StartPos):Length() + thickness + epsilon
    if damage < 1 or distance >= 56756 then return end
    // Retain the real far face for a cosmetic impact/decal. Consumers dispatch
    // it through their normal prediction/recipient path, without another damage hit.
    queue[#queue + 1] = {src = exit, dir = dir, damage = damage,
        distance = distance, budget = budget, layers = state.layers + 1,
        exitTrace = back, exitDamage = damage * MCV.BulletRangeMultiplier(self, distance - epsilon)}
end
```

The model: a **budget of 1** per pellet; each wall spends `thickness / depth` of it; residual
damage = `damage × (newBudget / oldBudget) ^ modifier` (modifier ≥ 1, so harder scripts lose
more); the bullet stops at `damage < 1`, distance cap, or `maxLayers`. The loss curve is an
explicit port rule — the game's own C++ formula is unknown (comment, 102-104). Total distance
accumulates through walls so `BulletRangeMultiplier` never resets (§6.3).

### 8.4 The three consumers

| Consumer | Realm | Role |
|---|---|---|
| hitscan `fireSegment` (sh_shoot.lua:618) | SH | continuations become real damage segments (§6.3) |
| server `advance` (sv_physbullets.lua:150) | SV | continuation re-launches the physical bullet out the exit |
| client `advanceVisual` (cl_physbullets.lua:254) | CL | cosmetic only: predicted impact + visual continuation |

### 8.5 Harness tests (cross-ref `docs/support-systems.md`)

`mcv_harness/penetration_tests.lua` (engine integration): metal costs more than wood, concrete
more than wood; 17/20 HU wood and 8 HU metal stop; oblique 13 HU stops while straight
penetrates; stacked layers lose damage; mixed budget exhaustion; eight pellets have independent
budgets (damage ×8 within 0.01) and carry `DMG_BUCKSHOT`; convar off disables; thick world
stops. `mcv_harness/penetration_world_tests.lua` runs the same probes against a compiled BSP
fixture (`mcv_penetration_test`), writing JSON results — it calls `FindPenetrationExit` and
`GetPenetrationStats` directly (lines 25, 35).

---

## 9. Rockets

### 9.1 `SWEP:RocketAttack(secondary, shootPos, shootDir)` (sh_shoot.lua:643-656) — SV only

`if CLIENT then return end` — projectiles are never predicted. VOLLEY launches
`max(1, min(Clip1(), VolleyCount))` rockets at once, each with its own spread; otherwise one.
Delegates to `LaunchProjectile` per rocket.

### 9.2 `SWEP:LaunchProjectile(secondary, seed, shootPos, shootDir)` (sh_shoot.lua:658-711) — SV

- Spread: `RandomSpread(GetSpread(), seed)` (§4.7) added to the aim angle.
- Entity/force: `GetProjectileClass()`/`ShootEntityForce` (default 5000,
  mcv_base/shared.lua:133-134) or, when `secondary`, `RifleGrenadeEntity`/`RifleGrenadeForce`.
- **The weapon owns the blast** (AGENTS.md:42-46): `ExplosionDamage`/`ExplosionRadius` come
  from the weapon when > 0, else the entity's own defaults, then ×
  `StatMult("explosion_damage"|"explosion_radius", category)` — rifle grenades use
  `MCV.CATEGORY_RIFLE_GRENADE`, not the host rifle's category.
- `projectile_speed` stat scales `force`.
- `rocket:SetOwner(owner)`, `rocket.Inflictor = self`, `rocket:SetWeapon(self)` when the entity
  supports it; `Spawn()`.
- Opt-in swept flight: if `!secondary and self.RocketGravity` →
  `rocket:StartRocketFlight(dir, force, RocketGravity, (RocketBoostSpeed or ShootEntityForce) ×
  speedmult, RocketBoostDelay, RocketBoostDuration)` and return; otherwise plain physics
  (`phys:SetVelocityInstantaneous(dir:Forward() * force)`).

### 9.3 `MCV.RocketFlightDistance(t, speed, boostSpeed, delay, duration)` (mcv/shared/sh_rocketflight.lua:4-12) — SH

```lua
-- mcv/shared/sh_rocketflight.lua:1-12
// Game flight approximation in Source units (one unit = one inch).
// Constant gravity; optional finite, linear boost along the launch direction.
// Returns distance along that direction and its current speed, before gravity.
function MCV.RocketFlightDistance(t, speed, boostSpeed, delay, duration)
    t = math.max(t, 0)
    duration = math.max(duration or 0, 0.001)
    local burning = math.Clamp(t - (delay or 0), 0, duration)
    local coast = math.max(t - (delay or 0) - duration, 0)
    local gain = math.max((boostSpeed or speed) - speed, 0)
    return speed * t + gain * (burning * burning / (2 * duration) + coast),
        speed + gain * burning / duration
end
```

Closed form: constant launch speed, an optional booster that ramps speed linearly to
`boostSpeed` between `delay` and `delay + duration` (integrated quadratic distance during burn,
linear after). Distance is **along the launch direction**; gravity drop is added separately by
the caller.

### 9.4 The consumer — swept server flight (entities/mcv_proj_base.lua:327-374; full entity doc in `docs/projectiles-entities.md`)

`ENT:StartRocketFlight` (329-344) freezes VPhysics (`MOVETYPE_NONE`, `SetNotSolid(true)` but
`SOLID_VPHYSICS` retained for `TraceEntity` — "avoids VPhysics' global speed cap without
changing physics settings for other addons") and records the flight table.
`ENT:Think_RocketFlight` (346-374): `MCV.RocketFlightDistance(age, …)` for axial distance,
`velocity = direction × speed − (0, 0, gravity × age)` and the matching ballistic drop term for
the destination; `util.TraceEntity` sweeps the entity's own 2-unit collision sphere
(COLLISION_GROUP_PROJECTILE, BUGLIST.md:157); on hit, forwards to the normal `Impact` path
(BUGLIST.md:159: sky hits detonate properly).

### 9.5 Launcher profiles & BUGLIST

All seven launchers have distinct `ShootEntityForce` and, for RPG-7/Kolos, boost phases:
RPG-7 `RocketGravity = 9.80665/0.0254`, `RocketBoostSpeed = 300/0.0254`, `RocketBoostDelay
0.1`, `RocketBoostDuration 0.4` (mcv_rpg7.lua:39-42); Kolos boosts to 560 m/s after 0.18 s for
0.3 s (mcv_kolos.lua:62-65) — "Provisional prototype approximation; see
work/ROCKET_BALLISTICS.md" (BUGLIST.md:161). Kolos is also the VOLLEY rocket launcher
(`VolleyCount = 7`, §3.7).

---

## 10. NPC Fire Path — `weapons/mcv_base/sh_npc.lua`

"Like TacRP, NPCs fire through a server-only path. They have no user commands, viewmodel,
reserve-ammo pool or player reload state. Source owns their schedules and reload animation"
(file header, lines 1-3).

### 10.1 Entry & gating

`PrimaryAttack`'s first line redirects NPCs to `NPC_PrimaryAttack` (sh_shoot.lua:8). The AI
helper block (lines 4-62, SH) is shared; everything after `if CLIENT then return end` (line 64)
is SV.

### 10.2 Spread & proficiency

- `GetNPCSpread()` (4-6): `(NPCSpread or Spread) × StatMult("spread") / 100` — same units as
  the player path; physical-bullet headings use it (sh_physbullets.lua:98).
- `GetNPCBulletSpread(proficiency)` (8-11): `8 / (clamp(proficiency, 0, 4) + 1)` degrees of AI
  aim error layered on top — the engine-facing cone.

### 10.3 Cadence, bursts, rest (BUGLIST.md:218, 223)

- `GetNPCShotInterval()` (21-39): `60 / GetFiremodeRate(mode)`, capped by proficiency for
  semi/HE/buckshot (60/90/120/180/240 RPM for Poor→Perfect, read live); `PlayCycleAnimation`
  guns enforce ≥ 0.6 s (pump) / 0.9 s (bolt) since "NPCs don't play the first-person cycling
  animation"; final floor `NPCShotInterval`.
- `GetNPCBurstSettings()` (41-54): BURST → `min(clip, BurstRounds)`; automatic non-cycling
  non-projectile guns → AI bursts of `ceil(0.3/delay)`…`ceil(0.8/delay)` rounds; else 1.
- `GetNPCRestTimes()` (56-62): burst recovery or 0.3/0.6 s floors.

### 10.4 `SWEP:NPC_PrimaryAttack(shootPos, shootDir)` (sh_npc.lua:125-161) — SV

```lua
-- weapons/mcv_base/sh_npc.lua:138-160
    local volley = self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY
    if volley then rounds = math.min(self:Clip1(), self.VolleyCount) end
    local delay = self:GetNPCShotInterval()
    self:SetNextPrimaryFire(CurTime() + delay)
    if delay < 0.1 then owner:NextThink(CurTime() + delay) end

    shootPos = shootPos or owner:GetShootPos()
    shootDir = shootDir or owner:GetAimVector()
    // Effects use the same pre-shot clip parity as player fire. Do not apply
    // view punch, gestures, trigger latches or predicted animation state here.
    self:EmitShotSound(volley and rounds > 1 and self.SoundDoubleShot or self.SoundSingleShot)
    self:DoMuzzle()
    if !self.NoEjectOnShoot or self.PlayCycleAnimation then self:DoEject() end
    if self:GetProjectileClass() then
        local enemy = owner:GetEnemy()
        if IsValid(enemy) then shootDir = (enemy:WorldSpaceCenter() - shootPos):GetNormalized() end
        self:RocketAttack(false, shootPos, shootDir)
    else
        self:BulletAttack(shootPos, shootDir)
    end
    if !IsValid(self) then return end // A nearby blast can remove the weapon.
    self:SetClip1(math.max(0, self:Clip1() - rounds))
    self:Think_WorldBodygroups()
```

Key differences from the player path: no `AttackEffects` (no view punch, no gesture, no burst
latch — effects are done inline with the *same pre-shot clip parity*); ammo via direct
`SetClip1` (no reserve); empty → `SCHED_HIDE_AND_RELOAD`/`SCHED_RELOAD` (armed enemy awareness,
lines 131-135); rockets **aim at the enemy's `WorldSpaceCenter()`**; physical bullets for NPCs
are gated by `mcv_physbullets_npcs` and use `math.Rand` spread with `"server:"` impact keys
(§7.6). `NPCShoot_Primary` (121-123) is the engine-facing alias.

### 10.5 NPC lifecycle (SV)

`NPC_Deploy` (66-90) resets deferred/lock/cycle/trigger/primed/GL/akimbo state, clamps ammo to
one magazine (`ClampNPCAmmo`, 93-102 — NPCs have no reserve), clamps `Firemode` into the valid
range, sets `HoldTypeNPC`/`HoldType` with an ar2 fallback when the model lacks the range
activity. `Equip` (104-111) routes NPC pickups there; `OnDrop` (113-119) re-clamps NPC-owned
weapons before they become loot. `NPC_Reload` (163-166) deliberately does nothing — "the engine
performs that transfer when its animation reaches the reload event."

---

## 11. Field Catalogue

### 11.1 SWEP fields (ballistics-relevant; defaults from mcv_base/shared.lua unless noted)

| Field | Default | Set by (examples) | Consumed by |
|---|---|---|---|
| `DamageGeneric` | 43 (:22) | every weapon | `BulletAttack` damage base, `DoImpactEffect` scale |
| `Damage{Head,Chest,Stomach,Arm,Leg}Multiplier` | 1 (:23-27) | occasional (type67 arms ×4) | `ApplyBulletDamage` |
| `RangeModifier` | 0.95 weapon_common/shared.lua:133 / 0.9 (:29) | every weapon | `BulletRangeMultiplier` |
| `DamageRampDistance/Start/End` | nil | Part 2 gyrojets | `BulletRangeMultiplier` (ramp regime) |
| `Spread` / `SpreadIronsighted` | 6.3 / 1.15 (:121-122) | every weapon | `GetSpread`, hip sway |
| `SpreadBipod` / `SpreadBipodIronsighted` | nil | MGs (rpd :101-102) | `GetSpread` |
| `{Crouch,Prone,StandMove,SneakMove,CrouchMove,Jump}SpreadMultiplier` | 0.85/0.75/1.5/1.4/1.35/3.0 (:144-149) | balance passes | `GetStanceSpreadMultiplier` |
| `FireRate` | 300 (:124) | every weapon (RPM) | `GetFiremodeRate`, anim fallback |
| `FireRate_DA/Fan/Fast/Slow` | 0 (:128-129) | revolvers | `GetFiremodeRate` |
| `Firemodes` | `{SEMI}` (:31-33) | every weapon | `GetFiremodeValue` |
| `VolleyCount` | 2 (:35) | kolos 7 | volley bullet/rocket count & recoil |
| `BurstRounds` / `BurstRecovery` | 3 / 0.2 (:49-50) | burst guns | §3.5 |
| `TriggerDelayTime` | 0.25 (:60) | revolvers | DA release (§2.5) |
| `PlayCycleAnimation` | false (:44) | bolt/pump guns | `NeedCycle` gating |
| `SlamFire` | false (:51) | M1897/M37 | cycle with trigger held |
| `Num` | 1 weapon_common/shared.lua:130 | shotguns (vcshotgun 5) | `GetBulletCount` |
| `MuzzleVelocity` | nil | most firearms (m/s) | `PhysicalBulletsEnabled`, `PhysicalBulletParameters` |
| `BulletBoostTime` / `BulletLaunchVelocity` | nil | Part 2 gyrojets | boost motor (§7.2) |
| `ArmorPiercing` | nil | mcv_ptrd.lua:12 | `ApplyBulletDamage` type override |
| `{Metal,Glass,Concrete,Wood,Other}PenetrationDepth` | 8/14/10/18/12 (:174-178) | every weapon | `GetPenetrationStats` |
| `{...}DamageModifier` | 1.55/1.15/1.75/1.25/1.25 (:180-184) | every weapon | penetration loss curve |
| `ShootEntity` / `ShootEntityForce` | nil / 5000 (:133-134) | launchers | `GetProjectileClass`, `LaunchProjectile` |
| `RocketGravity/BoostSpeed/BoostDelay/BoostDuration` | nil | rpg7/kolos (§9.5) | `StartRocketFlight` |
| `ExplosionDamage` / `ExplosionRadius` | nil | launchers | weapon-owned blast (§9.2) |
| `TracerParticle` / `TracerParticle2` | rifle_primary / rifle_secondary (:218-219) | every weapon | tracer/ricochet/physbullet visuals; `…2` unused |
| `TracerFrequency` | 1 (:222) | MGs 2-3 | glow/ricochet cadence (clip parity) |
| `TracerRandomness` | 6 | every weapon | **no consumer** (carried stat) |
| `NoEjectOnShoot` | false (:212) | shotguns/bolt guns | eject gating |
| Recoil fields | §5.6 | every weapon | `AttackEffects`, `QueueRecoilImpulse` |
| `SoundSingleShot` / `SoundDoubleShot` | SKS.Single / "" (:187-188) | every weapon | `EmitShotSound` |
| `NPCSpread` / `NPCShotInterval` | nil | AI tuning | §10 |

### 11.2 NetworkVars consumed by the shooting path (weapon_common/shared.lua:196-285)

| Var (slot) | Type | Written by | Read by |
|---|---|---|---|
| `AnimLockTime` (F0) | Float | animations | `StillWaiting` |
| `LastRecoilTime` (F2) | Float | `AttackEffects`, rifle grenade | crosshair/HUD |
| `LastTriggerTime` (F3) | Float | DA prime | DA release delay |
| `SightAmountRaw` (F5) | Float | `Think_Sights` | `GetSpread`, recoil lerp, sway |
| `Speed` (F6) | Float | common think | 150 HU/s trigger gate |
| `LastShotTimeR/L` (F7/8) | Float | pose-recoil fire | anim layers (§5.4) |
| `HammerReleaseTime` (F14) | Float | `ScheduleHammerRelease` | `Think_HammerRelease` |
| `Firemode` (I2) | Int | `ChangeFiremode` (clamped ≥1 at setup, :283) | `GetFiremodeValue` |
| `BurstCount` (I4) | Int | fire/burst logic | `IsBursting`, progressive recoil, ShotKey |
| `RecoilCommand` (I9) | Int | `QueueRecoilImpulse` | SetupMove dedup |
| `NeedTriggerPress` (B5) | Bool | fire/burst/safety | trigger latch |
| `NeedCycle` (B10) | Bool | fire on cycle guns | fire gate, cycle think |
| `PrimedAttack` (B12) | Bool | DA prime/release | §2.5 |
| `Safe` (B19) | Bool | `ToggleSafe` | fire gate, idle, hints |
| `RecoilImpulse` (V0) | Vector | `QueueRecoilImpulse` | SetupMove |
| `Akimbo` (B11), `Bipod` (B3), `Reloading` (B0), `GrenadeLauncher` (B9), `Bayonet` (B8) | Bool | respective systems | gates & multipliers above |

### 11.3 Stat multiplier keys touching ballistics (sh_categories.lua:36-46)

`damage`, `penetration`, `spread`, `spread_sights`, `recoil`, `firerate`,
`explosion_damage`, `explosion_radius`, `projectile_speed` — read exclusively through
`SWEP:StatMult(stat, category)` (weapon_common/shared.lua:80-82), which folds the `All`
category into the weapon's own.

---

## 12. Translation-Layer Surface (ranked)

1. **Never call `FireBullets` yourself.** Route every foreign attack through
   `SWEP:BulletAttack(shootPos, shootDir)` / `RocketAttack` — that is the only way to inherit
   lag compensation, penetration, hitgroup math, `DMG_BUCKSHOT`, stat multipliers, effect
   ownership (`{effects = false}`) and the tracer system. The optional `shootPos`/`shootDir`
   arguments exist precisely for callers with custom origins (NPC path, harness).
2. **Damage contract**: foreign `Damage`/`DamageNum` map to `DamageGeneric` + `Num`. Do **not**
   also apply hitgroup scaling in a `ScalePlayerDamage`-style hook — MCV *cancels* the
   engine/gamemode multipliers (`CancelBodyDamage`) and applies its own `Damage*Multiplier`
   fields inside `ApplyBulletDamage`; a foreign hook would fight or double that.
3. **Spread units**: MCV's `Spread`/`SpreadIronsighted` are authored units where the engine cone
   = `units / 100` (radians). A foreign base's cone in degrees must be converted (deg × 1.0 →
   units × 100, i.e. units = degrees). Stance/sight blending is MCV-internal — supply only the
   two (plus optional bipod) numbers.
4. **Fire rate**: map foreign RPM → `FireRate` (and `FireRate_DA/Fan/…`); never set
   `NextPrimaryFire` from outside — cadence is animation-derived first (§2.2), and foreign
   timing fights `StillWaiting`/`AnimLockTime`.
5. **Fire modes**: foreign semi/auto/burst map onto `Firemodes = {MCV.FIREMODE_*}` +
   `BurstRounds`/`BurstRecovery`; MCV owns the trigger latch and runaway-burst logic. Modes are
   model-gated (`FiremodeAvailable`) — a translated SWEP whose model lacks selector animations
   silently drops modes.
6. **Recoil**: map foreign view-kick to `ViewSlideRecoil{Up,Right}[Ironsight]` +
   `ProgressiveRecoil*` + `RecoilPushbackValue` + `Shake*`; never call `ViewPunch` directly —
   `AttackEffects` computes the punch on both modes with `SharedRandom`, and the realistic mode
   expects `cl_camera` to eat most of it (§4.5).
7. **Effects/sound gating**: eject/muzzle/shot sounds are `IsFirstTimePredicted`-gated and
   channel-rotated; a translation layer emitting its own effects must apply the same gates and
   the shooter-exclusion recipient rules or double-fire them (§6.7, §6.9).
8. **Clip-parity state**: tracer cadence, akimbo left/right and volley counts read `Clip1()`
   at specific pre/post-decrement moments (§6.7, §7.7). Preserve MCV's ammo accounting order
   (`AttackEffects` takes the round *after* the bullet call) or visual state desynchronizes.
9. **Projectiles**: a foreign "shoot a rocket/grenade" maps to `ShootEntity` +
   `ShootEntityForce` (+ `ExplosionDamage/Radius`, optionally `RocketGravity` + boost fields);
   the entity side is `docs/projectiles-entities.md`. `RocketAttack` is server-only — do not
   expect client-side launch hooks.
10. **Physical bullets are opt-in and additive**: with `mcv_physbullets 0` (default) nothing
    changes; if a foreign SWEP sets `MuzzleVelocity` it silently gains the whole §7 system.
    Conversely a foreign base that implements its own travel-time bullets must not run both.
11. **NPCs**: foreign NPC support routes through `NPC_PrimaryAttack` (server-only, no
    `AttackEffects`); proficiency caps and cycle delays are applied there (§10).
12. **Penetration**: `mcv_bullet_penetration` defaults **on** — any translated hitscan inherits
    wall penetration from the field defaults unless depths are zeroed.

---

## 13. File Map

| File (reference/mcv/lua/) | Lines | Realm | Contents (this doc) |
|---|---|---|---|
| `weapons/mcv_base/sh_shoot.lua` | 820 | SH | PrimaryAttack, pose-recoil query, hammer release scheduling, stance/sway/spread, AttackEffects, shot audio, GetFiremodeRate, BulletAttack, RocketAttack, LaunchProjectile, firemode machinery |
| `weapons/mcv_base/sh_gun.lua` | 132 | SH | weapon_common hook implementations: idle/deploy anim, scope FOV, HUD ammo/name/hints, SecondaryAttack, ToggleSafe |
| `weapons/mcv_base/sh_penetration.lua` | 113 | SH | material stats, ApplyBulletDamage, FindPenetrationExit, QueuePenetration |
| `weapons/mcv_base/sh_think.lua` | 140 | SH | ThinkWeapon: runaway burst, trigger release, DA release, cycle, safety toggle (cross-ref) |
| `weapons/mcv_base/sh_npc.lua` | 166 | SH→SV | NPC spread/cadence/bursts + server NPC_PrimaryAttack & lifecycle |
| `weapons/mcv_base/sh_sights.lua` | 147 | SH | GetSightAmount (spread/recoil input) — gun-core cross-ref |
| `weapons/mcv_base/shared.lua` | 227 | SH | field defaults (§11.1) |
| `mcv/shared/sh_common.lua` | 175 | SH | FIREMODE enum, names, ammo remap, CancelMultipliers, shot channels, registered ammo types, shell types (support-systems cross-ref) |
| `mcv/shared/sh_physbullets.lua` | 109 | SH | enable gate, flight integrator, range multiplier, trace reuse, parameters, keys, heading |
| `mcv/shared/sh_hitgroups.lua` | 13 | SH | CancelBodyDamage |
| `mcv/shared/sh_rocketflight.lua` | 12 | SH | RocketFlightDistance closed form |
| `mcv/shared/sh_tracercolor.lua` | 33 | SH | tracer colour modes/streak families |
| `mcv/shared/sh_convars.lua` | 57 | SH | shooting convars (§1.3) — support-systems cross-ref |
| `mcv/shared/sh_hitscaneffects.lua` | 42 | SH | hitscan tracer/impact/ricochet routing — effects cross-ref |
| `mcv/shared/sh_impacts.lua` | 154 | SH | BulletImpact/SurfaceImpact — effects doc |
| `mcv/server/sv_physbullets.lua` | 187 | SV | launch, advance, Tick stepper, water splash, glass, network messages |
| `mcv/server/sv_physbullet_glass.lua` | 35 | SV | func_breakable_surf pane shattering |
| `mcv/client/cl_physbullets.lua` | 330 | CL | prediction/adoption/correction, muzzle capture & projection, smoke/beam rendering, lifecycle |
| `mcv/client/cl_physbullet_impacts.lua` | 69 | CL | contact dedup ring buffer, MCV_PhysicalImpact receiver |
| `mcv/client/cl_tracercolor.lua` | 3 | CL | `mcv_tracer_color` userinfo convar |
| `effects/mcv_tracer.lua` | 175 | CL | hitscan tracer effect (consumer of §6.8) — effects cross-ref |
| `mcv/weapon_common/shared.lua` | 401 | SH | base stats/defaults, SetupDataTables, StillWaiting, GetAimAngle base, RandomSpread, StatMult, gestures |
| `mcv/weapon_common/sh_movement.lua` | 65 | SH | QueueRecoilImpulse/SetupMove, GetWeaponMovement |
| `entities/mcv_proj_base.lua` | 465 | SH/SV | StartRocketFlight/Think_RocketFlight — projectiles-entities cross-ref |
| `mcv_harness/penetration_tests.lua` / `penetration_world_tests.lua` | 108/36 | SV | penetration regression suites — support-systems cross-ref |

*End of audit. Cross-references: `docs/animation-system.md` §5.6, §7.3-7.5, §7.7, §7.9, §8;
`docs/gun-core.md`; `docs/reload-ammo.md`; `docs/weapon-definitions.md`;
`docs/projectiles-entities.md`; `docs/effects.md`; `docs/support-systems.md`.*
