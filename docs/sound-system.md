# MCV Base — Sound System (Exhaustive Audit)

This document audits how the Military Conflict: Vietnam (MCV) base produces sound: every Lua
dispatch point, the soundscript registry and its complete entry grammar, the model-driven foley
system, prediction/realm behavior, and what a translation layer must generate.

**Scope decision (user-approved):** the three soundscript data files total ~16K lines of
`sound.Add` entries. They are **generated rip data** (see `BUGLIST.md:485` —
`parse_soundscripts.py` carries overrides, so a re-rip keeps them). This audit therefore covers
the **mechanism and the format exhaustively** — plus statistics and representative samples —
and does *not* catalogue the individual entries. Cross-references:
[animation-system.md](animation-system.md) (§5.5 model events, §8.2 gestures),
`docs/weapon-definitions.md`, `docs/effects.md`, `docs/gun-core.md`, `docs/shooting-ballistics.md`.

---

## 1. Architecture Overview

### 1.1 Three dispatch tiers

Every sound the base makes reaches the engine through one of three channels:

1. **Scripted soundscript lookups** — Lua calls `Entity:EmitSound("<scriptname>")` (or
   `sound.Play` / `CreateSound` with a script name). The name is resolved by the *engine's*
   sound-script registry, which GMod's global `sound.Add` populates. The script entry carries
   channel, volume, soundlevel and pitch — the Lua call site passes **no** level/pitch/volume of
   its own (deliberate, see `mcv/weapon_common/shared.lua:75-77`).
2. **Engine-driven model foley** — the ported viewmodel MDLs bake Source animation events whose
   options are soundscript names. The engine plays them itself when the sequence's event track
   crosses the event cycle. **No Lua is involved** — this is why ~13K foley/reload entries exist:
   they are referenced by the models, not by the Lua. Only the weapon's owner has a viewmodel,
   so this tier is inherently first-person-only (cross-ref [animation-system.md §5.5]).
3. **Raw `.wav` direct plays** — a handful of entity/effect call sites pass literal file paths
   (`"buttons/button17.wav"`, `"ambient/fire/fire_med_loop1.wav"`, chainsaw wavs) with explicit
   level/pitch/volume arguments and no script indirection.

### 1.2 Realm split at a glance

| Tier | Realm | Notes |
|---|---|---|
| Shot reports (`EmitShotSound`) | shared, predicted | `IsFirstTimePredicted()` gate; layered near+distant on rotating channels |
| Third-person foley (`EmitThirdPersonSound`) | split | server broadcasts via `RecipientFilter` minus owner; holder's echo client-side; SP via `CallOnClient` |
| Model-event foley | client (viewmodel) | engine plays it; nobody else hears it |
| Melee / iron sights / UI clicks / bayonet bash | shared, unguarded | run on both realms; same-channel restart makes the double dispatch inaudible (§8.2) |
| Entity sounds (grenades, C4, fire) | server (mostly) | plain `EmitSound` on the entity |
| Effects (shell tink, ricochet) | client | inside `EFFECT:` hooks via `sound.Play` |
| Chainsaw loops | client | `CSoundPatch` state machine driven by networked state |

### 1.3 Why this matters for the translation layer

A foreign weapon base that "animates via engine activities" almost universally drives sound from
Lua (`SWEP.Primary.Sound` tables, `EmitSound` inside `PrimaryAttack`/deploy/reload hooks, timed
`timer.Simple` "animation event" fakes). MCV instead splits sound four ways: shot layers through
`EmitShotSound`, third-person foley through three `Sound*ThirdPerson` fields, first-person foley
through the **model's own event track** (which a foreign viewmodel will not have), and everything
else through bespoke fields. A converter must generate `sound.Add` data *and* field assignments,
and must decide, per sound, which of MCV's four lanes it belongs in (§9).

---

## 2. Dispatch Points Inventory (Complete)

### 2.1 The shot pipeline — `SWEP:EmitShotSound` (mcv_base/sh_shoot.lua:540-553)

```lua
-- weapons/mcv_base/sh_shoot.lua:540-553
function SWEP:EmitShotSound(name)
    if !IsFirstTimePredicted() or (name or "") == "" then return end

    // Cosmetic only, advanced after the replay guard. Do not derive this from
    // BurstCount: release/repress resets it and would cut off two quick taps.
    local slot = self.MCVShotSoundSlot or 0
    self.MCVShotSoundSlot = (slot + 1) % MCV.SHOT_SOUND_SLOTS
    emitShotLayer(self, name, MCV.CHAN_SHOT + slot)

    local far = distantShot(name)
    if far then
        emitShotLayer(self, far, MCV.CHAN_SHOT_DISTANT + slot)
    end
end
```

Call sites: player fire (`sh_shoot.lua:466,468` — volley/double vs single) and NPC fire
(`weapons/mcv_base/sh_npc.lua:148`). The channel constants live in `mcv/shared/sh_common.lua:15-20`:

```lua
-- mcv/shared/sh_common.lua:15-20
// Bounded overlap per weapon: recordings can have 60-100 ms of mechanism before
// the report. Replacing them every shot cuts that report out on fast automatics.
// Four slots per layer preserve the attack without CHAN_STATIC's unbounded tails.
MCV.SHOT_SOUND_SLOTS = 4
MCV.CHAN_SHOT = CHAN_USER_BASE
MCV.CHAN_SHOT_DISTANT = CHAN_USER_BASE + MCV.SHOT_SOUND_SLOTS
```

`distantShot` (sh_shoot.lua:484-498) derives `<name>Distant` **by string concatenation** and
memoizes existence via `sound.GetProperties`, so the seven weapons without a distant recording
(the Uzi family, the SOG Sterling, the Vz.23 — `BUGLIST.md:486`) silently fall back to near-only
without console warnings. `emitShotLayer` (sh_shoot.lua:518-538) resolves the script with
`sound.GetProperties`, **picks a concrete sample/volume/pitch in Lua** (because
"`Entity:EmitSound` can ignore channel/volume overrides on script names"), and re-emits the raw
sample on the rotating channel. `pickShotValue` (sh_shoot.lua:506-516) selects table entries with
`util.SharedRandom` when the owner is a player (so prediction replays pick the identical sample)
and `math.Rand` otherwise.

### 2.2 Third-person broadcast — `EmitThirdPersonSound` / `PlayOwnThirdPersonSound`

```lua
-- mcv/weapon_common/shared.lua:32-78 (abridged; comments in original)
function SWEP:PlayOwnThirdPersonSound(name)
    if SERVER or !name or name == "" then return end
    if !game.SinglePlayer() and !IsFirstTimePredicted() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) or owner != LocalPlayer() then return end
    if !owner:ShouldDrawLocalPlayer() then return end
    owner:EmitSound(name)
end

function SWEP:EmitThirdPersonSound(name)
    if !name or name == "" then return end
    local owner = self:GetOwner()
    if CLIENT then
        self:PlayOwnThirdPersonSound(name)
        return
    end
    local from = IsValid(owner) and owner or self
    local filter = RecipientFilter()
    filter:AddPVS(from:GetPos())
    if IsValid(owner) and owner:IsPlayer() then
        filter:RemovePlayer(owner)
        if game.SinglePlayer() then
            self:CallOnClient("PlayOwnThirdPersonSound", name)
        end
    end
    if filter:GetCount() == 0 then return end
    from:EmitSound(name, nil, nil, nil, nil, 0, 0, filter)
end
```

