# MCV Base — Effects, Impacts & Explosions (Exhaustive Audit)

This document exhaustively audits every visual/damage-side effect system in the MCV (Military
Conflict Vietnam) base: the five clientside `lua/effects/` entities, the shared impact / decal /
ricochet / melee-blood dispatchers, the explosion particle picker, the weapon-side muzzle / shell /
muzzle-light dispatch in `weapons/mcv_base/sh_effects.lua`, and the client convars that gate them.
It is written as engineering reference for the translation layer that must run foreign-base SWEPs
(whose effects are driven by engine activities, `TracerName` strings and stock `util.Effect` calls)
on top of MCV. Every behavioral claim cites `path/file.lua:LINE` relative to `reference/mcv/lua/`.

Sibling audits: animation (incl. native `eject`/`eject2` model events) in
[animation-system.md](animation-system.md) §5.5; firing/ballistics in `docs/shooting-ballistics.md`;
weapon fields in `docs/weapon-definitions.md`; projectiles & `util.BlastDamage` in
`docs/projectiles-entities.md`. Upstream's own notes are in `reference/mcv/BUGLIST.md` — the items
relevant to this system are collected in §4.9 and throughout.

---

## 1. Architecture Overview

### 1.1 Three dispatch mechanisms

MCV never uses the engine's per-bullet effect pipeline (`Tracer = 1`, engine `Impact` on
`FireBullets`). Every visible effect is dispatched by one of three explicit mechanisms:

1. **`util.Effect` + `EffectData` → a clientside EFFECT entity** (`lua/effects/*.lua`). The entire
   muzzle / shell / tracer / impact / ricochet / melee-blood surface. The payload doubles as a
   courier for non-positional data (family index, shell type, RGB ricochet colour) through
   otherwise-unused `EffectData` fields (`sh_impacts.lua:133-148`).
2. **`ParticleEffect` / `ParticleEffectAttach` called from shared or server code**. Used where a
   plain world-positioned system with default control points suffices: explosions
   (`sh_explosions.lua:118`), projectile trails (`entities/mcv_proj_base.lua:145`), fire pools,
   fuse/blink particles. Called on the **server**, `ParticleEffect` is networked by the engine to
   PVS clients automatically (documented at `sh_explosions.lua:111-112`).
3. **Direct clientside `CreateParticleSystem`** inside the EFFECT entities themselves (§3), plus the
   manually-drawn viewmodel particle batch (`self.PCFs`, rendered in
   `mcv/weapon_common/sh_vm.lua:136-203`).

### 1.2 Realm split and load order

* `mcv/shared/*.lua` (including `sh_effects.lua` = particle manifest, `sh_impacts.lua`,
  `sh_impact_decals.lua`, `sh_melee_effects.lua`, `sh_hitscaneffects.lua`, `sh_explosions.lua`)
  load on both realms via the autorun loop in name order, after `sh_convars.lua`
  (`autorun/sh_mcv_load.lua:17-23`).
* `lua/effects/*.lua` are loaded by the engine **clientside only** as effect entities, on demand by
  name. They are not `AddCSLuaFile`'d anywhere — GMod scans `lua/effects/` itself.
* `weapons/mcv_base/sh_effects.lua` is a SWEP module, included by
  `MCV.IncludeWeaponModules("weapons/mcv_base")` (`weapons/mcv_base/shared.lua:226`); it defines
  predicted SWEP methods (`DoMuzzle`, `DoEject`, `DoMuzzleLight`, `GetTracerOrigin`).
* `mcv/client/cl_effectsettings.lua` and `cl_tracercolor.lua` register client convars
  (`cl_effectsettings.lua:5` documents the deliberate centralisation).
* `weapons/mcv_melee/sh_melee.lua:2` and `weapons/mcv_chainsaw.lua:4` lazily re-include
  `sh_melee_effects.lua` if the autorun load missed it (defensive ordering).

### 1.3 The prediction / ownership model (first-class)

The invariant, stated at `weapons/mcv_base/sh_effects.lua:5-6`:

> Effect position and recipients belong to the shooter, never the default EffectData origin
> (0,0,0). The firing client already predicts its own effects.

Concretely:

* Weapon-side dispatch (`DoMuzzle`, `DoEject`) is gated by `IsFirstTimePredicted()`
  (`sh_effects.lua:48`, `:93`) and on the server excludes the shooting player from the
  RecipientFilter in multiplayer (`sh_effects.lua:13`).
* Hitscan per-bullet effects are owned by the **firing callback**, not the engine's impact hook:
  `MCV.HitscanEffects` returns early when `CLIENT and !game.SinglePlayer() and
  !IsFirstTimePredicted()` (`sh_hitscaneffects.lua:3`), and the server builds a PVS recipient
  filter around `tr.StartPos` + `tr.HitPos`, removing the MP shooter
  (`sh_hitscaneffects.lua:6-15`).
* The authoritative impact hook (`SWEP:DoImpactEffect`) deliberately does **not** use
  `IsFirstTimePredicted` — the SP client receives it outside user-command prediction
  (`sh_impacts.lua:128-131`); effects are instead forced past the engine's prediction filter with
  `util.Effect(name, fx, true, ...)` (`sh_impacts.lua:41`, `:151`).
* NPC fire calls the same `DoMuzzle`/`DoEject` from the server with no predicted client to exclude
  (`weapons/mcv_base/sh_npc.lua:146-150`), so NPCs get server-driven effects only.
* Physical bullets: the server sends keyed `MCV_PhysicalImpact` confirmations; each client
  deduplicates predicted echoes before calling `MCV.BulletImpact`
  (`mcv/client/cl_physbullet_impacts.lua:19-31`).

### 1.4 PVS and dormancy

Every clientside effect that parents to a weapon bails out when the weapon or its owner is
dormant: `effects/mcv_muzzleeffect.lua:6`, `effects/mcv_shelleffect.lua:25`. Server dispatch uses
`RecipientFilter:AddPVS(shooter origin)` (`sh_effects.lua:11-12`, `sh_hitscaneffects.lua:7-9`).
Third-person particles attach to the hand-drawn world models (`cl_worldmodel.lua`), which are
retired on PVS loss together with their particles (`cl_worldmodel.lua:263-272`). See BUGLIST item
at `reference/mcv/BUGLIST.md:201` (weapon PVS lifecycle: detached 253-unit muzzle offset fixed).

---

## 2. Effect Dispatch Points — the Complete Map

### 2.1 Every `util.Effect` call in the base

| # | Effect name | Dispatcher (file:line) | Trigger |
|---|-------------|------------------------|---------|
| 1 | `mcv_muzzleeffect` | `weapons/mcv_base/sh_effects.lua:71,79` (`SWEP:DoMuzzle`) | every shot (player, NPC, UBGL), first-predicted only |
| 2 | `mcv_shelleffect` | `weapons/mcv_base/sh_effects.lua:121` (`SWEP:DoEject`) | shot (unless `NoEjectOnShoot`) or model `eject`/`eject2` event (`sh_shoot.lua:201-205`) — reload/cycle ejections arrive through those events too |
| 3 | `mcv_tracer` | `mcv/shared/sh_hitscaneffects.lua:36` (`MCV.HitscanEffects`) | each hitscan bullet, from the `FireBullets` callback |
| 4 | `mcv_impact` | `mcv/shared/sh_impacts.lua:151` (`MCV.SurfaceImpact`) | any impact with a resolvable surface family or ricochet opt-in |
| 5 | `mcv_melee_blood` | `mcv/shared/sh_melee_effects.lua:33` (`MCV.MeleeBloodImpact`) | melee/chainsaw flesh hits, when `mcv_surface_impacts` on |
| 6 | `Impact` (stock) | `mcv/shared/sh_impacts.lua:41` (`MCV.BulletImpact`) | fallback when custom impacts unavailable/off |
| 7 | `BloodImpact` (stock) | `mcv/shared/sh_melee_effects.lua:33` | fallback blood when convar off / unknown colour |
| 8 | `watersplash` (stock) | `mcv/server/sv_physbullets.lua:20` | physical bullet crossing a water surface, server-side |
| 9 | `Sparks` (stock) | `weapons/mcv_melee/sh_melee.lua:342` | wrench repair tick, server-side |
| 10 | `ManhackSparks` (stock) | `entities/mcv_proj_base.lua:197` | `DefuseOnDamage` projectile destroyed |

Additionally the test harness uses `util.Effect("Sparks", ...)` at
`mcv_harness/ricochet.lua:42` (dev-only).

### 2.2 The `EffectData` contract for each MCV effect

