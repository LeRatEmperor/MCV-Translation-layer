# MCVPort — Translation Layer Specification

How SWEPs written for other bases get ported onto the MCV base. This document
is the design contract for the layer in `lua/` and the templates in
`templates/`; the behaviour it builds on is cited from the audits in this
folder. Organizational model: Dandy's Hellraiser Base's `DHR.Define`
(`reference/dhrb/dhr/core.lua`), used as the example, not ported.

---

## 1. What porting means here

A port is a **full rewrite with a clean cut**. The workflow:

1. Decompile the original mod.
2. Fill in a template gun (`templates/port_*.lua` → `lua/weapons/<class>.lua`)
   with the original's data: models, stats, sounds, timings.
3. Port the original's sound lua into a plain
   `lua/autorun/port_sounds_<class>.lua` of `sound.Add` declarations —
   vanilla GMod, no proprietary base.
4. Done. The weapon depends on **mcv_base + this layer only**; the original
   mod and its base are never required again.

The porter is the converter. The layer's job is to make the rewrite
systematic: a fixed schema to fill (the template), one declarative table for
everything translational (`MCV.Define`), and small runtime bridges that map
foreign models' animation contracts onto MCV's audited seams. No config
parsers, no runtime coupling to foreign bases, no emulation of their APIs.

### The two-homes rule

> If MCV consumes a field natively, it stays a flat SWEP field. Only
> translational data and custom mechanics go in `MCV.Define`.

Consequences: upstream MCV updates flow through untouched (a new native field
works with zero layer changes); the Define table stays small and
behaviour-only; and the layer only ever owns what MCV cannot consume natively.
Provenance is deliberately **not** schema — ports are severed from their
source, so origin data is bookkeeping, and it lives in the port file's header
comment where the porter's judgment calls ("dropped the burst mode, no anim")
are actually useful when debugging.

---

## 2. Architecture

```
lua/
  autorun/sh_mcvport_init.lua     loader: AddCSLuaFile tree, collision guards
  mcvport/
    sh_define.lua                 MCVP global, MCV.Define, role catalogue, validation
    sh_hooks.lua                  integration registry + hook runner
    sh_report.lua                 mcvport_report console command
    sh_animroles.lua              role resolution + PlayAnimation/HasAnimation bridges
    sh_events.lua                 synthetic timeline events
    sh_lifecycle.lua              Initialize/Deploy/Holster/Think/PrimaryAttack/Reload wrappers
  weapons/
    mcvport_gun.lua               the gun port base (mcv_base + the three method modules)
templates/                        copy-me port templates (not loaded by GMod)
reference/dhrb/                   the DHRB example files this design borrows from
```

Base chain: `weapon_base ← mcv_base ← mcvport_gun ← <your port>`.

The three method modules (`sh_animroles`, `sh_events`, `sh_lifecycle`) are
included by `mcvport_gun.lua` while the global `SWEP` is that base, so their
`SWEP:` definitions land on the port base without touching `mcv_base` at all.
Future melee/throwable/placeable port bases repeat the same three includes
against `mcv_melee` and friends. The global-API modules load from autorun
before any weapon file, so `MCV.Define` exists when port files run.

Load guards: `sh_mcvport_init.lua` refuses to overwrite an existing
`MCV.Define` (upstream collision), and warns when the MCV base is absent.

---

## 3. `MCV.Define(weapon, config)`

Mirrors `DHR.Define` (`reference/dhrb/dhr/core.lua:70-119`): deep-merge over
defaults, eager structural validation with precise messages, marker flags.

```lua
MCV.Define(SWEP, {
    anims    = { ... },   -- animation role table (section 4)
    events   = { ... },   -- synthetic timeline events (section 5)
    hooks    = { ... },   -- custom mechanics (section 6)
    required = { "idle", "draw", "fire" },
    act_roles = { [ACT_] = "role" },  -- extra activity->role bindings
    attachments = { muzzle = "1", eject = "2" }, -- this model's port names
    movement = true,      -- discrete walk/sprint bridge (section 7.1)
    foley    = "qc",     -- "qc" | "synthetic" (section 7.2)
    base     = "mcvport_gun",
})
```

What it does, in order:

1. Merges `config` over `MCVP.DefaultConfig`; `anims` merges over the full
   default role table, so rebinding `fire` alone still inherits defaults for
   every other role. **List values union, porter's candidates first**, the
   default activity appended as final fallback. Map values merge per key.
2. Validates structure eagerly (see below).
3. Sets `weapon.Base` (default `mcvport_gun`), warns when the base is not a
   `mcvport_*` one (the bridges would not exist).
4. Sets `weapon.MCVP = data` and `weapon.MCVPort = true`, returns the weapon.