Design notes (verbatim comments at shared.lua:28-31, 55-56, 75-77): the holder's own first-person
foley rides the viewmodel's events, so emitting the third-person set to them too would be "the
same sound twice" — *unless* `ShouldDrawLocalPlayer()` (third-person camera), which is exactly
what `PlayOwnThirdPersonSound` checks. The server emits **from the player, not the weapon**
("a carried weapon is not where the player is"), passes **no** level/pitch/volume/channel
("the soundscript carries all four"), and singleplayer asks the client outright via
`CallOnClient` because "singleplayer runs none of the weapon on the client".

Call sites (all predicted shared code, replay-guarded per `BUGLIST.md:310`):

| Call site | Field | Trigger |
|---|---|---|
| `weapons/mcv_base/sh_reload.lua:91` | `SoundReloadThirdPerson` | reload start (mag or shotgun-loop start) |
| `weapons/mcv_base/sh_reload.lua:223,243` | `SoundReloadLoopThirdPerson` | each per-round insert (shotgun / stripper / akimbo swap) |
| `weapons/mcv_base/sh_think.lua:120` | `SoundCycleThirdPerson` | bolt/pump cycle after each shot |
| `weapons/mcv_m79_base/shared.lua:94` | `SoundReloadThirdPerson` | M79 break-open ammo-type switch |

### 2.3 Direct `self:EmitSound` / `owner:EmitSound` call sites (weapons)

| File:line | Sound | Trigger / notes |
|---|---|---|
| `weapons/mcv_base/sh_sights.lua:133` | `MCV_Weapon_Foley_Ironsights.In/.Out` | sighted-state transition; shared, unguarded |
| `weapons/mcv_base/sh_gun.lua:122` | `MCV_Weapon_Foley_Movement.ProneCrawl` | safety / at-ease toggle (cloth rustle reused as the click) |
| `weapons/mcv_base/sh_shoot.lua:816` | `MCV_Weapon_Foley_AK47.DrawMetal` | firemode switch fallback when the model lacks a firemode animation |
| `weapons/mcv_binoculars/shared.lua:77` | `MCV_Weapon_Foley_AK47.DrawMetal` | zoom-level fallback when no firemode sequence |
| `mcv/server/sv_second_weapon.lua:11` | `MCV_Weapon_Foley_AK47.DrawMetal` | server: akimbo unlock on picking up a second copy |
| `mcv/weapon_common/sh_bash.lua:103,105` | `MCV_Weapon_AK47_Bayonet.ThrustStab/.ThrustHit` or `MCV_Weapon_Fists.PowerPunch/.PowerPunchWall` | USE+fire bash hit (flesh vs world chosen by trace) |
| `weapons/mcv_melee/sh_melee.lua:86,88` | `SoundThrustFlesh/World`, `SoundHitFlesh/World` | melee swing land |
| `weapons/mcv_melee/sh_melee.lua:120` | `SoundSwing` | melee swing start (guarded `!= ""`) |
| `weapons/mcv_melee/sh_melee.lua:344` | `physics/metal/metal_box_impact_soft{1-3}.wav` | melee parry/block (raw path, random pick) |
| `weapons/mcv_base/sh_ubgl.lua:68` | `SoundGrenadeShot` | UBGL / rifle-grenade launch |
| `weapons/mcv_flamethrower/sh_flame.lua:31,32,39` | `SoundFireStart/Loop/Stop` | flame loop start/stop; loop `StopSound` at :38,:143 |
| `weapons/mcv_underbarrel_flame/shared.lua:32` | `MCV_Weapon_LPO50.Primary_Fire_Start` | underbarrel flamethrower start |
| `weapons/mcv_placeable/sh_place.lua:279` | `buttons/button17.wav` (raw) | remote detonator press |
| `weapons/mcv_placeable/sh_place.lua:316-318` | `SoundFuseLoop` start/stop | **server-only** (`if CLIENT ... return`, :309) so one loop reaches everyone |
| `weapons/mcv_equipment_box/sh_box.lua:128,130` | HL2 stock `items/*.wav` | medkit/ammo box use, empty-box denial |

Related cleanup: `mcv/weapon_common/sh_clock.lua:73` stops `SoundFireLoop` inside
`ResetWeaponClock` (full-state reset), and `sh_place.lua:395-398` stops the fuse on re-deploy
("nothing is alight in a weapon just drawn").

### 2.4 Entity-side sounds

| File:line | Sound | Trigger |
|---|---|---|
| `entities/mcv_grenade_base.lua:97` | `ENT.ExplosionSound` (default `MCV_BaseGrenade.Explode`, :27) | grenade detonation; every `mcv_proj_*` overrides or inherits |
| `entities/mcv_proj_base.lua:123-126,166-169` | `ENT.AudioLoop` via `CreateSound`/`CSoundPatch` | in-flight loop (field declared :52; currently no shipped entity sets it — vestigial) |
| `entities/mcv_proj_base.lua:284-289` | `ENT.BounceSounds` (random pick, table-of-tables tolerated) | first bounce after 100 ms |
| `entities/mcv_proj_base.lua:192` | raw `physics/plastic/plastic_box_break{1,2}.wav` | `DefuseOnDamage` break |
| `entities/mcv_proj_flare.lua:28` + :23 | raw `ambient/fire/ignite.wav`; `BounceSounds = {"MCV_Bounce.Shell"}` | flare ignite / bounce tink |
| `entities/mcv_grenade_molotov.lua:50` | raw `physics/glass/glass_bottle_break2.wav` | molotov impact (the fancier `MCV_Inferno.*` scripts are unused by Lua) |
| `entities/mcv_grenade_smoke.lua:39-40,81,99` | `SmokeSound` / `SmokeLoop` | smoke pop + loop, stopped on expiry |
| `entities/mcv_placed_c4.lua:34,55` | `MCV_Weapon_C4_Demolition.Plant/.Defuse` | plant / pick-back-up |
| `entities/mcv_placed_dynamite.lua:28,48,53` | `MCV_Weapon_C4_Demolition.Plant`; `FuseSound` (`MCV_Weapon_C4.FuseBurningLoop`) | plant + lit fuse loop (server-stopped :53) |
| `entities/mcv_placed_mine.lua:37,47,100` | `MCV_Weapon_C4_Demolition.Plant/.Defuse` | mine arm/disarm |
| `entities/mcv_proj_bolt.lua:96,114` | `MCV_Weapon_Crossbow.BoltHitBody/.BoltHitWorld` | crossbow bolt impacts |
| `entities/mcv_proj_m202.lua:57` | `MCV_XM202MissileExplosionEffect.Sound` | missile detonation |
| `entities/mcv_firepool.lua:31,41,82` | raw `ambient/fire/fire_med_loop1.wav` (`CHAN_STATIC`) | molotov fire pool loop |
| `mcv/shared/sh_burn.lua:33,47` | raw `ambient/fire/fire_small_loop2.wav` (`CHAN_STATIC`) | burning-entity loop |
| `entities/mcv_thrown_melee.lua:18-19,41-43` | `SoundFlesh` / `SoundWorld` (thrown machete) | thrown-blade impact |
| `entities/mcv_supply_box.lua:51,55` | HL2 stock `items/*.wav` | supply box open/denied |