These tables are the wire format between shared dispatchers and clientside entities. A translation
layer that dispatches these effects directly must reproduce them exactly.

**`mcv_muzzleeffect`** (written at `weapons/mcv_base/sh_effects.lua:66-69,74-78`):

| Field | Value | Meaning |
|-------|-------|---------|
| `Entity` | the SWEP | particle names are read off the weapon's fields |
| `Attachment` | viewmodel muzzle QCA index | `muzzle`, `muzzle2` for UBGL (`:55-57`), `muzzleleft`/`muzzle2` for akimbo left (`:61-64`) |
| `Magnitude` | 1 / 0 | marks the **left gun of an akimbo dual** in third person (`:69`) |
| `Origin` | `owner:GetShootPos()` | set by `dispatchWeaponEffect` purely for PVS routing (`:8-9`) |

**`mcv_shelleffect`** (written at `weapons/mcv_base/sh_effects.lua:115-119`):

| Field | Value | Meaning |
|-------|-------|---------|
| `Entity` | the SWEP | shell type, eject particles read from weapon fields |
| `Attachment` | viewmodel `eject`/`eject2` QCA | which port the case leaves |
| `Flags` | `self.EjectBrassType` | index into `MCV.ShellTypes` (§3.3), i.e. the cartridge |
| `Magnitude` | 1 / 0 | left gun of a dual (`:119`) |
| `Origin` | shooter shoot pos | PVS routing only |

**`mcv_tracer`** (written at `mcv/shared/sh_hitscaneffects.lua:32-35`):

| Field | Value | Meaning |
|-------|-------|---------|
| `Entity` | the SWEP | `TracerParticle`, `TracerFrequency`, akimbo state read clientside |
| `Start` | `tr.StartPos` | informational (the effect re-derives its own origin, §3.4) |
| `Origin` | `tr.HitPos` | the **end** of the tracer beam |

**`mcv_impact`** (written at `mcv/shared/sh_impacts.lua:133-148`):

| Field | Value | Meaning |
|-------|-------|---------|
| `Origin` | `tr.HitPos` | impact point |
| `Normal` | `tr.HitNormal` | surface normal; orients particles and decal |
| `DamageType` | `DMG_BULLET` or `0` | **ricochet opt-in flag**: only incoming bullets may spark (`:138`) |
| `Start` | `tr.StartPos` (ricochet) / `tr.HitPos` | incoming direction for reflection math (`:139`) |
| `Flags` | family index into `MCV.ImpactFamilies` | 0 = "no family, ricochet only" (`:140`) |
| `Scale` | `MCV.ImpactScale(damage)` | particle radius multiplier 0.5–2 (`:141`) |
| `Magnitude`/`Radius`/`Color` | r/g/b of tracer colour | smuggled RGB for the ricochet spark, only when ricochet (`:145-147`) |

**`mcv_melee_blood`** (written at `mcv/shared/sh_melee_effects.lua:26-30`):

| Field | Value | Meaning |
|-------|-------|---------|
| `Origin` | `tr.HitPos` | hit point |
| `Normal` | `tr.HitNormal` | spray direction |
| `Color` | `ent:GetBloodColor()` | indexes `MCV.MeleeBloodParticles` |
| `Scale` | `1` | placeholder (unused by the effect) |

### 2.3 Direct `ParticleEffect` dispatch (server → PVS broadcast)

| Call | Site | Trigger |
|------|------|---------|
| `MCV.ExplosionEffect(family, pos, normal, inwater)` | `entities/mcv_grenade_base.lua:94`; `mcv_proj_rpg.lua:50`; `mcv_proj_rpg2.lua:50`; `mcv_proj_panzerschreck.lua:36`; `mcv_proj_bazooka.lua:36`; `mcv_proj_kolos.lua:36`; `mcv_proj_m202.lua:55`; `mcv_proj_40mm.lua:48`; `mcv_proj_riflegrenade.lua:48`; `mcv_proj_riflegrenade_vc.lua:48` (the `_ger` variant inherits from `_vc`, `mcv_proj_riflegrenade_ger.lua:3`) | projectile `Detonate` (§5) |
| `ParticleEffect("Molotov_Explosion", ...)` | `entities/mcv_grenade_molotov.lua:35` | molotov burst (no family table; fixed system) |
| `ParticleEffect(self.Particle, ...)` | `entities/mcv_firepool.lua:28` | incendiary pool start (angle from `MCV.SurfaceAngle`) |
| `ParticleEffectAttach(self.TrailParticle, PATTACH_ABSORIGIN_FOLLOW, self, 0)` | `entities/mcv_proj_base.lua:145` | rocket flight trail |
| `ParticleEffectAttach(self.WickParticle/GroundParticle/FuseParticle/BlinkParticle, ...)` | `mcv_grenade_molotov.lua:24`, `mcv_proj_flare.lua:30`, `mcv_placed_dynamite.lua:42-44`, `mcv_placed_c4.lua:36` | persistent attached particles |

Explosion **damage** is `util.BlastDamage` and lives in the projectile entities
(`entities/mcv_grenade_base.lua:72`) — see `docs/projectiles-entities.md`.

---

## 3. The `lua/effects/` Clientside Entities

All five are CL-only engine effect entities. Common pattern: `Init(data)` consumes the
`EffectData`, `Think()` returns whether the effect entity should live on (engine removes it when
`Think` returns falsy), `Render()` draws manual geometry.

### 3.1 `effects/mcv_impact.lua` — surface impact + decal + cosmetic ricochet

**Purpose:** one bullet impact "in the game's own art for the surface that was hit"
(`effects/mcv_impact.lua:1`), replacing the engine dust puff. Carries three jobs: the decal, the
per-surface particle family, and the cosmetic ricochet.

* `EFFECT:Init(data)` — `effects/mcv_impact.lua:84-113`. Resolves `family =
  MCV.ImpactFamilies[data:GetFlags()]`; bails entirely if no family **and** not a bullet
  (`:86`); clamps the normal to `vector_up` if degenerate (`:90`); puts the decal down
  (`:94-97`, see §4.5); plays one of the three variants
  `mcv_scaled_impact_<family>_<1..3>` via the local `particle()` helper (`:108`); stamps
  `DieTime = CurTime() + 4` (`LIFETIME`, `:13`, `:111`); then attempts the ricochet (`:112`).
* `local function particle(self, name, pos, ang, scale, color)` — `:31-47`. The heart of the
  orientation contract: sets the effect entity's pos/angles first (so the engine-initialised CP0
  has the launch pose), then `CreateParticleSystem(self, name, PATTACH_ABSORIGIN, 0)` and
  **explicitly sets control points 0 and 1** to the hit position with the normal's forward/right/up
  — because the pcf children spray along control-point local X and 180 of them read point 1
  (`:5-10`, mirrored in `sh_impacts.lua:7-12`). CP2 carries the scale vector, CP3 an optional
  colour (`:43-44`).
* `local function ricochet(self, data, family, pos, normal, scale)` — `:49-82`. Cosmetic only
  (no damage, no flight change — BUGLIST `:37`). Rules:
  * only `DMG_BULLET` damage types (`:50`) — the dispatcher's opt-in, excluding melee and
    penetration exits;
  * surface hardness table `ricochetSurfaces` (`:17-27`): metal 0.9 … asphalt 0.35, unknown
    surfaces 0.1 (`:28`);
  * client-side rate limit: one ricochet addition per 125 ms per viewer (`:52-57`), never
    throttling the impact itself or its decal;
  * requires a real incoming direction (`:58-59`) and positive incidence (`:61-62`);
  * chance `(0.2 + 0.8·hardness) · (0.35 + 0.65·grazing²)` (`:65`);
  * reflection vector `incoming + normal·(2·incidence)`; orientation via `AngleEx(normal)` except
    at near-normal incidence where reflected ∥ normal (`:68-73`);
  * colour arrives as smuggled RGB (`:74`), passed to CP3;
  * plays a positional ricochet sound locally at 87 dB / 0.7 volume from
    `mcv/weapons/fx/rics/vietnam_rics_<metal|concrete>_<1-4>.wav` (`:79-80`) — deliberately not on
    the weapon's sound channels;
  * extends the effect entity's life to 5 s so the flying spark's trail can finish (`:81`).
* `EFFECT:Think()` — `:116-118`. Lives until `DieTime`. `EFFECT:Render()` — `:120`, empty (all
  drawing is inside the particle systems).

**Prediction notes:** the entity is created by a forced (`true`) `util.Effect` so it plays even in
prediction contexts; `ricochet` uses `UnPredictedCurTime()` (`:54`) so the 125 ms budget is not
consumed by prediction replays. BUGLIST `:29`, `:31`, `:33`, `:37` document the ricochet feature's
history (colour inheritance, invisible-spark shader fix, zero-emission donor fix, original
introduction).

