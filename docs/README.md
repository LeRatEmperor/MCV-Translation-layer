# MCV Base Audit — Complete Documentation Index

Exhaustive audit of the **Military Conflict Vietnam (MCV)** weapon base by the Arctic team,
performed as the engineering foundation for the **MCV Translation Layer** — a layer that lets
SWEPs written for other weapon bases (which drive animations via engine activities / sequence
names) run perfectly on MCV.

- **Audited upstream**: `tacrp/Military-Conflict--Vietnam-SWEPs` @ `06f4a24b` (read-only copy under `reference/mcv/`)
- **Scope**: all 239 lua files (~45K lines; ~29K logic lines excluding soundscript data)
- **Method**: every system documented with verbatim code excerpts and `file:line` citations
  (552 citations across these docs machine-validated for path/bounds; 150 verbatim excerpts
  verified against source), per-function coverage, realm & prediction notes, and a ranked
  "translation-layer surface" of hook points per system.

## Document Index

| # | Document | System | Lines |
|---|----------|--------|-------|
| 1 | [animation-system.md](animation-system.md) | Playback API, prediction timeline, pose-parameter engine, model contracts, per-action animation state machines, gestures, viewmodel render pipeline | 1,055 |
| 2 | [gun-core.md](gun-core.md) | SWEP lifecycle, composition loader, fixed datatable, Think loops, clock/timers, movement, sights & optics (RT scopes, overlays), bipod, akimbo, UBGL, bayonet charge, bash, camera, world models | 1,850 |
| 3 | [shooting-ballistics.md](shooting-ballistics.md) | Trigger pipeline, 13 fire modes, spread model, recoil, hitscan, segment/damage queue, physical bullets (server sim + client prediction), penetration budget, rocket flight, NPC fire path | 1,793 |
| 4 | [reload-ammo.md](reload-ammo.md) | Reload state machine (anim-lock driven), chamber/magazine model, delayed round credit, UBGL/M79 cartridge paths, interrupts, resupply (supply box, ammo/medic boxes) | 1,048 |
| 5 | [weapon-definitions.md](weapon-definitions.md) | **The translation layer's target schema**: complete field catalogue (~313 fields, 19 groups), worked line-by-line dissection, variant idioms, minimal viable definition, nested-table traps | 1,264 |
| 6 | [special-weapon-bases.md](special-weapon-bases.md) | Melee, throwable, placeable, flamethrower (+underbarrel), chainsaw, crossbow, binoculars, equipment box, M79, lunge mine — the two composition strategies | 2,032 |
| 7 | [projectiles-entities.md](projectiles-entities.md) | `mcv_proj_base` family (14 projectiles), grenade base & variants, placed explosives (C4/dynamite/mines), firepool, thrown melee — "weapon owns the numbers" injection contract | 815 |
| 8 | [sound-system.md](sound-system.md) | Dispatch taxonomy, soundscript entry grammar, loader & caches, foley (model-event driven), tink, near/distant layering, prediction-safe sample picks (mechanism + format; 1,732 entries counted, not catalogued) | 815 |
| 9 | [effects.md](effects.md) | Effect dispatch architecture, the 5 lua effects (impact/muzzle/shell/tracer/melee blood), impact & decal system, explosions, weapon-side dispatch, convars | 941 |
| 10 | [hud-settings.md](hud-settings.md) | HUD architecture & elements, fonts, kill icons, categories/subcategories, 212-convar registry, settings UI, localization, dev HUD | 617 |
| 11 | [support-systems.md](support-systems.md) | NPC integration, burning, `sh_common` constants, safe movement, model cache/GC, random weapons, the 27-module dev harness (incl. verification tooling) | 623 |

**Total: ~12,800 lines of audit documentation.**

## Architecture at a Glance

```
lua/
├── autorun/sh_mcv_load.lua        → bootstraps the library on both realms
├── mcv/                           → the LIBRARY (not a SWEP)
│   ├── weapon_common/             → module template: shared.lua + sh_/cl_ modules
│   │     (sandboxed & deep-copied into every base via load.lua — NOT inheritance)
│   ├── shared/ server/ client/    → global systems: sounds, impacts, effects,
│   │                                physbullets, NPC, burn, categories, harness glue
│   └── (soundscripts: 1,732 sound.Add entries across 3 files)
├── weapons/
│   ├── mcv_base/                  → THE gun base (composes weapon_common modules)
│   ├── mcv_melee/ throwable/ placeable/ equipment_box/   → special bases
│   │     (weapon_common + Base="weapon_base" — sequence-name driven, no gun systems)
│   ├── mcv_flamethrower/ binoculars/ m79_base/ underbarrel_flame/
│   │     (inherit mcv_base, surgically replace ThinkWeapon/PrimaryAttack)
│   └── mcv_<weapon>.lua           → ~150 weapon definitions (single file or folder)
├── entities/                      → proj_base family, grenades, placed explosives,
│                                    firepool, supply box (server-only, weapon injects numbers)
└── effects/                       → 5 clientside effects (impact/muzzle/shell/tracer/blood)
```