### 2.5 Client-only: effects and the chainsaw

- **Shell tink** — `effects/mcv_shelleffect.lua:136-147`: first `PhysicsCollide` plays
  `sound.Play(self.Sound, self:GetPos())` where `self.Sound = MCV.ShellTypes[Type].Sound`
  (:74), then `StopSound("Default.ImpactHard")`; `Think` (:151) also `StopSound("Default.ScrapeRough")`
  to keep HL2's physics sounds out. Full treatment in §6.
- **Ricochet** — `effects/mcv_impact.lua:49-82`: on an accepted ricochet (grazing-angle +
  surface-hardness probability) plays a raw wav
  `sound.Play("mcv/weapons/fx/rics/vietnam_rics_" .. surface.sound .. "_" .. math.random(4) .. ".wav", pos, 87, 100, 0.7)`
  with a **per-viewer 125 ms additive throttle** (:52-57) and the comment "These sounds do not
  use the firing weapon's channels" (:77-78).
- **Chainsaw** — `mcv/client/cl_chainsaw.lua` (99 lines): a `Think`-driven `CSoundPatch` state
  machine keyed off *networked* weapon state (`GetPrimedAttack`, `GetReady`, `GetHolsterTime`),
  never per-command replays ("Audio follows the final predicted/received state", :1-2).
  Raw wavs from `SWEP.SoundSawIdle/Cut/Start/Stop` (`weapons/mcv_chainsaw.lua:34-37`), played
  with `SetSoundLevel(75)` + `PlayEx(volume, 100)`; one patch per file per entity, transitions
  stop the previous patch, `EntityRemoved`/`PostCleanupMap`/`ShutDown` release handles.

### 2.6 Model-event sounds — what Lua never touches

Draw/holster/reload-stage/movement foley, per-weapon reload foley, `LovelyClipPing`-style
details, movement walk/sprint/prone foley, near-wall foley — none of it has a Lua call site.
The viewmodel MDLs' event tracks fire the soundscript names directly at the engine level
(cross-ref [animation-system.md §5.5]). The **only** animation-event hook in the base is:

```lua
-- weapons/mcv_base/sh_shoot.lua:201-205
function SWEP:FireAnimationEvent( pos, ang, event, name )
    if (name == "eject" or name == "eject2") and IsFirstTimePredicted() then
        self:DoEject(name)
    end
end
```

`eject`/`eject2` are the porter's custom event names (`sh_effects.lua:89-91` documents them);
sound events pass straight through to the engine. `DoEject` (sh_effects.lua:92-123) is itself an
effect dispatch (`mcv_shelleffect`), not a sound call — the tink sound lives in the effect (§6).

---

## 3. The Soundscript Format

### 3.1 Entry grammar

All three files are pure, flat `sound.Add` blocks — no locals, no loops, no includes. The
complete grammar observed across 1,732 entries:

```
sound.Add( {
        name    = "<ScriptName>",            -- required, unique registry key
        channel = CHAN_STATIC | CHAN_WEAPON | CHAN_AUTO | CHAN_ITEM | CHAN_BODY,  -- optional (engine default if omitted)
        volume  = <number 0.0-1.0>,          -- optional (default 1.0)
        level   = <int 0-150>,               -- optional; soundlevel in "dB at 1m"-style units
        pitch   = <int> | { <lo>, <hi> },    -- optional (default 100)
        sound   = "<wav path>" | { "<wav path>", ... },  -- required; list = uniform random pick
} )
```

**No other keys exist in these files.** GMod's `sound.Add` accepts no attenuation/chance/position
keys (those belong to engine `game_sounds.txt`, not the Lua binding), and the base uses none.
`MCV_ShellTime()`-style convar coupling does not appear in the scripts — everything is static.

Annotated real examples, one per idiom:

```lua
-- mcv/shared/sh_soundscript_weapons.lua:1-15  (shot report: the canonical weapon entry)
sound.Add( {
        name = "MCV_Weapon_AK47.Single",
        channel = CHAN_STATIC,
        volume = 1.0,
        level = 110,                  -- near report reach (~76 m per BUGLIST.md:493)
        pitch = {98, 101},            -- +/-1% detune
        sound = {
                "mcv/weapons/weapon_ak47/AK47_GunFire_Single_01.wav",
                -- ... 6 samples total, uniform random pick
        },
} )
```

```lua
-- mcv/shared/sh_soundscript_weapons.lua:4506-4513  (empty click: the CHAN_WEAPON family)
sound.Add( {
        name = "MCV_Weapon_Generic.ClipEmpty_01",
        channel = CHAN_WEAPON,
        volume = 1.0,
        level = 65,
        pitch = 100,
        sound = "mcv/weapons/weapon_common/Common_Weapon_EmptyClick_01.wav",
} )
```

```lua
-- mcv/shared/sh_soundscript_foley.lua:4904-4915  (reload foley: multi-sample + scalar pitch)
sound.Add( {
        name = "MCV_Weapon_Foley_M37_Reload.MetalStart",
        channel = CHAN_STATIC,
        volume = 0.95,
        level = 60,                   -- first-person foley reach
        pitch = 95,
        sound = {
                "mcv/foley/weapon_specific/vietnam_weapon_m37_foley_reload_pump_in_01.wav",
                -- ... 3 samples
        },
} )
```

```lua
-- mcv/shared/sh_soundscript_foley.lua:9569-9575  (third-person reload: level 80)
sound.Add( {
        name = "MCV_Weapon_Foley_ThirdPerson_M38.Reload",
        channel = CHAN_STATIC,
        volume = 0.8,
        level = 80,
        sound = "mcv/foley/weapon_specific_tp/vietnam_weapon_m38_foley_tp_reload.wav",
} )
```

```lua
-- mcv/shared/sh_soundscript_weapons.lua:3751-3760  (melee family: CHAN_AUTO + level 0)
sound.Add( {
        name = "MCV_Weapon_M7_Bayonet.Deploy",
        channel = CHAN_AUTO,
        volume = 0.6,
        level = 0,                    -- SNDLVL_NONE: unattenuated / non-positional
        sound = {
                "mcv/foley/weapon_specific/vietnam_weapon_knife_foley_draw_1.wav",
                "mcv/foley/weapon_specific/vietnam_weapon_knife_foley_draw_2.wav",
        },
} )
```