Validation is load-time and hard (`error`, not console spam), with DHR-style
precision: `anims.fire[2] must be an activity number or a sequence name`,
`events.reload[1].t must be a nonnegative number...`,
`hooks.Blah is not a known hook (see MCVP.HookPolicies)`,
`required role "cycle" has no candidate in anims`. At *deploy* time the
philosophy flips to MCV's tolerance: resolve everything, warn once with the
complete missing list, and never let a missing animation lock the weapon
(`docs/animation-system.md` §2, the check → play → tolerate-nil contract).

Per-instance copy: `sh_lifecycle.lua`'s `Initialize` does
`self.MCVP = table.Copy(self.MCVP)` after the base initialize — the
GMod-inheritance nested-table lesson (`docs/weapon-definitions.md` §1.3:
derived tables merge index-by-index; mutable class tables must be copied per
instance, exactly like `weapon_common`'s `Primary` copies and DHRB's
`self.HR = table.Copy(self.HR)` at `dhr_base.lua:131`).

---

## 4. Animation roles

### 4.1 The problem

MCV addresses animations by engine activity at audited call sites — the
complete inventory is `docs/animation-system.md` §5.1 (~50 activities: draw,
holster, fire, dry-fire, shoot-last, cycle, pump, five reload forms, bayonet,
bipod, firemode, UBGL...). Foreign models frequently:

- name their sequences instead of mapping activities,
- map the *wrong* activities (an M9K "reload" on `ACT_VM_RELOAD_EMPTY`),
- or have variant chains the porter wants to try in order.

### 4.2 The role table

`MCVP.ActRoles` (sh_define.lua) names each call site's **intent** — `draw`,
`fire`, `fire_empty`, `fire_last`, `cycle`, `pump`, `reload`,
`reload_empty`, `reload_insert`, `reload_insert_empty`, `reload_start`,
`reload_finish`, `reload_bipod`, `bash`, `bayonet_swing`, `bayonet_on`,
`bayonet_off`, `bipod_in`, `bipod_out`, `bipod_idle`, `fire_bipod`,
`firemode`, `safety_in/out`, `idle_safety`, `fidget`, `fire_left` (akimbo),
`fire_fan`, `fire_volley`, `ubgl_*` — and inverts into `MCVP.DefaultAnims`,
one default activity per role. A port rebinds any role:

```lua
anims = {
    draw  = { "deploy", ACT_VM_DRAW },     -- candidate list, in order
    fire  = ACT_VM_PRIMARYATTACK,          -- an activity
    idle  = "idle01",                      -- a sequence name
    cycle = "bolt_work",
}
```

Unmentioned roles keep MCV's default activity, so **a model that already
speaks `ACT_VM_*` needs an almost-empty anims table** — that is the point of
the two-homes rule: the bridge only exists for the mismatch.

### 4.3 Resolution and the bridges

`MCVP.Resolve(self, vm)` (sh_animroles.lua, a port of DHRB's
`ResolveAnimations`, core.lua:174-246) walks every role against the real
viewmodel at deploy: activities via `SelectWeightedSequence`, names via
`MCV.CachedSequence` (the audited per-model cache, `docs/animation-system.md`
§6 — swapping the viewmodel automatically gets fresh lookups). Results cache
per model path, so model swaps re-resolve. Required roles missing → **one**
warning listing all of them; optional roles missing → listed in the cache for
`mcvport_report`, no warning; the weapon deploys and fires regardless.

The bridges on every `mcvport_*` base:

| Bridge | Behaviour |
|---|---|
| `SWEP:PlayAnimation(act, ...)` | If the act maps to a role that resolves, play the resolved form (name via base `PlaySequence`, activity via base `PlayAnimation` — a re-entrancy guard keeps act-kind resolutions from looping back into the bridge). Unresolved or unbound → base behaviour, byte for byte. |
| `SWEP:HasAnimation(act)` | True when the mapped role resolves — call sites gate optional anims with this probe, so it must agree with the bridge or the play never happens. |
| `SWEP:IdleSequence()` | Returns the idle role's name when it resolved to a sequence; base `Idle()` already gives `IdleSequence()` precedence over `IdleActivity()` and re-checks `HasSequence` (§2.4), so this is a clean seam. |

Everything downstream — prediction timeline stamps
(`AnimationStart`/`AnimationDuration`), hammer scheduling, idle bookkeeping,
third-person gestures — is inherited from `applySequence` unchanged
(`docs/animation-system.md` §2.3). The layer never touches it.

---

## 5. Synthetic timeline events

For models whose Source event tracks are missing or unreadable. Declared per
role:

```lua
events = {
    reload_empty = {
        { t = 0.8, sound = "PORT_X.MagOut" },
        { t = 2.0, sound = "PORT_X.MagIn" },
        { t = 2.4, data = { kind = "eject" } },   -- lands in OnRoleEvent
    },
    cycle = {
        { t = 0.6, sound = "PORT_X.BoltBack", realm = "server" },
    },
}
```

