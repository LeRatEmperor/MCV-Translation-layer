# MCV Base — Support Systems & Dev Harness (Exhaustive Audit)

This audit covers every MCV base subsystem that is *not* the weapon pipeline itself: NPC integration (weapon selection + the server-only AI firing path), the burning system, the shared constant/utility file, safe movement, model-lookup caching and clientside-model GC, the random-weapon selector system, and — by far the largest part — the developer harness (`autorun/sh_mcv_harness.lua` plus all 27 files of `lua/mcv_harness/`), the file-queue-driven test rig upstream drives from Python tooling (`work/harness.py`). It is written as engineering reference for the translation layer whose goal is making SWEPs written for other weapon bases run perfectly on MCV; sibling audits: `docs/animation-system.md` (§6 model cache, §7.1 deploy), `docs/gun-core.md`, `docs/shooting-ballistics.md`, `docs/reload-ammo.md`, `docs/weapon-definitions.md`, `docs/special-weapon-bases.md`, `docs/projectiles-entities.md` (firepool), `docs/sound-system.md`, `docs/effects.md`. Upstream's own notes (`reference/mcv/AGENTS.md`, `CLAUDE.md`, `BUGLIST.md`, `weapon_list.md`) are referenced where relevant.

## 1. Architecture Overview

### 1.1 What "support systems" means here

MCV's `lua/mcv/` tree is a flat module library loaded by one autorun file; on top of it sit the SWEP bases (`weapons/mcv_base`, `mcv_throwable`, …) which compose modules out of `mcv/weapon_common/`. The files audited here are the cross-cutting layer that serves *all* of those bases:

- **`mcv/shared/sh_common.lua`** — the shared constant tables (firemode enums, hitgroup multipliers, ammo types, shell catalogue, sound-channel layout). No functions; pure data + ammo registration.
- **`mcv/shared/sh_npc.lua`** + **`weapons/mcv_base/sh_npc.lua`** — NPC-side weapon selection menus and the server-only AI firing path.
- **`mcv/shared/sh_burn.lua`** — a custom damage-over-time fire system used by flamethrowers, incendiaries and flares.
- **`mcv/shared/sh_safe_movement.lua`** — a generated model whitelist that gates the at-ease movement-pose range.
- **`mcv/shared/sh_modelcache.lua`** / **`mcv/client/cl_modelgc.lua`** — model-metadata caching and clientside-model lifecycle.
- **`mcv/shared/sh_random_weapons.lua`** / **`mcv/client/cl_random_weapons.lua`** — "random weapon" selectors for the spawn menu and NPC spawns.
- **`autorun/sh_mcv_harness.lua`** + **`mcv_harness/*.lua`** — development/test tooling shipped inside the addon, inert in normal play.

### 1.2 Load order — `autorun/sh_mcv_load.lua`

The addon's only gameplay autorun file wires the whole thing (the harness autorun is separate; see §8.1):

```lua
-- autorun/sh_mcv_load.lua:1-23
AddCSLuaFile()

if CLIENT and MCV and MCV.CleanupClientModels then MCV.CleanupClientModels() end
MCV = {}

local searchdir = "mcv/"

// The shared files come back in name order, and several of them register convars through the
// helper in sh_convars.lua, which some of them sort ahead of. It goes first.
local first = "sh_convars.lua"

local function loadshared(v)
    include(searchdir .. "shared/" .. v)
    AddCSLuaFile(searchdir .. "shared/" .. v)
end

loadshared(first)

for _, v in pairs(file.Find(searchdir .. "shared/*", "LUA")) do
    if v != first then
        loadshared(v)
    end
end
```

Consequences that matter here:

- `MCV` is a single global table, wiped on every reload; `sh_convars.lua` loads first (convar helper), then every `mcv/shared/*.lua` in **alphabetical** name order on both realms. This is why `sh_common.lua` (constants) is available to every later shared file, and why `sh_categories.lua` (defines `MCV.Categories`, `MCV.CategorySlug`, `MCV.CategoryConVarName` at sh_categories.lua:22-58) is loaded before `sh_random_weapons.lua` consumes it at sh_random_weapons.lua:88.
- Client files (`mcv/client/*.lua`, `mcv/client/vgui/*.lua`) are `AddCSLuaFile`'d and included on the client only (`sh_mcv_load.lua:25-37`); server files last (`sh_mcv_load.lua:39-43`).
- The pre-wipe `MCV.CleanupClientModels()` call (`sh_mcv_load.lua:3`, mirrored inside cl_modelgc.lua:3) is reload safety for the clientside-model tracker — see §6.2.

### 1.3 Realm split of the audited files

| File | Realm | Nature |
|---|---|---|
| `mcv/shared/sh_common.lua` | SH | constants, `game.AddAmmoType` at load |
| `mcv/shared/sh_npc.lua` | SH (split body) | SV: NPC-weapon list + spawn hook; CL: menu bar |
| `weapons/mcv_base/sh_npc.lua` | SH header / SV body | AI firing path (`if CLIENT then return end` at :64) |
| `mcv/shared/sh_burn.lua` | SH header / SV loop | burn API shared, tick loop server-only |
| `mcv/shared/sh_safe_movement.lua` | SH | static table |
| `mcv/shared/sh_modelcache.lua` | SH | caches |
| `mcv/client/cl_modelgc.lua` | CL | clientside-model lifecycle |
| `mcv/shared/sh_random_weapons.lua` | SH | pools + SV concommand |
| `mcv/client/cl_random_weapons.lua` | CL | spawn-menu content type |
| `autorun/sh_mcv_harness.lua` | SH | queue driver (SV) + capture/report (CL) |
| `mcv_harness/*.lua` | mixed, per module | never loaded by the addon; see §8 |

### 1.4 Prediction & realm conventions used throughout

Because realm discipline is first-class for the translation layer, the conventions these files follow:

- **Split-body shared files**: `sh_npc.lua` (both files), `sh_burn.lua` and `sh_random_weapons.lua` define shared API up top and guard server-only sections with `if CLIENT then return end` / `if SERVER then … else … end` boundaries (e.g. weapons/mcv_base/sh_npc.lua:64, sh_burn.lua:50, sh_random_weapons.lua:149). Nothing in these files runs inside prediction except the pure queries (`GetNPCSpread`, `GetNPCShotInterval`, `MCV.IsBurning`) — they are called from `Think`/fire paths that own their own prediction discipline.
- **Server-owned plain-field state**: burn fields (`MCV_BurnEnd/DPS/Attacker/Inflictor/NextTick`, sh_burn.lua:25-34) and `SWEP.MCVWasNPCWeapon` (weapons/mcv_base/sh_npc.lua:78) are plain entity/weapon fields written only on the server; clients never read them.
- **NetworkVar accessors stay shared**: everything the harness and NPC path consume (`GetSighted`, `GetAnimLockTime`, `GetFiremode`…) is defined in the shared halves of the bases, so both realms see the same names — the single most important convention for §9.
- **Load-time side effects are realm-symmetrical**: `game.AddAmmoType` runs on both realms (sh_common.lua:64-80), the NPC-weapon list registration runs on both (sh_npc.lua:27-28), and the harness autorun runs on both behind its marker.

## 2. NPC Integration

MCV follows the TacRP split: players fire through predicted code, NPCs fire through a **server-only** path with no user commands, viewmodel, reserve-ammo pool or player reload state — Source owns NPC schedules and reload animations, and the engine's reload animation event refills the clip (`weapons/mcv_base/sh_npc.lua:1-3`).

### 2.1 Weapon selection — `mcv/shared/sh_npc.lua`

**`MCV.GetNPCWeapons(category, ply)`** — sh_npc.lua:4-16 (SH). Iterates `weapons.GetList()`, resolving each entry through `weapons.Get(entry.ClassName)` "to resolve inherited NPCUsable/Spawnable" (sh_npc.lua:7), and keeps weapons that are `MilitaryConflictVietnam`, `Spawnable`, `NPCUsable`, optionally match a `SubCategory == category`, and pass `AdminOnly` (admin only; note this gate checks `ply:IsAdmin()` and does **not** include the `game.SinglePlayer()` allowance the random-weapons catalog uses — sh_random_weapons.lua:99). Returns `{class, title, category}` rows sorted by title then class. Callers: the list registration, both menu builders, `PlayerSpawnedNPC`, and the harness (`mcv_harness/npc.lua:104`).

**`registerWeapons()`** — sh_npc.lua:18-28 (SH). Adds every NPC-usable MCV weapon to the engine list `list.Get("NPCUsableWeapons")` with title `"MCV: " .. entry.title`, skipping classes already present. Runs on `InitPostEntity` and `OnReloaded`. This is what makes MCV weapons appear in sandbox's native per-NPC weapon dropdown.

**Client menu bar** — sh_npc.lua:30-57 (CL, `PopulateMenuBar`). Adds a top-bar menu **"MCV NPC Weapons"** writing the sandbox userinfo convar `gmod_npcweapon`: "Default weapon" (`""`), "No weapon" (`none`), "Random MCV weapon" (`!mcv|all`), then one submenu per `SubCategory` with "Random <category>" (`!mcv|<category>`) plus every weapon in it. A "Miscellaneous" submenu lists the random groups with NPC support (`kind != "category"`, `key != "all"`, `npcCount > 0`) as `!mcv|random:<key>` (sh_npc.lua:50-56).

**`PlayerSpawnedNPC` hook** — sh_npc.lua:59-77 (SV). The `!mcv|` protocol:

- An explicit weapon from the NPC's right-click menu takes precedence: `if npc.Equipment and npc.Equipment != "" then return end` (sh_npc.lua:62).
- Reads the spawning player's `gmod_npcweapon` userinfo; anything not starting `!mcv|` is ignored (sh_npc.lua:63-64).
- Requires `CAP_USE_WEAPONS` in `npc:CapabilitiesGet()` (sh_npc.lua:65).
- `!mcv|all` → all NPC weapons; `!mcv|random:<key>` → `MCV.GetRandomWeaponChoices(key, ply, true)`; otherwise `!mcv|<category>` → `MCV.GetNPCWeapons(category, ply)` (sh_npc.lua:66-72).
- One uniform roll: `choices[math.random(#choices)].class`, `npc:Give(class)`, then `npc.Equipment = class` so duplicating the NPC preserves the resolved weapon (sh_npc.lua:74-76).

Upstream notes this in BUGLIST.md:223 ("NPC support follows the TacRP split … Added individual weapons to the native NPC weapon list and an MCV category/random menu. Combine, Citizen and Metropolice combat/reload checks, menu selection and player pickup passed. Flamethrower AI, thrown equipment and melee remain excluded.").

### 2.2 The AI firing path — `weapons/mcv_base/sh_npc.lua`

Defaults: `mcv/weapon_common/shared.lua:11` sets `SWEP.NPCUsable = false` with `SWEP:CanBePickedUpByNPCs()` returning it (:13-15); `weapons/mcv_base/shared.lua:5` overrides `SWEP.NPCUsable = true` for the gun base.