```lua
-- mcv/shared/sh_soundscript_weapons.lua:1802-1808  (loop on CHAN_BODY + duplicate-weighted list)
sound.Add( {
        name = "MCV_Inferno.Loop",
        channel = CHAN_BODY,
        volume = 0.5,
        level = 110,
        sound = "mcv/weapons/weapon_molotov/MOLOTOV_Fire_Loop.wav",
} )
```

Note `MCV_Inferno.Start` (mcv/shared/sh_soundscript_weapons.lua:1767-1778) lists the *same* wav three times —
duplication is the only weighting mechanism available.

### 3.2 Key-by-key semantics

- **`name`** — the registry key. Referenced (a) by Lua `EmitSound(name)`, (b) by model
  animation-event options, (c) by `distantShot`'s `name .. "Distant"` convention
  (sh_shoot.lua:490).
- **`channel`** — observed values and their jobs:

  | Channel | Count (weapons file / foley file) | Used for |
  |---|---|---|
  | `CHAN_STATIC` | 339 / **all 1,315** | everything ambient/positional; loops, foley, explosions, shot reports |
  | `CHAN_WEAPON` | 15 / 0 | empty clicks, `MCV_Inferno.Start`, `MCV_Weapon_Turrets_M134.SingleLoop` |
  | `CHAN_AUTO` | 50 / 0 | the melee/bayonet sets (M7/AK47/Type30/M1905 bayonets, M1942, Shovel, Katana) |
  | `CHAN_ITEM` | 7 / 0 | `MCV_Molotov.Throw` (mcv/shared/sh_soundscript_weapons.lua:1838-1845), the 5 `NearlyEmptyClick_*` + base variant |
  | `CHAN_BODY` | 1 / 0 | `MCV_Inferno.Loop` |

  (The remaining 3 weapons-file entries — the crossbow `BoltHitWorld/BoltHitBody/BoltSkewer`
  set — omit `channel` and take the engine default.)

  The base's *own* shot dispatch **overrides** the script channel: `emitShotLayer` re-emits the
  resolved raw sample on `MCV.CHAN_SHOT + slot` (sh_shoot.lua:537). `BUGLIST.md:197` records the
  history — "Existing scripts already requested CHAN_STATIC despite the caller passing
  CHAN_WEAPON, so channel ambiguity is corrected".
- **`volume`** — 0.1 (`MCV_Inferno.FadeOut`) to 1.0; foley typically 0.3-0.8.
- **`level`** — the reach dial, and the most-edited field (see §3.4).
- **`pitch`** — scalar (`95`, `97`, `100`) or `{lo, hi}`. `{98, 101}` appears 248× in the
  weapons file (every standard report); `{95, 105}`, `{80, 130}`, `{100, 110}`, `{105, 120}` also
  occur. The foley file uses pitch on only 36 entries.
- **`sound`** — single path or list. Multi-sample lists: 91 entries in the foley file; nearly all
  weapons-file report entries are lists (3-8 samples). **List picks are uniform random**; when a
  player fires, `emitShotLayer` performs the pick itself with `util.SharedRandom` so the client
  and server agree across prediction (sh_shoot.lua:529-536).

### 3.3 Soundlevel usage map

| level | Meaning in this base | Where |
|---|---|---|
| `0` | SNDLVL_NONE — unattenuated, effectively non-positional | all melee/bayonet sets (65 uses), `MCV_Airstrike.IncomingCannon`, `MCV_Weapon_Turrets_Generic.ExplosionDistant` |
| `60` | first-person foley reach | 1,151 of 1,315 foley entries |
| `65` | empty clicks | `MCV_Weapon_Generic.ClipEmpty_*`, `MCV_Default.ClipEmpty_*` |
| `80` | third-person foley | `MCV_Weapon_Foley_ThirdPerson_*` |
| `85-95` | mid-range effects | inferno start, molotov, some loops |
| `110` | **near shot report** (161 uses, weapons file) | `*.Single` |
| `130-150` | distant layer & explosions | `*.SingleDistant` = `149` (148 uses) |

Two BUGLIST items govern these numbers and should be treated as spec:

- `BUGLIST.md:485` — the game's own levels carried only "a few metres" in GMod, so the rip
  overrides them: near report raised, distant raised, third-person foley kept at 60.