### 3.2 `effects/mcv_muzzleeffect.lua` — muzzle flash

* `EFFECT:Init(data)` — `effects/mcv_muzzleeffect.lua:1-57`. Reads the weapon from
  `data:GetEntity()`; removes itself if the weapon, owner, either's dormancy check fails (`:4-6`).
  Picks the particle set:
  * first person (owner is `LocalPlayer()` and not drawn in third person): viewmodel, and if
    `wpn:GetSightAmount() >= 1` uses the `MuzzleParticleIronsighted[IronsightedSmoke]` pair
    instead of `MuzzleParticle[MuzzleParticleSmoke]` (`:8-25`);
  * third person: re-parents to the **hand-drawn world model** (`wpn:GetWorldModelFor(magnitude >=
    0.5)` for akimbo left, `:29`), looks up its `muzzle` attachment (`:30-31`), and uses
    `MuzzleParticle3rdPerson` (`:32`).
  * For each non-empty name, `CreateParticleSystem(parent, name, PATTACH_POINT_FOLLOW, att)` and
    `StartEmission` (`:42-47`). First-person systems get `SetShouldDraw(false)` and are pushed into
    `wpn.PCFs` so the viewmodel render pass draws them by hand inside the viewmodel camera
    (`:49-53`; rendered in `mcv/weapon_common/sh_vm.lua:153-179`). A weapon with `""` particles
    (crossbows/launchers) simply flashes nothing (`:43`).
* `Think` returns `false` and `Render` is a no-op (`:59-65`) — the effect entity dies immediately;
  the particle handles it created outlive it.

**Note:** the ironsight particle pair is **not** blended — it is a hard swap at full sight amount.
Muzzle flash *light* is separate (§6.5).

### 3.3 `effects/mcv_shelleffect.lua` — ejected shell casing

The most complex effect entity: a physically simulated clientside prop with lifetime management.

* Class fields — `effects/mcv_shelleffect.lua:1-12`: default `Type = 1`, `Pitch = 100`, fallback
  `Model`, `ShellTime = 0.5` (overwritten per-instance from the convar at `:103`),
  `VMContext = true` (drawn inside the viewmodel pass until first bounce, `:12`).
* `EFFECT:Init(data)` — `:14-134`:
  * `self.Type = data:GetFlags()` selects `MCV.ShellTypes[self.Type]` (`:19-21`), the cartridge
    table (23 entries, models under `models/weapons/shells/`, bounce sounds
    `MCV_Bounce.Shell` / `MCV_Bounce.ShotgunShell`) defined at `mcv/shared/sh_common.lua:82-175`.
  * validity gates on weapon, owner and dormancy (`:23-25`).
  * **Attachment resolution:** third person → the drawn world model's `shell_eject` (fallback
    `eject`) attachment (`:30-39`); models with neither spawn the case "from a point behind the
    muzzle": muzzle attachment minus 12 units forward, plus 1.5 right / 1 up, with a -90° roll
    (`:41-47`). First person → the viewmodel's attachment (`:50-52`) and registers itself in
    `ent.ActiveEffects` so `ViewModelDrawn` draws it (`:51`; `sh_vm.lua:87-97`).
  * physics: `PhysicsInitBox(±2, ±0.25, ±0.25)` — a long thin box, `COLLISION_GROUP_DEBRIS`
    (`:81-83`); mass 1, material `gmod_silent` (the Lua sound replaces engine impact noise,
    `:96`); launch velocity `dir·150·Rand(1,2) + owner velocity` where `dir` is the attachment's
    forward **rotated 90° around its up** (`:62-65`, `:98`); spin `VectorRand()·100` plus
    `-up·2500·Rand(0.75,1.25)` — the classic spinning-brass tumble (`:100-101`).
  * particles: the ejection-port puff `EjectBrassParticle` parented to the (view/world) model's
    attachment (`:108`), and the in-flight smoke trail `EjectBrassTrail` parented to the shell
    itself — only when `MCV.ShellSmoke()` is on (`:114-115`). In first person both are
    `SetShouldDraw(false)`'d and pushed into `ent.PCFs` (`:121-130`).
  * `SetNoDraw(true)` at spawn (`:72`) — in first person the case is invisible until drawn by
    `ViewModelDrawn` (`sh_vm.lua:93`).
* `EFFECT:PhysicsCollide(colData)` — `:136-147`: on first touch, reflect at `HitNormal · -150`,
  play the shell-type bounce sound, stop the engine's `Default.ImpactHard`, flip `VMContext` off
  and `SetNoDraw(false)` so the case is now drawn in the world, and latch
  `AlreadyPlayedSound`.
* `EFFECT:Think()` — `:149-166`: while velocity > 0, keeps refreshing `SpawnTime` (so `ShellTime`
  is **time at rest**, per `cl_effectsettings.lua:9-10`); kills scrape sounds; then a three-stage
  death: `kRenderFxFadeFast` at `SpawnTime + ShellTime` (`:153-155`), motion disabled at +0.25
  (`:156-158`), removed at +0.5 (`:159-162`).
* `EFFECT:Render()` / `DrawTranslucent()` — `:168-178`, plain `DrawModel` (the world-context half;
  the viewmodel-context half is drawn by `ViewModelDrawn`).

**Prediction:** dispatched under `IsFirstTimePredicted` from `DoEject` (§6.4); the server excludes
the MP shooter, so each player simulates only their own shells' physics — shells are client-local
cosmetic, never networked.

### 3.4 `effects/mcv_tracer.lua` — hitscan tracer

Two-part rendering: the game's particle system for **smoke**, and a hand-drawn **beam streak**,
because `render_sprite_trail`-based tracer systems do not draw in GMod
(`effects/mcv_tracer.lua:96-102` — the operator set is in the client binary; MCV draws the streak
"the way TacRP draws its own tracers").

* `FAMILY` table — `:20-32`: per-tracer-family `{tail_length, radius}` taken from the game's own
  systems (`assaultrifle {150,2}` … `silenced {0,0}`). `SPEED = 10000` u/s, `STREAK_SCALE = 1/10`
  (the pcf radii read ~3× too wide as a beam, `:16-18`).
* Materials — `:34-41`: a runtime `CreateMaterial("mcv_tracer_beam", "UnlitGeneric", ...)` additive
  beam, and `sprites/light_glow02_add` for the head glow.
