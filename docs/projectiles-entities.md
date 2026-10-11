# MCV Base — Projectiles & Entities (Exhaustive Audit)

This document exhaustively audits every scripted entity under `lua/entities/` in the MCV (Military Conflict Vietnam) weapon base: the projectile base family (`mcv_proj_*`), the grenade family (`mcv_grenade_*`), the placed explosives (`mcv_placed_*`, `mcv_mine_stake`), the thrown-melee entity, and the area-denial fire pool. The purpose, as with `docs/animation-system.md`, is engineering reference for the translation layer: SWEPs written for other bases must be able to run their rockets, grenades, mines and thrown weapons on MCV's entity machinery. Every behavioral claim cites `path/file.lua:LINE` relative to `reference/mcv/lua/`. Realm (SH/CL/SV) and prediction status are treated as first-class facts.

The single most important architectural fact, stated up front (upstream's own words):

> "A projectile's basic numbers, explosion damage, explosion radius and launch speed, belong to the weapon that fires it, not to the entity: the entity has no category for a multiplier to reach. The entity keeps them as defaults and `LaunchProjectile` overrides and scales them, the way the thrown grenades and planted charges already work." — `AGENTS.md:42-46` (identical in `CLAUDE.md:42-46`)

A converter therefore has two jobs: pick/derive an entity class, and compute the field overrides the spawning weapon injects before `Spawn()`.

---

## 1. Architecture Overview

### 1.1 Entity family tree

All entities live in `entities/`. Every projectile derives (directly or transitively) from `mcv_proj_base`, which derives from `base_entity`. Two support entities derive from `base_anim` instead. `mcv_supply_box` (spawned by the equipment-box weapon, `weapons/mcv_equipment_box/sh_box.lua:159`) is a logistics entity outside this audit's scope — see `docs/special-weapon-bases.md`.

```
base_entity
└── mcv_proj_base                      entities/mcv_proj_base.lua (464 lines, THE base)
    ├── mcv_proj_40mm                  40mm grenades (M79 / GP-25 UBGL)
    │   └── mcv_proj_lunge_mine        Lunge Mine contact charge
    ├── mcv_proj_rpg                   RPG-7 rocket (IsRocket = true, sphere phys)
    │   ├── mcv_proj_bazooka           M9 Bazooka rocket
    │   ├── mcv_proj_kolos             Kolos volley rocket
    │   └── mcv_proj_panzerschreck     Panzerschreck rocket
    ├── mcv_proj_rpg2                  RPG-2 rocket
    ├── mcv_proj_m202                  M202 rocket (post-detonation burn)
    ├── mcv_proj_bolt                  Crossbow bolt (sticks, retrievable)
    ├── mcv_proj_flare                 US flare (M8, Part 2)
    │   └── mcv_proj_flare_vc          VC flare (Type 97)
    ├── mcv_proj_riflegrenade          US rifle grenade (base default)
    │   └── mcv_proj_riflegrenade_ger  German rifle grenade (via the VC class!)
    ├── mcv_proj_riflegrenade_vc       VC rifle grenade
    ├── mcv_thrown_melee               Thrown blade (machete)
    └── mcv_grenade_base               Hand grenades & placed explosives
        ├── mcv_grenade_frag           Fragmentation (all frag throwables)
        ├── mcv_grenade_molotov        Molotov (impact-fused, fire pool)
        ├── mcv_grenade_smoke          Smoke canister (pops, does not remove)
        │   └── mcv_grenade_gas        Gas canister (damaging smoke)
        ├── mcv_grenade_wp             White phosphorus (short fire pool)
        ├── mcv_placed_c4              C4 charge (remote fuse)
        ├── mcv_placed_dynamite        Dynamite (lit 6 s fuse)
        └── mcv_placed_mine            Tripwire mine

base_anim
├── mcv_mine_stake                     Tripwire stake (pairs with mcv_placed_mine)
└── mcv_firepool                       Burning ground (molotov / WP / incendiary)
```

Inheritance is verified from each file's `ENT.Base` line: `entities/mcv_proj_lunge_mine.lua:2`, `entities/mcv_proj_bazooka.lua:3`, `entities/mcv_proj_kolos.lua:3`, `entities/mcv_proj_panzerschreck.lua:3`, `entities/mcv_proj_riflegrenade_ger.lua:3` (→ `mcv_proj_riflegrenade_vc`, not the US class), `entities/mcv_grenade_gas.lua:3` (→ `mcv_grenade_smoke`), `entities/mcv_placed_c4.lua:3` / `mcv_placed_dynamite.lua:3` / `mcv_placed_mine.lua:3` (→ `mcv_grenade_base`), `entities/mcv_thrown_melee.lua:3` (→ `mcv_proj_base` directly).

Note that `mcv_proj_bazooka`/`_kolos`/`_panzerschreck` inherit from **`mcv_proj_rpg`**, not from `mcv_proj_base` — they inherit `IsRocket = true` and `CollisionSphere = 2` (`entities/mcv_proj_rpg.lua:9-10`) for free.

### 1.2 Spawn entry points — which weapon base creates which entity

Entities are never spawned by map or console (all have `ENT.Spawnable = false`); six weapon-side factories create them. Every one gates `ents.Create` behind `if CLIENT then return end` — **all entity creation is server-only**:

| Factory (weapon file) | Weapon base | Field read | Default entity | Part 1 users |
|---|---|---|---|---|
| `SWEP:LaunchProjectile` — `weapons/mcv_base/sh_shoot.lua:658-711` (via `RocketAttack` :643-656) | `mcv_base` (all guns) | `ShootEntity` / `RifleGrenadeEntity` (secondary) | `mcv_proj_riflegrenade` (`weapons/mcv_base/shared.lua:158`) | RPG-7 & RPG-2 (`mcv_proj_rpg`), Kolos, crossbow (`mcv_proj_bolt`), Type 97 flare gun (`mcv_proj_flare_vc`), 14 rifles' secondary (`mcv_proj_riflegrenade_vc`), GP-25 AKM (`mcv_proj_40mm`) |
| `SWEP:LaunchThrowable` — `weapons/mcv_throwable/sh_throw.lua:155-239` | `mcv_throwable` | `ThrowEntity` | `mcv_grenade_frag` (`weapons/mcv_throwable/shared.lua:20`) | all frag grenades, CSS smoke (`mcv_grenade_smoke`); Part 2 adds molotov/WP/gas/Nebelhandgranate |
| `SWEP:SpawnPlaced` / `SpawnStake` / `Deferred_ThrowLit` — `weapons/mcv_placeable/sh_place.lua:178-202, 204-224, 245-266` | `mcv_placeable` | `PlacedEntityClass` / `StakeEntityClass` | `mcv_placed_c4` + `mcv_mine_stake` (`weapons/mcv_placeable/shared.lua:19-20`) | C4, dynamite (thrown-lit), RG42/OZM-4 + M16 mine (`mcv_placed_mine`) |
| `SWEP:LaunchBlade` — `weapons/mcv_melee/sh_melee.lua:217-253` | `mcv_melee` | `ThrownEntity` | `mcv_thrown_melee` (`weapons/mcv_melee/shared.lua:36`) | thrown machete |
| `SWEP:CreateMine` — `weapons/mcv_lunge_mine.lua:42-56` | `mcv_melee` subclass | `ThrownEntity` | `mcv_proj_lunge_mine` (`weapons/mcv_lunge_mine.lua:24`) | lunge mine (contact detonation or launch) |
| `SWEP:Deferred_BoxDrop` — `weapons/mcv_equipment_box/sh_box.lua:153-173` | `mcv_equipment_box` | `DroppedEntity` | `mcv_supply_box` (out of scope) | medic/ammo boxes |

Entities defined here but with **no weapon in this repo** referencing them are consumed by the sibling Part 2 pack (Western content; `AGENTS.md:5-9`): `mcv_proj_flare` (M8 Flaregun `mcv_m8`), `mcv_proj_bazooka`, `mcv_proj_panzerschreck`, `mcv_proj_m202`, `mcv_proj_rpg2` (the Part 1 `mcv_rpg2` weapon actually fires `mcv_proj_rpg` — `weapons/mcv_rpg2.lua:37`), `mcv_proj_riflegrenade_ger`, `mcv_grenade_molotov` (`mcv_molotov`), `mcv_grenade_wp` (`mcv_m34`), `mcv_grenade_gas` (M6A1). Part 2 weapon names verified against `weapon_list.md:148,152,234`. (Grep of `ThrowEntity|PlacedEntityClass|ShootEntity|...` across `reference/mcv/lua/weapons` returned no hits for these classes — see §9.)

### 1.3 Realm split and prediction status

- **Entity creation is server-only.** Prediction is entirely a *weapon-side* concern: the throwing/placing/firing stages run in the predicted SWEP through deferred actions stored in NetworkVars (`BUGLIST.md:326`), and only the final server-side stage calls `ents.Create`. Cross-ref `docs/animation-system.md` §3.5 (Deferred actions — `mcv/weapon_common/sh_timers.lua`). A newly created server entity has no client-predictable handle, which is why the placeable base keeps the mine reference in an NWEntity outside the predicted datatable (`weapons/mcv_placeable/sh_place.lua:8-12`, `BUGLIST.md:330`).
- **Client-side entity code is render/audio only**: `Draw`/`DrawTranslucent`, trail particle start, smoke cloud particles, flare dynamic light. All damage, fuses, detonation and movement logic is server-side; the client's `Think` copies run the same shared code but their gameplay branches are gated (e.g. `PreDetonate` returns on `CLIENT` — `entities/mcv_proj_base.lua:426`).
- **Plain Lua fields do not network.** `Armed`, `ArmTime`, `Delay`, `Detonated`, `ExplosionDamage`, etc. exist only in the server's Lua state. Clients never learn a projectile's fuse state; there is no client-side countdown. The only replicated entity state is the data-table section below.
- NPCs fire projectiles through the same `RocketAttack`/`LaunchProjectile` path (`weapons/mcv_base/sh_npc.lua:151-157`), with the aim direction replaced by the vector to the enemy's `WorldSpaceCenter()`.

### 1.4 Networked fields (data tables)

`mcv_proj_base` declares the family's slots (`entities/mcv_proj_base.lua:60-63`):

```lua
-- entities/mcv_proj_base.lua:60-63
function ENT:SetupDataTables()
    self:NetworkVar("Entity", 0, "Weapon")
    self:NetworkVar("Entity", 1, "Planter") // who planted a charge (its owner is cleared once planted)
end
```

| Slot | Type | Accessor | Set by | Consumed by |
|---|---|---|---|---|
| Entity 0 | Entity | `GetWeapon`/`SetWeapon` | `LaunchProjectile` (`sh_shoot.lua:693-695`), lunge mine (`mcv_lunge_mine.lua:52`) | bolt damage inflictor (`entities/mcv_proj_bolt.lua:73-76`) |
| Entity 1 | Entity | `GetPlanter`/`SetPlanter` | `ReleaseOwner` (`mcv_proj_base.lua:72`) | C4 pickup (`mcv_placed_c4.lua:52`), detonator scan (`sh_place.lua:273`), stake init (`mcv_mine_stake.lua:26`) |
| Bool 0 / Bool 1 / Vector 0 | smoke only | `GetPopped`/`SetPopped`, `GetStopped`/`SetStopped`, `GetSmokeColorVec`/`SetSmokeColorVec` | smoke `Detonate`/`OnThink` (`entities/mcv_grenade_smoke.lua:22-29, 33-37, 78-81`) | smoke/gas client particles (`mcv_grenade_smoke.lua:51-73`) |
| Entity 2 | mine only | `GetStake`/`SetStake` | `SetStakeEntity` (`entities/mcv_placed_mine.lua:43-48`) | wire trace + render (`mcv_placed_mine.lua:67-82, 107-113`) |
| Entity 0 (stake's own table) | Entity | `GetPlanter`/`SetPlanter` | stake `Initialize` (`entities/mcv_mine_stake.lua:11-13, 25-28`) | (currently unread; kept symmetric with charges) |

**Gotcha (documented upstream):** subclasses adding NetworkVars must call the *root* table setup via `baseclass.Get("mcv_proj_base").SetupDataTables(self)` — using `self.BaseClass` recurses on intermediate classes and the table is never created (the gas grenade crashed for lack of `GetPopped` before this fix; `entities/mcv_grenade_smoke.lua:23-25`, `BUGLIST.md:368`).

### 1.5 The weapon→entity parameter injection contract

Every factory follows the same ordering: `ents.Create` → **set plain fields on the entity** → `SetPos`/`SetAngles`/`SetOwner` → `Spawn()` → `Activate()` → physics velocity. Fields read inside `Initialize` (notably `Model`, `ModelSkin`, `Material`, physics shape fields) **must** be set before `Spawn()`; fields read at detonation time (`Delay`, `ExplosionDamage`, `IgniteRadius`, …) can be set any time before they are consumed. The exact injection lists are tabulated in §2.1 and §8.2.

---

## 2. `mcv_proj_base` Deep-Dive

`entities/mcv_proj_base.lua` — 464 lines. `ENT.Type = "anim"`, `ENT.Base = "base_entity"`, `ENT.RenderGroup = RENDERGROUP_TRANSLUCENT` (lines 3-5), so the engine calls `DrawTranslucent`, which forwards to `Draw` (line 448-450). `AddCSLuaFile()` at line 1; the whole file is shared-realm.

### 2.1 Field catalogue (class-level defaults)

| Field | Default | Where consumed | Meaning |
|---|---|---|---|
| `Model` | `""` | `Initialize`:91 | model path; overridden pre-Spawn by weapons (`ent.Model = self.ThrowModel or self.WorldModel`, `sh_throw.lua:196`) |
| `Material` | `false` | `Initialize`:93 | custom material override |
| `ModelSkin` | (nil) | `Initialize`:92 | `$skin`; gas grenade uses 7 (`mcv_grenade_gas.lua:8`) |
| `IsRocket` | `false` | `Initialize`:114-116 | disables gravity on the physics object |
| `Sticky` | `false` | `PhysicsCollide`:249-273 | stick to first hit surface/entity |
| `StickyPlace` | `true` | commented out :253-255 | (dead) adopt surface normal |
| `InstantFuse` | `true` | `Initialize`:128-131 | armed at spawn |
| `TimeFuse` | `false` | `Think`:391-394 | seconds after spawn to arm (`false`/`nil` = never; a *number* — including 0 — arms) |
| `RemoteFuse` | `false` | detonator scan `sh_place.lua:273` | eligible for remote detonation (only C4 sets true) |
| `ImpactFuse` | `false` | `PhysicsCollide`:225-235 | arm on first collision |
| `StickyFuse` | `false` | `PhysicsCollide`:268-271 | arm when stuck (unused by any current entity — live hook) |
| `RemoveOnImpact` | `false` | — | **never read anywhere** (vestigial) |
| `ExplodeOnImpact` | `false` | `PhysicsCollide`:233 | detonate on the arming collision |
| `ExplodeOnDamage` | `false` | `OnTakeDamage`:187-190 | detonate when damaged |
| `ExplodeUnderwater` | `false` | `Think`:400-402 | detonate when `WaterLevel() > 0` |
| `Defusable` | `false` | `Initialize`:99-101, `Use`:411 | E-to-pickup enabled (`SIMPLE_USE`) |
| `DefuseOnDamage` | `false` | `OnTakeDamage`:191-200 | destroyed (sparks) by non-blast damage (unused — live hook) |
| `ImpactDamage` | `25` | `PhysicsCollide`:236-244 | max collision damage |
| `ImpactDamageSpeed` | `1000` | `PhysicsCollide`:240 | speed at which full `ImpactDamage` applies (ramp starts at 60%) |
| `Delay` | `5` | `Think`:396-398 | seconds from arming to detonation (grenade fuse; set per-throw by the weapon) |
| `Armed` | `false` | fuse logic | runtime state |
| `SmokeTrail` | `false` | `DoSmokeTrail`:299 | legacy sprite emitter (all current entities leave it off) |
| `TrailParticle` | `nil` | `StartTrail`:142-146 | game particle system attached `PATTACH_ABSORIGIN_FOLLOW` |
| `FlareColor` / `FlareSizeMin/Max` | `nil` / 200 / 250 | `Draw`:460-463 | additive sprite behind the projectile (no current entity sets it — live hook) |
| `AudioLoop` | `nil` | `Initialize`:123-126 | `CreateSound` loop started at spawn (no current entity sets it — live hook) |
| `BounceSounds` | `nil` | `PhysicsCollide`:284-289 | sound list; entries may be `{name, ...}` tables |
| `CollisionSphere` | `nil` | `InitProjectilePhysics`:78-79 | physics sphere radius |
| `FallbackRadius` | (nil→2) | `InitProjectilePhysics`:84 | sphere when the model has no `.phy` |
| `GunshipWorkaround` | `true` | — | **never read anywhere** (vestigial; presumably historic helicopter filter) |
| `PickupAmmo` | (nil) | `Use`:413-415 | ammo type given when defused/picked up |
| `SpawnTime`/`ArmTime`/`Attacker`/`Inflictor`/`Detonated` | runtime | throughout | set in `Initialize`/by weapons |

### 2.2 `Initialize` and physics setup (SH entry, SV-heavy)

```lua
-- entities/mcv_proj_base.lua:89-117
function ENT:Initialize()
    if SERVER then
        self:SetModel(self.Model)
        if self.ModelSkin != nil then self:SetSkin(self.ModelSkin) end
        self:SetMaterial(self.Material or "")
        self:InitProjectilePhysics()
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)

        self:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
        if self.Defusable then
            self:SetUseType(SIMPLE_USE)
        end

        local phys = self:GetPhysicsObject()
        if !IsValid(phys) then
            self:Remove()
            return
        end

        phys:EnableDrag(false)
        phys:SetDragCoefficient(0)
        phys:SetBuoyancyRatio(0)
        phys:Wake()

        if self.IsRocket then
            phys:EnableGravity(false)
        end
    end
```

Physics profile: VPhysics motion, **drag disabled, drag coefficient 0, buoyancy 0**, gravity off for rockets — i.e. ballistic flight is either pure gravity (non-rockets, e.g. grenades, 40mm, rifle grenades, M202, bolts) or straight-line until the opt-in swept flight of §2.8 takes over. Collision group `COLLISION_GROUP_PROJECTILE` for the whole family.

`InitProjectilePhysics` (`:77-87`): `PhysicsInitSphere(self.CollisionSphere)` when set; otherwise `PhysicsInit(SOLID_VPHYSICS)` from the model's `.phy`, falling back to `PhysicsInitSphere(self.FallbackRadius or 2)` because "The game's rocket / bolt models ship without a .phy" (`:82-85`). Per `BUGLIST.md:157` all launcher rockets use a consistent 2-unit sphere (set via `CollisionSphere = 2` on `mcv_proj_rpg`:10 and `mcv_proj_m202`:10).

The shared tail (`:119-137`): records `SpawnTime`, sets `NPCDamage = IsValid(GetOwner()) and GetOwner():IsNPC()` (**never consumed anywhere** — vestigial), starts the `AudioLoop` sound if any, arms immediately when `InstantFuse`, and on CLIENT starts the trail particle. `OnInitialize()` is the subclass hook (`:137`, stub `:295-296`).

### 2.3 The `Think` loop (SH; default cadence)

```lua
-- entities/mcv_proj_base.lua:378-408
function ENT:Think()
    if !IsValid(self) or self:GetNoDraw() then return end

    local rocketFlight = SERVER and self.RocketFlight != nil
    if rocketFlight then
        self:Think_RocketFlight()
        if !IsValid(self) then return end
    end

    if !self.SpawnTime then
        self.SpawnTime = CurTime()
    end

    if !self.Armed and isnumber(self.TimeFuse) and self.SpawnTime + self.TimeFuse < CurTime() then
        self.ArmTime = CurTime()
        self.Armed = true
    end

    if self.Armed and self.ArmTime + self.Delay < CurTime() then
        self:PreDetonate()
    end

    if self.ExplodeUnderwater and self:WaterLevel() > 0 then
        self:PreDetonate()
    end

    self:DoSmokeTrail()

    self:OnThink()
    if rocketFlight then self:NextThink(CurTime()) return true end
end
```

Observations a converter must internalize:

- **A hidden entity stops thinking its gameplay logic**: `GetNoDraw()` early-outs the whole body (`:379`). This is why the M202 hides its spent rocket with `SetRenderMode(RENDERMODE_NONE)` instead of `SetNoDraw(true)` — it needs `OnThink` to keep ticking its burn (`entities/mcv_proj_m202.lua:59-65, 68-84`; the render mode networks and hides the client model while leaving the think gate open).
- **`TimeFuse = 0` is a valid timed fuse** — `isnumber(0)` is true, so grenades (base `TimeFuse = 0`, `mcv_grenade_base.lua:11`) arm on the first think tick after spawn, then count `Delay` down. `TimeFuse = false` means "never self-arm".
- Swept rocket flight re-schedules itself every tick (`:407`); every other projectile relies on the default think cadence. Subclasses that override `Think` choose their own: C4 at 10 Hz (`mcv_placed_c4.lua:63`), the mine at 20 Hz (`mcv_placed_mine.lua:85`), thrown melee at 2 Hz (`mcv_thrown_melee.lua:69`).
- `DoSmokeTrail` (`:298-325`, CLIENT only) is the legacy per-think sprite emitter — every current entity leaves `SmokeTrail = false` and uses `TrailParticle` instead. Live but dormant machinery.

### 2.4 The fuse model

Five orthogonal arming/detonation inputs, all server-side plain fields:

1. **`InstantFuse`** — armed in `Initialize` (`:128-131`).
2. **`TimeFuse` (number)** — armed by `Think` after N seconds from spawn (`:391-394`). This is the *pin-pull-to-throw* model for grenades: the weapon passes the *remaining* fuse as `Delay` and the entity arms immediately (`TimeFuse = 0`), so cooking is already discounted (`sh_throw.lua:163-166`).
3. **`ImpactFuse`** — armed on the first `PhysicsCollide` (`:225-228`); combined with `Delay == 0` or `ExplodeOnImpact` it detonates on that same collision (`:233-235`), otherwise it becomes a post-impact timed charge.
4. **`StickyFuse`** — armed when the projectile sticks (`:268-271`); no current user.
5. **`RemoteFuse` + `RemoteDetonate()`** — base implementation sets `ArmTime = CurTime(); Armed = true` (`:420-423`) so the entity blows after `Delay`; the C4 overrides it to detonate immediately (`mcv_placed_c4.lua:43-48`). The detonator is the placeable weapon's `SWEP:Detonate`, which scans `ents.FindByClass(self.PlacedEntityClass)` for `GetPlanter() == owner and ent.RemoteFuse and !ent.Detonated` (`sh_place.lua:268-281`).

Armed → boom always flows through `PreDetonate` → `Detonate`:

```lua
-- entities/mcv_proj_base.lua:425-439
function ENT:PreDetonate()
    if CLIENT then return end

    if !self.Detonated then
        self.Detonated = true

        if !IsValid(self.Attacker) and !IsValid(self:GetOwner()) then self.Attacker = game.GetWorld() end

        self:Detonate()
    end
end

function ENT:Detonate()
    // fill this in :)
end
```

`PreDetonate` is idempotent (`Detonated` flag), server-only, and guarantees *some* attacker exists (falls back to `game.GetWorld()`, `:431`). `Detonate` is the subclass's payload.

### 2.5 `PhysicsCollide` — impact handling (SV callback)

The full flow, in order (`:203-290`):

1. **Record impact geometry** for the explosion effect: `self.ImpactNormal = -data.HitNormal; self.ImpactPos = data.HitPos` (`:205-206`). Note the sign flip: physics collision normals point *into* the projectile, trace normals out of the surface.
2. **Glass passthrough** (`:208-223`): against `func_breakable_surf`, fires a zero-damage `FireBullets` (which shatters the pane), then resets position/angles and halves velocity (`SetVelocityInstantaneous(vel * 0.5)`), letting the projectile fly on.
3. **Fuse dispatch** (`:225-247`):
   - `ImpactFuse and !Armed`: arm now; call `Impact(data, collider)` (subclass hook — returning true aborts the rest); then if `Delay == 0 or ExplodeOnImpact`, `PreDetonate()`.
   - elseif `ImpactDamage > 0` **and** the hit entity passes `IsValid` **and** (not TTT or not a player): apply collision damage — `DMG_CRUSH + DMG_CLUB`, force = old velocity, damage = `Lerp((speed - 0.6·S) / (0.4·S), ImpactDamage/5, ImpactDamage)` where `S = ImpactDamageSpeed` — i.e. 20% of max damage below 60% of threshold speed, ramping to 100% at the threshold (`:236-244`). Because worldspawn fails `IsValid`, **grenades only deal impact damage to entities, never to the world** (the world falls through to the next branch).
   - elseif `!ImpactFuse`: call `Impact(data, collider)` on *every* collision — this is how the flare and thrown blade (both `ImpactDamage = 0`, `ImpactFuse = false`) get their per-hit hook.
4. **Sticking** (`:249-273`): if `Sticky` — set `COLLISION_GROUP_DEBRIS`, snap to `HitPos`; if the target is world/BSP, `MOVETYPE_NONE`, otherwise `SetParent(HitEntity)`; then hand damage credit over (`self.Attacker = self:GetOwner(); self:SetOwner(NULL)` — the shootable-by-planter pattern), arm if `StickyFuse`, and call `Stuck()` (subclass hook, `:444-446`).
5. **Bounce dampening** (`:274-282`): only the *first* bounce (`Bounced` flag), and only when the surface normal points downward (`dot < 0`, i.e. ceiling/underside hits): `SetVelocityInstantaneous(OurNewVelocity * (1 + dot * 0.5))` — up to −50% speed on a flat underside. Floor bounces are undamped.
6. **Bounce sounds** (`:284-289`): skipped when `data.DeltaTime < 0.1` (resting/scraping contact), otherwise a random entry from `BounceSounds` (which may be `{name, ...}` tables — `istable` check at `:288`).

The bolt replaces this entire function (§3.2) because sticking must be deferred out of the physics callback (`entities/mcv_proj_bolt.lua:137-155`).

### 2.6 `OnTakeDamage` — detonation and defusal by damage (SV)

```lua
-- entities/mcv_proj_base.lua:184-201
function ENT:OnTakeDamage(dmg)
    if self.Detonated then return end

    if self.ExplodeOnDamage then
        if IsValid(self:GetOwner()) and IsValid(dmg:GetAttacker()) then self:SetOwner(dmg:GetAttacker())
        else self.Attacker = dmg:GetAttacker() or self.Attacker end
        self:PreDetonate()
    elseif self.DefuseOnDamage and dmg:GetDamageType() != DMG_BLAST then
        self:EmitSound("physics/plastic/plastic_box_break" .. math.random(1, 2) .. ".wav", 70, math.Rand(95, 105))
        ... ManhackSparks effect ...
        self.Detonated = true
        self:Remove()
    end
end
```

`ExplodeOnDamage` **re-credits** the kill: whoever shot the charge becomes its owner/attacker. This is the "shoot the C4/dynamite/mine to set it off" rule — and the reason planted charges cannot keep their planter as owner (a bullet passes through anything its shooter owns, so the engine's trace filter would make the charge unshootable by its own planter). See `ReleaseOwner` (`:65-75`, quoted in §5.1). `DefuseOnDamage` (destroyed by non-blast damage, sparks + plastic break sound) has no current user.

### 2.7 Detonation geometry — `GetImpactPos` / `GetImpactNormal`

```lua
-- entities/mcv_proj_base.lua:148-164
// Collision data describes a detonation only for an immediate impact fuse. A
// timed/remote explosive may have bounced, rolled or moved with its parent since.
// Planted charges retain their explicit orientation; airborne bursts face up.
function ENT:GetImpactNormal()
    if self.ImpactFuse and (self.Delay == 0 or self.ExplodeOnImpact) and self.ImpactNormal then
        return self.ImpactNormal
    end
    return self.PlacedNormal or vector_up
end

function ENT:GetImpactPos()
    if self.ImpactFuse and (self.Delay == 0 or self.ExplodeOnImpact) and self.ImpactPos then
        return self.ImpactPos + (self.ImpactNormal or vector_up) * 2
    end

    return self:GetPos()
end
```

This is the fix for `BUGLIST.md:143` ("Timed/remote grenade explosions no longer use the last bounce position or normal"). Rule: immediate impact fuses detonate at the contact point (pushed 2 units out along the normal); timed/remote/planted charges detonate at their *current* position with `PlacedNormal` (set by the placeable weapon, `sh_place.lua:189`) or straight up. Every `Detonate` implementation calls `MCV.ExplosionEffect(family, self:GetImpactPos(), normal, ...)` with these — cross-ref `docs/effects.md` (`mcv/shared/sh_explosions.lua:105-119`: `MCV.SurfaceAngle` builds the angle whose *up* axis is the normal, because the game's particle systems build their column along control point up).

### 2.8 Swept rocket flight — `StartRocketFlight` / `Think_RocketFlight` (SV only)

Opt-in alternative to VPhysics for launchers that set `RocketGravity` (RPG-7, RPG-2, Kolos — `weapons/mcv_rpg7.lua:38-42`, `mcv_rpg2.lua:39`, `mcv_kolos.lua:62-65`). The weapon calls it right after `Spawn()` (`sh_shoot.lua:699-704`). Motivation per comment: "Swept server flight avoids VPhysics' global speed cap without changing physics settings for other addons" (`:327-328`); see `BUGLIST.md:161`.

```lua
-- entities/mcv_proj_base.lua:329-344
function ENT:StartRocketFlight(direction, speed, gravity, boostSpeed, delay, duration)
    if !SERVER then return end
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    self:SetMoveType(MOVETYPE_NONE)
    // Keep the physics collision model available to TraceEntity, but do not
    // let the stationary physics object block other entities or volley rockets.
    self:SetSolid(SOLID_VPHYSICS)
    self:SetNotSolid(true)
    self.RocketFlight = {
        origin = self:GetPos(), direction = direction, started = CurTime(),
        speed = speed, gravity = gravity, boostSpeed = boostSpeed,
        delay = delay, duration = duration,
    }
    self:NextThink(CurTime())
end
```

`Think_RocketFlight` (`:346-376`): computes `distance, speed = MCV.RocketFlightDistance(age, ...)` (the analytic boost/gravity model in `mcv/shared/sh_rocketflight.lua:4-12` — flight math is documented in `docs/shooting-ballistics.md`), integrates the ballistic destination, then `util.TraceEntity` sweeps the *initialized sphere itself* (not the AABB; `:356-362`, `BUGLIST.md:157`) with `mask = MASK_SHOT`, `filter = {self, owner}`, `collisiongroup = COLLISION_GROUP_PROJECTILE`. On hit: stores `ImpactPos`/`ImpactNormal` (trace normals, sign-flipped into the PhysicsCollide convention when synthesising the `Impact` call), forces `Armed`, calls `Impact(...)` with a synthesised collision table, then `PreDetonate()`. Sky hits detonate normally (`BUGLIST.md:159`); age > 30 s removes the rocket without a boom (`:350`).

### 2.9 Trails, sounds, rendering (CL)

- `StartTrail` (`:141-146`, CL): one-shot `ParticleEffectAttach(self.TrailParticle, PATTACH_ABSORIGIN_FOLLOW, self, 0)`; called from `Initialize` and defensively again from `Draw` (`:457`).
- `OnRemove` (`:166-174`): stops the `AudioLoop` sound and, on client, `StopParticles()` (kills the trail — the flare's comment at `mcv_proj_flare.lua:49-51` relies on exactly this).
- `Draw` (`:454-464`): skips when `Detonated` (a server-only field, so in practice this guard never fires on clients — harmless), starts the trail, draws the model, and if `FlareColor` is set draws an additive sprite (`effects/ar2_altfire1b`) 16 units behind the origin. No current entity sets `FlareColor`; the real flares use particles + dynamic light instead (§3.3).
- `GetInflictor` (`:180-182`): "What the damage names as its cause: the weapon that fired or threw this, while it is still around, so the kill icon is the weapon's own". Weapons set `ent.Inflictor = self` at spawn (`sh_shoot.lua:691`, `sh_throw.lua:209`, `sh_melee.lua:228`); fallback is the entity itself, whose class must have a registered kill-icon alias (`mcv/client/cl_killicons.lua`, per comment `:176-179`).

### 2.10 `Use` — defuse/pickup (SH entry, server effect)

```lua
-- entities/mcv_proj_base.lua:410-418
function ENT:Use(ply)
    if !self.Defusable then return end

    if self.PickupAmmo then
        ply:GiveAmmo(1, self.PickupAmmo, true)
    end

    self:Remove()
end
```

Base behavior: any player, any time, silently refunds one round of `PickupAmmo`. The bolt and thrown blade override with player-gated versions; C4 and the mine gate on the planter (§5.6).

### 2.11 Vestigial-but-live machinery (translation-layer gold)

Verified by grep across `reference/mcv/lua` — the following base features have **zero current consumers** but are fully wired and can be adopted by a converter without touching the base: `AudioLoop` (flight loop sound), `FlareColor`/`FlareSizeMin`/`FlareSizeMax` (rendered glow sprite), `SmokeTrail` (legacy sprite emitter), `StickyFuse` (timed after sticking), `DefuseOnDamage` (destroyed by non-blast damage), `RemoveOnImpact`, `GunshipWorkaround`, `NPCDamage` (the last three are *declared but never read* — do not rely on them doing anything).

---

## 3. Per-Projectile Override Matrix

### 3.1 The matrix

All values are the entity's class defaults; the spawning weapon may override `ExplosionDamage`/`ExplosionRadius` (with `StatMult`) and `Delay` before `Spawn()` (§8.2). "Force" = the `SetDamageForce` of the anti-vehicle `FireBullets` call in `Detonate` (LVS penetration input).

| Entity | Base | Model | Fuse | Rocket / phys | Trail particle | Dmg / Radius | Force | FX family | Sound |
|---|---|---|---|---|---|---|---|---|---|
| `mcv_proj_40mm` | proj_base | `shells/gren_ignited.mdl` | Impact, Delay 0 | ballistic | `vietnam_weaponeffect_ubgrenade` | 100 / 300 | 4500 | `ubgl` | `MCV_BaseGrenade.Explode` |
| `mcv_proj_lunge_mine` | proj_40mm | `mcv/w_lunge_mine.mdl` | Impact + ExplodeOnImpact | ballistic | `false` | 250 / 160 | 4500 (inherited) | `ubgl` (inherited) | inherited |
| `mcv_proj_rpg` | proj_base | `shells/rpg7_rocket.mdl` | Impact, Delay 0 | **IsRocket**, sphere 2 | `rpg_missile_trail` | 125 / 300 | 4000 | `rpg` | `MCV_BaseGrenade.Explode` |
| `mcv_proj_rpg2` | proj_base | `shells/rpg7_rocket.mdl` | Impact, Delay 0 | **IsRocket**, sphere 2 | `rpg_missile_trail` | 105 / 512 | 500 | `rpg` | `MCV_BaseGrenade.Explode` |
| `mcv_proj_bazooka` | proj_rpg | `shells/bazooka_rocket.mdl` | inherited | inherited | `rpg_missile_trail` | 175 / 250 | 4000 | `rpg` | inherited |
| `mcv_proj_panzerschreck` | proj_rpg | `shells/panzerschreck_rocket.mdl` | inherited | inherited | `rpg_missile_trail` | 175 / 250 | 4000 | `rpg` | inherited |
| `mcv_proj_kolos` | proj_rpg | `shells/kolos_rocket.mdl` | inherited | inherited | `kolos_missile_trail` | 60 / 200 | 3000 | `kolos` | inherited |
| `mcv_proj_m202` | proj_base | `shells/rpg7_rocket.mdl` | Impact, Delay 0 | ballistic, sphere 2 | `rpg_missile_trail` | 100 / **70** | 500 | `xm202` | `MCV_XM202MissileExplosionEffect.Sound` + 3 s burn |
| `mcv_proj_riflegrenade` | proj_base | `shells/shell_rg_us.mdl` | Impact, Delay 0 | ballistic | `vietnam_weaponeffect_riflegrenade` | 100 / 250 | 7500 | `ubgl` | `MCV_BaseGrenade.Explode` |
| `mcv_proj_riflegrenade_vc` | proj_base | `shells/shell_rg_vc.mdl` | Impact, Delay 0 | ballistic | `vietnam_weaponeffect_riflegrenade` | 125 / 300 | 4000 | `ubgl` | `MCV_BaseGrenade.Explode` |
| `mcv_proj_riflegrenade_ger` | riflegrenade_vc | `shells/shell_rg_ger.mdl` | inherited | inherited | inherited | inherited | inherited | inherited | inherited |
| `mcv_proj_bolt` | proj_base | `mcv/crossbow_bolt.mdl` | none (sticky) | ballistic, sphere fallback | — | 55 direct (head ×4, chest/stomach ×3) | — | `MCV.BulletImpact` | crossbow hit sounds |
| `mcv_proj_flare` | proj_base | `shells/flare.mdl` | none | ballistic | `env_flare_us_trail` | 50 direct + burn | — | burn particles | `MCV_Bounce.Shell` |
| `mcv_proj_flare_vc` | proj_flare | inherited | inherited | inherited | `env_flare_trail` | inherited | — | `env_flare_ground` | inherited |

Citations for the columns: 40mm `entities/mcv_proj_40mm.lua:7-24`; lunge mine `entities/mcv_proj_lunge_mine.lua:5-13`; rpg `entities/mcv_proj_rpg.lua:7-26`; rpg2 `entities/mcv_proj_rpg2.lua:7-26`; bazooka `entities/mcv_proj_bazooka.lua:7-14`; panzerschreck `entities/mcv_proj_panzerschreck.lua:7-14`; kolos `entities/mcv_proj_kolos.lua:7-14`; m202 `entities/mcv_proj_m202.lua:7-31`; riflegrenade `entities/mcv_proj_riflegrenade.lua:7-24`; riflegrenade_vc `entities/mcv_proj_riflegrenade_vc.lua:7-24`; riflegrenade_ger `entities/mcv_proj_riflegrenade_ger.lua:2-6`; bolt `entities/mcv_proj_bolt.lua:7-25`; flare `entities/mcv_proj_flare.lua:7-23`; flare_vc `entities/mcv_proj_flare_vc.lua:8-10`.

Every explosive rocket/grenade's `Detonate` shares the same skeleton (`util.BlastDamage` + a 32-unit `FireBullets` with `DMG_AIRBOAT + DMG_BLAST` "for helicopters and LVS vehicles" and `SetDamageForce` "LVS uses this to calculate penetration!" — e.g. `mcv_proj_40mm.lua:31-45`). Upstream notes record the game-script values where they differ from the shipped defaults (bazooka/panzerschreck "Game script: ExplosionDamage 175, ExplosionRadius 250" — matched; kolos "Game script: 125, 200 per rocket (seven leave at once)" — deliberately shipped at 60, `mcv_proj_kolos.lua:11-14`).

### 3.2 `mcv_proj_bolt` — the crossbow bolt (161 lines, the most custom projectile)

Configuration (`entities/mcv_proj_bolt.lua:9-25`): no fuse at all (`InstantFuse=false`, `TimeFuse=false`, `Delay=0`, `ImpactFuse=false`), `Sticky = true`, `StickyPlace = false`, `ImpactDamage = 0`, `Damage = 55`, `HeadMultiplier = 4`, `ChestMultiplier = 3`, `PickupAmmo = "XBowBolt"` (BUGLIST ammo audit, `BUGLIST.md:123`), `Lifetime = 60`. Model tip is 20.03 units along local +X, embed depth 2 (`:24-25`).

- **`OnInitialize`** (`:27-41`, SV/CL split): server — `SIMPLE_USE`, `DieTime`, physics mass 2, drag off, and `phys:AddGameFlag(FVPHYSICS_NO_IMPACT_DMG)` because "Impact() owns bolt damage" (`:35`); client — widened render bounds because "Flight rendering can rotate independently of the collision sphere" (`:38-39`).
- **`Draw`** (`:47-63`, CL): the core workaround for `BUGLIST.md:216` ("Crossbow bolts stopped mid-flight and fell in steps because their angle updates reset VPhysics velocity"):

```lua
-- entities/mcv_proj_bolt.lua:47-57
function ENT:Draw()
    // SetAngles on a flying VPhysics entity clears its velocity. Align only the
    // rendered mesh, every frame; the server sets the final angle when it sticks.
    if self:GetMoveType() == MOVETYPE_VPHYSICS then
        // Server-only VPhysics does not supply reliable client GetVelocity().
        // Follow the interpolated positions, retaining the angle between updates.
        local pos = self:GetPos()
        local delta = self.LastDrawPos and (pos - self.LastDrawPos)
        if delta and delta:LengthSqr() > 0.000001 then self.FlightRenderAngle = delta:Angle() end
        self.LastDrawPos = pos
        self:SetRenderAngles(self.FlightRenderAngle or self:GetAngles())
```

- **`Impact`** (`:65-116`, SV): against players/NPCs/nextbots/anything-with-health, one `FireBullets` (Damage 55, Force 4, `DMG_SLASH + DMG_NEVERGIB`, hitgroup multipliers via callback, source back-traced 16 units along the incoming velocity so the engine resolves the hitgroup) with `MCV.BulletImpact(tr, dmg, true)` for the shared per-surface impact effect (`BUGLIST.md:67`); the bolt is removed 0.05 s after a body hit ("no bolt to pick up out of a body", `:97-100`). Against the world/props: a normal-flipped `TraceLine` resolves surface metadata for `MCV.BulletImpact`, with a fallback table if "a moving prop can leave the contact before the deferred callback" (`:101-115`).
- **`Stick`** (`:118-135`, SV): destroys physics, `MOVETYPE_NONE`, `SOLID_BBOX` with 2-unit bounds, `COLLISION_GROUP_DEBRIS`, aligns to the *incoming* direction ("The tip enters the surface while the shaft stays outside", `:121-122`), positions at `HitPos - direction * (tipDistance - embedDepth)`, parents to non-world entities, `ReleaseOwner()` (shootable by / credit to the original shooter — §5.1), then the no-op `Stuck()`.
- **`PhysicsCollide`** (`:137-155`, SV): entirely replaced. The whole collision data is copied and deferred with `timer.Simple(0, ...)` because "Sticking reparents the bolt and changes its collision rules. Doing that inside the physics callback spews warnings and can destabilize VPhysics" (`:140-142`). `ImpactQueued`/`HitDone` guards keep it terminal. Glass panes still route through the base class handler for the shared shatter/passthrough (`:146-149`).
- **`Use`** (`:157-161`): any player picks the bolt up for one `XBowBolt` (no notification — `GiveAmmo(..., false)`).

### 3.3 `mcv_proj_flare` / `mcv_proj_flare_vc`

Configuration (`entities/mcv_proj_flare.lua:7-23`): fuseless, non-sticky, `ImpactDamage = 0`, `Damage = 50` (direct hit, plus fire), `BurnTime = 25` (total lifetime), `TrailParticle = "env_flare_us_trail"`, `GroundParticle = "env_flare_us_ground"` (the game's env_flare effects — `BUGLIST.md:359`), `LightColor = Color(40, 255, 40)`, bounce sound `MCV_Bounce.Shell`. The VC subclass swaps trail/ground particles and the light to red `Color(255, 60, 40)` (`entities/mcv_proj_flare_vc.lua:8-10`).

- `OnInitialize` (`:25-32`): server sets `DieTime`, plays `ambient/fire/ignite.wav`, and attaches the *ground* burn particle immediately — "the flare burns from the moment it leaves the gun, not only once it has landed".
- `Impact` (`:34-52`): first hit on a player/NPC/nextbot — 50 `DMG_BURN` direct plus `MCV.Burn(ent, 6, attacker, self, 10)` (6 s at 10 DPS; burning system in `mcv/shared/sh_burn.lua` — cross-ref `docs/support-systems.md`). Sets `Landed` when it hits the world.
- `OnThink` (`:54-82`): CLIENT — a 2048-unit `DynamicLight` at brightness 3, decay 2048, `dietime = CurTime() + 1` (re-created every think). SERVER — removes at `DieTime`; and once `Landed`, every 0.5 s sets fire to players/NPCs/nextbots within 48 units (`MCV.Burn(ent, 4, ..., 10)`, `:73-81`).
- `Draw` (`:84-86`): model only — the class relies on particles + light, not the base's `FlareColor` sprite.

### 3.4 `mcv_proj_m202` — rocket with a post-detonation burn

Configuration (`entities/mcv_proj_m202.lua:9-31`): notably **not** `IsRocket` (gravity applies unless the weapon opts into swept flight), `CollisionSphere = 2`, impact fuse, tiny 70-unit blast radius, `BurnTime = 3`, `Detonated = false` and `DieTime = 0` declared at class level (instance-state pattern). `Detonate` (`:33-66`) is the standard blast + anti-vehicle bullets (force 500) + `MCV.ExplosionEffect("xm202", ...)` + `MCV_XM202MissileExplosionEffect.Sound`, but instead of removing itself it goes invisible-but-alive:

```lua
-- entities/mcv_proj_m202.lua:59-65
    self:SetRenderMode(RENDERMODE_NONE)
    self:StopParticles()
    self:DrawShadow(false)

    SafeRemoveEntityDelayed(self, self.BurnTime)
    self:SetMoveType(MOVETYPE_NONE)
    self.DieTime = CurTime()
```

`OnThink` (`:68-84`) then ticks an incendiary cloud while `Detonated`: damage `engine.TickInterval() * 500` per think as `DMG_BURN` through `util.BlastDamageInfo(dmginfo, pos, d * 512)` where `d = 1 - age/BurnTime` — i.e. a 500-DPS burn whose radius shrinks from 512 to 0 over 3 seconds. This entity is the reference implementation the fire pool and `MCV.Burn` comments point to ("damage ticking in sh_burn style, no Ignite()", `mcv_grenade_base.lua:74-75`; `BUGLIST.md:356`). Note the render-mode choice instead of `SetNoDraw` keeps the base `Think`'s `GetNoDraw()` gate (`mcv_proj_base.lua:379`) from silencing `OnThink`.

### 3.5 The rifle-grenade family

Three entities, all impact-fused ballistic shells with `Delay = 0`, `ExplodeUnderwater = true`, trail `vietnam_weaponeffect_riflegrenade`, `ubgl` explosion family. The US class (`mcv_proj_riflegrenade`) is the default `RifleGrenadeEntity` on the gun base (`weapons/mcv_base/shared.lua:158-159` with force 5000); every Part 1 rifle overrides to the VC variant with `RifleGrenadeForce = 2000` (e.g. `weapons/mcv_m38.lua:54-55`, SKS, Type 63, SVT-40, AVT-40, vz.24, vz.54, kbkg60, M91 …), the GP-25 AKM overrides to `mcv_proj_40mm` at force 7000 (`weapons/mcv_akm_gp25.lua:114-115`), and the prewar Kar 98K (Part 2) uses the German model on VC physics ("Same flight/damage as the existing Kar 98K grenade, with the WW2 model", `entities/mcv_proj_riflegrenade_ger.lua:2`; `BUGLIST.md:171`).

Spawn path: rifle grenades go through `LaunchProjectile(secondary = true)`, which swaps in `RifleGrenadeEntity`/`RifleGrenadeForce` and — critically — **never** uses `StartRocketFlight` ("rifle grenades and other projectiles keep their physics", `sh_shoot.lua:698-704`) and scales stats by `MCV.CATEGORY_RIFLE_GRENADE` rather than the host rifle's category (`sh_shoot.lua:676-686`, `AGENTS.md:45-46`). The weapon-side firing flow (sequence, spread, UBGL toggle) is in `docs/shooting-ballistics.md` and `docs/gun-core.md` (§7.11 of `docs/animation-system.md` for the UBGL animation).

### 3.6 The rocket family (rpg / rpg2 / bazooka / panzerschreck / kolos)

All share the `Detonate` skeleton quoted in §3.1; the differences are exactly: model, trail particle, damage/radius, LVS force, explosion family, and inheritance depth. The RPG classes set `IsRocket = true` + `CollisionSphere = 2` ("Shared by RPG-2/7, LAW, Bazooka, Panzerschreck and Kolos", `mcv_proj_rpg.lua:10`), so the bazooka/kolos/panzerschreck get no-gravity VPhysics unless the weapon opts into swept flight. Actual flight parameters are weapon-owned: RPG-7 force 115 m/s, gravity 9.80665 m/s², boost 300 m/s after 0.1 s for 0.4 s; Kolos 110 m/s, boost 560 after 0.18 s for 0.3 s (`weapons/mcv_rpg7.lua:38-42`, `weapons/mcv_kolos.lua:61-65`; units converted by `/ 0.0254`; `BUGLIST.md:161`). The Kolos fires all seven rockets at once via `FIREMODE_VOLLEY` (`VolleyCount = 7`, `weapons/mcv_kolos.lua:56`; volley logic `sh_shoot.lua:646-656`). The M79's selectable HE/buckshot simply returns `nil` from `GetProjectileClass` for buckshot so the base fires pellets instead (`weapons/mcv_m79_base/shared.lua:40-43`, `BUGLIST.md:119`).

### 3.7 `mcv_proj_40mm` and `mcv_proj_lunge_mine`

The 40mm grenade is the canonical `Detonate` implementation — quoted in §8.3 as the template. The lunge mine subclasses it and is spawned by the melee-based lunge mine weapon in two ways: contact detonation (`MeleeHit` creates the mine at the trace hit and calls `mine:Detonate()` immediately, then removes the weapon, `weapons/mcv_lunge_mine.lua:58-73`) and a thrown mode (`LaunchBlade` gives it velocity; `CanThrow = false` currently disables it because "Throw animations are unfinished; contact attacks only", `weapons/mcv_lunge_mine.lua:25`, `BUGLIST.md:181`). Its overrides (`entities/mcv_proj_lunge_mine.lua:5-13`): `InstantFuse = false` ("the projectile base arms ImpactFuse on its first collision"), `ExplodeOnImpact = true`, 250/160, no trail, no underwater detonation.

---

## 4. Grenade Base & Variants

### 4.1 `mcv_grenade_base` — the throwable explosive base

`entities/mcv_grenade_base.lua` (101 lines). Configuration (`:9-31`): `InstantFuse = false`, **`TimeFuse = 0`** (arm on first think), `Delay = 4` (the fuse — always overwritten by the weapon), `ImpactFuse = false`, `ImpactDamage = 5` @ `ImpactDamageSpeed = 600`, `ExplosionDamage = 150`, `ExplosionRadius = 350`, `IgniteRadius = 0`, `BurnDuration = 3`, `BurnDamagePerSecond = 30`, `BurnParticle = nil`, `ExplosionFamily = "grenade"`, `ExplosionSound = "MCV_BaseGrenade.Explode"`, `BounceSounds = {"MCV_HEGrenade.Bounce"}`, `RoundCollision = true`.

Cooking is weapon-side: the fuse runs from the pin pull (`GetCookTime`, `sh_throw.lua:84-91`), `LaunchThrowable` subtracts it (`remaining = math.max(fuse - (CurTime() - cookstart), 0)` — but only for timed, not impact, fuses — `sh_throw.lua:163-166`), passes it as `ent.Delay`, and if `remaining <= 0` arms and detonates the grenade *in the hand* (`sh_throw.lua:218-224`; `BUGLIST.md:368`). The pin/windup/underhand/roll state machine is `docs/special-weapon-bases.md` territory.

### 4.2 Round-collision physics — `InitProjectilePhysics` override

```lua
-- entities/mcv_grenade_base.lua:33-60 (excerpt)
function ENT:InitProjectilePhysics()
    if !self.RoundCollision then
        return baseclass.Get("mcv_proj_base").InitProjectilePhysics(self)
    end

    // V40's body is a 1.5-unit sphere at the model origin; exclude its lever.
    if string.lower(self:GetModel()) == "models/weapons/mcv/w_v40.mdl" then
        self.RollRadius = 1.5
        self:PhysicsInitSphere(self.RollRadius, "metal")
    else
        // All thrown canisters/bottles are authored along local Z. A regular
        // convex cylinder removes the protrusions and seams of the model .phy.
        local mins, maxs = self:GetModelBounds()
        ... 64-point convex cylinder fitted to the model bounds ...
        self.RollRadius = radius
        self:PhysicsInitConvex(points)
    end
    self:EnableCustomCollisions(true)
end
```

Per `BUGLIST.md:203`: thrown grenades use 64-sided convex cylinders fitted to model bounds (true 1.5-unit sphere for the V40). `RollRadius` feeds the underhand-roll spin: `LaunchThrowable` lays the cylinder's Z axis horizontal (`Angle(0, ang.y, 90)`) and matches forward surface speed (`sh_throw.lua:179-187, 230-237`). Placed charges set `RoundCollision = false` and keep their model `.phy` (`mcv_placed_c4.lua:4`, `mcv_placed_dynamite.lua:4`, `mcv_placed_mine.lua:4`).

### 4.3 `Detonate` — the shared explosive payload

```lua
-- entities/mcv_grenade_base.lua:69-101 (excerpt)
function ENT:Detonate()
    local attacker = self:GetAttacker()

    util.BlastDamage(self:GetInflictor(), attacker, self:GetPos(), self.ExplosionRadius, self.ExplosionDamage)

    // incendiary (the game's IgniteRadius extends ExplosionRadius): a short patch of fire like
    // the M202's, damage ticking in sh_burn style, no Ignite()
    if self.IgniteRadius > 0 and SERVER then
        local pool = ents.Create("mcv_firepool")
        if IsValid(pool) then
            pool:SetPos(self:GetImpactPos() + self:GetImpactNormal() * 4)
            pool:SetAngles(MCV.SurfaceAngle(self:GetImpactNormal()))
            pool.Attacker = attacker
            pool.Inflictor = self:GetInflictor()
            pool.Radius = self.ExplosionRadius + self.IgniteRadius
            pool.DamagePerSecond = self.BurnDamagePerSecond
            pool.Duration = self.BurnDuration
            pool.Particle = self.BurnParticle
            pool:Spawn()
        end
    end

    // a planted charge blows normal to the surface it was placed on; anything thrown or
    // dropped blows straight up, whatever it happened to bounce off last.
    local normal = self.PlacedNormal or vector_up
    MCV.ExplosionEffect(self.ExplosionFamily, self:GetImpactPos(), normal, self:WaterLevel() > 0)

    if self.ExplosionSound then
        self:EmitSound(self.ExplosionSound)
    end

    self:Remove()
end
```

`GetAttacker` (`:62-67`) resolves `Attacker` → owner → world, mirroring `PreDetonate`'s fallback. Note `Detonate` itself removes the entity — the smoke grenade is the one subclass that must *not* be removed, so it overrides without calling up (§4.6).

### 4.4 `mcv_grenade_frag` and `mcv_grenade_wp`

- **frag** (7 lines): pure alias — inherits everything, pins `ExplosionFamily = "grenade"` (`entities/mcv_grenade_frag.lua:3-7`). All Part 1 frag throwables (M26, Mk 2, RGD-5, ChiCom, homemade, V-40, Type 67) point `ThrowEntity` at this class; per-grenade stats come from the weapon's `ExplosionDamage`/`ExplosionRadius` injection. The Nebelhandgranate (Part 2) uses the smoke entity with zero blast instead (`BUGLIST.md:226`).
- **wp** (12 lines): the M34's phosphorus burst — `ExplosionFamily = "m34"`, `IgniteRadius = 200`, `BurnDuration = 3`, `BurnDamagePerSecond = 40` (`entities/mcv_grenade_wp.lua:7-12`). "everything within ExplosionRadius + this burns. The M34 effect is a single burst of phosphorus with no lingering fire, so the patch is as short as the M202's" (`:8-10`) — i.e. a fire pool of radius 350+200 = 550, 40 DPS, 3 seconds (`BUGLIST.md:369`).

### 4.5 `mcv_grenade_molotov` — impact-fused fire starter

Configuration (`entities/mcv_grenade_molotov.lua:9-19`): `TimeFuse = false`, `ImpactFuse = true`, `ExplodeOnImpact = true`, `Delay = 0`, no bounce sounds, `ExplosionDamage = 35`, `ExplosionRadius = 200` (used both as the *fire* radius and, halved, as the blast radius), `FireParticle = "Molotov_GroundFire"`, `WickParticle = "vietnam_entityeffect_zippo_flame"`.

`Initialize` (`:20-26`) explicitly calls the proj_base initializer (bypassing the grenade base's would-be double physics setup is unnecessary here — it calls `baseclass.Get("mcv_proj_base").Initialize(self)` then attaches the wick flame to the model's `Wick` attachment, matching the viewmodel-side burning rag of `BUGLIST.md:400`).

`Detonate` (`:28-53`): blast of 35 damage at **half** radius (100); `ParticleEffect("Molotov_Explosion", ...)` oriented by `MCV.SurfaceAngle`; then a `mcv_firepool` with `Radius = 200`, `DamagePerSecond = 20`, `Duration = self.EffectDuration or 12`, `Particle = FireParticle`; glass-break sound `physics/glass/glass_bottle_break2.wav`; remove.

### 4.6 `mcv_grenade_smoke` — the popping canister

Configuration (`entities/mcv_grenade_smoke.lua:7-20`): zero damage/radius, `EffectDuration = 25`, `SmokeParticle = "vietnam_smokegrenade_attached"`, `SmokeParticleColored = "vietnam_smokegrenade_colorcoded"`, `SmokeSound`/`SmokeLoop` (M18), `Hurts = false`, bounce `MCV_SmokeGrenade.Bounce`, `FadeTime = 12`.

`Detonate` is redefined as **pop, not remove** (`:31-45`): sets `Detonated = true` (so the base think never re-detonates), `SetPopped(true)`, networks `SmokeColor` (set by the weapon from `SWEP.SmokeColor`, `sh_throw.lua:207`) into `SmokeColorVec`, plays the pop + loop sounds, records `PopTime`/`StopTime`, and calls the `OnPop` hook.

`OnThink` (`:50-92`): CLIENT — once `Popped`, creates the attached particle system, using the *colored* system with control point 1 = `col / 255` when a color is networked (`:59-72`); once `Stopped`, calls `StopEmission(false, false, false)` so remaining smoke drifts off rather than vanishing (`:52-58`, `BUGLIST.md:357`). SERVER — stops the loop at `StopTime`, removes at `StopTime + FadeTime`, and calls `HurtTick` while active if `Hurts` (base no-op, `:94-95`).

`OnRemove` (`:97-105`): stops the loop server-side, destroys the client particle system immediately, then chains to the proj_base `OnRemove` (trail/sound cleanup) — via `baseclass.Get("mcv_proj_base")` for the same recursion reason as §1.4.

### 4.7 `mcv_grenade_gas` — the damaging cloud

Extends smoke (`entities/mcv_grenade_gas.lua:3-19`): M18 model with skin 7, gas particles on both colored/uncolored slots, M6A1 sounds, `Hurts = true`, `ExplosionDamage = 125` ("damage per second to anyone in the cloud without a gas mask (game: ExplosionDamage)"), `ExplosionRadius = 500`, `TickRate = 0.5`. `OnPop` delays the first hurt by 1.5 s — "the cloud needs a moment to spread" (`:21-23`).

A **global** helper ships here: `function MCV_HasGasProtection(ent) return ent.MCV_GasMask == true end` (`:26-28`) — "Gas masks (later) set ply.MCV_GasMask = true; the check lives here so it is one place." (Translation note: any addon can grant immunity by setting `ent.MCV_GasMask`.)

`HurtTick` (`:30-60`, SV): every `TickRate`, cloud radius = `ExplosionRadius * 0.5 * Clamp(age/4, 0.3, 1)` (150→250 units over the first 4 s), damage scale = `Clamp(left * 3, 0.2, 1)` where `left` is the fraction of `EffectDuration` remaining; each victim in `FindInSphere` that is a player/NPC/nextbot, alive, unprotected, and within **128 units vertically**, takes `ExplosionDamage * TickRate * scale * 0.5` as `DMG_NERVEGAS` (`:48-54`) plus a `ScreenFade` for players (`:56-58`).

---

## 5. Placed Explosives

### 5.1 The shared `PlantOn` / owner-release pattern

All three charges override `PlantOn(parent)`, called by the weapon right after `Spawn()`/`Activate()` (`sh_place.lua:195`). Their common body: freeze motion (`MOVETYPE_NONE`, `EnableMotion(false)`), keep `SOLID_VPHYSICS`, drop to `COLLISION_GROUP_WEAPON`, parent to the surface entity, then:

```lua
-- entities/mcv_proj_base.lua:65-75
// A planted charge is shot to set it off, and a bullet passes through anything its shooter
// owns (the engine's trace filter skips entities owned by the pass entity), so a charge cannot
// keep its planter as the owner: the planter moves to Planter (the remote and the pickup look
// at it) and to Attacker (the damage credit) and the owner is cleared.
function ENT:ReleaseOwner()
    local o = self:GetOwner()
    if !IsValid(o) then return end
    self:SetPlanter(o)
    if !IsValid(self.Attacker) then self.Attacker = o end
    self:SetOwner(NULL)
end
```

`PlacedNormal` is set by the weapon ("the explosion goes off normal to the surface it sits on", `sh_place.lua:189`) and consumed by `GetImpactNormal` (§2.7). The bolt calls `ReleaseOwner` too when it sticks (`mcv_proj_bolt.lua:133`).

Weapon-side context (full detail in `docs/special-weapon-bases.md`): `SpawnPlaced` positions at `tr.pos + normal * 0.5` with `SWEP:PlaceAngle(normal)` (model up along the surface normal, `sh_place.lua:33-49`); `ConfigurePlaced` injects `ExplosionDamage`/`Radius` (with stat multipliers), `Attacker`, `Inflictor`, `Model`, and for dynamite `Delay = FuseTime` (`sh_place.lua:167-176`). Mines and stakes can mount walls/slopes/ceilings (`BUGLIST.md:59`); the stake faces the mine in the mounting plane.

### 5.2 `mcv_placed_c4` — remote-detonated charge

Configuration (`entities/mcv_placed_c4.lua:10-20`): `RoundCollision = false`, `TimeFuse = false`, `Delay = 0`, **`RemoteFuse = true`**, `ImpactFuse = false`, `ExplodeOnDamage = true` (shootable), `Defusable = true`, no bounce sounds, `ExplosionFamily = "artillery"`, 500/500, `BlinkParticle = "vietnam_weaponeffect_c4_blinklight"`.

- `PlantOn` (`:23-38`): the shared pattern plus plant sound `MCV_Weapon_C4_Demolition.Plant` and the attached blinking light.
- `Light()` (`:40-41`): no-op — C4 has no fuse to light (the placeable weapon calls `Light()` on thrown dynamite only, `sh_place.lua:260`).
- `RemoteDetonate` (`:43-48`): `ArmTime = CurTime() - 1; Delay = 0; Armed = true; PreDetonate()` — immediate, bypassing the base's one-`Delay`-later semantics.
- `Think` (`:59-65`): **overrides the base think entirely** — no fuse logic at all ("no timer: waits for the remote", `:60`), keeps only the underwater check and `OnThink`, at a 10 Hz cadence.
- `Use` (`:50-57`): the planter (and only the planter, via `GetPlanter`) can pick a charge back up for one `mcv_explosive_charge` ammo with the defuse sound.
- Detonation is the inherited grenade-base `Detonate` (artillery-family explosion, 500/500) with `PlacedNormal` orientation.

The C4 weapon doubles as the detonator: right-click calls `SWEP:Detonate` which triggers every planted charge of `PlacedEntityClass` whose `GetPlanter()` is the owner (`sh_place.lua:268-281`), and the weapon stays in hand as empty-handed detonator while any charge lives (`sh_place.lua:283-297`, `BUGLIST.md:401`).

### 5.3 `mcv_placed_dynamite` — lit-fuse throwable/plantable

Configuration (`entities/mcv_placed_dynamite.lua:10-19`): `RoundCollision = false`, `TimeFuse = false` ("lit explicitly"), **`Delay = 6`**, `ExplodeOnDamage = true`, bounce sounds inherited from the grenade base, `ExplosionFamily = "artillery"` ("the mortar shell family: heavier than the hand grenade, every surface variant"), 500/550, `FuseParticle = "vietnam_weaponeffect_dynamite_fuse"`, `FuseSound = "MCV_Weapon_C4.FuseBurningLoop"` ("the game ships one burning-fuse loop (under the C4 name); the dynamite has no other", `:47-48`; `BUGLIST.md:353`).

- `PlantOn` (`:21-30`): shared pattern + plant sound + `self:Light()` — a *planted* dynamite is lit immediately.
- `Light` (`:32-50`): one-shot (`Lit` flag) arming — `ArmTime = CurTime(); Armed = true` — plus the fuse particle on the model's `"fuse"` attachment (falling back to origin follow) and the fuse loop sound. The base `Think` then counts `Delay` (6 s, or the weapon's `FuseTime`, injected by `ConfigurePlaced`, `sh_place.lua:173-175`) down to detonation.
- `OnRemove` (`:52-55`): stops the fuse sound, chains to proj_base cleanup.
- **Thrown-lit**: the placeable weapon's secondary attack winds up and throws the stick already burning (`ThrowLit`/`Deferred_ThrowLit`, `sh_place.lua:226-266`): creates the entity with `ent.Thrown = true`, `Light()`s it, and gives it velocity + random spin. The in-hand fuse audible to bystanders is weapon-side (`Think_Fuse`, `sh_place.lua:306-320`).

### 5.4 `mcv_placed_mine` — the tripwire mine

Configuration (`entities/mcv_placed_mine.lua:10-21`): `RoundCollision = false`, `TimeFuse = false`, `Delay = 0`, `ExplodeOnDamage = true` (shootable), `Defusable = true`, no bounce sounds, `ExplosionFamily = "grenade"`, 175/250, **`ArmDelay = 2`** ("seconds after the stake goes in before the wire is live"), **`SelfDestructDelay = 300`** ("seconds from placement, including time waiting for a stake" — the five-minute self-destruct of `BUGLIST.md:61`), `MineBodygroups = {mine = 0, stick = 1}`.

- `SetupDataTables` (`:23-26`): base slots + `NetworkVar("Entity", 2, "Stake")` (no conflicts — §1.4).
- `PlantOn` (`:28-38`): shared pattern + plant sound.
- `SetStakeEntity(stake)` (`:43-48`): called by the weapon after the stake exists (`sh_place.lua:222`): networks the stake, sets `LiveTime = CurTime() + ArmDelay`, back-links `stake.Mine = self`, plays the plant sound.
- `GetWireStart`/`WireEnds` (`:50-59`): wire start is `GetPos() + GetUp() * 4` ("Model up follows the mounting surface, including a moving/rotating parent"); wire end is the stake's position; both nil-safe when the stake is gone.
- `Think` (`:61-87`, 20 Hz, SV logic): (1) self-destruct at `SpawnTime + SelfDestructDelay` via the normal detonation path; (2) once past `LiveTime`, sweep a 4×4×4 hull along the wire — `util.TraceHull({start = a, endpos = b, mins = Vector(-2,-2,-2), maxs = Vector(2,2,2), filter = {self, stake}, mask = MASK_SHOT_HULL})` — and detonate on anything crossing that is a player, NPC, nextbot, vehicle, LVS (`ent.LVS`), simfphys (`ent.IsSimfphyscar`), or a `prop_physics` moving faster than 50 u/s (`:71-77`); (3) a destroyed stake (`StakeSet` and stake invalid) detonates the mine ("stake destroyed: the mine goes off", `:78-81`). The wire may be up to the weapon's `WireLength` away with LOS enforced at placement (`sh_place.lua:69-79`).
- `Detonate` (`:89-93`): removes the stake, then chains to the grenade-base detonation (175/250, grenade family, `PlacedNormal` orientation).
- Client `Draw` (`:104-115`): model + the wire itself — `render.DrawBeam(a, b, 1, 0, length/16, color_white)` with `cable/cable2` (`BUGLIST.md:354`).

### 5.5 `mcv_mine_stake` — the tripwire stake

Standalone `base_anim` entity (`entities/mcv_mine_stake.lua:3-5`), model `w_mine.mdl` with bodygroups showing only the stake: mine group set to its last (blank) option — "option 1 was the VC mine, not a blank" — and stick group 0 (`:29-32`, `BUGLIST.md:393`). Server `Initialize` (`:15-34`): static VPhysics (`MOVETYPE_NONE`, motion disabled), `COLLISION_GROUP_WEAPON`, and the planter/owner split (`SetPlanter(GetOwner()); SetOwner(NULL)` — "shootable by the planter too", `:24-28`). Own `SetupDataTables` with `Planter` (Entity 0, `:11-13`). `OnTakeDamage` (`:36-41`): damage > 10 removes the stake — which the mine notices and detonates for (§5.4 branch 3). The weapon raises it `StakeRaise` units and rolls the point-up mesh over (`sh_place.lua:30-32, 215-216`; `BUGLIST.md:393`).

### 5.6 Defuse / pickup audit — including one apparent bug

| Entity | Gate | Refund | Verdict |
|---|---|---|---|
| base `Use` | `Defusable` only | `PickupAmmo` ×1 (any player) | generic |
| bolt | any player | `XBowBolt` ×1 | `mcv_proj_bolt.lua:157-161` |
| thrown blade | any player without the weapon | gives + selects the weapon | `mcv_thrown_melee.lua:52-62` |
| C4 | `ply == GetPlanter()` | `mcv_explosive_charge` ×1 | `mcv_placed_c4.lua:50-57` — correct |
| mine | `ply == GetOwner()` | `mcv_mine` ×1 + removes stake | `mcv_placed_mine.lua:95-102` — **see below** |

**Apparent bug (code-verified, not runtime-tested):** the mine's `Use` checks `ply != self:GetOwner()` (`mcv_placed_mine.lua:97`), but `PlantOn` — always called on placement (`sh_place.lua:195`) — invokes `ReleaseOwner()`, which does `SetOwner(NULL)` and moves the planter into the `Planter` NetworkVar (`mcv_proj_base.lua:69-75`). After planting, `GetOwner()` is the NULL entity, so `ply != NULL` is always true and **no player can ever satisfy the check**: the planted mine cannot be picked back up, despite `Defusable = true` and the defuse sound/abort code path existing below it. The C4's otherwise-identical `Use` correctly uses `GetPlanter()` (`mcv_placed_c4.lua:52`). Recommended fix pattern for the translation layer: always gate on `GetPlanter()`. (No BUGLIST entry covers this as of the audited revision.)

---

## 6. `mcv_firepool` — Area-Denial Fire

`entities/mcv_firepool.lua` (84 lines), `base_anim`, server-logic-only. This is the shared ground-fire entity spawned by the molotov (`mcv_grenade_molotov.lua:37-48`), by any grenade with `IgniteRadius > 0` (WP; `mcv_grenade_base.lua:76-89`), and usable directly. Defaults (`:8-14`): `Radius = 200`, `DamagePerSecond = 20`, `Duration = 12`, `Particle = "Molotov_GroundFire"`, `TickRate = 0.25`, `BurnAfter = 3` ("seconds a victim keeps burning after leaving the pool"), `BurnAfterDPS = 8`.

`Initialize` (`:16-34`, SV): invisible collisionless plate (`models/hunter/plates/plate.mdl`, `SetNoDraw(true)`, `MOVETYPE_NONE`, `SOLID_NONE`, no shadow), `DieTime`, and the ground-fire particle + `ambient/fire/fire_med_loop1.wav` (volume 0.6, `CHAN_STATIC`).

`Think` (`:36-78`, SV): removes (stopping particles and the loop) at `DieTime`; otherwise every `TickRate`:

- damage fades over the last quarter of life: `scale = Clamp(life * 4, 0, 1)` where `life` is remaining fraction (`:50-52`);
- victims: players (alive), NPCs, nextbots, `prop_physics`, LVS, simfphys within `Radius`, **gated to the same floor** — `|ent.z - self.z| > 96` skipped (`:54-59`);
- payload: `DamagePerSecond * TickRate * scale` as `DMG_BURN`, credited to `Attacker`/`Inflictor` (both falling back to world/self, `:48-49`), then `MCV.Burn(ent, BurnAfter, attacker, inflictor, BurnAfterDPS)` so victims keep burning after leaving — "a few seconds of burning after leaving the fire (sh_burn.lua, no Ignite)" (`:69-72`).

The victim-side burn system itself (`MCV.Burn`/`MCV.Extinguish`, 0.25 s `DMG_BURN` ticks, `burning_character` particle, water extinguish) is `mcv/shared/sh_burn.lua:18-79` — cross-ref `docs/support-systems.md`.

---

## 7. `mcv_thrown_melee` — The Thrown Blade

`entities/mcv_thrown_melee.lua` (71 lines), direct child of `mcv_proj_base`. Configuration (`:9-19`): fuseless (`InstantFuse = false`, `TimeFuse = false`, `Delay = 0`), `Sticky = true`, `StickyPlace = false`, `ImpactDamage = 0`, `Damage = 60`, `WeaponClass = "mcv_m1942_machete"`, flesh/world sounds from the melee weapon.

- `OnInitialize` (`:21-25`): `SIMPLE_USE` server-side.
- `Impact` (`:27-45`): once (`HitDone`); living targets take `Damage` as `DMG_SLASH` with force = old velocity, credited to `Attacker`/inflictor; world/props just get the world-hit sound. (Compare the bolt, which uses `FireBullets` for hitgroup multipliers — the blade does not.)
- Sticking is the **base class** sticky path (§2.5 step 4): DEBRIS group, world → `MOVETYPE_NONE`, entity → `SetParent`, owner cleared to `Attacker`. `Stuck()` (`:48-50`) just re-asserts `SIMPLE_USE` — "The blade sticks where it lands; pressing USE takes it back."
- `Use` (`:52-62`): any player who does **not** already hold `WeaponClass` is given and **auto-selects** the weapon ("fetching a thrown blade is a deliberate walk over to it, so it is what you meant to be holding", `:58-60`).
- `Think` (`:64-71`): 2 Hz; no fuse logic — "keep the projectile base's smoke / think hooks quiet" via the `Stuck2` latch; note it does **not** chain to the base `Think`, so no fuse/underwater logic ever applies (there is none to apply).

Weapon side: `mcv_melee`'s `LaunchBlade` (`weapons/mcv_melee/sh_melee.lua:217-253`) injects `Model`, `WeaponClass`, `Inflictor` ("the kill icon is the weapon's, not the blade in flight"), `Damage` (`ThrowDamage or GetStabDamage()`), both sounds, `Attacker`, then velocity `ThrowForce` + owner velocity and `AddAngleVelocity(Vector(0, 1500, 0))` spin; the weapon is stripped from the thrower a frame later ("the blade is gone until picked up again", `:245-252`).

---

## 8. Translation-Layer Surface

### 8.1 Ranking: how foreign ordnance maps onto this library

1. **Foreign rocket/launcher → `mcv_proj_rpg` subclass + weapon fields (easiest, highest fidelity).** Create a thin `ENT.Base = "mcv_proj_rpg"` (or `mcv_proj_base` + `IsRocket`/`CollisionSphere = 2`), copy the `Detonate` skeleton, and put flight numbers on the *weapon*: `ShootEntity`, `ShootEntityForce`, and — for boost/drop — `RocketGravity`/`RocketBoostSpeed`/`RocketBoostDelay`/`RocketBoostDuration` to opt into the swept flight of §2.8. Damage/radius can live on the entity as defaults; the weapon's `ExplosionDamage`/`ExplosionRadius` (times `StatMult`) override them at launch (`sh_shoot.lua:676-684`). This satisfies the upstream doctrine verbatim (`AGENTS.md:42-46`).
2. **Foreign grenade → `mcv_grenade_frag` (frag), `mcv_grenade_smoke` (screening), `mcv_grenade_molotov` (impact/incendiary) with weapon-side `ThrowEntity`.** The throwable base already supplies overhand/underhand/roll throws, cooking from pin pull, fuse presets (`FuseModes`), and the full injection list of §8.2. Impact-fused throwables need `FuseImpact = true` on the weapon (the weapon flips `ImpactFuse`/`ExplodeOnImpact`/`TimeFuse` on the entity at throw time, `sh_throw.lua:198-202`).
3. **Foreign satchel/remote charge → `mcv_placed_c4`**; **timer charge → `mcv_placed_dynamite`** (set `Delay`); both get planting, planter credit, shootability and the detonator for free from `mcv_placeable`.
4. **Foreign proximity/tripwire mine → `mcv_placed_mine` + `mcv_mine_stake`.** The trigger is a *wire*, not a proximity sphere — a foreign proximity mine has no direct host; either repurpose the wire sweep or extend the mine's `Think` (the clean seam: replace the `TraceHull` block, `mcv_placed_mine.lua:68-77`).
5. **Foreign crossbow/throwable-knife → `mcv_proj_bolt` / `mcv_thrown_melee`** — both are retrievable, sticky, fuseless; the bolt additionally has hitgroup multipliers and per-model tip embedding (`tipDistance`/`embedDepth`, `mcv_proj_bolt.lua:25`).
6. **Gas/chemical → `mcv_grenade_gas`** (cloud growth/thinning/z-gate/gas-mask hook §4.7).
7. **Anything with lingering fire → `mcv_firepool`** directly (its `Attacker`/`Inflictor`/`Radius`/`DamagePerSecond`/`Duration`/`Particle` are all injectable fields, `mcv_grenade_molotov.lua:37-47` is the template).

### 8.2 The complete pre-`Spawn()` injection contract

What each factory writes onto the entity between `ents.Create` and `Spawn()` — a converter must produce exactly these:

| Factory | Fields injected | Citation |
|---|---|---|
| `LaunchProjectile` (guns/launchers) | `ExplosionDamage`*, `ExplosionRadius`* (*weapon value if > 0, else entity default; × `StatMult("explosion_damage"/"explosion_radius" [, CATEGORY_RIFLE_GRENADE])`), `SetOwner`, `Inflictor`, `SetWeapon`, pos/angles; post-spawn: `StartRocketFlight(dir, force×speedmult, gravity, boost×speedmult, delay, duration)` **or** `phys:SetVelocityInstantaneous(dir * force)` | `sh_shoot.lua:665-710` |
| `LaunchThrowable` (grenades) | `Model` (`ThrowModel or WorldModel`), `Delay` (remaining fuse after cooking), `ImpactFuse`+`ExplodeOnImpact`+`TimeFuse=false` when weapon `FuseImpact`, `ExplosionDamage`×mult, `ExplosionRadius`×mult, `IgniteRadius`, `EffectDuration`, `SmokeColor`, `Attacker`, `Inflictor`, skin; post-spawn: velocity (overhand/underhand/roll variants + owner velocity), roll spin or random `ThrowSpin` | `sh_throw.lua:193-238` |
| `SpawnPlaced` (charges/mines) | via `ConfigurePlaced`: `ExplosionDamage`×mult, `ExplosionRadius`×mult, `Attacker`, `Inflictor`, `Model` (`PlacedModel or WorldModel`), `Delay = FuseTime` (dynamite only); plus `PlacedNormal`; post-spawn `PlantOn(parent)`; mines: `MineBodygroups`, stick bodygroup blanked | `sh_place.lua:167-202` |
| `Deferred_ThrowLit` (thrown dynamite) | `ConfigurePlaced` set + `Thrown = true`; post-spawn `Light()` + velocity + spin | `sh_place.lua:245-266` |
| `SpawnStake` | `Model` (`StakeModel or WorldModel`), `MineBodygroups`, pos/angles (`PlaceAngle` with `StakeRaise`, `StakeAngleOffset`), owner; `SetParent`; then `mine:SetStakeEntity(stake)` | `sh_place.lua:204-224` |
| `LaunchBlade` (melee) | `Model`, `WeaponClass`, `Inflictor`, `Damage`, `SoundFlesh`, `SoundWorld`, `Attacker`; post-spawn velocity + `Vector(0, 1500, 0)` spin | `sh_melee.lua:223-243` |
| `CreateMine` (lunge mine) | `Attacker`, `ExplosionDamage`×mult, `ExplosionRadius`×mult, `SetWeapon`; contact mode detonates immediately | `mcv_lunge_mine.lua:42-73` |

Ordering rule: anything read in `Initialize` (`Model`, `ModelSkin`, `Material`, shape fields) **must** precede `Spawn()`; `Delay`/damage fields are read later but are conventionally also pre-spawn.

### 8.3 The canonical `Detonate` template

Every explosive should look like this (40mm shown; the whole family differs only in the quoted numbers — §3.1):

```lua
-- entities/mcv_proj_40mm.lua:26-53
function ENT:Detonate()
    local attacker = self.Attacker or self:GetOwner() or self
    local mult = 1
    local dmg = self.ExplosionDamage

    util.BlastDamage(self:GetInflictor(), attacker, self:GetPos(), self.ExplosionRadius, dmg * mult)
    self:FireBullets({
        Attacker = attacker,
        Damage = dmg * mult,
        Tracer = 0,
        Src = self:GetPos(),
        Dir = self:GetForward(),
        HullSize = 0,
        Distance = 32,
        IgnoreEntity = self,
        Callback = function(atk, btr, dmginfo)
            dmginfo:SetDamageType(DMG_AIRBOAT + DMG_BLAST) // airboat damage for helicopters and LVS vehicles
            dmginfo:SetDamageForce(self:GetForward() * 4500) // LVS uses this to calculate penetration!
        end,
    })

    // Game explosion effect, picked per surface (see lua/mcv/shared/sh_explosions.lua)
    MCV.ExplosionEffect("ubgl", self:GetImpactPos(), self:GetImpactNormal(), self:WaterLevel() > 0)

    self:EmitSound("MCV_BaseGrenade.Explode")

    self:Remove()
end
```

Converter notes: (a) the `FireBullets` second stage is a 32-unit anti-vehicle shot — `DMG_AIRBOAT + DMG_BLAST` and the forward force are what LVS vehicles read; do not drop it for vehicle-compat; (b) always use `GetImpactPos()`/`GetImpactNormal()` for the effect, `GetPos()` for the `BlastDamage` (this asymmetry is deliberate — §2.7); (c) effect families in use: `ubgl`, `rpg`, `kolos`, `xm202`, `grenade`, `m34`, `artillery` (surface-variant resolution in `mcv/shared/sh_explosions.lua:113-119`, documented in `docs/effects.md`).

### 8.4 Behavior seams to respect (ranked by trip-wire severity)

1. **Owner clearing on plant/stick** (`ReleaseOwner`, §5.1): damage credit and E-interaction move to `Planter`/`Attacker`. Any foreign code that assumes `GetOwner()` keeps working after planting will break (see the mine bug §5.6).
2. **`GetNoDraw()` gates the base `Think`** (`mcv_proj_base.lua:379`): never hide a live projectile with `SetNoDraw(true)`; use `SetRenderMode(RENDERMODE_NONE)` as the M202 does.
3. **Server-only fields**: fuses/damage never replicate; any client-side HUD of a foreign grenade's fuse must be re-implemented weapon-side (MCV itself puts nothing client-side on entities beyond smoke's `Popped`/`Stopped`/`SmokeColorVec`).
4. **Sign conventions**: physics `HitNormal` points into the projectile, trace `HitNormal` out of the surface; `ImpactNormal` is stored flipped (`mcv_proj_base.lua:205`, `mcv_proj_bolt.lua:104, 151`).
5. **Glass passthrough** (`func_breakable_surf`, §2.5 step 2) fires zero-damage bullets and halves velocity — foreign projectiles routed through `PhysicsCollide` get it free; overriding `PhysicsCollide` (bolt-style) requires re-calling the base for it (`mcv_proj_bolt.lua:146-149`).
6. **Never call `SetAngles` on a flying VPhysics entity** (clears its velocity — the bolt bug, `BUGLIST.md:216`); use `SetRenderAngles` client-side or the swept flight.
7. **`baseclass.Get("...")` for cross-class calls** in this family (SetupDataTables/Initialize/OnRemove chain) — `self.BaseClass` recurses through intermediate subclasses (§1.4).
8. **Impact damage vs `Impact()` hook routing** (§2.5 step 3): with `ImpactDamage > 0` and a non-impact fuse, `Impact()` only ever runs for world hits (entities take collision damage instead); set `ImpactDamage = 0` if the subclass hook must see entity hits.
9. **TTT guard**: collision damage skips players on `terrortown` (`mcv_proj_base.lua:236`).
10. **`SafeRemoveEntityDelayed` + `Detonated`-gated `OnThink`** is the pattern for post-detonation residual effects (M202); `PreDetonate`'s idempotency makes re-entrant thinks safe.

### 8.5 Vestigial capacity free for the taking

`AudioLoop`, `FlareColor` sprite, `SmokeTrail` emitter, `StickyFuse`, `DefuseOnDamage`, `PickupAmmo`+`Defusable` on the base — all live and unclaimed (§2.11). A converter with a foreign feature (e.g. a beeping satchel, a glowing fuel rod) can often express it purely through these fields instead of new entity code.

---

## 9. File Map

All under `reference/mcv/lua/entities/`:

| File | Lines | Class | Role |
|---|---|---|---|
| `mcv_proj_base.lua` | 464 | `mcv_proj_base` | the projectile base: physics, fuses, collision, detonation, swept flight, render |
| `mcv_proj_40mm.lua` | 53 | `mcv_proj_40mm` | 40mm grenade (M79/GP-25); canonical Detonate |
| `mcv_proj_lunge_mine.lua` | 13 | `mcv_proj_lunge_mine` | contact/impact mine on the 40mm payload |
| `mcv_proj_rpg.lua` | 55 | `mcv_proj_rpg` | RPG-7 rocket; IsRocket + sphere template |
| `mcv_proj_rpg2.lua` | 55 | `mcv_proj_rpg2` | RPG-2 rocket (Part 2 weapon) |
| `mcv_proj_bazooka.lua` | 41 | `mcv_proj_bazooka` | Bazooka rocket (rpg child) |
| `mcv_proj_panzerschreck.lua` | 41 | `mcv_proj_panzerschreck` | Panzerschreck rocket (rpg child) |
| `mcv_proj_kolos.lua` | 41 | `mcv_proj_kolos` | Kolos volley rocket (rpg child) |
| `mcv_proj_m202.lua` | 84 | `mcv_proj_m202` | M202 rocket + 3 s post-detonation burn |
| `mcv_proj_riflegrenade.lua` | 53 | `mcv_proj_riflegrenade` | US rifle grenade (base default) |
| `mcv_proj_riflegrenade_vc.lua` | 53 | `mcv_proj_riflegrenade_vc` | VC rifle grenade |
| `mcv_proj_riflegrenade_ger.lua` | 6 | `mcv_proj_riflegrenade_ger` | German model on VC physics |
| `mcv_proj_bolt.lua` | 161 | `mcv_proj_bolt` | crossbow bolt: stick/retrieve/hitgroups |
| `mcv_proj_flare.lua` | 86 | `mcv_proj_flare` | US flare: burn, ignite ground, light |
| `mcv_proj_flare_vc.lua` | 10 | `mcv_proj_flare_vc` | VC flare skin/particles |
| `mcv_grenade_base.lua` | 101 | `mcv_grenade_base` | throwable explosive base + round collision |
| `mcv_grenade_frag.lua` | 7 | `mcv_grenade_frag` | frag alias |
| `mcv_grenade_wp.lua` | 12 | `mcv_grenade_wp` | WP burst + short fire pool |
| `mcv_grenade_molotov.lua` | 53 | `mcv_grenade_molotov` | impact fuse + fire pool + wick |
| `mcv_grenade_smoke.lua` | 105 | `mcv_grenade_smoke` | popping canister, networked color |
| `mcv_grenade_gas.lua` | 60 | `mcv_grenade_gas` | damaging cloud + gas-mask global |
| `mcv_placed_c4.lua` | 65 | `mcv_placed_c4` | remote charge |
| `mcv_placed_dynamite.lua` | 55 | `mcv_placed_dynamite` | lit-fuse charge |
| `mcv_placed_mine.lua` | 115 | `mcv_placed_mine` | tripwire mine |
| `mcv_mine_stake.lua` | 41 | `mcv_mine_stake` | tripwire stake (base_anim) |
| `mcv_thrown_melee.lua` | 71 | `mcv_thrown_melee` | retrievable thrown blade |
| `mcv_firepool.lua` | 84 | `mcv_firepool` | burning ground (base_anim) |
| `mcv_supply_box.lua` | — | `mcv_supply_box` | logistics entity — out of scope (`docs/special-weapon-bases.md`) |

Key external touchpoints (cross-referenced docs): `mcv/shared/sh_rocketflight.lua` (flight math → `docs/shooting-ballistics.md`), `mcv/shared/sh_explosions.lua` (effect families, `MCV.SurfaceAngle` → `docs/effects.md`), `mcv/shared/sh_burn.lua` (victim burning → `docs/support-systems.md`), `mcv/shared/sh_impacts.lua` (`MCV.BulletImpact` → `docs/effects.md`), `weapons/mcv_base/sh_shoot.lua` + `sh_npc.lua` (launch → `docs/gun-core.md`, `docs/shooting-ballistics.md`), `weapons/mcv_throwable/`, `mcv_placeable/`, `mcv_melee/`, `mcv_m79_base/`, `mcv_equipment_box/` (spawning bases → `docs/special-weapon-bases.md`), `mcv/client/cl_killicons.lua` (inflictor fallback icons). Upstream notes consulted: `AGENTS.md`/`CLAUDE.md` (weapon-owns-the-numbers doctrine, pack split), `BUGLIST.md` items 59, 61, 65, 67, 119, 123, 143, 157, 159, 161, 171, 181, 203, 216, 226, 326, 330, 353, 354, 356, 357, 359, 368, 369, 393, 400, 401 (see §2-§7 passim), `weapon_list.md` (Part 2 weapon names).