- `t` is **wall-clock seconds after the animation starts**, keyed to the
  networked `AnimationStart` value — the same clock the client's render path
  reconstructs the cycle from (§3), so event timing survives prediction and
  re-simulation with no extra networking. `GetAnimationStart()` doubles as
  the generation key: a new value means a new animation, resetting the fired
  set per realm.
- `realm` gates where the body runs: `"server"` (default — EmitSound
  replicates to everyone), `"client"` (the local player's predicted weapon
  only, for one-shot first-person visuals), `"shared"`. Non-local players'
  weapons never Think on their clients, so anything others must perceive must
  come from the server realm.
- Built-ins: `ev.sound` → `EmitSound`. Everything else → the port's
  `OnRoleEvent` hook (e.g. brass via `self:DoEject()`, the audited eject
  entry point at `sh_shoot.lua:201-205`).

**Native first, always**: `MagInTime` / `MagOutTime` / `ReloadInsertTime`
and the models' own event tracks (foley soundscripts fire themselves,
`docs/sound-system.md` §2) cover most timing; synthetic events are the last
resort, not the default.

---

## 6. Hooks — custom mechanics

Port of DHRB's integration system (`reference/dhrb/dhr/integrations.lua`) with its
three dispatch policies:

| Policy | Meaning | Hooks |
|---|---|---|
| `check` | any `false` return vetoes | `CanFire`, `CanReload`, `CanDeploy` |
| `event` | notification | `OnInitialize`, `OnDeploy`, `OnHolster`, `OnThink`, `OnShotFired`, `OnRolePlayed`, `OnRoleEvent` |
| `provider` | first non-nil wins | reserved |

Three sources per dispatch, in order: the weapon's own Define `hooks` (the
port's custom mechanics — exotic features land here as small functions instead
of forks of the base), registered integrations
(`MCVP.RegisterIntegration(id, callbacks, priority)` — for companion addons;
priority-sorted, namespaced IDs), and legacy global hooks under prefixed
names (`hook.Add("MCVP_OnShotFired", ...)`) that must not collide with real
gamemode hooks. Every callback is `xpcall`-wrapped and duplicate errors
report once — a broken addon must not spam or take the weapon down
(DHRB `report()`, integrations.lua:17-22).

The lifecycle wrappers (`sh_lifecycle.lua`) are deliberately thin and
non-forking: run layer bookkeeping, run hooks, hand the call to
`self.BaseClass`. The fire/reload/think pipelines remain MCV's own — a port
gets upstream behaviour and upstream fixes byte for byte. Order of operations
is documented per hook in the file header (notably: `Think` runs events
before the base think so an action's events fire before the idle loop can
switch animations; `Deploy` resolves roles before the base deploy so the
draw animation already goes through the bridge).

---

## 7. Foreign-model bridges

Discrete animsets (NMRiH, INS2-style: named Walk/Sprint sequences, HL2-numbered
attachments, QC-baked 5004 foley) need three more translations than
activity-mapped models do. Both modules ride seams the audit identified; both
are opt-in per port and inert without their config.

### 7.1 Discrete movement (`sh_movement.lua`, `movement = true`)

MCV's movement is pose-parameter driven — one idle sequence keeps playing
while `player_movement` blends walk/sprint layers. A model without those pose
parameters no-ops into still idle while the player runs. The bridge rides the
idle loop instead of fighting it: `Idle()` gives `IdleSequence()` precedence
(sh_anim.lua:119-129) and re-triggers whenever `GetNextIdle()` lapses
(sh_think.lua:21-23), so the bridge's `IdleSequence` override simply returns the
sequence matching the movement state — `idle` / `walk` / `sprint`, each with an
`_empty` variant when the gun is dry (falling back to the base role when the
model lacks it). The model's own `fadein 0.2` blends every swap.