Load order: `autorun/sh_mcv_load.lua` → `mcv/shared/*` globals → per-base
`weapon_common/load.lua` sandbox-copy → `MCV.IncludeWeaponModules("weapons/mcv_base")` →
weapon definitions register via `SWEP.Base` chains. Details: [gun-core.md §1](gun-core.md).

## Master Translation-Seam List

The single most important input to translation-layer design. Consolidated from each doc's
ranked "translation-layer surface" section (see each doc for the full ranked list):

1. **`SWEP:PlayAnimation(act) / PlaySequence(name)`** — the ONLY choke point for discrete
   actions (anim §2, §11). Everything (deploy, fire, reload, bash…) routes through
   `applySequence`; tolerance for missing animations must never unlock gameplay.
2. **Pose parameters, not activities, carry continuous state** — `DoBodygroups` /
   `DoBodygroupsWeapon` write `player_movement`, `ironsight`, `ammo_fraction`, `empty`,
   `hammerpos`, `recoil_r/l`, … every frame (anim §4). Foreign models lack these.
3. **Viewmodel timeline is reconstructed in Lua** from `AnimationStart`/`AnimationDuration`
   NetworkVars with monotonic-progress guards (anim §3) — the engine activity state machine
   is bypassed entirely; no `SendWeaponAnim`/`SendWeaponMatchingSequence` anywhere.
4. **The shared datatable is fixed** — derived bases must not redefine `SetupDataTables`
   (gun-core §2). Foreign weapon state goes into plain Lua fields or NW2.
5. **`BulletAttack` / `RocketAttack` are the only sanctioned fire injection points** —
   direct `FireBullets` loses lag compensation, penetration, hitgroup cancel, and effect
   ownership (shooting §12).
6. **Reload has no duration fields** — timing is the model's `SequenceDuration`; the state
   machine advances on `AnimLockTime` expiry and ammo transfers via replayable predicted
   writes. `DefaultReload` / engine reload handling must be intercepted (reload §2, §11).
7. **The weapon-definition schema is the target format** — ~313 fields in 19 groups
   (weapon-definitions §3). The nested-table patch semantics of GMod mean converters must
   emit complete tables (weapon-definitions §1, §7).
8. **`SWEP.MilitaryConflictVietnam = true` gates 8+ global systems** (NPC pickup, world
   models, movement prediction, clock resets…) — must survive any table surgery.
9. **DeferredActions replace `timer.Simple`** — append-only, networked by index; closures
   cannot predict (gun-core §5, special-bases §1).
10. **Entities are dumb, weapons own the numbers** — `LaunchProjectile`/`ConfigurePlaced`
    inject `ExplosionDamage`/`Radius`/`Delay`… pre-`Spawn()` (projectiles §1, §8).
11. **Sound: near (110) + distant (149) layered entries** resolved from soundscripts;
    first-person foley is 100% model-event driven — foreign viewmodels carry no events, so
    the converter must schedule foley itself (sound §9).
12. **Impacts/tracers are firing-callback owned** — `SWEP:DoImpactEffect` must re-point at
    `MCV.BulletImpact`; engine `TracerName` is inert (effects §8).
13. **HUD comes free** via engine SWEP hooks mixed into every base — but kill icons
    hard-require the `mcv_` class prefix + icon file, and `cl_subcategories` replaces
    `DoPopulate` for any category containing an MCV weapon (hud-settings §11).
14. **The dev harness verifies conversions** — `report` + `H.WeaponState`, `ptrace`
    (prediction diff), `visual_trace` (VM sequence/parity recorder), `reload_trace` /
    `cycle_timing` (wrap `PlayAnimation`, consume its return value) (support-systems §9).

## Repo Layout

```
mcv-translation-layer/
├── README.md            → this repo's purpose (translation layer workspace)
├── docs/                → the audit documentation (this index + 11 system docs)
└── reference/mcv/       → read-only upstream copy @ 06f4a24b (lua + root notes:
                           AGENTS.md, CLAUDE.md, BUGLIST.md, weapon_list.md, addon.json)
```

Known upstream issues are cross-referenced throughout from `reference/mcv/BUGLIST.md`.