- `BUGLIST.md:493` — **the soundlevel ceiling**: 286 computed to ~300 m but went silent
  entirely; 149 is the highest known to work (~126 m) and is what the distant layer carries;
  the near report is 110 (~76 m). "Do not read a bigger number off the formula and trust it."
  (Note the code comment at `sh_shoot.lua:502-503` still says "the near one at 100 ... far one
  at 125" — stale relative to the shipped 110/149 data.)

### 3.4 Wave-path character prefixes

Some `sound` paths carry a Source wave-char prefix:

- `")mcv/weapons/..."` — on the LPO50/M9A1 flamethrower loop triads, molotov break/sweetener,
  smoke-grenade start/loop, crossbow hits, RGD5 fuse pop, all explosion sets, turret sounds.
- `"^mcv/weapons/..."` — only `MCV_WaterExplosionEffect.Sound` (mcv/shared/sh_soundscript_weapons.lua:4500-4503).

These are Source-engine `soundchars` (per the engine's `soundchars.h`: `)` = CHAR_DRYMIX,
`^` = CHAR_SURROUND) — **exact audible semantics unverified**; what matters mechanically is that
a converter copying paths must preserve the prefix byte-for-byte, and that they were ripped from
the game's own scripts, not authored.

### 3.5 Naming conventions

The name grammar encodes the consumer, which is how the base finds things:

- `MCV_Weapon_<Family>.Single` / `.SingleDistant` — shot report pair (player + NPC fire).
- `MCV_Weapon_<Family>.RifleGrenade` / `.RifleGrenadeDistant` — UBGL shot (8 guns:
  KAR98K, KBKG60, M1C, M1G, M14, M38, M1903, SKS).
- `MCV_Weapon_<Family>.Double` — volley second-barrel report (e.g. `MCV_Weapon_IZH43.Double`,
  mcv/shared/sh_soundscript_weapons.lua:197).
- `MCV_Weapon_<Melee>.<Move>` — Lua-dispatched melee sets: `Deploy/Slash/Hit/Stab/ThrustStab/
  ThrustHit` (bayonets, M1942), plus `Charge/Swipe/SwipeCharge/HitWall/HitFlesh/HitChargeWall/
  HitChargeFlesh` (Shovel), `Swing/Thrust/ThrustHit/ThrustHitFlesh` (Katana),
  `Punch/PunchWall/PowerPunch/PowerPunchWall` (Fists — these live in the **foley file**,
  foley.lua:9365-9418, at `level = 60`, unlike the other melee sets in the weapons file).
- `MCV_Weapon_Foley_<Weapon>.<Action>` — model-event foley: `Draw`, `DrawMetal`,
  `DrawMetalStart/End`, `Holster`, `LovelyClipPing`.
- `MCV_Weapon_Foley_<Weapon>_Reload.<Stage>` — reload-stage foley: `Hand`, `HandStart`,
  `HandMid`, `HandEnd`, `Metal`, `MetalStart`, `MetalMid`, `MetalEnd`, `MagIn`, `MagOut`,
  `Bullet`, `Bullets`, `BulletsSingular`, `Ding`, `Pump`, `Unlock`... 768 entries follow this
  shape.
- `MCV_Weapon_Foley_ThirdPerson_<Weapon>.Reload|.ReloadLoop|.Cycle` — the Lua-dispatched
  third-person set (159 entries).
- `MCV_Weapon_Foley_Movement.*`, `_Ironsights.In/Out`, `_Nearwall.In/Out`, `_Pickup.In/Out`,
  `_CommonSmall.In/Out`, `_Bayonet.KnifeMovement_Off`, `_RifleGrenade.Attach/Insert/Raise` —
  shared families (§5.3).
- `MCV_Weapon_Generic.*` — empty clicks (9 `ClipEmpty_NN` + 5 `NearlyEmptyClick_*` variants),
  `RocketLoop`, artillery/napalm strikes. `MCV_Default.ClipEmpty_Rifle/Pistol` alias stock clicks.
- `MCV_BaseGrenade.Explode(Distant)`, `MCV_<X>ExplosionEffect.Sound(Distant)` (Base, Water, XM202,
  Kolos, M34) — detonations.
- `MCV_Bounce.Shell` / `MCV_Bounce.ShotgunShell` — shell tink (§6).
- `MCV_Inferno.*`, `MCV_Airstrike.*`, `MCV_Weapon_Turrets_*`, `MCV_Weapon_C4.TickingLoop` —
  ripped-but-unused by the shipped Lua (§5.5).
- `Weapon_SKS.RifleGrenade` — the base default for `SoundGrenadeShot`
  (`mcv_base/shared.lua:198`) is an **HL2/stock script name**, used only when the weapon file
  doesn't override; `BUGLIST.md:377` documents the rifle-grenade fallback logic in the generator.

---

## 4. Loader & Lookup

### 4.1 File loading (realm)

```lua
-- autorun/sh_mcv_load.lua:12-23 (abridged)
local function loadshared(v)
    include(searchdir .. "shared/" .. v)
    AddCSLuaFile(searchdir .. "shared/" .. v)
end
...
for _, v in pairs(file.Find(searchdir .. "shared/*", "LUA")) do
    if v != first then
        loadshared(v)
    end
end
```

The autorun file is shared, so `sh_soundscript_foley.lua`, `sh_soundscript_tink.lua` and
`sh_soundscript_weapons.lua` all execute **on both realms**, in `file.Find` name order
(convars first, otherwise unordered load is fine here since these files depend on nothing).
Both realms need the registry: the server resolves script names when entities emit them
(grenades, third-person foley), and the client resolves them for prediction-echoed emissions
and the viewmodel's model-event foley.

### 4.2 The registry and `sound.GetProperties`

There is **no Lua-side table of entries and no lookup cache of MCV's own** — `sound.Add`
writes straight into the engine's sound-script system. The only readers:

- `sound.GetProperties(name)` — `sh_shoot.lua:493` (distant-exists probe) and `sh_shoot.lua:519`
  (resolve sample/volume/pitch/level before re-emitting on a custom channel).
- The engine's own `EmitSound`-by-name resolution (used everywhere else).

### 4.3 The two in-code caches

1. `distant_of` (sh_shoot.lua:484) — memoizes near-name → distant-name-or-`false`, "worked out
   once per sound name rather than written into every weapon file".
2. `self.MCVShotSoundSlot` (sh_shoot.lua:545-546) — per-weapon-instance rotating channel index
   over `MCV.SHOT_SOUND_SLOTS` (4), deliberately *not* derived from `BurstCount` (comment:
   release/repress would reset it and cut off two quick taps).

---

## 5. The Foley System

### 5.1 First person: model-driven, owner-only

The ported viewmodels carry the game's foley in their MDL event tracks; the engine fires the
soundscript names as the sequence plays ([animation-system.md §5.5]). Consequences:

- Draw, holster, every reload stage, bolt/pump detail, and per-weapon flourishes are **zero-Lua
  sounds** — they arrive with the `ViewModel` asset, not with the weapon script.
- They are audible **only to the owner** (viewmodels are client-only), which is the entire
  reason the third-person set exists (`BUGLIST.md:441`).
- A weapon with a *different* viewmodel (e.g. an M21 sharing the M1G's model) automatically
  gets that model's foley — the "foley model per weapon" is the ViewModel itself; there is no
  `SWEP.FoleyModel`-style indirection. (Cross-ref `docs/weapon-definitions.md` for
  `ViewModel`/`ViewModelAkimbo`/`SingleViewModel` fields; `sh_shoot.lua:3-5` shows
  `animationModel()` selecting among them.)

### 5.2 `eject` / `eject2` — the only Lua interception

`SWEP:FireAnimationEvent` (sh_shoot.lua:201-205, quoted in §2.6) catches the porter's custom
`eject`/`eject2` events and routes them to `DoEject` (an *effect* dispatch — the shell and its
tink, §6), guarded by `IsFirstTimePredicted()`. All *sound* events fall through to the engine.
`DoEject` (sh_effects.lua:92-123) picks the port by parity (odd clip count → left gun /
`eject2`, both on a volley) — see [animation-system.md §5.4] for the attachment inventory.

### 5.3 Shared foley families (model-referenced, cross-weapon)

Defined in the foley file, referenced by event tracks on **many** models:

- `MCV_Weapon_Foley_Movement.WalkLight/SprintLight/WalkMedium/SprintMedium`
  (foley.lua:8748-8809) — 7 samples each from the shared `mcv/foley/vietnam_weapon_foley_light/
  medium_N.wav` pool; the walk/sprint distinction is which slice of the numbered pool is listed.
- `MCV_Weapon_Foley_Movement.ProneCrawl` + `ProneCrawl_GunLight/GunMedium/GunHeavy`
  (foley.lua:8812-8870) — also Lua-reused as the at-ease toggle click (`sh_gun.lua:122`).
- `MCV_Weapon_Foley_Ironsights.In/Out` (foley.lua:8952-8977) — model events **and** the Lua
  dispatch at `sh_sights.lua:133` ([animation-system.md §4.3] notes both).
- `MCV_Weapon_Foley_Nearwall.In/Out` (foley.lua:8980-9005) — no Lua dispatch; rides the
  nearwall locomotion layers the game viewmodels carry ([animation-system.md §4.2] pose map).
- `MCV_Weapon_Foley_Pickup.In/Out`, `_CommonSmall.In/Out` (foley.lua:9008-9057) — pickup and
  small-weapon foley (model-driven).
- `MCV_Weapon_Foley_RifleGrenade.Attach/Insert/Raise` (foley.lua:9060-9077) — UBGL mount foley.
- `MCV_Weapon_Foley_Bayonet.KnifeMovement_Off` (foley.lua:8940-8949) — bayonet fold.

### 5.4 The third-person set

159 `MCV_Weapon_Foley_ThirdPerson_*` entries: 118 `.Reload`, 9 `.ReloadLoop`, 16 `.Cycle` (+
misc). All `level = 80`, all pointing at the separate `mcv/foley/weapon_specific_tp/` rip
(141 paths; some entries alias other sets). They are dispatched **only** through the
`EmitThirdPersonSound` fields (§2.2) — 234 assignments across 200 weapons per `BUGLIST.md:441`,
with only the R76 having none ("the game not giving it one"). The unused weapon field default
is `""` and `EmitThirdPersonSound` early-outs on empty names.

### 5.5 Ripped-but-unused entries (data archaeology)

These exist in the files with **no Lua consumer at the audited commit**:

- `MCV_Inferno.*` (mcv/shared/sh_soundscript_weapons.lua:1767-1828) and `MCV_Molotov.Loop/Throw/IdleLoop`
  (mcv/shared/sh_soundscript_weapons.lua:1830-1853) — the game's molotov fire system; the GMod port uses
  raw `ambient/fire` loops and a raw glass break instead.
- `MCV_Airstrike.IncomingCannon/IncomingIntro/Incoming` (mcv/shared/sh_soundscript_weapons.lua:4638-4666) and the artillery/
  napalm/phosphorus/mortar strike sets (mcv/shared/sh_soundscript_weapons.lua:4681-4850) — the binoculars' strikes are not
  implemented; the sounds shipped anyway.
- `MCV_Weapon_Turrets_*` (mcv/shared/sh_soundscript_weapons.lua:5121-5234) and `MCV_Weapon_Foley_Turrets_*`
  (foley.lua:10896-10997) — mounted turrets (DSHK, SPG9, M2Browning, M134) are data-only.
- `MCV_Weapon_C4.TickingLoop` (mcv/shared/sh_soundscript_weapons.lua:4622) — the placed C4 is remote-detonated and never
  ticks; `FuseBurningLoop` *is* used (dynamite).
- `ENT.AudioLoop` (proj_base.lua:52) — declared, played at :123-126 if set, but no shipped
  entity sets it (`MCV_Weapon_Generic.RocketLoop` / `MCV_Missile.Accelerate` wait unused).

A converter porting a weapon whose sounds exist in this rip should check these families first —
they are free, already-corrected assets.

---

## 6. Tink — Shell Bounce Sounds

`mcv/shared/sh_soundscript_tink.lua` (29 lines, read in full) defines exactly two entries:

```lua
-- mcv/shared/sh_soundscript_tink.lua:1-29 (complete file, abridged to one entry)
sound.Add( {
        name = "MCV_Bounce.ShotgunShell",
        volume = 0.65,
        level = 75,
        pitch = 100,
        sound = {
                "mcv/weapons/fx/tink/vietnam_tink_shotgun_shell1.wav",
                -- ... 3 samples
        },
} )
sound.Add( {
        name = "MCV_Bounce.Shell",     -- 8 rifle/pistol shell samples, same volume/level/pitch
        ...
} )
```

(No `channel` key — default `CHAN_AUTO`.)

The selection chain:

1. `SWEP.EjectBrassType` (`mcv_base/shared.lua:214`, default 5) indexes
   `MCV.ShellTypes` (`mcv/shared/sh_common.lua:82-175`) — 23 rows, each `{Model = "<shell mdl>",
   Sound = "MCV_Bounce.Shell" | "MCV_Bounce.ShotgunShell"}`. Only index 2 (12 gauge) uses the
   shotgun variant; every other row, from 7.62×39 to .50 BMG to flare and chain links, aliases
   `MCV_Bounce.Shell`.
2. `DoEject` (sh_effects.lua:92-123) dispatches the `mcv_shelleffect` effect with
   `SetFlags(EjectBrassType)`; prediction is guarded (`IsFirstTimePredicted`, :93) and the
   effect goes through `dispatchWeaponEffect` (sh_effects.lua:7-18), which on the server targets
   a PVS `RecipientFilter` minus the firing player (predicted locally by that client).
3. `effects/mcv_shelleffect.lua` reads `MCV.ShellTypes[self.Type]` (:21), sets
   `self.Sound = typetbl.Sound` (:74), simulates the brass (`gmod_silent` physics material so
   the engine makes no noise of its own), and on **first** `PhysicsCollide` plays
   `sound.Play(self.Sound, self:GetPos())` (:141) — one tink per case, however it bounces.
   `StopSound("Default.ImpactHard")` (:142) and `StopSound("Default.ScrapeRough")` (:151) keep
   stock HL2 physics sounds suppressed; the fade-out lifetime is the `mcv_shell_time` convar
   (`cl_effectsettings.lua:11`).

Cross-ref: [animation-system.md §5.4] for the `eject`/`eject2` attachments feeding this, and
`docs/effects.md` for the shell/trail particles.

---

## 7. Statistics

Grep-counted at the audited commit (structural patterns, not hand counts):

| File | Lines | `sound.Add` entries | Notes |
|---|---|---|---|
| `mcv/shared/sh_soundscript_weapons.lua` | 5,236 | **415** | reports, melee sets, generics, explosions, unused rip families |
| `mcv/shared/sh_soundscript_foley.lua` | 10,999 | **1,315** | FP foley, TP foley, shared families, C4/dynamite, Fists melee set |
| `mcv/shared/sh_soundscript_tink.lua` | 29 | **2** | shell bounce |
| **Total** | **16,264** | **1,732** | |

Weapons-file breakdown:

- 131 `*.Single` entries; 154 `*Distant` entries (131 report pairs + 8 `RifleGrenade` +
  explosion/misc `Distant` variants).
- `level = 110` ×161, `level = 149` ×148, `level = 0` ×65; `pitch = {98, 101}` ×248.
- Melee families present: M7_Bayonet, AK47_Bayonet, Type30_Bayonet, M1905_Bayonet, M1942,
  Shovel, Katana (Fists lives in the foley file).

Foley-file breakdown:

- 1,048 entries point at `mcv/foley/weapon_specific/` (first-person), 141 at
  `mcv/foley/weapon_specific_tp/` (third-person); the remaining ~126 use the shared
  `mcv/foley/` pool, HL2 `physics/` or `mcv/weapons/` paths.
- 768 entries are `*_Reload.<Stage>` names; 91 use multi-sample lists; 36 carry `pitch`;
  `level = 60` ×1,151 (the rest are the level-80 TP set and a few level-90 plant sounds).
- 159 `MCV_Weapon_Foley_ThirdPerson_*` names: 118 `.Reload`, 16 `.Cycle`, 9 `.ReloadLoop`,
  remainder misc.

Per-weapon sound field census (from `BUGLIST.md` + spot checks): 199 weapons; 192 have a
distant report (`BUGLIST.md:486`); 200 weapons carry 234 third-person reload assignments with
only the R76 absent (`BUGLIST.md:441`).

---

## 8. Prediction & Networking Notes

### 8.1 Guarded paths (the careful ones)

- `EmitShotSound` — `IsFirstTimePredicted()` first line (sh_shoot.lua:541). Sample/volume/pitch
  selection is `util.SharedRandom` keyed on `"MCVShotSound:" .. name .. ":" .. key` when the
  owner is a player (sh_shoot.lua:506-516), so a re-simulated command re-picks the *same*
  sample — and because the sample is emitted on a rotating channel, the replay restarts rather
  than stacks.
- `PlayOwnThirdPersonSound` — client-only + `IsFirstTimePredicted` in MP
  (weapon_common/shared.lua:33-34).
- `EmitThirdPersonSound` — MP: the holder's own client decides (viewmodel-on-screen check);
  SP: `CallOnClient`; server: PVS filter minus owner (§2.2). The reload-side effects "run only
  on the first prediction pass" (`BUGLIST.md:310`).
- `DoEject` / `DoMuzzle` — `IsFirstTimePredicted` (sh_effects.lua:48,93); the *sound* then
  happens client-side inside the effect.
- Chainsaw — explicitly "follows the final predicted/received state, never each command replay"
  (cl_chainsaw.lua:1-2).
- Ricochet — per-viewer 125 ms additive throttle on `UnPredictedCurTime`
  (mcv_impact.lua:52-57).

### 8.2 Unguarded shared `EmitSound` — why it still works

Ironsights in/out, ProneCrawl, DrawMetal clicks, bash hits, melee swing/hit, UBGL shot,
flamethrower start/stop, M79 switch: these run in shared code with **no** realm or replay
guard. In multiplayer the predicting client and the server both execute them; the local player
receives the client-local sound *and* the networked server sound. Because both are the same
script on the same entity and channel within the same tick, the second play restarts the first
(Source channel behavior) rather than doubling audibly; other players hear only the server
copy. This is engine-level behavior relied upon implicitly — **(verification note: not
asserted anywhere in the repo's own docs; inferred from standard Source channel semantics)**.
The harness probes this overlap: `mcv_harness/reload_trace.lua:36-42` logs every
`EntityEmitSound` containing "reload" with its `IsFirstTimePredicted`/`GetPredictionPlayer`
state to catch exactly such double dispatch.

### 8.3 Sound choking / limits

- The shot layer's four-slot channel pool exists specifically to bound overlap: "recordings
  can have 60-100 ms of mechanism before the report. Replacing them every shot cuts that
  report out on fast automatics. Four slots per layer preserve the attack without
  CHAN_STATIC's unbounded tails" (sh_common.lua:15-17).
- `emitShotLayer`'s sample resolution is also an anti-choking measure: emitting the *script
  name* would let `Entity:EmitSound` ignore the channel override and pile every report on the
  script's own channel (sh_shoot.lua:525-528); resolving to a raw sample makes "each layer's
  replacement channel explicit".
- `BUGLIST.md:197` (open item): automatic-fire audio cutoffs — the channel fix landed
  ("dispatch skips prediction replays") but "audible cutoffs/mixer saturation still need
  in-game diagnosis".
- The soundlevel ceiling (§3.3, `BUGLIST.md:493`) is the other hard limit: values above 149
  can go silent outright in GMod.

### 8.4 What is *not* networked

No sound name, sample index or slot ever crosses the network as data. The only networked
sound-adjacent state is the weapon state the chainsaw reads (`GetPrimedAttack` etc.) and the
effect dispatches whose `EffectData` carries the brass type (`SetFlags`) and attachment id.
Sound identity is reconstructable on both realms because (a) script registries are identical,
(b) sample picks are `util.SharedRandom`-seeded from the sound name.

---

## 9. Translation-Layer Surface (Ranked)

How foreign-base sound calls map onto MCV, and what a converter must generate.

1. **Primary fire sound** (foreign `SWEP.Primary.Sound` / `EmitSound` in fire hooks — the single
   most common pattern). Map to `SWEP.SoundSingleShot` (and `SoundDoubleShot` for the second
   barrel/volley). The converter must generate a `sound.Add` entry
   `MCV_Weapon_<Class>.Single` with `channel = CHAN_STATIC, level = 110, pitch = {98, 101}` —
   **and, if a distant variant exists, the `SingleDistant` entry at `level = 149`** — then let
   `EmitShotSound` do the dispatch. Do *not* port the foreign `EmitSound(sound, level, pitch,
   volume, channel)` arguments into the call; fold them into the script entry (that is the
   MCV contract, `shared.lua:75-77`). Foreign pitch/volume *ranges* translate directly to the
   `pitch`/`volume` table forms — but note only `pitch` accepts `{lo, hi}` and only `sound`
   accepts a list; volume ranges must be dropped or baked (the base itself only ever varies
   pitch and sample).
2. **Sound tables with per-sample lists** — direct fit: list of wavs → `sound = { ... }`.
   Remember the pick is uniform random and, for players, done in Lua with `SharedRandom`
   (identical on both realms) — no extra work needed.
3. **Animation-timed sounds** (foreign bases fake events with `timer.Simple` off
   `SequenceDuration`, or call `EmitSound` from their own `FireAnimationEvent`). MCV models
   own this lane. A foreign viewmodel has no foley events, so the converter must either
   (a) schedule the sounds itself off the sequence timings MCV already computes
   ([animation-system.md §2-3] — `PlayAnimation` returns the duration, and `MCV.HammerEvents`/
   event-cycle extraction shows the pattern), or (b) leave them silent. Any sound it schedules
   must additionally decide the audience: owner-only (`self:EmitSound`), room
   (`EmitThirdPersonSound`), or both.
4. **Third-person equivalents** — MCV plays the room's copy of reload/cycle from the
   `Sound*ThirdPerson` fields (§2.2). A converted weapon with reload sounds should generate
   `MCV_Weapon_Foley_ThirdPerson_<Class>.Reload/.ReloadLoop/.Cycle` entries at `level = 80`
   and fill the three fields, or the reload is silent to everyone but the holder
   (`BUGLIST.md:441` is the cautionary tale).
5. **Empty-trigger click** — foreign bases almost always have one; MCV's `PrimaryAttack`
   auto-reloads on empty (`sh_shoot.lua:43-47`) and **never plays** `SoundEmpty`/
   `SoundNearlyEmpty` — both are data-only fields (the only reference is commented out,
   `sh_shoot.lua:473-475`, "disabled by the user's edit" per `BUGLIST.md:197`). The converter
   must either add its own click dispatch in `PrimaryAttack`'s empty branch (respecting the
   auto-reload behavior) or accept MCV's silence. `MCV_Weapon_Generic.ClipEmpty_01-09` /
   `NearlyEmptyClick_*` are ready-made targets.
6. **Loop sounds** (spin-up/down, sustained fire) — two sanctioned patterns: the flamethrower's
   `SoundFireStart/Loop/Stop` triad with `EmitSound`/`StopSound` (`sh_flame.lua:31-39`, stopped
   on clock reset at `sh_clock.lua:73`), or the chainsaw's client `CSoundPatch` machine
   (`cl_chainsaw.lua`). The `)`-prefixed loop wavs show the convention.
7. **Prediction hygiene** — foreign shared-realm `EmitSound` calls inside predicted hooks must
   be routed through `EmitShotSound` (or given `IsFirstTimePredicted` guards) or they will
   fire per replay command; conversely, sounds that *must* vary per shot need the
   `util.SharedRandom` trick to avoid desynced sample picks between the replay and the server.
8. **Channel discipline** — MCV's own rule: scripts carry `CHAN_STATIC` and the shot path
   overrides with `CHAN_USER_BASE + slot`. A converter emitting its own layered sounds should
   allocate from `CHAN_USER_BASE + 8` upward to avoid colliding with the shot pools, and should
   resolve via `sound.GetProperties` + raw-sample re-emit if it needs channel control
   (`emitShotLayer` is the template).
9. **Shell eject** — foreign `EjectShell`/brass-sound fields map to `SWEP.EjectBrassType`
   selecting one of the 23 `MCV.ShellTypes` rows (sh_common.lua:82-175); the tink follows
   automatically. Custom calibers get a new row + optionally a new tink script; `EjectBrassType
   = 0` disables. The eject *timing* must come from the model's `eject` event or the shot
   itself (`NoEjectOnShoot`, `sh_shoot.lua:449-451`).
10. **Melee weapons** — `SoundSwing`, `SoundHitFlesh`, `SoundHitWorld`, `SoundThrustFlesh`,
    `SoundThrustWorld` (melee base defaults `mcv_melee/shared.lua:43-47`) and the bash
    hardcodes in `sh_bash.lua:103-105` cover the whole melee surface; a converted melee SWEP
    only fills the five fields.
11. **Free assets** — before generating new entries, check the unused rip families (§5.5) and
    the generic namespaces (`MCV_Weapon_Generic.*`, `MCV_Default.*`, `MCV_BaseGrenade.*`) —
    the game's own corrected recordings are already registered.
12. **No precache work** — the base calls `util.PrecacheSound` nowhere (verified by grep);
    `sound.Add` registration plus first `EmitSound` is the whole story. Nothing to translate.

---

## 10. File Map

| Path (relative to `reference/mcv/lua/`) | Role |
|---|---|
| `mcv/shared/sh_soundscript_weapons.lua` | 415 entries: shot reports + distant pairs, melee sets, empty clicks, explosions, unused rip families |
| `mcv/shared/sh_soundscript_foley.lua` | 1,315 entries: FP/TP/reload foley, shared families, C4/dynamite, Fists |
| `mcv/shared/sh_soundscript_tink.lua` | 2 entries: shell bounce sounds |
| `mcv/shared/sh_common.lua` | `MCV.SHOT_SOUND_SLOTS`/`CHAN_SHOT`/`CHAN_SHOT_DISTANT` (:15-20), `MCV.ShellTypes` (:82-175) |
| `autorun/sh_mcv_load.lua` | loads all `mcv/shared/*` on both realms (:12-23) |
| `weapons/mcv_base/sh_shoot.lua` | `EmitShotSound`/`emitShotLayer`/`pickShotValue`/`distantShot` (:480-553), `FireAnimationEvent` eject interception (:201-205), firemode fallback click (:816) |
| `mcv/weapon_common/shared.lua` | `PlayOwnThirdPersonSound`/`EmitThirdPersonSound` (:32-78) |
| `weapons/mcv_base/sh_effects.lua` | `dispatchWeaponEffect` (:7-18), `DoMuzzle` (:47-87), `DoEject` (:92-123) |
| `weapons/mcv_base/shared.lua` | the `Sound*` SWEP field defaults (:186-200) |
| `weapons/mcv_base/sh_reload.lua` | reload/loop third-person dispatch (:91, :223, :243) |
| `weapons/mcv_base/sh_think.lua` | cycle third-person dispatch (:120) |
| `weapons/mcv_base/sh_sights.lua` | ironsights in/out (:133) |
| `weapons/mcv_base/sh_gun.lua` | at-ease toggle click (:122) |
| `weapons/mcv_base/sh_npc.lua` | NPC `EmitShotSound` (:148) |
| `weapons/mcv_base/sh_ubgl.lua` | `SoundGrenadeShot` (:68) |
| `weapons/mcv_m79_base/shared.lua` | ammo-switch reload sound (:94) |
| `weapons/mcv_melee/sh_melee.lua` | melee hit/swing dispatch (:86-88, :120, :344) |
| `mcv/weapon_common/sh_bash.lua` | bash/bayonet punch sounds (:103-105) |
| `weapons/mcv_flamethrower/sh_flame.lua`, `weapons/mcv_underbarrel_flame/shared.lua`, `weapons/mcv_chainsaw.lua` | loop-sound weapons |
| `weapons/mcv_placeable/sh_place.lua` | detonator click + fuse loop (server-only) (:279, :306-320) |
| `effects/mcv_shelleffect.lua` | shell case + tink (:74, :136-152) |
| `effects/mcv_impact.lua` | ricochet wav + throttle (:49-82) |
| `mcv/client/cl_chainsaw.lua` | client `CSoundPatch` state machine |
| `entities/mcv_proj_base.lua` | `AudioLoop`/`BounceSounds` machinery (:52, :123-126, :284-289) |
| `entities/mcv_grenade_base.lua` | `ExplosionSound` (:27, :97) |
| `entities/mcv_placed_c4.lua`, `mcv_placed_dynamite.lua`, `mcv_placed_mine.lua`, `mcv_grenade_smoke.lua`, `mcv_firepool.lua`, `mcv_thrown_melee.lua`, `mcv_proj_bolt.lua`, `mcv_proj_flare.lua`, `mcv_proj_m202.lua`, `mcv_grenade_molotov.lua` | entity-side sound call sites (§2.4) |
| `mcv/shared/sh_burn.lua` | burning-entity fire loop (:33, :47) |
| `mcv/server/sv_second_weapon.lua` | akimbo-unlock click (:11) |
| `mcv_harness/reload_trace.lua` | `EntityEmitSound` probe for reload sound prediction (:36-52) |
| `reference/mcv/BUGLIST.md` | sound items: :197 (audio cutoffs, open), :213 (cycle timings), :233 (mag-in retiming), :353 (dynamite fuse), :377 (rifle-grenade fallback), :441 (TP reload set), :476 (in-hand fuse), :485-490, :493 (levels, distant layer, audience fix) |