**`SWEP:GetNPCSpread()`** — sh_npc.lua:4-6 (SH). `(self.NPCSpread or self.Spread) * self:StatMult("spread") / 100`. Called by the physical-bullet server sweep (`mcv/shared/sh_physbullets.lua:98`) and by `mcv_base/sh_shoot.lua:362` when the owner is an NPC.

**`SWEP:GetNPCBulletSpread(proficiency)`** — sh_npc.lua:8-11 (SH). The AI's own aim error in degrees on top of weapon dispersion: `8 / (math.Clamp(proficiency or 0, 0, 4) + 1)` — 8° for Poor down to 1.6° for Perfect. Read by the engine's AI shooting hooks.

**`semiAutoRPM`** — sh_npc.lua:13-19 (SV table). Per-proficiency semi-auto fire caps: Poor 60, Average 90, Good 120, Very Good 180, Perfect 240 RPM. (BUGLIST.md:218 records the change: "NPC semi-auto fire is capped at 60/90/120/180/240 RPM for Poor/Average/Good/Very Good/Perfect weapon proficiency.")

**`SWEP:GetNPCShotInterval()`** — sh_npc.lua:21-39 (SH, proficiency logic server-only):

```lua
-- weapons/mcv_base/sh_npc.lua:21-39
function SWEP:GetNPCShotInterval()
    local mode = self:GetFiremodeValue()
    local delay = 60 / self:GetFiremodeRate(mode)
    local owner = self:GetOwner()
    if SERVER and (mode == MCV.FIREMODE_SEMI or mode == MCV.FIREMODE_HE or mode == MCV.FIREMODE_BUCKSHOT)
        and IsValid(owner) and owner:IsNPC() then
        local proficiency = math.Clamp(owner:GetCurrentWeaponProficiency(),
            WEAPON_PROFICIENCY_POOR, WEAPON_PROFICIENCY_PERFECT)
        // Read proficiency each time so skill changes take effect without re-equipping.
        // Cap after stat multipliers; the weapon's own slower rate still wins.
        delay = math.max(delay, 60 / semiAutoRPM[proficiency])
    end
    // A 600-RPM script value on a pump/bolt gun describes the shot, not working
    // the action. NPCs don't play the first-person cycling animation.
    if self.PlayCycleAnimation then
        delay = math.max(delay, mode == MCV.FIREMODE_PUMP and 0.6 or 0.9)
    end
    return math.max(delay, self.NPCShotInterval or 0)
end
```

Order of precedence: firemode rate → semi-auto proficiency cap (server, semi/HE/buckshot only) → manual-action floor (0.6 s pump, 0.9 s bolt) → explicit `SWEP.NPCShotInterval` override.

**`SWEP:GetNPCBurstSettings()`** — sh_npc.lua:41-54 (SH). Returns `(min, max, delay)` for the AI burst hooks: burst firemode → `BurstRounds` capped by clip; automatic modes (AUTO/FAST/SLOW, non-projectile, non-manual-action) → bursts sized from the interval (`ceil(0.3/delay)` … `ceil(0.8/delay)` shots, minimums 2/3); everything else single shots. Note `FIREMODE_FAST`/`FIREMODE_SLOW` count as automatic here.

**`SWEP:GetNPCRestTimes()`** — sh_npc.lua:56-62 (SH). Burst mode rests at `BurstRecovery` (+0.3 s for the max); otherwise `max(delay, 0.3)` / `max(delay, 0.6)`.