* `EFFECT:Init(data)` — `:43-121`:
  * bails if `TracerParticle` empty (`:48`) or if this is a silenced trail and the local player
    is not the shooter (`:49-50` — suppressed trails are shooter-private, matching the server-side
    recipient logic in `sh_hitscaneffects.lua:18-30`).
  * works out `from`: first person → viewmodel `muzzle` attachment (`muzzleleft`/`muzzle2` when
    akimbo left gun, decided by `Clip1() % 2 == 0`, `:53` — the mirrored parity of `DoMuzzle`'s
    pre-shot "odd count = left gun": `BulletAttack` runs before `AttackEffects`/`TakePrimaryAmmo`
    (`sh_shoot.lua:144-146`), and the effect entity's `Init` evidently executes only after the
    fire call has finished and `Clip1` reflects the consumed round — engine effect-deferral
    timing inferred from the code's own comment, unverified);
    third person → `wpn:GetWorldModelAttachment("muzzle", left)` (`:71-81`); final fallback the
    owner's shoot pos or the weapon's origin (`:82-84`).
  * `self:Trail(...)` starts the pcf (§ below) on **every** round (`:87`).
  * streak gating: only every `TracerFrequency`-th round glows — computed as
    `wpn:Clip1() % freq != 0 → return` (`:93-94`), deliberately magazine-relative so "both realms
    reach the same answer without anything being networked" (`:89-92`).
  * streak parameters: family lookup with `_green` stripped (`:103-106`), `DieTime` from
    `dist / SPEED` (`:119-120`).
* `EFFECT:StreakColor(owner, wpn, green)` — `:127-129` — defers entirely to
  `MCV.TracerColor(owner, wpn.TracerParticle)` (§7): the colour is the **shooter's** convar
  choice, read via userinfo so everyone sees that player's chosen colour (`:123-126`).
* `EFFECT:Trail(name, from, to, ent, att)` — `:137-152`: with a real attachment, hangs the system
  off it `PATTACH_POINT_FOLLOW` with CP1 = hit pos (follows the muzzle on screen); otherwise
  `CreateParticleSystemNoEntity` with CP0/CP1 set outright. Comment: "Keep this cosmetic: the
  firing callback already owns the bullet trace and damage" (`:136`).
* `EFFECT:Think()` — `:154-156` — alive until `DieTime` (uses `UnPredictedCurTime`).
* `EFFECT:Render()` — `:160-175`: beam from the round's head back `Tail` units, plus a head sprite
  at 3× width, tinted `self.Color`.

### 3.5 `effects/mcv_melee_blood.lua` — melee blood

* `EFFECT:Init(data)` — `effects/mcv_melee_blood.lua:2-20`: resolves
  `MCV.MeleeBloodParticles[data:GetColor()]`; if unknown, returns (no effect). Creates the system
  `PATTACH_ABSORIGIN_FOLLOW` on the effect entity itself — "The effect owns the particles, so a
  lethal hit/removal cannot cut them off" (`:1`). CP0/CP1 = hit pos with normal orientation;
  **CP2 is set to `vector_origin` because "the original velocity initializers use CP2 as a vector,
  not a position"** (`:16-17`). `DieTime = CurTime() + 4`.
* `Think`/`Render` — `:22-26`: standard life-time pattern, no manual drawing.

The particle names come from a **private copy** of the game's blood pcfs to dodge Source's
`blood_impact_red_01` name collision (`mcv/shared/sh_melee_effects.lua:3-5`; BUGLIST `:51`).

---

## 4. The Impact System

### 4.1 Entry point and stock fallback — `MCV.BulletImpact`

```lua
// mcv/shared/sh_impacts.lua:27-42
function MCV.BulletImpact(tr, damage, recipients, ricochet, color)
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    if MCV.SurfaceImpact(tr, damage, recipients, ricochet, color) then return end
    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetStart(tr.StartPos)
    fx:SetNormal(tr.HitNormal)
    fx:SetSurfaceProp(tr.SurfaceProps or 0)
    fx:SetDamageType(DMG_BULLET)
    fx:SetHitBox(tr.HitBox or 0)
    // Worldspawn fails IsValid, but the engine's Impact effect needs entity 0
    // for map geometry (and static props addressed through HitBox). Dropping it
    // leaves the effect without a target, so neither particles nor decals appear.
    if tr.Entity then fx:SetEntity(tr.Entity) end
    util.Effect("Impact", fx, true, recipients or true)
end
```

* Realm: **SH**. Signature `(tr, damage, recipients, ricochet, color)`.
* Tries the custom path first; only if that declines (convar off, no family, no ricochet) does it
  build the stock `Impact` payload. The worldspawn comment documents BUGLIST `:4` (stock impacts
  missing on map geometry — fixed by preserving entity 0).
* `ricochet`/`color` flow only into the custom path; the stock effect is always `DMG_BULLET`.
* Callers: `MCV.HitscanEffects` (`sh_hitscaneffects.lua:40`), the crossbow bolt
  (`entities/mcv_proj_bolt.lua:92,113`), the chainsaw (`weapons/mcv_chainsaw.lua:91`), and the
  client physical-bullet deduplicator (`mcv/client/cl_physbullet_impacts.lua:30`).

### 4.2 Surface family resolution — `MCV.ImpactFamily`

`MCV.ImpactFamilies` (`sh_impacts.lua:48-54`) is an **ordered list of 33 surface names** — ordered
because the family travels as an index (`:44-47`). Resolution:

```lua
// mcv/shared/sh_impacts.lua:106-112
function MCV.ImpactFamily(tr)
    local data = tr.SurfaceProps and util.GetSurfaceData(tr.SurfaceProps)
    local name = data and data.name
    if name and index[name] then return name end

    return mattype_to_family[tr.MatType]
end
```

The surface **property name wins** over the material type because it separates brick, asphalt,
rock, carpet etc. from the single `MAT_CONCRETE` the engine reports for all of them (`:104-105`).
`mattype_to_family` (`:71-89`) is the coarse fallback; flesh is deliberately absent — "the engine's
blood is better than anything in here" (`:69-70`), so flesh hits keep stock blood.

The pcf side: `particles/vietnam_impact_effects.pcf` holds `impact_<surface>_1..3` (33 surfaces ×
3), each numbered system being a whole impact with children (debris, mist, smoke, sparks) — hence
MCV's re-scaled copies `mcv_scaled_impact_<family>_<v>` in `particles/mcv_scaled_impacts.pcf`
(`sh_impacts.lua:1-12`, `:56-67`). The `_spike` alternates are pulled in by the numbered systems
themselves (`:45-47`).

### 4.3 Damage-scaled particles — `MCV.ImpactScale`

```lua
// mcv/shared/sh_impacts.lua:118-120
function MCV.ImpactScale(damage)
    return math.Clamp(math.sqrt(math.max(damage or 40, 0) / 40), 0.5, 2)
end
```

40 damage is the original art size; square-root growth keeps pellet marks modest and caps custom
weapons at 2× radius (`:116-117`; BUGLIST `:147`). The effect entity clamps again
(`effects/mcv_impact.lua:104-106`) so a hand-dispatched effect can't go wild.

### 4.4 Dispatch — `MCV.SurfaceImpact`

```lua
// mcv/shared/sh_impacts.lua:122-154
function MCV.SurfaceImpact(tr, damage, recipients, ricochet, color)
    if !MCV.SurfaceImpacts() then return false end
    if !tr or !tr.Hit or tr.HitSky then return false end

    local family = MCV.ImpactFamily(tr)
    local i = family and index[family]
    if !i and !ricochet then return false end
    // This hook receives authoritative client impacts (including singleplayer),
    // outside user-command prediction. IsFirstTimePredicted can be false here;
    // it is not a replay indicator for this callback. The engine gates the hook.

    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetNormal(tr.HitNormal)
    // Only incoming bullets opt in. Melee and reverse penetration-exit traces
    // share this surface effect but must never produce a bullet ricochet.
    fx:SetDamageType(ricochet and DMG_BULLET or 0)
    fx:SetStart(ricochet and tr.StartPos or tr.HitPos)
    fx:SetFlags(i or 0) // zero adds only the ricochet; stock impact/blood still runs
    fx:SetScale(MCV.ImpactScale(damage))
    if ricochet then
        color = color or MCV.TracerColor(nil, "")
        // RGB in otherwise unused payload fields; preserve Start for reflection.
        fx:SetMagnitude(color.r)
        fx:SetRadius(color.g)
        fx:SetColor(math.floor(color.b + 0.5))
    end
    // Authoritative/SP callers run outside prediction. Hitscan supplies its own
    // recipient filter and gates first-predicted dispatch at the firing callback.
    util.Effect("mcv_impact", fx, true, recipients or true)

    return i != nil
end
```

* Realm: **SH** (returns whether handled — `true` is `SWEP:DoImpactEffect`'s signal to suppress the
  engine's own impact + decal, `mcv/weapon_common/shared.lua:301-307`).
* A family-less hit with `ricochet` still dispatches with `Flags = 0`: "zero adds only the
  ricochet; stock impact/blood still runs" (`:140`) — the effect entity then only performs decal
  + ricochet, no family particles (`effects/mcv_impact.lua:86` allows `family == nil` only for
  bullets).
* The forced `true` third argument bypasses prediction filtering in both realms (BUGLIST `:153`).
* `MCV.SurfaceImpacts()` (`:21-23`) reads the server convar `mcv_surface_impacts` (§7) — "1: the
  game's own per-surface bullet impacts. 0: the engine's" (`:18-19`).

### 4.5 Decals — `sh_impact_decals.lua` + `MCV.ImpactDecalName`

* `MCV.SurfaceDecals` (`mcv/shared/sh_impact_decals.lua:3-27`) maps 21 decal families to 4–6
  standalone materials each under `mcv/decals/...` ("Standalone materials preserve original
  textures and decal scale", generated by `work/import_impact_decals.py`, `:1-2`). Several impact
  families share decal art (carpet/grass/leaves/mud/sand/snow → dirt; plastic → computer; vent →
  metal).
* Registration loop `game.AddDecal("MCV.Impact." .. family, materials)` (`:29-31`).
* `MCV.ImpactDecalName(family)` (`sh_impacts.lua:97-102`): **no decal for water** (`puddle`,
  `water_*`); `decal_alias` maps the 7 families without their own art onto neighbours
  (`metalsteam→metal`, `clay→dirt`, `paper→cardboard`, `cloth→upholstery`, …, `:92-95`); unknown →
  `concrete`; returns the `MCV.Impact.*` decal name.
* The decal is applied **inside the effect entity**, not by the dispatcher:

```lua
// effects/mcv_impact.lua:92-97
    // Deliver the hole with the effect, including to the firing prediction host.
    // Decal's fourth argument excludes entities; passing the hit prop would skip it.
    local decal = family and MCV.ImpactDecalName(family)
    if decal then
        util.Decal(decal, pos + normal * 4, pos - normal * 4)
    end
```

  i.e. a 8-unit-deep trace along the normal, no entity filter — the same trick the engine's
  `UTIL_ImpactTrace` uses, re-implemented because returning `true` from `DoImpactEffect` took the
  engine's hole away (`sh_impacts.lua:14-16`). BUGLIST `:43` documents the extension of this to
  penetration **exit** faces.

### 4.6 Hitscan per-bullet effects — `sh_hitscaneffects.lua`

```lua
// mcv/shared/sh_hitscaneffects.lua:2-42
function MCV.HitscanEffects(wep, tr, damage, tracer, noRicochet)
    if CLIENT and !game.SinglePlayer() and !IsFirstTimePredicted() then return end
    local owner = wep:GetOwner()
    local recipients = true
    if SERVER then
        recipients = RecipientFilter()
        recipients:AddPVS(tr.StartPos)
        recipients:AddPVS(tr.HitPos)
        // The shooter already emitted the first predicted command's effects.
        // NPCs and singleplayer have no such client firing callback.
        if !game.SinglePlayer() and IsValid(owner) and owner:IsPlayer() then
            recipients:RemovePlayer(owner)
        end
    end
    local tracerRecipients = recipients
    local showTracer = tracer > 0
    if showTracer and wep.TracerParticle == "vietnam_tracer_silenced_primary" then
        if SERVER then
            // MP players predict their own trail. Only SP needs server delivery;
            // NPC trails have no shooter client. Impacts still use the full PVS.
            showTracer = game.SinglePlayer() and IsValid(owner) and owner:IsPlayer()
            if showTracer then
                tracerRecipients = RecipientFilter()
                tracerRecipients:AddPlayer(owner)
            end
        else
            showTracer = IsValid(owner) and owner == LocalPlayer()
        end
    end
    if showTracer then
        local fx = EffectData()
        fx:SetEntity(wep)
        fx:SetStart(tr.StartPos)
        fx:SetOrigin(tr.HitPos)
        util.Effect("mcv_tracer", fx, true, tracerRecipients)
    end
    local ricochet = !noRicochet and showTracer and MCV.HasTracerStreak(wep.TracerParticle)
        and wep:Clip1() % math.max(wep.TracerFrequency or 1, 1) == 0
    MCV.BulletImpact(tr, damage, recipients, ricochet,
        ricochet and MCV.TracerColor(owner, wep.TracerParticle) or nil)
end
```

* Realm: **SH**, called only from the `FireBullets` **callback** in `SWEP:BulletAttack`
  (`weapons/mcv_base/sh_shoot.lua:619`) and for penetration-exit traces (`:601`, with `tracer = 0`
  and `noRicochet = true`). Header comment: "Hitscan effects belong to the firing callback, not a
  second engine impact hook" (`:1`).
* Silenced trails are **shooter-private** in both delivery directions: MP servers don't send them
  (the shooter predicted it), SP servers send them only to the shooter, and the client-side
  `mcv_tracer` effect double-checks (`effects/mcv_tracer.lua:49-50`). BUGLIST `:63`.
* Ricochet is offered only when the round also shows its glowing streak, on the
  `TracerFrequency`-th round, and not for penetration continuations (`:38-39`).
* `MCV.HasTracerStreak(tracer)` (`mcv/shared/sh_tracercolor.lua:22-26`) — strips
  `vietnam_tracer_`/`_primary`/`_secondary`/`_green` and checks a fixed family set (silenced,
  shotgun_dots excluded).
* The `FireBullets` call itself passes `Tracer = 0, TracerName = "mcv_tracer"`
  (`sh_shoot.lua:612-613`) — the `TracerName` is inert (never used with `Tracer = 0`); it exists
  as documentation and the callback returns `{effects = false}` (`:620`) to disable the engine's
  per-bullet effects (BUGLIST `:85`).

### 4.7 Physical-bullet impact registration (cross-ref `docs/shooting-ballistics.md`)

* Server: each contact of a swept physical bullet is broadcast as a `MCV_PhysicalImpact` net
  message with a dedup key `owner:key:pellet:id` and a contact index `layers*2 + exit`
  (`mcv/server/sv_physbullets.lua:67-85`); the ricochet flag is `!exit and !penetrated and b.glow
  and MCV.HasTracerStreak(b.tracer)` with the colour resolved at launch (`:81-83`, `:103`).
* Client: `MCV.PhysicalBulletImpact(key, contactIndex, tr, damage, ricochet, color)`
  (`mcv/client/cl_physbullet_impacts.lua:19-31`) rebuilds a trace table from the net message
  (`:33-42`), suppresses echoes within 32 units of the same contact id within 15 s (ordered
  expiry queue, `:44-68`), then calls `MCV.BulletImpact` — with `ricochet` only on **even**
  (entry/terminal) contact indices. Predicted client flights call it directly from
  `advanceVisual` (`mcv/client/cl_physbullets.lua:258-263`).
* Water: `watersplash` is server-dispatched separately at the water trace hit, scale
  `sqrt(damage/40)`×10, flags 1 for slime (`sv_physbullets.lua:7-21`; BUGLIST `:101`).

### 4.8 Other impact callers

* `SWEP:DoImpactEffect(tr, dmgtype)` — `mcv/weapon_common/shared.lua:305-307` — the base's
  authoritative hook: `return MCV.SurfaceImpact(tr, (self.DamageGeneric or 40) *
  self:StatMult("damage"))`. This is what runs when *any* code (foreign included) calls
  `FireBullets` without disabling effects and without MCV's callback — the engine routes the
  impact here and MCV replaces it.
* Melee: `SWEP:MeleeHit` dispatches one authoritative server impact from the hull contact; blood
  via `MCV.MeleeBloodImpact` for flesh, `MCV.SurfaceImpact(tr, damage)` for the world, and only if
  both decline a zero-damage cosmetic `FireBullets` for the stock path
  (`weapons/mcv_melee/sh_melee.lua:61-83`).
* Bash (all guns): same pattern (`mcv/weapon_common/sh_bash.lua:78-91`).
* Chainsaw `SawTick`: blood-or-bullet impact per tick, no cosmetic bullets at all
  (`weapons/mcv_chainsaw.lua:87-92`).
* Crossbow bolt: body hits dispatch `MCV.BulletImpact` from the damage bullet's callback with
  `{effects = false}`; world hits build a trace from the physics contact (normal negated, prop
  escape guarded) and call `MCV.BulletImpact` (`entities/mcv_proj_bolt.lua:85-115`; BUGLIST `:67`).

### 4.9 Relevant BUGLIST items (upstream's own notes)

* `:4` stock impacts on worldspawn (fixed — entity 0 preserved, `sh_impacts.lua:37-40`).
* `:29`, `:31`, `:33`, `:37` the cosmetic-ricochet series (colour inheritance, invisible sparks =
  shader importer bug, zero-emission donor pcf, original feature).
* `:43` penetration-exit impacts + decals on the exit face.
* `:51` melee/chainsaw blood using private pcfs to avoid the Source name collision.
* `:63` silenced smoke-only trails restored, shooter-private.
* `:67` crossbow impacts share the dispatcher.
* `:85`, `:87` hitscan/physical effects moved into the firing callback / keyed confirmations.
* `:89`, `:91`, `:99`, `:101`, `:103` physical-bullet smoke/streak/muzzle-blend history.
* `:147` damage-scaled impacts (`ImpactScale`).
* `:153` SP missing effects: `IsFirstTimePredicted` gate removed from the authoritative hook,
  forced effect dispatch, decal registration (the design §4.4 now encodes).
* `:251` (open) some manual-action weapons lack proper shell-ejection delay.
* `:346` (historical) default GMod tracers replaced by custom ones.
* `:347` (historical) crossbow muzzle flash removed (empty `MuzzleParticle`).

---

## 5. Explosions — `mcv/shared/sh_explosions.lua`

### 5.1 Families and per-surface selection

`MCV.ExplosionFamilies` (`sh_explosions.lua:4-14`) maps 9 families to the game's system-name
prefixes (`rpg → Vietnam_Explosion_RPGRocket`, …). `single` (`:17-21`) lists families with no
per-surface variants (`xm202`, `m34`, `phosphorus`). Every base name and all 19 `<base>_<Surface>`
combinations are precached (`:55-60`), plus the in-flight trails `rpg_missile_trail`,
`kolos_missile_trail`, and three weapon-effect grenade trails (`:63-66`).

`MCV.GetExplosionSystem(family, pos, normal, inwater)` (`:70-100`):

* unknown family → `grenade` (`:71`); `single` families return the bare base (`:73`);
  underwater → `<base>_Water` (`:74`).
* otherwise a `util.TraceLine` along the normal (8 out, 24 in, `MASK_SOLID`, `:76-80`) probes the
  actual surface: `mattype_to_surface` (`:23-46`, note `MAT_CONCRETE → "Asphalt"`) then surfaceprop
  name overrides for brick / plaster / drywall / paper / cardboard / cloth / carpet / mud
  (`:87-94`), then a `have` whitelist of surfaces the pcfs really contain (`:49-53`, `:97`).

### 5.2 `MCV.SurfaceAngle(normal)`

```lua
// mcv/shared/sh_explosions.lua:105-109
function MCV.SurfaceAngle(normal)
    local ang = (normal or vector_up):Angle()
    ang:RotateAroundAxis(ang:Right(), -90) // +90 put the normal on the angle's down axis
    return ang
end
```

The explosion/fire systems build their column along the control point's **up**, so a normal passed
as the angle's forward had them shooting sideways (`:102-104`). This helper is reused outside
explosions: the fire pool and molotov pool orientation
(`entities/mcv_grenade_base.lua:80`, `mcv_grenade_molotov.lua:40`).

### 5.3 `MCV.ExplosionEffect` and its callers

```lua
// mcv/shared/sh_explosions.lua:111-119
// Spawns the explosion effect for a projectile. Shared: calling it on the server dispatches
// the particle system to every client.
function MCV.ExplosionEffect(family, pos, normal, inwater)
    normal = normal or vector_up

    local name = MCV.GetExplosionSystem(family, pos, normal, inwater)

    ParticleEffect(name, pos, MCV.SurfaceAngle(normal))
end
```

Realm: SH, but **effectively server-only by convention** — every caller is a server-side
`Detonate` (grenade base `entities/mcv_grenade_base.lua:94`; rockets at
`mcv_proj_rpg.lua:50`, `mcv_proj_rpg2.lua:50`, `mcv_proj_panzerschreck.lua:36`,
`mcv_proj_bazooka.lua:36`, `mcv_proj_kolos.lua:36`, `mcv_proj_m202.lua:55`, 40 mm / rifle
grenades at `mcv_proj_40mm.lua:48`, `mcv_proj_riflegrenade.lua:48`,
`mcv_proj_riflegrenade_vc.lua:48` — the `_ger` variant only inherits from `_vc` with no override,
`mcv_proj_riflegrenade_ger.lua:3`). The grenade
base chooses the normal deliberately: planted charges use their placement normal, thrown/dropped
ones always `vector_up` (`mcv_grenade_base.lua:91-93`; BUGLIST `:143` — timed grenades no longer
use the last bounce normal). `WaterLevel() > 0` selects the water variant. There is **no
LOS/attenuation logic in the effect path** — damage is a separate `util.BlastDamage`
(`mcv_grenade_base.lua:72`); see `docs/projectiles-entities.md` for the damage semantics.

### 5.4 Trail / attached particles on projectiles

`entities/mcv_proj_base.lua:145` attaches `self.TrailParticle` with `PATTACH_ABSORIGIN_FOLLOW` for
rocket flight (stopped clientside on detonation, `:171-173`); molotov wicks, flare ground glow,
dynamite fuses and C4 blink lights use `ParticleEffectAttach` at the sites listed in §2.3. These
are entity-driven (networked with the entity) rather than `util.Effect`-driven — a foreign base
translating an "attach smoke to my projectile" feature should follow this pattern instead of
spawning effects per tick.

---

## 6. Weapon-Side Dispatch — `weapons/mcv_base/sh_effects.lua`

### 6.1 `dispatchWeaponEffect(name, data, owner)` — the local courier

```lua
// weapons/mcv_base/sh_effects.lua:7-18
local function dispatchWeaponEffect(name, data, owner)
    local origin = owner:GetShootPos()
    data:SetOrigin(origin)
    if SERVER then
        local recipients = RecipientFilter()
        recipients:AddPVS(origin)
        if owner:IsPlayer() and !game.SinglePlayer() then recipients:RemovePlayer(owner) end
        util.Effect(name, data, true, recipients)
    else
        util.Effect(name, data)
    end
end
```

Every weapon-triggered effect (`mcv_muzzleeffect`, `mcv_shelleffect`) goes through this: the
`Origin` field is the **shooter's eye position** (for PVS routing only — the clientside entities
ignore it and re-derive their own origins), the server force-dispatches to PVS clients minus the
MP shooter, and the client calls `util.Effect` without force (already inside a
first-time-predicted gate). Class-level default tables `SWEP.ActiveEffects = {}` / `SWEP.PCFs =
{}` are declared here (`:2-3`) — per-instance copies are created in `SWEP:Initialize`.

### 6.2 `SWEP:GetTracerOrigin()`

`weapons/mcv_base/sh_effects.lua:20-45`. Realm SH. Returns the world position of the muzzle for
**this frame's context**: server or non-local or third-person → the world model's (or hand-drawn
model's, via `GetWorldModelAttachment`, `:25-26`) `muzzle` attachment, cached by
`MCV.CachedAttachment` (`mcv/shared/sh_modelcache.lua:30-32`); first person → viewmodel muzzle
(akimbo left on odd clip count via `muzzleleft`/`muzzle2`, `:35-38`). Fallback chain ends at the
owner's shoot pos (`:31`, `:40-43`). Used by `DoMuzzleLight` (`:140`, `:166`) and by the physical
muzzle capture (cross-ref `docs/shooting-ballistics.md`).

### 6.3 `SWEP:DoMuzzle(alt)`

`weapons/mcv_base/sh_effects.lua:47-87`. Realm SH (predicted).

* Gated by `IsFirstTimePredicted()` (`:48`) — the single replay guard for the whole flash.
* Resolves the viewmodel (or the weapon itself for NPC owners, `:51`), its `muzzle` QCA,
  overridden to `muzzle2` when firing the UBGL while `RifleGrenadeIsUBGL` (`:55-57`), and to
  `muzzleleft`/`muzzle2` when the akimbo **left** gun fires — "the left gun fires on an odd count"
  (`:61-64`, comment at `:35`), except during a volley (`:59`).
* Dispatches `mcv_muzzleeffect` with `Entity = self`, `Attachment = muzz_qca`, `Magnitude = 1`
  only for the akimbo-left shot (`:66-71`).
* Akimbo volleys additionally dispatch a second flash at hardcoded attachment **4** with
  `Magnitude = 1` for the left gun (`:73-80`).
* Then the light: clientside `DoMuzzleLight()` for the local player, or `CallOnClient` in
  singleplayer (`:82-86`). NPCs get server-dispatched particles but **no muzzle light** (the
  light is client-only).

### 6.4 `SWEP:DoEject(attachment)`

`weapons/mcv_base/sh_effects.lua:92-123`. Realm SH (predicted).

* `IsFirstTimePredicted` gate (`:93`); `EjectBrassType == 0` weapons eject nothing (`:94`).
* The `attachment` argument names the port: **animation events carry their own** ("`eject2` on the
  duals' left-hand shots"); a bare call from the shot picks the port by the same parity `DoMuzzle`
  uses — odd count → `eject2`, volley → both (`:89-108`).
* For each port: falls back to `eject` if the named one is missing (`:113`), then dispatches
  `mcv_shelleffect` with `Entity`, `Attachment`, `Flags = EjectBrassType`, `Magnitude = 1` for
  `eject2` (`:115-121`).
* Overrides downstream: the M79 suppresses the eject while switching loaded ammo types
  (`weapons/mcv_m79_base/shared.lua:61-64`).

### 6.5 `SWEP:DoMuzzleLight()`

`weapons/mcv_base/sh_effects.lua:125-181`. Realm **CL** (called locally or via `CallOnClient`).

* Guard: `if !IsFirstTimePredicted() and !game.SinglePlayer() then return end` (`:126`) — in SP
  the `CallOnClient` invocation arrives outside prediction, so only MP prediction replays are
  suppressed.
* Skips weapons with no muzzle particles at all (the crossbow: "a gun that flashes always has
  one", `:128-130`).
* Mode 1 `MCV.MUZZLE_LIGHT_DYNAMIC` (`:137-147`): `DynamicLight(self:EntIndex())` at
  `GetTracerOrigin()`, colour 255/226/170, brightness/size halved when silenced, 0.06 s life,
  decay 3000.
* Mode 2 `MCV.MUZZLE_LIGHT_FULL` (`:150-180`): a `ProjectedTexture` (shadow-casting) with
  `MuzzleFlashLightTexture` (default `"effects/flashlight_muzzleflash"` at
  `weapons/mcv_base/shared.lua:208`; silenced pistols use `_sl` variants, `mcv_pb.lua:162`),
  randomised brightness/FOV (silenced 0.2–0.4 / 100–105°, else 2–3 / 115–120°), far Z 600,
  positioned at the tracer origin aimed along `GetAimAngle()`. It is stored on
  `self.MuzzleLight` and killed by `Think` (see `docs/gun-core.md`); a 0.06 s `timer.Simple`
  failsafe removes it if the weapon stops thinking first (`:176-180`).

### 6.6 Call sites of the weapon dispatchers

| Caller | Site | Notes |
|--------|------|-------|
| `SWEP:AttackEffects` (player fire) | `weapons/mcv_base/sh_shoot.lua:448-453` | `DoEject()` unless `NoEjectOnShoot`, then `DoMuzzle()`, inside `IsFirstTimePredicted` |
| `SWEP:FireAnimationEvent` | `sh_shoot.lua:201-205` | model `eject`/`eject2` events → `DoEject(name)`; cross-ref animation-system.md §5.5 (the only native events handled in Lua) |
| NPC fire | `weapons/mcv_base/sh_npc.lua:148-150` | `DoMuzzle()` always; `DoEject()` unless `NoEjectOnShoot` (or `PlayCycleAnimation`); "Effects use the same pre-shot clip parity as player fire" (`:146-147`) |
| UBGL launch | `weapons/mcv_base/sh_ubgl.lua:77-82` | `DoEject()` + `DoMuzzle()` first-time-predicted |
| M79 base | `weapons/mcv_m79_base/shared.lua:61-64` | overrides `DoEject` to suppress during ammo-type reload transitions |

### 6.7 The render path for weapon-parented particles (cross-ref animation §9)

* First-person muzzle/shell particles are created with `SetShouldDraw(false)` and pushed into
  `SWEP.PCFs` (`effects/mcv_muzzleeffect.lua:49-53`, `effects/mcv_shelleffect.lua:121-130`);
  `SWEP:PostDrawViewModel` draws them **by hand inside the still-open viewmodel camera**, so they
  sit on the gun's attachments at viewmodel FOV and depth-test against it
  (`mcv/weapon_common/sh_vm.lua:143-179`), with a refraction-buffer save/restore around the batch
  for Contact Shadows (BUGLIST `:23`, `:209`; harness note at `sh_vm.lua:163-165`).
* In-flight first-person shells register in `SWEP.ActiveEffects` and are drawn by
  `SWEP:ViewModelDrawn` inside the viewmodel's own render pass ("TacRP's system: a shell lives
  here until it hits something, then draws itself in the world", `sh_vm.lua:79-100`); the shell
  itself flips `VMContext` on first bounce (`effects/mcv_shelleffect.lua:143`).
* Systems that reach into the world (flamethrower) are tagged in `SWEP.WorldPCFs` and drawn in a
  separate world-projection pass (`sh_vm.lua:188-197`; `weapons/mcv_flamethrower/sh_flame.lua:177-178`).

---

## 7. Settings — Convars

Registered centrally in `cl_effectsettings.lua` (rationale comment at `:4-5`) except the two
impact/tracer ones. `MCV.RegisterConVar` is the shared helper (see `docs/support-systems.md`).

| Convar | Default | Realm | Helper | Description |
|--------|---------|-------|--------|-------------|
| `mcv_surface_impacts` | `"1"` | SV (replicated, via `MCV.RegisterConVar`) | `MCV.SurfaceImpacts()` — `sh_impacts.lua:21-23` | "1: the game's own per-surface bullet impacts. 0: the engine's." Gates `SurfaceImpact` and the melee-blood custom particles (`sh_melee_effects.lua:31`) |
| `mcv_shell_time` | `"0.5"` | CL (saved) | `MCV.ShellTime()` — `cl_effectsettings.lua:30-32` | seconds a case lies **at rest** before fading (`math.max(..., 0)`) |
| `mcv_shell_smoke` | `"1"` | CL (saved) | `MCV.ShellSmoke()` — `:34-36` | the smoke trail following an ejected case |
| `mcv_muzzle_light` | `"2"` | CL (saved) | `MCV.MuzzleLightMode()` — `:38-40` | "2 projected with shadows, 1 a plain dynamic light, 0 none"; clamped; constants `MCV.MUZZLE_LIGHT_OFF/DYNAMIC/FULL` at `:17-19` |
| `mcv_tracer_color` | `"0"` | CL (saved, **userinfo**) | `MCV.TracerColorMode(ply)` — `sh_tracercolor.lua:6-9` | "0 the gun's own, 1 your player colour, 2 your physgun colour. Other players see the one you pick." (registered in `mcv/client/cl_tracercolor.lua:2-3`) |

"Every one of these is that client's own: nobody else is affected by turning a light off to hold a
frame rate" (`cl_effectsettings.lua:1-2`) — except `mcv_surface_impacts`, which is a **server**
content gate that changes which effect everyone receives.

Tracer colour resolution (`sh_tracercolor.lua:28-33`): mode 1 → `MCV.BrightColor(owner:GetPlayerColor())`,
mode 2 → weapon colour, else the art default (`235,175,51` or green `96,235,51` when the particle
name contains `_green`). `MCV.BrightColor` (`:11-16`) normalises any vector to its brightest
component at 255. The colour feeds both the hand-drawn streak and the ricochet spark (§4.6).

---

## 8. Translation-Layer Surface (ranked)

How foreign weapon bases' effect idioms map onto MCV's pipeline, ranked by impact on correctness.

1. **`DoImpactEffect` / engine `Impact` replacement is automatic and total.** Any foreign code
   that fires `FireBullets` *without* returning `{effects = false}` from a callback gets MCV's
   `SWEP:DoImpactEffect` → `MCV.SurfaceImpact` for every bullet (`mcv/weapon_common/shared.lua:305-307`)
   — surface particles, custom decals, forced `mcv_impact` dispatch (without ricochet, since
   `ricochet = nil` there). Foreign code that *itself* overrides `SWEP:DoImpactEffect` will
   **stomp MCV's** (last-defined wins) and must be re-pointed at `MCV.BulletImpact(tr, damage)` to
   keep decal/prediction/recipient semantics. This is the single most collision-prone hook.
2. **Muzzle flash must be routed to `DoMuzzle`, not re-implemented.** Foreign bases typically
   either emit `util.Effect("muzzleflash")`/`MuzzleFlash()` in a predicted shoot path or set
   `SWEP.MuzzleFlashScale` and let the engine draw. On MCV the flash is data
   (`MuzzleParticle`/`…Smoke`/`…Ironsighted`/`…3rdPerson` fields, `weapons/mcv_base/shared.lua:203-210`)
   dispatched by `DoMuzzle` with the akimbo/UBGL parity logic (§6.3). The translation layer should
   translate a foreign "fire happened" event into `self:DoMuzzle()` and populate the particle
   fields from the foreign base's asset names; direct `util.Effect("muzzleflash")` calls will
   still work (engine effect, world-attached) but lose the viewmodel-pass drawing, ironsight swap
   and akimbo logic. Note the engine's `MuzzleFlash()` on the viewmodel is *not* used by MCV at
   all.
3. **Shell ejection: model events vs explicit calls.** MCV handles native `eject`/`eject2` events
   in `FireAnimationEvent` (`sh_shoot.lua:201-205`) and otherwise ejects from `AttackEffects`
   (`:448-451`, suppressed by `NoEjectOnShoot` for manual-cycle weapons). Foreign bases that
   eject via their own event tables or `AE` codes must funnel into `SWEP:DoEject(port)` and set
   `EjectBrassType` (index into `MCV.ShellTypes`, `sh_common.lua:82-175`), `EjectBrassParticle`,
   `EjectBrassTrail`. Calling `DoEject` twice per shot (event + explicit) double-ejects — pick one
   path per weapon, exactly as MCV's `NoEjectOnShoot` implies.
4. **Tracers: `TracerName` is inert; the callback owns everything.** MCV passes `Tracer = 0` and
   dispatches `mcv_tracer` itself (`sh_shoot.lua:612-613`, `sh_hitscaneffects.lua:31-37`). A
   foreign base that relies on `FireBullets(..., Tracer = 1, TracerName = "..."`) will get GMod's
   default tracer *plus* MCV's, or none if it also sets `Tracer = 0`. Translation: intercept the
   foreign tracer name, map it to a `TracerParticle` family name (or translate its colour/length
   intent), and let `MCV.HitscanEffects` run; if the foreign base wants the engine tracer
   verbatim, suppress `mcv_tracer` by keeping `TracerParticle = ""` (`effects/mcv_tracer.lua:48`).
5. **Prediction/recipient contract for any custom `util.Effect`.** Foreign bases commonly call
   `util.Effect` inside predicted hooks with no filter — on MCV this double-fires (client + server
   broadcast) or vanishes in replays. The house pattern to enforce: gate with
   `IsFirstTimePredicted()`, route through `dispatchWeaponEffect`-style PVS filtering minus the
   shooter (`sh_effects.lua:7-18`), or accept the forced-dispatch `true` convention used by the
   impact path (`sh_impacts.lua:151`) which is safe *because* those entry points are
   authoritative-only.
6. **`EffectData` field collisions.** MCV overloads `Magnitude`/`Radius`/`Color` (RGB),
   `Flags` (family/shell index), `DamageType` (ricochet opt-in) on its own effects. These are
   private to MCV's five effect entities — but a translation layer that *reuses* `mcv_impact` /
   `mcv_shelleffect` to render foreign-base impacts must populate exactly the contracts in §2.2
   (e.g. `Flags` must be a valid `MCV.ShellTypes`/`MCV.ImpactFamilies` index or 0).
7. **Explosions: map to `MCV.ExplosionEffect(family, ...)`.** Foreign `util.Effect("explosion")`
   / `EFFECT_EXPLOSION` calls should be translated to a family (`grenade` is the safe default,
   `sh_explosions.lua:71`) so the per-surface variant, water variant and up-axis orientation all
   work; the damage half stays `util.BlastDamage` (see `docs/projectiles-entities.md`). Direct
   `ParticleEffect` calls in shared code are fine on the server only.
8. **Blood/melee.** Foreign melee blood (`util.Effect("BloodImpact")`) still works — MCV keeps the
   stock name as its fallback (`sh_melee_effects.lua:33`). For parity with the convar, route flesh
   hits through `MCV.MeleeBloodColor`/`MCV.MeleeBloodImpact`.
9. **Water/ricochet gating.** The ricochet only fires for `DMG_BULLET`-typed dispatches with a
   visible streak on the frequency round (§4.6); foreign weapons with `TracerFrequency > 1` will
   ricochet only on glowing rounds — intentional, document it.
10. **Client convars are per-viewer** (§7): the translation layer must not gate *dispatch* on
    `mcv_shell_time`/`mcv_shell_smoke`/`mcv_muzzle_light` server-side; only
    `mcv_surface_impacts` is a server gate.

---

## 9. File Map

| File | Realm | Contents |
|------|-------|----------|
| `lua/effects/mcv_impact.lua` | CL | impact effect entity: decal, `mcv_scaled_impact_*` family variants, cosmetic ricochet (§3.1) |
| `lua/effects/mcv_muzzleeffect.lua` | CL | muzzle flash effect entity, FP/TP particle selection (§3.2) |
| `lua/effects/mcv_shelleffect.lua` | CL | shell casing physics entity + eject puff/trail (§3.3) |
| `lua/effects/mcv_tracer.lua` | CL | tracer smoke + hand-drawn streak (§3.4) |
| `lua/effects/mcv_melee_blood.lua` | CL | melee blood particle owner (§3.5) |
| `mcv/shared/sh_effects.lua` | SH | `game.AddParticles` manifest — 45 pcfs (§1.1) |
| `mcv/shared/sh_impacts.lua` | SH | `MCV.BulletImpact`, `MCV.SurfaceImpact`, `MCV.ImpactFamily`, `MCV.ImpactScale`, `MCV.ImpactDecalName`, `MCV.ImpactFamilies`, `mcv_surface_impacts` (§4) |
| `mcv/shared/sh_impact_decals.lua` | SH | `MCV.SurfaceDecals` + `game.AddDecal("MCV.Impact.*")` (§4.5) |
| `mcv/shared/sh_hitscaneffects.lua` | SH | `MCV.HitscanEffects` — per-bullet tracer + impact from the firing callback (§4.6) |
| `mcv/shared/sh_melee_effects.lua` | SH | `MCV.MeleeBloodParticles`, `MCV.MeleeBloodColor`, `MCV.MeleeBloodImpact` (§3.5/§4.8) |
| `mcv/shared/sh_explosions.lua` | SH | `MCV.ExplosionFamilies`, `MCV.GetExplosionSystem`, `MCV.SurfaceAngle`, `MCV.ExplosionEffect` (§5) |
| `mcv/shared/sh_tracercolor.lua` | SH | `MCV.TracerColor`, `MCV.TracerColorMode`, `MCV.BrightColor`, `MCV.HasTracerStreak` (§7) |
| `mcv/shared/sh_common.lua:82-175` | SH | `MCV.ShellTypes` — 23 shell models/sounds (§3.3) |
| `mcv/client/cl_effectsettings.lua` | CL | `mcv_shell_time`, `mcv_shell_smoke`, `mcv_muzzle_light` + accessors (§7) |
| `mcv/client/cl_tracercolor.lua` | CL | `mcv_tracer_color` userinfo convar (§7) |
| `mcv/client/cl_physbullet_impacts.lua` | CL | `MCV.PhysicalBulletImpact` dedup + net receive (§4.7) |
| `mcv/server/sv_physbullets.lua` | SV | water splash, `MCV_PhysicalImpact` broadcast (§4.7) |
| `mcv/client/cl_physbullets.lua` | CL | predicted flight, streak/smoke rendering, predicted contacts (§4.7) |
| `weapons/mcv_base/sh_effects.lua` | SH | `dispatchWeaponEffect`, `GetTracerOrigin`, `DoMuzzle`, `DoEject`, `DoMuzzleLight` (§6) |
| `weapons/mcv_base/shared.lua:202-222` | SH | default particle SWEP fields (§6) |
| `weapons/mcv_base/sh_shoot.lua:201-205,405-478,573-641` | SH | `FireAnimationEvent` eject, `AttackEffects`, `BulletAttack` (§6.6, §4.6) |
| `weapons/mcv_base/sh_npc.lua:146-157` | SH | NPC fire effects (§6.6) |
| `weapons/mcv_base/sh_ubgl.lua:77-82` | SH | UBGL eject/muzzle |
| `weapons/mcv_m79_base/shared.lua:61-64` | SH | M79 `DoEject` override |
| `weapons/mcv_melee/sh_melee.lua:53-94,330-345` | SH | melee hit blood/surface dispatch, repair sparks |
| `weapons/mcv_chainsaw.lua:65-93` | SV | chainsaw saw-tick blood/impact |
| `mcv/weapon_common/shared.lua:301-307` | SH | `SWEP:DoImpactEffect` default (§4.8) |
| `mcv/weapon_common/sh_bash.lua:64-99` | SH | bash strike impact dispatch |
| `mcv/weapon_common/sh_vm.lua:83-100,136-203` | CL | `ViewModelDrawn` (ActiveEffects), `PostDrawViewModel` (PCFs) (§6.7) |
| `mcv/weapon_common/cl_worldmodel.lua:256-288` | CL | `GetWorldModelFor`, `GetWorldModelAttachment`, PVS retire |
| `entities/mcv_proj_bolt.lua:70-115` | SH | crossbow bolt impacts |
| `entities/mcv_grenade_base.lua:69-101` | SV | `Detonate`: blast + firepool + `ExplosionEffect` |
| `entities/mcv_proj_*.lua` (rpg, rpg2, bazooka, panzerschreck, kolos, m202, 40mm, riflegrenade×3) | SV | rocket detonate effect dispatch (§5.3) |
| `entities/mcv_grenade_molotov.lua`, `mcv_firepool.lua`, `mcv_placed_*.lua`, `mcv_proj_flare.lua` | SV/SH | direct `ParticleEffect`/`ParticleEffectAttach` users (§5.4) |
| `mcv/shared/sh_modelcache.lua:30-32` | SH | `MCV.CachedAttachment` (used by every attachment lookup here) |

*End of audit. Cross-references: [animation-system.md](animation-system.md) (§5.5 eject events,
§9 viewmodel render pipeline), `docs/shooting-ballistics.md` (hitscan/physbullet flight),
`docs/projectiles-entities.md` (blast damage), `docs/weapon-definitions.md` (particle SWEP fields),
`docs/support-systems.md` (convar helper).*