`ThinkMovement` (lifecycle Think, before the base) handles state *changes*:
entering or leaving the sprint carry plays the model's transition sequence
(`sprint_in`/`sprint_out`, i.e. NMRiH's Idle_to_Sprint / Sprint_to_Idle) when
one is bound, otherwise re-arms the idle loop (`SetNextIdle(0)`) so `Idle()`
picks the new state on the same think. State changes never cut an in-flight
action animation: they only act when the current viewmodel sequence belongs
to the port's movement family; a change mid-fire or mid-reload lands when that
animation's own NextIdle lapses — exactly how the base already recovers.
Sighting defers to MCV's vector ironsights (state reads nil); the ironsequence
contract (Idle_Iron etc.) stays unbound as a future tier. Sighting while
walking, sprint-toggling, prediction and singleplayer all follow the base's
own clocks because the bridge only ever answers "what should the idle be".

### 7.2 FX and foley (`sh_fxbridge.lua`, `attachments` + `foley`)

- **Attachments**: foreign models name their ports "1" (muzzle) and "2"
  (ejection) per the HL2 convention; MCV's `DoEject`/`DoMuzzle` resolve
  "eject"/"muzzle" internally. `DoEject` takes the attachment name as a
  parameter (sh_effects.lua:92), so the bridge is a pure wrapper injecting the
  configured default. `DoMuzzle` has no such seam — a gated one-line fork of
  sh_effects.lua:47-87 (kept in step with upstream), inherited untouched by
  ports that don't set `attachments.muzzle`.
- **Engine events**: `SWEP:FireAnimationEvent` runs MCV's handler first (the
  duals' "eject2"), then returns true — blocking the engine's default — for:
  NMRiH-style discrete brass (options like `"45acp Eject 140"`, whose engine
  handler spawns an unresolvable error model in GMod), the engine muzzle
  flash (AE_MUZZLEFLASH = 21; MCV draws its own), and, in `foley =
  "synthetic"` mode, the 5004 soundscript events (the port's timed events
  own the audio instead). In the default `foley = "qc"` mode the 5004 events
  pass through and the model's own reload foley plays at the QC's exact frame
  timing whenever its soundscript names resolve.

---

## 8. The gun port base

`mcvport_gun` derives from `mcv_base` and adds exactly the five method
modules (animroles, events, fxbridge, movement, lifecycle). Everything else
— fire pipeline, ballistics, penetration, reload state machines, sights/
scopes, NPC support, prediction — is inherited.
Notable native fields the templates lean on (full catalogue:
`docs/weapon-definitions.md` §3):

- Firemodes: `MCV.FIREMODE_AUTO/SEMI/BURST/SA/DA/FAN/BOLT/PUMP/...`
  (sh_common.lua:1-12).
- Reload shaping: `MagInTime(_Empty)`, `MagOutTime(_Empty)`;
  `ShotgunReload` + `ShotgunReloadRounds` + `ReloadInsertTime` for
  shell/clip insertion; `MagInClip` for stripper clips.
- Cycle: `PlayCycleAnimation`, `CyclePostDelay`. **Foreign bolt-actions keep
  `AnimationHandlesHammer = false`** — the native true path reads
  `MCV.HammerEvents`, a generated table covering only the eight shipped
  manually-cycled MCV models (§5.6); a foreign model is not in it and the
  hammer would never drop. The timed path always works.
- Scopes: `HasScope`, `ScopeMaterial`, `ScopeFOV`/`ScopeFOV2`,
  `RTScopeMaterialIndex`, `AdjustableScopes`, `SightedViewModelFOV`.

`mcvport_report` (console) lists every registered port: base, model, declared
roles vs required, synthetic event and hook counts, plus live resolution
state for weapons currently held in the world.

---

## 9. What is deliberately NOT here

Things DHRB builds that MCV already has natively — duplicating them would be
upkeep with no payoff (the audit's central lesson):

- **Duration caching** — `MCV.CachedSequence` + `SWEP:SequenceLength`.
- **NPC support** — `mcv_base/sh_npc.lua`; a port is a real MCV weapon, NPCs
  work day one.
- **Soundscript plumbing** — flat slots already consume `sound.Add` names.
- **ADS smoothing** — the `ironsight` pose parameter on MCV-rigged models;
  foreign models degrade to discrete sequences or plain `IronsightPos`, by
  design, never by accident.
- **Dual-wield composition** — MCV's akimbo is model-based
  (`ViewModelAkimbo` + `HasAkimbo`), not class-composition like DHRB's
  `SingleClass` pair; revisit only if a port genuinely needs it.

And the known honest limit: **no layer conjures MCV model rigs.** The discrete
movement bridge (§7.1) now covers walk/sprint sequences, but the continuous
pose-parameter states — blended ironsight layers, the ammo gauge — still need
rig-side work the layer detects (`mcvport_report`) but cannot fabricate.

## 10. Future tiers (not built yet)

- **Sequence ADS** — binding the NMRiH-style iron sequences (Idle_Iron,
  Fire_Iron_*, Idle_to_Iron) alongside/instead of MCV's vector ironsights.
- **Drafting assistant** — after the first few hand-ports establish the real
  field-mapping pain, a disposable script that pre-fills a template from a
  decompiled foreign weapon lua with `-- TODO` markers. Explicitly
  garbage-in-reviewable-out; the porter reviews everything regardless.
- **Exotic bridges** — new built-in event actions or hook policies, added
  only when a real port needs one. Never speculative.
- **Melee / throwable / placeable port bases** — the same three-include
  pattern against `mcv_melee`, `mcv_throwable`, `mcv_placeable`.