**`SWEP:NPC_Deploy()`** — sh_npc.lua:66-90 (SV). Called from `Equip` when an NPC picks the weapon up. Cancels deferred actions, clears reload/cycle/trigger/launcher/akimbo NetworkVars, flags `self.MCVWasNPCWeapon = true`, clamps ammo to one magazine (§below), clamps the firemode index into `#self.Firemodes`, sets the hold type to `HoldTypeNPC or HoldType`, and applies a fallback: the engine translates `ACT_RANGE_ATTACK1` through `self.ActivityTranslateAI` (populated by GMod's `weapon_base` `SetHoldType` translation table — engine/GMod base behavior, not defined in MCV itself); if the NPC's model cannot play the translated attack activity (`SelectWeightedSequence < 0`), it falls back to `SetHoldType("ar2")` because "Combine/Citizen models lack some pistol/crossbow/RPG animations" (sh_npc.lua:83-88). Finishes with `Think_WorldBodygroups()` (sh_npc.lua:89).

**`SWEP:ClampNPCAmmo()`** — sh_npc.lua:93-102 (SV). "Only call on the NPC ownership/drop path, never on a fresh player pickup" (:92): clamps Clip1/Clip2 to `GetClip1Capacity()`/`GetClip2Capacity()` (capacity helpers defined at `weapons/mcv_base/sh_reload.lua:125-131`). Fresh SWEPs carry `DefaultClip` (magazine + starting reserve) in Clip1 until player pickup distributes it; NPCs get only a magazine (comment at sh_npc.lua:76-78). BUGLIST.md:195 records the bug this fixed ("Corrected NPC ammo handling without stripping fresh player weapons of their starting reserves… removed the general player/duplicate-pickup clamp").

**`SWEP:Equip(newOwner)`** — sh_npc.lua:104-111 (SV). Player pickup clears `MCVWasNPCWeapon`; NPC pickup of an `NPCUsable` weapon calls `NPC_Deploy()`.

**`SWEP:OnDrop()`** — sh_npc.lua:113-119 (SV). If the weapon was an NPC's, clamps the ammo again ("Also contain any excess left by an NPC/third-party reload before it becomes loot", :114) and clears the flag.

**`SWEP:NPCShoot_Primary(shootPos, shootDir)`** — sh_npc.lua:121-123 (SV). The engine entry point; forwards to `NPC_PrimaryAttack`.

**`SWEP:NPC_PrimaryAttack(shootPos, shootDir)`** — sh_npc.lua:125-161 (SV). Gated by owner validity, `NPCUsable` and `GetNextPrimaryFire()`. Empty-magazine handling: picks `SCHED_HIDE_AND_RELOAD` when the current enemy is armed (has a valid active weapon) else plain `SCHED_RELOAD`, and returns without firing (sh_npc.lua:131-135). Volley firemodes spend up to `VolleyCount` rounds. Sets `NextPrimaryFire` to `CurTime() + delay`, and calls `owner:NextThink(CurTime() + delay)` when `delay < 0.1` so fast guns think on time (sh_npc.lua:140-142). Effects mirror the player path's pre-shot clip parity — `EmitShotSound` (double-shot sound for multi-round volleys), `DoMuzzle()`, `DoEject()` (suppressed by `NoEjectOnShoot` unless a manual cycle follows) — but deliberately **no** view punch, gestures, trigger latches or predicted animation state (sh_npc.lua:146-150). Projectile weapons re-aim exactly at the enemy's `WorldSpaceCenter()` and call `RocketAttack(false, pos, dir)`; everything else calls `BulletAttack(shootPos, shootDir)` (sh_npc.lua:151-157). Post-fire: `SetClip1(clip - rounds)` (after a validity check — "A nearby blast can remove the weapon", :158) and `Think_WorldBodygroups()` so round-count bodygroups update.

**`SWEP:NPC_Reload()`** — sh_npc.lua:163-166 (SV). Intentionally empty: "Refilling here would give ammunition before the NPC finishes reloading. The engine performs that transfer when its animation reaches the reload event."

### 2.3 Weapon fields NPCs read (definition surface)

`NPCUsable` (weapon_common/shared.lua:11, mcv_base/shared.lua:5), `CanBePickedUpByNPCs`, `NPCSpread`, `NPCShotInterval`, `HoldTypeNPC`, `ActivityTranslateAI` (engine-populated), plus everything the shared fire machinery uses: `Firemodes`/`GetFiremodeRate`, `PlayCycleAnimation`, `BurstRounds`, `BurstRecovery`, `VolleyCount`, `AmmoPerShot`, `Primary.ClipSize`, `Primary.Chamber` (via capacity helpers), `GetProjectileClass()`, `SoundSingleShot`/`SoundDoubleShot`, `NoEjectOnShoot`, `StatMult("spread")`.

### 2.4 Harness link — `mcv_harness/npc_cadence.lua`

The cadence rules above are contract-tested by `mcv_harness/npc_cadence.lua` (§8.9): it asserts `GetNPCShotInterval` equals `max(60/semiRate, 60/cap)` for all five proficiencies, that a ×10 firerate `StatMult` cannot beat the cap (:39) while a ×0.1 slowdown still applies (:41), that `NPCShotInterval` wins (:42-43), the manual-action floors for M37 (0.6) and Vz.24 (0.9) (:53-57), and at runtime that no two recorded shots of any NPC come closer than the promised interval (npc_cadence.lua:116-133).

## 3. Burning — `mcv/shared/sh_burn.lua`

### 3.1 Why it exists

The engine's `Entity:Ignite()` was rejected on purpose (sh_burn.lua:1-4): its `entity_flame` takes over damage attribution, cannot be shortened, and drops its own fire sprite on the model. MCV instead keeps a per-entity burn timer and deals `DMG_BURN` in ticks "the way the M202's fire does", playing the game's own `burning_character` particle on the victim. BUGLIST.md:356 tracks this: "Replace Ignite() with the M202-style fire damage method (`lua/mcv/shared/sh_burn.lua`: MCV.Burn ticks DMG_BURN with the game's burning_character particle; incendiary grenades make a short fire pool)".

Constants: `MCV.BurnTickRate = 0.25` (4 damage ticks/second) and `MCV.BurnParticle = "burning_character"` (sh_burn.lua:7-8).

### 3.2 API

**`MCV.IsBurning(ent)`** — sh_burn.lua:12-14 (SH). True while `ent.MCV_BurnEnd > CurTime()`. Prediction-safe query (plain field reads, server is the writer).

**`MCV.Burn(ent, seconds, attacker, inflictor, dps)`** — sh_burn.lua:18-36 (SV; returns immediately on client):

```lua
-- mcv/shared/sh_burn.lua:18-36
function MCV.Burn(ent, seconds, attacker, inflictor, dps)
    if CLIENT or !IsValid(ent) then return end
    if !(ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_physics") then return end
    if ent:IsPlayer() and !ent:Alive() then return end
    if ent:WaterLevel() >= 2 then return end

    local was = MCV.IsBurning(ent)
    ent.MCV_BurnEnd = math.max(ent.MCV_BurnEnd or 0, CurTime() + seconds)
    ent.MCV_BurnDPS = math.max(was and ent.MCV_BurnDPS or 0, dps or 10)
    ent.MCV_BurnAttacker = IsValid(attacker) and attacker or ent.MCV_BurnAttacker
    ent.MCV_BurnInflictor = IsValid(inflictor) and inflictor or ent.MCV_BurnInflictor
    burning[ent] = true

    if !was then
        ParticleEffectAttach(MCV.BurnParticle, PATTACH_ABSORIGIN_FOLLOW, ent, 0)
        ent:EmitSound("ambient/fire/fire_small_loop2.wav", 75, 100, 0.7, CHAN_STATIC)
        ent.MCV_BurnNextTick = CurTime()
    end
end
```

Rules: only players/NPCs/NextBots/`prop_physics` burn; dead players and submerged entities (WaterLevel ≥ 2) are immune. A new burn **extends** the end time (max) and keeps the highest DPS seen (default 10); attacker/inflictor only overwrite when still valid. First ignition attaches the particle and the looping fire sound and arms the next tick. Side effects: four plain fields on the entity (`MCV_BurnEnd/DPS/Attacker/Inflictor/NextTick`) and the module-local `burning` set.

**`MCV.Extinguish(ent)`** — sh_burn.lua:38-48 (SV). Zeroes `MCV_BurnEnd`, drops the set entry, stops the particle (`StopParticlesWithNameAndAttachment` when available, else blanket `StopParticles()`) and the loop sound.

### 3.3 The tick loop

Server `Think` hook `"mcv_burn"` (sh_burn.lua:50-75): iterates the `burning` set, drops invalid entities, extinguishes on expiry, submersion or player death, and otherwise deals `DamageInfo` every `BurnTickRate` seconds — `SetDamage(DPS * tickRate)`, `DMG_BURN`, attacker/inflictor falling back to `game.GetWorld()`/attacker when no longer valid, damage position at `WorldSpaceCenter()`. `PlayerDeath` and `PlayerSpawn` hooks extinguish the player outright (sh_burn.lua:77-78).

### 3.4 Callers (who sets people on fire)

- **Firepool** (`entities/mcv_firepool.lua:71`): entities standing in an incendiary ground fire get `MCV.Burn(ent, self.BurnAfter, attacker, inflictor, self.BurnAfterDPS)` — "a few seconds of burning after leaving the fire (sh_burn.lua, no Ignite)" (mcv_firepool.lua:69). The pool's own in-fire damage is a separate `DMG_BURN` tick; see `docs/projectiles-entities.md`.
- **Flare** (`entities/mcv_proj_flare.lua:45,78`): direct hits burn 6 s @ 10 DPS; proximity 4 s @ 10.
- **Flamethrowers** (`weapons/mcv_flamethrower/sh_flame.lua:83,98,269`): stream hits `IgniteTime` @ `BurnDamagePerSecond`; the landing cloud half that; direct contact with the flame entity 10 s.
- **Underbarrel flame** (`weapons/mcv_underbarrel_flame/shared.lua:54`): 3 s @ 5 DPS.

## 4. Common Utilities — `mcv/shared/sh_common.lua`

Despite the name, this file exports **no functions** — it is the shared constant/registration file every other doc cross-references. Loaded on both realms in name order (after `sh_convars.lua`, before `sh_categories.lua`), its only executable statement is the ammo-type registration loop.

### 4.1 Firemode enums — sh_common.lua:1-13

`MCV.FIREMODE_AUTO=0, _SEMI=1, _BURST=2, _SA=3, _DA=4, _FAN=5, _BOLT=6, _PUMP=7, _FAST=8, _SLOW=9, _VOLLEY=10, _HE=11, _BUCKSHOT=12`. These indices are what `SWEP.Firemodes` tables store and what the firemode NetworkVar holds. Consumers: the whole fire chain (`docs/gun-core.md`); NPC logic treats SEMI/HE/BUCKSHOT as proficiency-capped and AUTO/FAST/SLOW as burstable (§2.2).

### 4.2 Shot-sound channel layout — sh_common.lua:15-20

```lua
-- mcv/shared/sh_common.lua:15-20
// Bounded overlap per weapon: recordings can have 60-100 ms of mechanism before
// the report. Replacing them every shot cuts that report out on fast automatics.
// Four slots per layer preserve the attack without CHAN_STATIC's unbounded tails.
MCV.SHOT_SOUND_SLOTS = 4
MCV.CHAN_SHOT = CHAN_USER_BASE
MCV.CHAN_SHOT_DISTANT = CHAN_USER_BASE + MCV.SHOT_SOUND_SLOTS
```

Eight `CHAN_USER_BASE`-relative channels: 4 near + 4 distant, rotated per shot by `mcv_base/sh_shoot.lua:546-551` (`MCVShotSoundSlot = (slot + 1) % MCV.SHOT_SOUND_SLOTS`) so overlapping mechanical-then-report layers don't cut each other off. See `docs/sound-system.md`.

### 4.3 `MCV.FiremodeAmmo` — sh_common.lua:22-25

Maps `FIREMODE_HE → "smg1_grenade"` and `FIREMODE_BUCKSHOT → "buckshot"`; consumed by the M79 family to pick a firemode's ammo type (`weapons/mcv_m79_base/shared.lua:24`).

### 4.4 `MCV.FiremodeNames` — sh_common.lua:28-42

Display names per firemode ("Automatic", "Single-Fire", "3-Round Burst", "Single-Action", "Double-Action", "Fan Fire", "Bolt-Action", "Pump-Action", "Fast-Fire", "Slow-Fire", "Volley", "HE", "Buckshot"). Consumer: `SWEP:GetFiremodeName()` at `weapons/mcv_base/sh_gun.lua:63`; also surfaced by the harness `WeaponState` snapshot (`t.firemode`, autorun/sh_mcv_harness.lua:86).

### 4.5 `MCV.CancelMultipliers` — sh_common.lua:44-61

Hitgroup damage multipliers keyed by gamemode: default `[1]` is head ×2, arms/legs/gear ×0.25; `"terrortown"` is head ×1, limbs/gear ×0.55. Consumed by `mcv/shared/sh_hitgroups.lua:2` as `MCV.CancelMultipliers[string.lower(engine.ActiveGamemode())] or MCV.CancelMultipliers[1]`. (Despite the name these are plain damage multipliers; cross-ref `docs/shooting-ballistics.md`.)

### 4.6 `MCV.AmmoTypes` registration — sh_common.lua:64-80

Ten custom ammo types — `mcv_grenade, mcv_molotov, mcv_mine, mcv_explosive_charge, mcv_flamethrower_fuel, mcv_crossbowbolt, mcv_flareround, mcv_ammobox, mcv_medicbox, mcv_flame_cartridge` — registered with `game.AddAmmoType` on **both realms at load** (comment: "Registered on both realms at load so weapons can use them in Primary.Ammo", :64-65) with neutral stats (`DMG_GENERIC`, `TRACER_NONE`, 0 damage/force). Weapons reference them by name in `Primary.Ammo`/`Secondary.Ammo`.

### 4.7 `MCV.ShellTypes` — sh_common.lua:82-175

23 numbered shell/ejection-brass definitions, each `{Model, Sound}`:

| Idx | Entry | Idx | Entry |
|---|---|---|---|
| 1 | 7.62×39 Soviet | 13 | flare shell |
| 2 | 12 gauge (own bounce sound) | 14 | grenade shell |
| 3 | 14.5×114 | 15 | .22 LR |
| 4 | 5.56×45 | 16 | .30-06 |
| 5 | 7.62×25 Tokarev | 17 | .30 |
| 6 | 7.62×38mmR | 18 | .45 APC |
| 7 | 7.51×51 NATO | 19 | .50 BMG |
| 8 | 7.62×54mmR | 20 | M60 belt link |
| 9 | 7.92×33 Kurz | 21 | RP-46 belt link |
| 10 | 7.92×57 Mauser | 22 | RPD belt link |
| 11 | 9×18 Makarov | 23 | Stoner 63 belt link |
| 12 | 9×19 Parabellum | | |

All use sound `MCV_Bounce.Shell` except the 12-gauge (`MCV_Bounce.ShotgunShell`). Consumer: `effects/mcv_shelleffect.lua:21` (`MCV.ShellTypes[self.Type]`), indexed by the weapon's `EjectBrassType` (default `5` at `weapons/mcv_base/shared.lua:214`). See `docs/effects.md`.

## 5. Safe Movement — `mcv/shared/sh_safe_movement.lua`

### 5.1 What problem it solves

This is the follow-up to an old upstream bug (BUGLIST.md:373): "LMGs (and the flamethrower) point left while walking: the walk drove `player_movement` into the model's run layer (Lua walked at 100, the M60 run layer starts at 106, the LPO-50 at 80). Mapped onto each model's run layer range (`MovementPoseWalk/Sprint`)". That fix mapped walk/sprint onto each model's layer range (see `docs/animation-system.md` §4.2). The remaining hazard is the **at-ease (safety) state**: when the weapon is lowered (`+use +walk`, `SWEP:ToggleSafe` at `weapons/mcv_base/sh_gun.lua:115-132`), only models whose nearwall locomotion layers were recompiled/validated may use the full pose range. `sh_safe_movement.lua` is the machine-generated whitelist:

```lua
-- mcv/shared/sh_safe_movement.lua:1-2
// Generated by work/install_safe_movement.py after model validation.
MCV.SafeMovementModels = {
    ["models/weapons/mcv/v_kar98_dov.mdl"] = true,
    ...
```

228 viewmodel paths (sh_safe_movement.lua:3-230, inside a 231-line file) — effectively every shipped MCV viewmodel.

### 5.2 The consumer — one clamp in `GetMovementPose`

```lua
-- mcv/weapon_common/sh_think.lua:77-83
    // Only models with grip-corrected nearwall locomotion can use the full movement range.
    // Check the active model too: dual wield swaps ViewModel on the same weapon instance.
    local safeMovement = self.SafeMovementAnimations or (MCV.SafeMovementModels and
        MCV.SafeMovementModels[string.lower(self.ViewModel or "")])
    if self:GetSafe() and !safeMovement then
        pose = math.Clamp(pose, 0, 86)
    end
```

When the weapon is at ease **and** the active viewmodel is not whitelisted, the `player_movement` pose parameter is clamped to 86 (below the model's run-layer threshold) so the lowered gun doesn't drift into uncorrected sprint poses. The lookup re-checks `self.ViewModel` every call precisely because akimbo swaps the model on the same weapon instance (comment :78).

### 5.3 Per-weapon override — `SWEP.SafeMovementAnimations`

The whitelist is model-keyed; weapons whose models aren't in it (or that want to force either side) set the field explicitly: `true` in `weapons/mcv_svd_irons.lua:12`, `mcv_type56_drum.lua:12` (custom compiles validated by hand), `mcv_vz24.lua:72` ("nearwall idle/walk/sprint and transitions baked together"), `mcv_vz59b.lua:21`; `false` in `mcv_chainsaw.lua:22` and `mcv_lunge_mine.lua:27` (forcing the clamp). The field also appears in the animation audit's SWEP surface (`docs/animation-system.md`, `SafeMovementAnimations` "model list opt-out").

## 6. Model Cache & Garbage Collection

### 6.1 Lookup caches — `mcv/shared/sh_modelcache.lua`

Covered in depth by `docs/animation-system.md` §6; summary for completeness. A weak-keyed (`__mode = "k"`) table maps entity → `{model = …}` with per-method index subtables (sh_modelcache.lua:4-15). The generic `lookup` caches only successful results above a per-method minimum — attachments ≥ 1, bones and sequences ≥ 0 — so **failed lookups are retried** (an entity can be networked before its model is ready; sh_modelcache.lua:17-28). Public API: `MCV.CachedAttachment(ent, name)` (:30-32), `MCV.CachedBone(ent, name)` (:34-36), `MCV.CachedSequence(ent, name)` (:38-40), and `MCV.SequenceLoops(ent, sequence)` (:42-54) which caches `GetSequenceInfo` flag bit 0 (looping) per model. Callers: `sh_anim.lua` (sequence lookup/capability queries/loop detection), `sh_vm.lua`, `cl_worldmodel.lua` (weapon/hand bones, muzzle attachments), `cl_physbullets.lua`, `mcv_base/sh_effects.lua`, `sh_flame.lua`. BUGLIST.md:77 records the optimization pass that introduced these ("model-aware attachment/bone/sequence caches with missing-metadata retries").

**Translation note:** nothing here is weapon-specific — any entity works — so translated SWEPs inherit correct cached lookups for free as long as they draw through MCV's viewmodel/worldmodel paths.

### 6.2 Clientside-model GC — `mcv/client/cl_modelgc.lua`

The problem (cl_modelgc.lua:1-2): "Keep strong references: Lua GC does not remove engine clientside entities. Independent of SWEP:OnRemove, which can be missed during transmission/owner changes." MCV creates several clientside models per weapon — the worldmodel copies (`WM`, `WMLeft`, created by `SWEP:GetWorldModelEntity` at `mcv/weapon_common/cl_worldmodel.lua:95-129`), the scope-overlay proxy (`"ScopeOverlayModel"`, `mcv/client/cl_scopeoverlay.lua:31`) and the placeable ghost (`"Ghost"`, `weapons/mcv_placeable/sh_place.lua:429-433`).

API (all CL):

- **`MCV.TrackClientModel(weapon, slot, model)`** — cl_modelgc.lua:22-29. Removes any previous occupant of the slot, registers `{weapon, slot, owner = weapon:GetOwner()}` under the model entity, flags `model.MCVClientModel = true`, stores `weapon[slot] = model`.
- **`MCV.RemoveClientModel(weapon, slot)`** — cl_modelgc.lua:16-20. Releases the model in that slot.
- **`local release(model, entry)`** — cl_modelgc.lua:6-14. Drops the registration, clears `weapon[slot]` (and `WMLeftBind`) if the weapon still points at it, and `model:Remove()`.
- **`MCV.CleanupClientModels()`** — cl_modelgc.lua:31-33. Releases everything; called from `PostCleanupMap`, `ShutDown` (:59-60), at the top of the file on Lua reload (:3), and from `sh_mcv_load.lua:3` before `MCV = {}` wipes the table.

The sweep — `timer.Create("MCV_ClientModels", 1, 0, …)` (cl_modelgc.lua:43-53) — checks each registered model once per second ("Only visit our registered models, once a second, not every entity every frame", :42) and releases it when the model/weapon/slot link, the owner, the owner identity, or dormancy breaks, or when the owner's active weapon is no longer this weapon. `EntityRemoved` and `NotifyShouldTransmit(ent, false)` sweep a removed owner's models via `releaseEntity` (cl_modelgc.lua:35-40, 55-58) — this is the PVS-loss half of the fix in BUGLIST.md:201 ("Weapon PVS lifecycle: repair detached clientside parents, retire world models on transmission loss…").

## 7. Random Weapons — `mcv/shared/sh_random_weapons.lua` + `cl_random_weapons.lua`

### 7.1 Concept

"Random spawn-menu choices are selectors, not extra SWEPs. Resolve a fresh class on the server, then let sandbox's ordinary give/spawn commands enforce permissions" (sh_random_weapons.lua:1-2). Pools are defined declaratively and resolved at query time against the live weapon list, so nothing goes stale when weapons are added. BUGLIST.md:219-220 records the UI work ("Random country selectors now share flat rectangular flags…", "Added random selectors to all 18 weapon sections and a Miscellaneous child tab with country, WW2 and mixed pools…").

### 7.2 Pool definitions — `MCV.RandomWeaponDefinitions`

`define(key, name, kind, data)` (sh_random_weapons.lua:5-9) fills `MCV.RandomWeaponDefinitions`; `kind` is one of `"other"`, `"country"`, `"ww2"`, `"category"`:

- **`"all"`** — "Random MCV Weapon" (:11).
- **Countries** — `country(key, name, flag, ...aliases)` (:13-17): 23 entries at :18-40 (us, ru, cn, fr, de, gb, au, be, nl, cz, kp, vn, fi, hu, il, it, dk, es, pl, rh, ro, se, yu) plus Japan at :56 — 24 in all. A weapon matches by its `SWEP.Country` string being one of the aliases.
- **Themes** — `theme(key, name, flag, members, kind)` (:42-46): explicit class lists prefixed `mcv_`: `homemade` (VC weapons), `custom` (kitbashes), and period pools `us_ww2`, `ru_ww2`, `de_ww2`, `gb_ww2`, `fr_ww2`, `jp_ww2` (kind `"ww2"`; "modern derivatives and SOG conversions stay out", :49).
- **Shared-design additions** — `alsoCountry(key, members)` (:61-65): classes added to a country pool without changing its display text/category/period lists — e.g. the L1A1 SLR sits in gb/au/be (:66-68); "Catalog traversal still gives each class one roll" (:58-60).
- **Features** — `feature:scope` (`HasScope`), `feature:dual` (`HasAkimbo`), `feature:launcher` (`HasRifleGrenade`) (:75-77).
- **Categories** — one per `MCV.Categories` entry (except `CATEGORY_ALL`) via `MCV.CategorySlug`, with singularized names ("Battle Rifles" → "Random Battle Rifle") (:79-92).

### 7.3 Resolution — catalog and matching

**`catalog(ply)`** (local, :94-104): every `Spawnable` MCV weapon as `{class, title, weapon}`, sorted by class, with `AdminOnly` weapons included only for admins or singleplayer. **`matches(group, entry)`** (:106-115) precedence: `group.category` (SubCategory equality) → `group.countries` (Country alias **or** explicit class list) → `group.classes` → `group.feature` (boolean field on the weapon table) → key `"all"`.

**`MCV.GetRandomWeaponChoices(key, ply, npcOnly)`** — :117-126 (SH). All catalog entries matching the group, optionally restricted to `NPCUsable`. Returns `{class, title, category}` rows.

**`MCV.GetRandomWeaponGroups(ply)`** — :128-143 (SH). One row per definition with `count` and `npcCount` computed against the catalog (groups with zero members dropped), sorted by name. Used by both menu builders.

**`MCV.RandomWeaponNPCSelection(key)`** — :145-147. Encodes `"!mcv|random:" .. key` — the `gmod_npcweapon` value consumed by `PlayerSpawnedNPC` (§2.1).

**`MCV.SpawnRandomWeapon(ply, key, drop)`** — :150-160 (SV). Requires a live player; rolls one class uniformly; `drop` routes through sandbox's `Spawn_Weapon` (ground pickup) otherwise `CCGiveSWEP(ply, "gm_giveswep", {class})` — sandbox's own permission-checked give.

**Concommand `mcv_random_weapon <key> [give|spawn]`** — :161-164 (SV). The spawn-menu icons invoke it; any other second argument is rejected.

### 7.4 Client UI — `cl_random_weapons.lua`

`spawnmenu.AddContentType("mcv_random_weapon", …)` (cl_random_weapons.lua:1-44) builds a `ContentIcon` that is *not* a weapon: material `mcv/random/<flag|question>.png`, light-sky-blue tint, `SetIsNPCWeapon(npcCount > 0)` badge, tooltip spelling out the three interactions. `DoClick` runs `mcv_random_weapon <key> give`; `DoMiddleClick` spawns a pickup; `OpenMenuExtra` adds "Give to me" / "Spawn a pickup" / "Use for NPCs" (the last sets `gmod_npcweapon` to `!mcv|random:<key>`, disabled with an explanatory tooltip when `npcCount == 0`, :24-31). `DrawSelections` is overridden to swap `m_SpawnName` for the `!mcv|` selector so sandbox's "selected for NPCs" badge logic matches (":34 // Match sandbox's selected-NPC badge while using a selector rather than a SWEP class", :35-41).

`MCV.CreateRandomWeaponIcon(container, group)` (:46-51) and `MCV.PopulateRandomWeaponMisc(container)` (:53-63) — the latter lays out three sections: "Mixed groups" (`other`), "Countries" (`country`), "World War II" (`ww2`). Integration points: `mcv/client/cl_subcategories.lua:60,76` adds a random icon to every category section, and :98-104 creates the "Miscellaneous" child tab (flagged `misc.MCVRandomMisc = true`) that `PopulateRandomWeaponMisc` fills.

**Who is it for:** players (spawn menu give/spawn), mappers/admins (middle-click ground pickups), and NPC authors (per-group NPC default) — not loadouts; there is no scripted loadout hook here.

## 8. The Developer Harness

### 8.1 What it is and how it is gated

`autorun/sh_mcv_harness.lua` is a **file-queue-driven remote-control rig** for a local listen server: "lets a script outside the game drive a local game session" (sh_mcv_harness.lua:1). The outside script is upstream's `work/harness.py`, which creates the enable marker and drops command files; the in-game side works through them one line at a time and writes results/screenshots back to disk. "Everything is written to disk, which both realms of a local listen server share, so no reply channel is needed" (:7-8).

Gating is a single existence check — **no convar, no developer flag**:

```lua
-- autorun/sh_mcv_harness.lua:31
if !file.Exists("mcv_harness/enable.txt", "DATA") then return end
```

Directory layout (:37-45): `garrysmod/data/mcv_harness/` containing `queue/` (driver → game command files), `results/` (JSON), `shots/` (PNG), `log.txt`; an instance launched with `-port N` (anything but 27015) uses `mcv_harness/pN/` instead so several can run at once (`work/harness.py --port N`, :28-29). `util.AddNetworkString("mcv_harness")` on the server (:47-49) is the only network channel (server → client requests). A local `log()` (:51-57) prints and appends timestamped lines to `ROOT .. "log.txt"` server-side. Readiness signalling: client `InitPostEntity` writes `client_ready.txt` (:299-301); server `PlayerInitialSpawn` writes `ready.txt` (:553-556) — this is how the Python driver knows the game is up.

`mcv_harness/*.lua` module files are **not** on the addon's load path at all — nothing in `mcv/` or `autorun/` includes them (the loader only scans `mcv/`, and `sh_mcv_load.lua` never touches `mcv_harness/`). They are included explicitly by harness queue commands (`lua include("mcv_harness/<file>")` on the server, `clua` on the client) or by the driver's test scripts (e.g. type67_timing.lua:1: "Explicitly included by work/tests/type67_timing.txt"). Because both realms of a listen server share the filesystem, no AddCSLuaFile is needed; the one multiplayer exception is `pvs.lua`, which calls `AddCSLuaFile()` and `SendLua('include("mcv_harness/pvs.lua")')` itself (pvs.lua:31, 45). Several modules additionally self-gate on `mcv_harness/enable.txt` (scope_buffers.lua:2, reload_trace.lua:2, visual_trace.lua:2, pvs.lua:2) so they stay inert if included accidentally; others (bolt, npc, npc_cadence, pack_split, cycle_timing, garand_m21, random_weapons, npc_models, type67_timing, missing_variants, penetration_tests, deploy_layers, custom_weapon_assets, ricochet, worldmodel_contact, spawn_icons, icon_assets, clock_restore_tests, clock_transition_seed, clock_transition_watch, hud_transition_tests) are pure API or run-on-include scripts with no gate — they rely on never being loaded outside the harness.

### 8.2 The command language

One command per line, `#` comments and blank lines skipped (sh_mcv_harness.lua:510-515). The full table (parsed by `step()`, :388-498):

| Command | Effect | Waits on |
|---|---|---|
| `give <class>` | `ply:Give` + auto-select after 0.05 s | 0.3 s |
| `select <class>` | `ply:SelectWeapon` | 0.2 s |
| `strip` | `ply:StripWeapons()` | — |
| `pos x y z` | teleport, zero velocity | — |
| `ang p y r` | `SetEyeAngles` | — |
| `noclip` | toggle `MOVETYPE_NOCLIP`/`WALK` | — |
| `god` | `GodEnable` | — |
| `key +attack2` | `ply:ConCommand(rest)` (any key press/release) | — |
| `tap +attack [s]` | press then release after hold (default 0.1 s), **timed on the client** | client `.done.txt` |
| `wait <seconds>` | pause | timer |
| `hud 0\|1` | `cl_drawhud` via ConCommand | — |
| `shot <name> [marker]` | PNG screenshot; `marker` forces the dev readout (§8.6) | shots `.done.txt` |
| `report <name>` | dump `H.WeaponState` both realms (§8.3) | client `.done.txt` |
| `spawn <class> [dist]` | entity `dist` units ahead, facing the player | — |
| `cmd <command>` | server console (`game.ConsoleCommand`) | — |
| `ccmd <command>` | player console | — |
| `lua <code>` | server Lua (`CompileString("local ply, job = ... ")`) | — |
| `clua <code>` | client Lua (`local ply = ...`) | — |
| `ptrace start <name>` / `ptrace stop` | prediction trace (§8.4) | stop waits for client `.done.txt` |
| `marker 0\|1` | toggle the dev readout without a shot | — |
| `quit` | finish job, `quit` the game | — |

Two mechanics deserve note. **`tap`** is deliberately client-timed: "lagged server packets can otherwise deliver +attack and -attack in one frame, without producing an attacking command" (:421-423) — the server sends a `tap` net message, the client presses, waits `hold`, releases and writes the done marker. **`spawn`** places the entity along the player's yaw and rotates it to face back (`ent:SetAngles(Angle(0, ang.y + 180, 0))`, :452).

### 8.3 `H.WeaponState(ply)` — the state snapshot

sh_mcv_harness.lua:66-144 (SH). The payload behind `report` (and the client-side half of it). Base block: realm, CurTime, map, player pos/eye/angles/health/onground. Weapon block: class, PrintName, Base, Clip1/Clip2, reserves via `GetAmmoCount`, `ply:GetAmmo()`. If `wep.MilitaryConflictVietnam` (:80): ironsight/sighted/sight_amount (+ client-only `sight_visual`), speed, `GetFiremodeName`, `GetActionState`, akimbo, grenade launcher, bayonet, bipod, holster_time, `next_idle` and `anim_lock` as **time-remaining** values, hold type, and `IronsightPos/Ang` vectors. Viewmodel block: model, sequence name + activity name, cycle, playback rate, pos/ang, every pose parameter and bodygroup by name (:99-111). Client-only extras: screen-space projections of the `muzzle`, `eject` and `cam` attachments (:112-124) and the **bore-axis projection** — the VM axis (of muzzle forward/right/up) best aligned with the eye forward, projected from `eye + fwd*4096` to screen, "on the centre when the sight picture is aligned" (:125-138) — plus screen size and FOV. This single function is a complete "is the converted weapon behaving" probe.

### 8.4 `ptrace` — the prediction tracer

The header comment (sh_mcv_harness.lua:146-155) states the matching contract: records are matched by `CUserCmd:CommandNumber`, weapon entity and hook; CurTime may be adjusted by tick-base correction; these are diagnostic samples, **not** the engine's acknowledged prediction snapshots; Think runs before movement on the client and after it on the server, so movement samples cannot be compared; replaying an unacknowledged command is normal and not an error; use `cl_showerror 2` for real field errors.

- `H.PtracePlain` (:158-159) lists the plain (non-networked) Lua fields recorded to expose drift: `ThrowReleaseAt, LitUntil, BayonetChargeReady, NextRepairTick, WasRunning, SlashCount, WindupKey, ViewModel, FuseBurning, PoseRecoilAvailable`. `H.PtraceKeys` (:160-161) packs 12 IN_ keys into a bitmask.
- `enc(v)` (:165-172) rounds/encodes numbers, vectors, angles, entities (EntIndex, −1 invalid), bools/strings, nil.
- `H.PtraceRecord(wep, phase)` (:174-231): only records under the prediction player with a real command number; captures tick, CurTime, `IsFirstTimePredicted`, frame, class/entindex/cmd number/cmd tick/buttons/phase, `UnPredictedCurTime` (client), clip/ammo quadruple, NextPrimary/SecondaryFire, `m_iViewModelIndex`, hold type, `#wep.ActiveTimers`, **every NetworkVar** via `wep:GetNetworkVars()` (prefixed `nv_`), the plain fields (prefixed `f_`), viewmodel sequence/rate/cycle/model/`m_nModelIndex`, player pos/vel/eye/punch/ground/crouch, `GetWeaponMovement()` triple at 12-digit precision, and the key bitmask.
- `ptraceWrap(wep)` (:235-251): wraps the **instance's** `Think`, `PrimaryAttack`, `SecondaryAttack`, `Reload` and `CaptureMovement` — "straight after its own Think, so it sees exactly what the tick left behind; the class table is not touched" (:233-234). `ptraceFollow(ply)` (:254-264) re-wraps whenever the active weapon changes (every frame client-side via `Think`, every `PlayerPostThink` for player 1 server-side, :286-292).
- `H.PtraceStart(name)` / `H.PtraceStop()` (:266-284): stop writes `results/<name>.ptrace.client.json` and `.server.json` (schema 2, tick interval, start/stop ticks, all records) plus a client `.done.txt`. The driver's `work/ptrace_diff.py` "compares by command, entity and hook" (:24-25). Upstream used this for the prediction fixes in BUGLIST.md:322/332 ("The harness checks real input, completed actions, client/server state and `cl_showerror 2`, with a deliberate mismatch calibration and a stock weapon control").

### 8.5 Server queue processing

`H.Job` (:368) is `{name, lines, i, waituntil, waitfile, results}`; results collect `log`, `errors`, `shots`, `reports`, `spawned` (entity indices), `ptraces`. `tick()` (:500-546), run every 0.1 s inside a `pcall` (timer `"MCV_Harness"`, :548-551): picks the alphabetically first `queue/*.txt`, deletes it, splits non-comment lines, then executes **one command per tick**. `waituntil` sleeps until a CurTime deadline; `waitfile` polls for a done-marker with a **10-second timeout** that records an error and moves on (:523-537). When the lines run out, `finishJob` writes `results/<name>.json` + `.done.txt` (:382-386). `step()` (:388-498) is the dispatcher of §8.2; unknown commands are recorded as errors (:495-497).

### 8.6 Client side — capture, report, marker

`net.Receive("mcv_harness")` (sh_mcv_harness.lua:327-360) handles six kinds: `shot` (sets `H.Marker` from the flag, arms `H.PendingShot`), `report` (writes `results/<name>.client.json` + done marker), `clua` (compiles `"local ply = ... "` + code, pcall), `tap` (press/hold/release + done marker), `marker` (toggle), `ptrace` (start/stop by empty arg). `PostRender` hook `"MCV_HarnessCapture"` (:308-325): when a shot is pending it first waits out `frames = 2` "so the marker state is drawn" (:310-314), then `render.Capture` PNG to `shots/<name>.png`, logs byte count, writes the done marker. `H.Marker` (:303) "forces the development readout on for a marked screenshot; it is drawn by mcv/client/cl_devhud.lua, which also brings it up on its own with `developer 1`" (:305-306) — the dev HUD (centre cross + weapon class, sight amount, sequence, cycle, rate, duration, CurTime readout, cl_devhud.lua:20-50) lives outside the harness precisely so it works without `enable.txt`.

### 8.7 Test suites (a) — timing, clocks, penetration, HUD, cycles

**`mcv_harness/clock_restore_tests.lua`** (33 lines, SV, run-on-include). Verifies `SWEP:OnRestore` (the clock-reset path, cross-ref `docs/animation-system.md` §3.4): gives seven weapon families (`mcv_m16a1, m16a1_m203, m37, mk2, c4, wrench, lpo50` — rifle, GL, pump shotgun, throwable, placeable, melee, flamethrower), pushes ten deadline NetworkVars (`AnimLockTime, NextIdle, HolsterTime, DeferredTime, ActionStart, ActionEnd, NextRepairTime, WindupEnd, HammerReleaseTime, AnimationStart`) plus next-fire, deferred/action/reloading/primed/holster/move command state 10 hours into the future, calls `OnRestore()` **twice** ("repeated restoration must not grant ammo or replay an action", :21), and asserts everything unlocked: input available, no residual action/command state, visual clocks zeroed, all deadlines ≤ now, ammo/firemode/scope/cycle/akimbo/launcher/bayonet unchanged (:22-29). Writes `results/clock_restore.json`.

**`mcv_harness/clock_transition_seed.lua`** (24 lines, SV, port 27016 only). Seeds the clock-transition scenario: strips the player, gives `mcv_m16a1, m37, m16a1_m203`, then after 2 s forces each weapon into a mid-action state (clip 7, alternate firemode, `MCVClockTransitionMarker`, next-fire/lock/idle 10 h out, reloading) and snapshots `clock_map_before.json` (:22-23). This state is then carried across a map change.

**`mcv_harness/clock_transition_watch.lua`** (22 lines, SV, port 27016 only). The far side of the map change: records the `PlayerSpawn` transition flag, then on the first Think with an active weapon dumps every MCV weapon's class/clip/mode/marker/serial/next-fire/lock/deferred/action/reload to `clock_map_<map>.json` and removes itself. Together the two verify clock resets survive map transitions (`GetClockResetSerial`).

**`mcv_harness/hud_transition_tests.lua`** (20 lines, CL). `PostDrawHUD` sampler: every frame records active-weapon class, frame, time, `GetHUDBlend`, `CrosshairReloadAlpha`, holster time, anim lock; weapon switches are captured separately (`switches`). `T.Finish()` removes the hook and writes `hud_transitions.json`. Verifies HUD fade in/out across weapon switches (cross-ref `docs/hud-settings.md`).

**`mcv_harness/penetration_tests.lua`** (107 lines, SV, run-on-include). "Real engine collision/damage integration checks" (:1). Requires an MCV weapon active; wraps it with zero spread and a fixed aim vector; builds `base_anim` boxes with `PhysicsInitBox` + surface materials at a buried test origin. `run(name, layers, aim, pellets)` stacks material layers of given thicknesses in front of a metal target and fires `w:BulletAttack()` with `mcv_bullet_penetration` forced on, tallying damage via an `EntityTakeDamage` hook that also validates attacker/inflictor attribution (:35-40). Cases (:68-99): unobstructed control; 4-unit wood/metal/glass/concrete/plastic each penetrating exactly once with reduced damage; material cost ordering (metal & concrete < wood); thick stops (wood 17/20, metal 8); shallow-angle penetration vs oblique stop; stacked layers losing damage; mixed budget stop (metal 4 + wood 8); **eight pellets with independent budgets** (8 hits, damage exactly 8× single, `DMG_BUCKSHOT` flag); the convar toggle disabling penetration; and `FindPenetrationExit` returning nil through a thick worldspawn floor. Restores convar/wrap state, writes `penetration_engine.json` with failures enumerated.

**`mcv_harness/penetration_multiplier_tests.lua`** (29 lines, SV, port 27016). Requires `mcv_m16a1`; sets the category convars (`MCV.CategoryConVarName` for All / the weapon's category / an unrelated category) through six multiplier combinations and asserts `w:GetPenetrationStats(mat)` equals the weapon's `<Material>PenetrationDepth` × product for all five materials (:10-17). Restores and writes `penetration_multipliers.json`.

**`mcv_harness/penetration_world_tests.lua`** (36 lines, SV, port 27016). The compiled-BSP fixture test: asserts the map is `mcv_penetration_test` (:2), then for three world-geometry cases (4-unit metal penetrates, 20-unit metal stops, two 3-unit metal walls penetrate) fires at world brushes and checks `HitWorld`, hit count vs expected, and that `FindPenetrationExit`'s measured thickness matches the compiled geometry within 0.1 unit ("BSP traces report a padded impact at each face (about 1/32 unit each)", :29-30). Writes `penetration_world.json`.

**`mcv_harness/cycle_timing.lua`** (51 lines, SH). Two halves. `T.Audit()` (:5-21): reads `cycle_manifest.json` (from the driver), loads each listed model as a prop/clientside model and asserts `SequenceDuration` of the listed cycle sequence matches the manifest to 1e-4. `T.Start(ply, tag)` (:23-40) wraps the active (manual-action) weapon's `PlayAnimation` and records every `ACT_VM_RELOAD_INSERT_PULL` — start time, returned duration, command number, first-predicted, model, playback rate, sequence, `GetHammerReleaseTime`, clip. `T.Finish()` (:42-51) restores, dumps `cycle_<tag>_<realm>.json`, and asserts at least one real-input cycle was recorded, `GetNeedCycle()` cleared, and every cycle played at authored speed (`rate == 1`).

**`mcv_harness/type67_timing.lua`** (41 lines, SH). Per-weapon deep probe of the Type 67 revolver's hammer/cycle choreography (included by `work/tests/type67_timing.txt`, :1). `T.Start(ply, tag)` wraps `ThinkWeapon` (records on first-predicted), `FireAnimationEvent` (records `eject`/`eject2` events) and `DoBodygroupsWeapon` (records on the visual pass); each row captures `GetViewModelTime()` (client) or CurTime, sequence, animation start/duration/elapsed, cycle, need-cycle, empty-reload, the `hammerpos` pose parameter, hammer release time, clip and akimbo state (:11-19). `T.Finish()` dumps `type67_<tag>_<realm>.json` with `AnimationHandlesHammer` and `CycleSpeed`.

**`mcv_harness/ricochet.lua`** (81 lines, CL, port 27018). Visual/material probe for the ricochet particle fix (BUGLIST.md:31: "Resolved invisible ricochet sparks… the importer had changed vietnam_sparktrails_1 from its native UnlitGeneric shader to SpriteCard"): `T.Start()` lays out four particle systems side by side 350 units ahead (`mcv_scaled_impact_metal_flying`, `mcv_ricochet`, `mcv_scaled_impact_metal_sparks`, and the stock `Sparks` effect as control), labels them on a HUDPaint overlay, pulses them 20× every 0.7 s, samples validity/render bounds/finished/simulate/owner/control points at 0.01/0.1/0.5 s delays into `ricochet_samples.json`, and records the spark material's shader/error/texture in `ricochet_material.json` (:78-80). `T.Stop()` cleans up. `T.Pulse` is exposed for on-demand re-fire.

**`mcv_harness/worldmodel_contact.lua`** (33 lines, CL, port 27016). "Development-only closeups and hand-relative index-finger measurements" (:1): a CalcView locked onto the player's right hand (drawviewer on), and `C.Record(label)` writes the hand-relative transforms of the right index-finger bones (`ValveBiped.Bip01_R_Finger1/11/12`) for the active weapon — the measurements used to hand-tune worldmodel placement on the gun's hands. `C.Stop()` removes the view hooks.

**`mcv_harness/pvs.lua`** (98 lines, SH, self-gating). The multiplayer PVS diagnostic ("Explicitly loaded multiplayer PVS diagnostic; never loaded by the addon", :1) with its own root `mcv_harness/pvs/`. Server side: `T.Setup()` gods/noclips every human and makes each client re-include the file with cleared state (:41-47); wraps `util.Effect` to log every `mcv_muzzleeffect`/`mcv_shelleffect` dispatch with phase/origin/time (:32-40); `T.Phase(name)` broadcasts a phase label to all clients (:12-17); `T.Flush(label)` saves both realms' data (:48-51). Client side: wraps the two effects' `Init` (weapon class, dormancy, attachment origin), wraps `CreateParticleSystem` for muzzle/flame particles (:54-80), and a 0.2 s timer samples every other player and NPC's active weapon worldmodel (`WM`/`WMLeft` existence, parent link, muzzle attachment world position, flamethrower particle state) (:81-98). `T.Capture(label)` hides the game UI and screenshots per client (:18-29). This is the instrumentation behind BUGLIST.md:201's two-real-client PVS verification.

**`mcv_harness/visual_trace.lua`** (163 lines, CL, self-gating). The per-frame viewmodel recorder. `H.StartVisualTrace(name, capture)` wraps the **weapon instance's** `GetViewModelPosition` (recording before/after each call, plus a prediction-path branch that counts replays and visual-cache frame writes without allocating full records — "keeping combined traces smaller in 32-bit GMod", :87-89), `PreDrawViewModel` (before/after) and `ViewModelDrawn` (the "drawn" record), and `CaptureMovement` (counting first-predicted vs replay calls) (:81-131). Each record (:17-37) captures stage, phase, frame, SysTime, CurTime, UnPredictedCurTime, frame times, prediction state, the raw/visual sight+speed caches and their frame stamps, move command/speed/grounded, the player's `m_nTickBase`, VM sequence/cycle/rate/`m_nAnimationParity`/`m_flAnimTime`/new-sequence and reset-events parities, `GetAnimationStart/Duration`, clip/reserve/reloading/lock, both key pose parameters, and VM pos/ang. On the "drawn" stage it also records local-space transforms of the bones whose names contain bolt/slide/pump ("mechanisms") and a sample of weapon/hand/cam bones (:38-69). `H.StopVisualTrace()` unwraps and writes `results/<name>.visual.json`; if `capture` was set, a `PostRender` hook grabbed up to 600 JPEG frames at 20 fps into `shots/<name>/` (:152-163). Cap: 200 000 records, then drops with a counter (:13).

**`mcv_harness/reload_trace.lua`** (54 lines, CL, self-gating). Reload-focused subset: wraps `PlayAnimation` on the active weapon and records each call's activity, command number, first-predicted, CurTime, frame, VM sequence/cycle/parity/animtime before and after, the returned duration, `GetAnimLockTime` and clip (:13-29); hooks `EntityEmitSound` filtering reload-named sounds from player/weapon/VM (:36-42); optional `third` argument pulls the camera back 110 units to film the third-person reload (:30-35). `H.Stop()` writes `results/<name>.reload.json`.

### 8.8 Asset generators (b)

**`mcv_harness/custom_weapon_assets.lua`** (67 lines, CL, port 27016). "Functional/render asset checks, deliberately separate from prediction regression" (:1). `T.WorldView()`/`T.StopWorldView()` anchor a third-person preview camera on the player origin (:6-16). `T.RecordLens()` writes the PTRD sniper's lens position in eye-relative axes + screen position + bone matrix (:17-27) — hand data for the scope overlay. `T.Check()` snapshots the active weapon's VM/worldmodel materials (asserting none are `___error`), bodygroups, `ShootAnimRate`, and per-class invariants: PTRD sniper must wear the Meopta `crosshair_meopta256` lens material at `RTScopeMaterialIndex`, have the `bulletDisplay` bodygroup, and be bipodded+scoped; XM16Super must keep `ShootAnimRate == 0.5` and the `gl_shoot_deployed` sequence; M635 must use the M601 receiver material and dumps its reload sequence info (:28-59). `T.RecordReload()` samples clip/reload-state/sequence/cycle/cartridge bodygroup over time (:60-67).

**`mcv_harness/icon_assets.lua`** (53 lines, CL, port 27016). "Development-only studio renders of the addon's actual compiled models" (:1): a `PostRender` pipeline that, one entry per frame, renders each of 11 listed worldmodels into the 2048×1024 `mcv_icon_asset_studio` render target with suppressed engine lighting, a three-light studio setup, alpha-write overrides, and a per-entry view offset, saving `icon_asset_<name>_alpha.png` per model (:19-53). These are source renders for spawn-menu icons.

**`mcv_harness/spawn_icons.lua`** (26 lines, CL). Verifies the real ContentIcon panels: creates a DFrame with a ContentContainer and builds `weapon`-type icons for six hand-tuned classes (`mcv_rhogun, cobra, ptrd_sniper, m635, xm16super, swm76`), asserting each icon material exists and is exactly 512×512 (:11-22); writes `spawn_icons.json` and leaves the frame up (global `MCVSpawnIconFrame`) for a screenshot.

**`mcv_harness/scope_buffers.lua`** (41 lines, CL, self-gating). The scope-render pipeline probe: `H.Capture(name)` instruments five render stages (`PreDrawViewModels`, `PreDrawEffects`, `PostDrawEffects`, `PreDrawHUD`, `PostDrawHUD`) plus a wrap of `MCV.CaptureScopeOverlay`, recording the view setup id and active render target per stage; two frames later it screenshots the full screen and dumps three texture contents — the composite `!mcv_scope_overlay_composite_v2`, the `mcv/scope_lens` scene and the saved source `!mcv_scope_overlay_source_v2` — plus a `passes.json` (:6-41). This is the regression harness behind the contact-shadow/scope-overlay rework (BUGLIST.md:6).

**`mcv_harness/pack_split.lua`** (36 lines, SH). Verifies the two-part addon split (Part 1 `mcv` + Part 2 `mcv-2`, AGENTS.md:5-9): reads the driver-supplied `pack_weapons.json`, asserts all **244** weapons are registered, `Spawnable`, `MilitaryConflictVietnam`, with matching country/name metadata and a `weapons/<class>.lua` file; loads every distinct `ViewModel/WorldModel/ViewModelAkimbo/ViewModelRifleGrenade` (ClientsideModel/prop_dynamic per realm) asserting bones exist; client side also asserts every icon material resolves (:5-33). Writes `pack_split_<realm>.json`.

**`mcv_harness/missing_variants.lua`** (42 lines, SH). Verifies the four late-added variants (BUGLIST.md:214: M16A1 XM3/SOG, Kar98 ZF41, StG44 ZF41): `T.Audit()` asserts each class's clip/reserve, `BodyGroups`/`WorldModelBodyGroups` strings, category, spawn-menu listing, and (client) icon + scope reticle materials (:11-28). `T.CheckHeld(ply, checkScope)` verifies the live weapon: every VM bodygroup matches the authored `BodyGroups` digit string, and when scoped, `GetSightAmountVisual() > 0.9`, `RenderingRTScope` active, and the ZF41A crosshair surface on the right material index (:30-42).

### 8.9 Gameplay simulators (c)

**`mcv_harness/npc.lua`** (115 lines, SV). Eight NPC lanes — combine/citizen/metropolice with AKM, M21, M37, Vz.24, Blackhawk, RPG-7, crossbow, M79 — each with a frozen million-HP zombie target 700 units ahead, forced `WEAPON_PROFICIENCY_PERFECT`, hatred + enemy memory set, and `additionalequipment` pre-given (asserted, :46). Wraps each weapon's `NPC_PrimaryAttack` (records clip deltas = real shots) and `NPC_Reload` (call count); clips are pinned to ≤ 2 rounds to force reload behavior (:50-63). Lanes are neutral to each other ("citizens and Combine must not start fighting each other", :68-77). An `EntityTakeDamage` hook accumulates target damage and returns true to prevent gibbing/flinching (:78-85). A Think hook keeps targets frozen and enemies fresh (:86-100). `T.Report(name)` dumps per-lane shots/reloads/damage/clip/hold type/schedule/activity/enemy/alive plus `#MCV.GetNPCWeapons()` to `results/<name>.json` (:103-115). `T.Clear()` removes hooks/entities.

**`mcv_harness/npc_cadence.lua`** (133 lines, SV). The contract test for §2.2: `T.Audit()` (§2.4) plus `T.Start()`/`T.Finish()` — six frozen NPCs driven by **direct `NPC_PrimaryAttack` calls every Think** (clip pinned to 200, firerate StatMult flattened to 1) and two lanes running native AI against a live target across proficiency 0 and 4 (:61-97). `T.Finish()` computes each lane's minimum inter-shot interval and asserts it never undercuts the promised `GetNPCShotInterval()` (with 1e-5 tolerance), ≥ 3 shots, writing `npc_cadence_runtime.json` and asserting overall pass (:116-133).

**`mcv_harness/npc_models.lua`** (52 lines, SH). Worldmodel-in-hand inspection: server `T.Spawn(class)` creates a frozen combine with `additionalequipment` and publishes it via `SetGlobalEntity("MCVModelTestNPC", npc)` (:5-16); client `T.View(npc)` mounts a CalcView on the NPC's (or local player's) right-hand bone with `ShouldDrawLocalPlayer` managed (:19-35); `T.Report(label)` computes the gun's `MCV.weapon_bone`/`ValveBiped.weapon_bone` and `muzzle` attachment transforms relative to the hand bone and dumps them with model/bodygroup info (:36-48). Used for the worldmodel rig fixes (BUGLIST.md:222 "M1 Garand / M1D and both flamethrowers were sideways or displaced in players' and NPCs' hands").

**`mcv_harness/random_weapons.lua`** (113 lines, SH). The random-pool audit: `T.Audit(ply)` (SV) checks every group's counts against `GetRandomWeaponChoices`, no invalid/duplicate entries, NPC subsets valid, every theme member class registered, and a set of semantic invariants — homemade pool = 6, US-WW2 contains the M1 Garand but not the M16A1/M635, Russia contains AKM + M91, the L1A1 in gb/au/be (both normal and NPC pools), Australia remains the L1A1's displayed `Country`, the SLR stays out of the GB-WW2 pool, every country addition present, and the flag choices (`de_imperial`, `de`, `su`) (:12-55). `T.SpawnNPC(ply, key, explicit)` runs sandbox's `Spawn_NPC` with a `!mcv|random:` selection (or an explicit class) and asserts the spawned NPC's weapon is inside the pool / is the explicit override (:56-69). Client side `T.Open(misc)` opens the spawn menu, walks the MCV tree node, optionally descends into the Miscellaneous tab (`MCVRandomMisc`), collects every `mcv_random_weapon` icon and asserts their materials load and > 10 groups exist (:71-98); `T.SelectNPC(key)` opens an icon's context menu, finds "Use for NPCs" and clicks it (:99-112).

**`mcv_harness/garand_m21.lua`** (48 lines, CL). Garand/M21 worldmodel + render checks: `T.WorldView()` third-person side view; `T.WorldReport(label)` dumps the worldmodel gun bone's hand-relative matrix (4×4 fields) (:16-26); `T.StartRender(label)` hooks `PostDrawViewModel` and records per-frame sequence, cycle, `empty` pose parameter, clip, reloading and the `BaseRoot/Base/hand_r/hand_l/Bolt` bone positions (:27-43); `T.StopRender()` writes `<label>_render.json`.

**`mcv_harness/bolt.lua`** (251 lines, SH). The crossbow-bolt projectile regression (BUGLIST.md:216: "Crossbow bolts stopped mid-flight and fell in steps because their angle updates reset VPhysics velocity… Impacts use the incoming direction and the compiled model's 20-unit tip offset, retire flight physics, and follow moving props"). Client half: `T.Model()` computes the posed bolt mesh bounds from `util.GetModelMeshes` and asserts the tip calibration `hi.x == 20.03 ± 0.05` (:6-27); `T.View(name)` finds a tagged stuck bolt and frames it in a CalcView (:28-37); `T.WatchFlight()` attaches a RenderOverride to the "free" bolt, measuring per-draw movement-vs-facing alignment (dot > 0.99 required) (:38-66); `T.CheckClient(label)` asserts ≥ 10 movement samples and writes `bolt_render_<label>.json` (:67-73). Server half: `T.Baseline()`/`T.FinishBaseline()` fly two bolts, one deliberately reproducing "the original velocity-reset bug on this test bolt only" (:77-109); `T.Start(ply, label)` launches five controlled bolts — free flight, ground impact, oblique 45° impact, a stationary prop hit and a "moving_prop" case (the prop is then teleported+rotated to verify the stuck bolt follows its parent within 0.02 units), and a frozen combine "body" case asserting exactly one damage event — plus a real `mcv_crossbow:LaunchProjectile` shot with `RandomSpread` zeroed (:111-194); a `SetupPlayerVisibility` hook adds all test entities to the PVS (:182-184). `T.Check()` validates each case: free flight keeps ≥ 90% velocity and no velocity "turns" (dot-product flips from the old angle-reset bug), body impacts apply exactly one damaging hit, world/prop impacts leave a `MOVETYPE_NONE` parented bolt aligned within 0.999 with tip error < 0.02 units (:196-236). `T.Cleanup(ply)` asserts the ground bolt stayed still across the whole test and still returns ammo on `Use` (:238-251).

**`mcv_harness/deploy_layers.lua`** (85 lines, CL). The deploy-animation movement-contamination probe (cross-ref `docs/animation-system.md` §7.1): a coroutine processes nine viewmodels (ak47, sks, m203, m21, dual_m1911, m635, xm16super, ptrd41_s, lpo50); for each it samples every draw/ready activity (`ACT_VM_DRAW*`, `ACT_VM_READY`, `ACT_VM_READY_M203`, `ACT_VM_EMPTY_DRAW`) at cycles 0.2/0.5/0.8 with `player_movement` at both pose-range extremes and asserts the worst bone-position difference is < 0.001 — movement must not leak into deploy poses; the `idle` sequence is the positive control and **must** still move (> 0.01) (:6-73). The coroutine yields across frames and a 0.3 s timer also lets "the sequence's ordinary 0.2-second transition settle; otherwise changing sequence between samples measures the previous animation's fade" (:75-77). Writes `deploy_layers_runtime.json`.

### 8.10 Convars and commands the harness touches

The harness itself registers **no convars** — the only gates are the `enable.txt` marker and `-port`. It *manipulates* existing ones: `mcv_bullet_penetration` (penetration_tests.lua:8,69,93-95), the `mcv_cat_<category>_<stat>` sliders (penetration_multiplier_tests.lua:5-8), `cl_drawhud` (hud command), `gmod_npcweapon` (via random-weapon tests), and reads `hostport` everywhere for its root path. The one concommand it depends on is the addon's own `mcv_random_weapon` (sh_random_weapons.lua:161). The dev readout is tied to the stock `developer` cvar (cl_devhud.lua:10-16) or `H.Marker`.

### 8.11 Anatomy of a job, end to end

A concrete run looks like this (all commands from §8.2; this is exactly the shape `work/tests/*.txt` scripts use — cf. type67_timing.lua:1):

```text
# data/mcv_harness/queue/01_give.txt — picked up within 0.1 s, one command per tick
give mcv_akm
wait 1
report akm_deployed
key +attack2
wait 0.5
report akm_sighted
shot akm_sighted marker
ptrace start akm_fire
tap +attack 0.1
wait 1
ptrace stop
lua include("mcv_harness/clock_restore_tests.lua")
quit
```

What happens: the `MCV_Harness` timer (:548-551) picks the file, deletes it and logs `job 01_give 13 commands`; `give` selects the weapon and sleeps 0.3 s; `key +attack2` holds the sight key down through the following reports; `report` writes `results/akm_deployed.server.json`, asks the client to write `akm_deployed.client.json` and blocks on its done marker; `shot … marker` turns on the dev readout and captures a PNG after two frames; `ptrace start/stop` wraps the weapon instance and emits both realm JSONs for `work/ptrace_diff.py`; the `lua` include runs a self-asserting module; `quit` finishes the job (`results/01_give.json` + `.done.txt`) and closes the game so the Python driver can start the next instance/port. The driver detects readiness through `ready.txt`/`client_ready.txt` (:299-301, :553-556) and success through the `.done.txt` markers plus the asserted JSONs.

## 9. Translation-Layer Surface

### 9.1 Ranked: harness tools that can verify converted weapons

1. **`report` + `H.WeaponState`** (autorun/sh_mcv_harness.lua:66-144). The cheapest, highest-value check. It already gates every MCV-specific field behind `wep.MilitaryConflictVietnam` (:80), so a converted weapon that sets that flag immediately gets client+server JSON dumps of sight state, firemode, action state, holster/idle/lock countdowns, VM sequence/activity/cycle/rate, pose parameters, bodygroups, and the sight-alignment screen projections (`t.vm.axis` should land on screen centre when sighted). Run `report before`, aim, `report after`, diff the two JSONs.
2. **`ptrace`** (§8.4). The strongest prediction verifier for converted weapons, provided the translation layer preserves: the NetworkVar accessor names (`GetNetworkVars` is walked generically), `ActiveTimers`, `GetHoldType`, `GetWeaponMovement` (speed/grounded/crouch triple), and the instance methods `Think/PrimaryAttack/SecondaryAttack/Reload/CaptureMovement` — the wrapper only needs those to exist as functions. `work/ptrace_diff.py` then compares realms by command/entity/hook.
3. **`visual_trace`** (§8.7). Directly measures what the translation layer exists to fix: VM sequence/cycle/parity per frame, animation start/duration from the weapon, sight/speed visual-cache frame discipline (it counts cache writes during prediction replays), and mechanism bone motion (bolt/slide/pump). Run it over a full fire/reload/sprint cycle of a converted weapon and compare against an MCV native of the same archetype.
4. **`reload_trace`** (§8.7). Wraps `PlayAnimation` — so it works on any weapon whose translation layer routes animation through MCV's `PlayAnimation` — and records sequence selection, lock times, and reload sound emission. Ideal for verifying converted reload choreography (cross-ref `docs/reload-ammo.md`).
5. **`cycle_timing`** (§8.7). For any converted manual-action weapon: asserts cycles happen through real input, complete (`NeedCycle` cleared), and play at authored rate (`rate == 1`). Requires `PlayCycleAnimation`, `GetHammerReleaseTime`, `GetActionStart`.
6. **`clock_restore_tests`** (§8.7). Include-and-run against a converted weapon: pushes every deadline NetworkVar into the future and verifies `OnRestore` clears them without side effects. Works only if the translation layer keeps the `Set<Name>`/`Get<Name>` accessors — which it must anyway for MCV's own think code.
7. **`penetration_tests` / `_multiplier_tests` / `_world_tests`** (§8.7). For converted hitscan weapons: only need `BulletAttack`, `FindPenetrationExit`, `GetPenetrationStats`, `Num`, `GetSpread`, `GetAimVector` — i.e., the weapon must route damage through MCV's fire path (cross-ref `docs/shooting-ballistics.md`).
8. **`npc` / `npc_cadence` / `npc_models`** (§8.9). NPC verification of converted weapons — cadence is asserted numerically, so a converted semi-auto that ignores `GetNPCShotInterval` fails loudly. `npc_models` verifies worldmodel-in-hand placement.
9. **`pack_split` / `missing_variants` / `random_weapons` audits** (§8.8-8.9). Metadata lint for converted classes: registration, `Spawnable`/`NPCUsable`/`MilitaryConflictVietnam` flags, model files load with bones, icons exist, pool membership correct.
10. **`bolt`** (§8.9) for converted projectile weapons (pattern reusable beyond `mcv_proj_bolt`: tag entities, sample flight alignment, assert single-damage impacts), **`hud_transition_tests`** for HUD blend hygiene, **`deploy_layers`** for viewmodels whose draw sequences must not inherit movement (exactly the failure mode of foreign-base models played on MCV's pose-parameter engine), and **`scope_buffers`** for scoped conversions.

### 9.2 What the translation layer must expose for harness validation

- `SWEP.MilitaryConflictVietnam = true` — the single flag that arms the MCV-specific half of `WeaponState`, the ptrace follow (`wep.MilitaryConflictVietnam` check at sh_mcv_harness.lua:258), NPC registration and random pools.
- The NetworkVar getter names enumerated in §8.3/§8.4 (`GetIronsight`, `GetSighted`, `GetSightAmount`, `GetSpeed`, `GetFiremodeName` (or the firemode value), `GetActionState`, `GetAkimbo`, `GetGrenadeLauncher`, `GetBayonet`, `GetBipod`, `GetHolsterTime`, `GetNextIdle`, `GetAnimLockTime`, `GetHoldType`, plus the deadline setters used by clock_restore_tests).
- `PlayAnimation` as the single choke point **returning the duration** (reload_trace/cycle_timing consume the return value; cross-ref `docs/animation-system.md` §2).
- Instance methods `Think`, `PrimaryAttack`, `SecondaryAttack`, `Reload`, `CaptureMovement` (ptrace wraps them on the instance).
- `ActiveTimers` (sh_timers) and `GetWeaponMovement()`; `StatMult`; the `ViewModel` field for model-keyed gates like `MCV.SafeMovementModels`.
- For foreign models in the safe-movement path: either add their `ViewModel` paths to an extension of `MCV.SafeMovementModels` or set `SWEP.SafeMovementAnimations` — otherwise at-ease movement is clamped to pose 86 (§5.2), which is the correct conservative default.

### 9.3 A ready-made smoke-test queue for a converted weapon

Drop this in `data/mcv_harness/queue/` (with `enable.txt` present, launched via `work/harness.py`, ideally `-port 27016` to match the pinned-port modules) — it exercises every generic probe against one converted class:

```text
# <class> = the converted SWEP's class name
give <class>
wait 1
report conv_deploy
ptrace start conv_fire
tap +attack 0.1
wait 0.5
ptrace stop
tap +attack2 0.3          # sight in (or whatever the host base used)
wait 1
report conv_sighted
shot conv_sighted marker   # bore-axis dot should sit on screen centre
tap +attack 0.1
wait 1
key +reload
wait 2.5
report conv_reloaded
lua include("mcv_harness/clock_restore_tests.lua")   # asserts OnRestore clears deadlines
quit
```

Then diff `results/conv_deploy.client.json` vs `.server.json` and the `conv_fire.ptrace.*.json` pair, and re-run with a native MCV weapon of the same archetype as the reference. For deeper per-frame verification add `clua include("mcv_harness/visual_trace.lua") MCV.VisualHarness.StartVisualTrace("conv", true)` before the action and `…StopVisualTrace()` after (§8.7); for reload choreography the same pattern with `reload_trace.lua` (§8.7).

## 10. File Map

| File (under `reference/mcv/lua/`) | Lines | Contents |
|---|---|---|
| `autorun/sh_mcv_load.lua` | 43 | addon loader: convars first, shared/client/server in name order |
| `autorun/sh_mcv_harness.lua` | 558 | harness entry: gate, dirs, WeaponState, ptrace, client capture, server queue |
| `mcv/shared/sh_common.lua` | 175 | firemode enums, sound channels, hitgroup multipliers, ammo types, 23 shell types |
| `mcv/shared/sh_npc.lua` | 78 | NPC weapon list/menus, `!mcv|` selection protocol on PlayerSpawnedNPC |
| `mcv/shared/sh_burn.lua` | 79 | `MCV.Burn`/`Extinguish`/`IsBurning`, 0.25 s DMG_BURN tick loop |
| `mcv/shared/sh_safe_movement.lua` | 231 | generated at-ease movement whitelist (228 viewmodel paths) |
| `mcv/shared/sh_modelcache.lua` | 54 | cached attachment/bone/sequence lookup + loop flags (anim doc §6) |
| `mcv/shared/sh_random_weapons.lua` | 165 | pool definitions, catalog/matching, spawn concommand |
| `mcv/client/cl_modelgc.lua` | 60 | clientside-model tracker: WM/WMLeft/ScopeOverlayModel/Ghost lifecycle |
| `mcv/client/cl_random_weapons.lua` | 63 | `mcv_random_weapon` content type, misc-tab population |
| `mcv/client/cl_devhud.lua` | 50 | developer readout (centre cross + anim state), `developer 1` or harness marker |
| `mcv_harness/clock_restore_tests.lua` | 33 | OnRestore clock-reset assertions over 7 weapon families |
| `mcv_harness/clock_transition_seed.lua` | 24 | seeds mid-action weapon state before a map change |
| `mcv_harness/clock_transition_watch.lua` | 22 | dumps weapon clock state after the map change |
| `mcv_harness/hud_transition_tests.lua` | 20 | HUD blend sampling across weapon switches |
| `mcv_harness/penetration_tests.lua` | 107 | engine-level penetration matrix (materials, angles, stacking, pellets) |
| `mcv_harness/penetration_multiplier_tests.lua` | 29 | category convar × penetration depth product |
| `mcv_harness/penetration_world_tests.lua` | 36 | BSP-fixture world penetration + exit-thickness measurement |
| `mcv_harness/cycle_timing.lua` | 51 | cycle sequence durations + live insert-cycle recording |
| `mcv_harness/type67_timing.lua` | 41 | Type 67 hammer/eject/bodygroup choreography probe |
| `mcv_harness/ricochet.lua` | 81 | ricochet particle/material visibility probe |
| `mcv_harness/worldmodel_contact.lua` | 33 | hand-relative finger-bone measurements for worldmodel tuning |
| `mcv_harness/pvs.lua` | 98 | multiplayer PVS effect/worldmodel sampler |
| `mcv_harness/visual_trace.lua` | 163 | per-frame VM/prediction recorder with optional JPEG capture |
| `mcv_harness/reload_trace.lua` | 54 | PlayAnimation + reload-sound recorder |
| `mcv_harness/custom_weapon_assets.lua` | 67 | material/lens/reload asset assertions for custom weapons |
| `mcv_harness/icon_assets.lua` | 53 | studio PNG renders of 11 worldmodels |
| `mcv_harness/spawn_icons.lua` | 26 | ContentIcon panel + 512² icon verification |
| `mcv_harness/scope_buffers.lua` | 41 | scope overlay render-stage/texture dump |
| `mcv_harness/pack_split.lua` | 36 | two-part addon integrity: 244 weapons, models, icons |
| `mcv_harness/missing_variants.lua` | 42 | ZF41/XM3/SOG variant metadata + live scoped checks |
| `mcv_harness/npc.lua` | 115 | 8-lane NPC combat/reload simulator |
| `mcv_harness/npc_cadence.lua` | 133 | NPC fire-cadence contract test + runtime enforcement |
| `mcv_harness/npc_models.lua` | 52 | NPC worldmodel-in-hand camera + transform report |
| `mcv_harness/random_weapons.lua` | 113 | random pool audit + spawn-menu/NPC-menu UI test |
| `mcv_harness/garand_m21.lua` | 48 | Garand/M21 worldmodel + render trace |
| `mcv_harness/bolt.lua` | 251 | crossbow bolt flight/impact/pickup regression |
| `mcv_harness/deploy_layers.lua` | 85 | deploy-pose movement-contamination probe |

Related upstream notes: `reference/mcv/AGENTS.md` / `CLAUDE.md` (identical; convar/menu house rules, two-part split), `BUGLIST.md` (harness-verified fixes cited above), `weapon_list.md` (the 244-class catalogue `pack_split` audits against).
