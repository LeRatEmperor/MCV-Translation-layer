# MCV Base — HUD, Settings & Convars (Exhaustive Audit)

Task 11 of the MCV translation-layer engineering reference. This document exhaustively audits every clientside surface the player *sees* or *configures*: the weapon HUD (`cl_hud.lua`), fonts, kill icons, spawn-menu categories/subcategories, the convar registry (`sh_convars.lua` + `sh_categories.lua` + every `CreateClientConVar` in the tree), the Q-menu settings pages, localization strings, the developer HUD, and the userinfo control convars. The goal, as with the sibling `docs/animation-system.md`, is that a SWEP written for another base and re-parented onto MCV runs *perfectly* — which means we must know exactly which weapon fields, NetworkVars and accessor functions the HUD reads, what happens when they are missing, and which one-shot registrations (kill icons, icons on disk, category membership) a converted weapon must perform.

All paths are relative to `reference/mcv/lua/`. Realm tags: **CL** (clientside only), **SV** (serverside only), **SH** (shared / runs on both).

---

## 1. Architecture Overview

### 1.1 Where these files sit in the load order

The autorun loader (`autorun/sh_mcv_load.lua`) loads, in order: `mcv/shared/sh_convars.lua` **explicitly first**, then every other `mcv/shared/*` in name order (so `sh_categories.lua` — which calls `MCV.RegisterConVar` at file scope — loads *after* the helper exists), then all `mcv/client/*` on the client, then `mcv/server/*` on the server:

```lua
-- autorun/sh_mcv_load.lua:8-23
// The shared files come back in name order, and several of them register convars through the
// helper in sh_convars.lua, which some of them sort ahead of. It goes first.
local first = "sh_convars.lua"
...
loadshared(first)

for _, v in pairs(file.Find(searchdir .. "shared/*", "LUA")) do
    if v != first then
        loadshared(v)
    end
end
```

`cl_hud.lua` is **not** in `mcv/client/` — it lives in `mcv/weapon_common/` and is mixed into every weapon base by `weapon_common/load.lua`, which captures a fake `SWEP` table and copies it into the real base (`weapon_common/load.lua:21-33`). Consequence: the HUD convars `mcv_hud_hints` / `mcv_hud_enable` / `mcv_hud_crosshair` are created **when the weapon bases load**, not at autorun time. The settings menu tolerates this because it resolves convars lazily via `GetConVar(s.convar)` when the Q menu is first populated (`mcv/client/cl_settings.lua:151`), which is always after weapon registration.

The pure-client files (`cl_font`, `cl_killicons`, `cl_language`, `cl_subcategories`, `cl_settings`, `cl_devhud`, `cl_controls`, `cl_effectsettings`, `cl_viewsettings`, `cl_tracercolor`) load once at autorun, in filename order.

### 1.2 HUD entry points — who calls what

MCV uses **only standard engine-invoked SWEP hooks** for the main HUD; there is no `HUDPaint` hook in `cl_hud.lua` at all. The five engine entry points defined there:

| Hook (all CL) | Defined at | Purpose |
|---|---|---|
| `SWEP:DrawHUD()` | `mcv/weapon_common/cl_hud.lua:343` | Ammo block, hints, per-frame blend; engine calls it each frame for the **active weapon** |
| `SWEP:DoDrawCrosshair(x, y)` | `mcv/weapon_common/cl_hud.lua:413` | Dynamic crosshair; returning `true` suppresses the engine default crosshair |
| `SWEP:HUDShouldDraw(element)` | `mcv/weapon_common/cl_hud.lua:534` | Hides stock `CHudAmmo` / `CHudSecondaryAmmo` while the MCV HUD is enabled |
| `SWEP:DrawWeaponSelection(x, y, w, h, a)` | `mcv/weapon_common/cl_hud.lua:706` | Weapon-select icon + stat info box |
| `SWEP:TranslateFOV(fov)` | `mcv/weapon_common/cl_hud.lua:386` | Passes FOV through unchanged but *records* it (`self.TrueFOV`) for crosshair scaling |

Plus one real hook, added at file scope: `PreDrawHUD` → `MCV_HUDWeaponSwitch` → `observeHUDWeapon()` (`cl_hud.lua:63-75`), which watches `LocalPlayer():GetActiveWeapon()` each frame so the incoming weapon's HUD state is initialized *before* the first draw (see §2.3). The only `HUDPaint` hooks in the whole addon are the dev HUD (`mcv/client/cl_devhud.lua:20`) and the test harness (`mcv_harness/hud_transition_tests.lua:5`, which samples `GetHUDBlend` per frame into JSON).

Because everything rides on engine SWEP hooks, **HUD code only runs for the local player's active weapon** — other players' weapons never execute it, and no draw order exists between MCV weapons and foreign weapons beyond the engine's own.

### 1.3 What the HUD reads from the weapon

The HUD never touches the weapon's internals directly; it goes through three tiers:

1. **Shared-dt NetworkVars** (defined once in `weapon_common/shared.lua:196-279`, inherited by every MCV base): `GetHolsterTime()`, `GetLastRecoilTime()`, `GetAnimLockTime()`, `GetReloading()`, `GetSightAmountRaw()`, `GetSpeed()`, `GetFiremode()`, `GetBayonet()`, `GetGrenadeLauncher()`, `GetAkimbo()`, `GetHasSecond()`, `GetSafe()`, `GetBulletCount` is *not* a NetworkVar (see below). These are prediction-safe and exist for **any** weapon deriving from an MCV base.
2. **Accessor stubs with per-base overrides** — defaults live in `weapon_common/shared.lua:287-347` ("no such feature" behaviour): `GetSightAmountVisual()` (0), `GetFiremodeName()` (""), `GetHUDAmmo()` (nil, nil), `GetBulletCount()` (`self.Num or 1`), `GetProjectileClass()` (`self.ShootEntity`), `DrawHUDExtra()` (no-op), `GetControlHints()`. Guns override `GetFiremodeName`/`GetHUDAmmo` in `weapons/mcv_base/sh_gun.lua:60-72`.
3. **Plain SWEP fields**, mostly read by the weapon-selection info box: `PrintName`, `Country`, `Spread`, `SpreadIronsighted`, `FireRate`, `Caliber`, `DamageGeneric`, `RangeModifier`, `DamageRampDistance/Start/End`, `ExplosionDamage/Radius`, `Silencer`, `HasAkimbo`, `HasBayonet`, `HasBipod`, `HasScope`, `AdjustableScopes`, `ArmorPiercing`, `HasRifleGrenade`, `RifleGrenadeEntity`, `RifleGrenadeIsUBGL`, `ThrowEntity`, `PlacedEntityClass`, `Primary.*`, `IconOverride`, `DrawWeaponInfoBox`.

Two *visual chaser* accessors matter to the HUD specifically: `GetSightAmountVisual()` (`weapons/mcv_base/sh_sights.lua:74-81`; client-side eased version of the sight blend — on the server it aliases the raw value) and `GetSpeedVisual()` (`mcv/weapon_common/sh_think.lua:118`; the movement blend smoothed per frame so a prediction correction is absorbed over a few frames). The crosshair deliberately reads the **visual** variants, never the raw predicted values.

### 1.4 Realm summary

Everything in this audit's files is **CL** except: `sh_convars.lua`, `sh_categories.lua`, `weapon_common/cl_hud.lua` and `weapon_common/load.lua` (all **SH** — `cl_hud.lua` is in the shared `weapon_common` tree and is AddCSLuaFile'd + included on both realms, but all its functions only ever execute clientside because they are engine HUD hooks; the `CreateClientConVar` calls inside it are client-only and inert on the server). `cl_controls.lua`'s convars are created CL but **read by the server** via `Player:GetInfoNum` for prediction (`weapons/mcv_base/sh_sights.lua:98`, `weapons/mcv_base/sh_reload.lua:19`) — that is why they are `userinfo` archived.

---

## 2. `cl_hud.lua` — Complete Walkthrough (725 lines)

### 2.1 File header, constants and convars

The file's own contract, verbatim:

```lua
-- mcv/weapon_common/cl_hud.lua:1-5
// HUD for every MCV weapon: crosshair, the ammo block bottom right with the weapon's icon
// behind it, control hints that fade out after a deploy, and in / out animations on switching.
//
// Deploy need not run clientside. Observe the actual active weapon before drawing;
// holster-out still follows the predicted HolsterTime.
```

Module table `MCV.HUD` plus tuning constants (`cl_hud.lua:10-19`): `Color` (white 150 a), `ColorBright` (230), `ColorDim` (140), `ColorIcon` (white 70 a), `InTime` 0.35 s slide-in, `OutTimeDefault` 0.3 s, `SlideDistance` 24 ScreenScale units, `HintDuration` 6 s, `HintFade` 1 s, `HintStagger` 0.06 s per line. Crosshair constants at `cl_hud.lua:395-398`: `CrosshairSmooth` 12, `CrosshairKick` 0.75, `CrosshairKickTime` 0.15, `CrosshairBob` 2.5. Rolling-counter constants at `cl_hud.lua:204-206`: `CountUpTime` 0.25, `CountUpMin` 30, `CountUpResume` 0.25.

Local helper `ease(p)` — clamped ease-out cubic (`cl_hud.lua:26-29`). Three local convars are created at file scope (see §6): `mcv_hud_hints`, `mcv_hud_enable`, `mcv_hud_crosshair` (`cl_hud.lua:21-23`). `cv_developer = GetConVar("developer")` is cached at `cl_hud.lua:379` for the debug crosshair overlay.

### 2.2 Key labels — `HUD.KeyLabel(spec)` (CL)

`cl_hud.lua:35-56`. Converts a bind specification to display text: splits on whitespace, resolves each token through `input.LookupBinding` (tries `true` first — "don't include inactive binds" — then the plain form, then the raw token), applies a pretty-name map (`mouse1→LMB`, `mouse2→RMB`, `mouse3→MMB`, `shift→SHIFT`, `alt→ALT`, `ctrl→CTRL`, `space→SPACE`), else uppercases. Joins with `" + "`. A `"hold:"` prefix (e.g. `"hold:+attack"`) becomes `"Hold LMB"`. Callers: only `DrawHUDHints` (`cl_hud.lua:312`). This is why hint strings are written as `"+use +attack"` in `GetControlHints`.

### 2.3 Active-weapon observation and the deploy/holster blend

`observeHUDWeapon()` (`cl_hud.lua:63-74`, bound to `PreDrawHUD` as `MCV_HUDWeaponSwitch`) compares `LocalPlayer():GetActiveWeapon()` against `HUD.ActiveWeapon`; on change it resets the incoming weapon's client HUD state (`HUDLastFrame = nil`, `CrosshairReloadAlpha = 1`, `CrosshairWasReloading = false`, `CrosshairReloadUntil = nil`). This is the fix for BUGLIST's *"Weapon switching briefly showed the HUD fully on before sliding in"* — the observation now initializes the incoming HUD before drawing, and the outgoing HUD stays hidden through the handover (BUGLIST.md:270-272; the harness regression test is `mcv_harness/hud_transition_tests.lua`).

`SWEP:GetHUDBlend()` (`cl_hud.lua:77-115`) returns 0..1 — how far the HUD is "in":

```lua
-- mcv/weapon_common/cl_hud.lua:84-114
    // deploy: first frame this weapon is drawn again
    if self.HUDLastFrame == nil or frame < self.HUDLastFrame or frame - self.HUDLastFrame > 2
            or now < (self.HUDDeployTime or now) then
        self.HUDDeployTime = now
        self.HUDHolsterStart = nil
        self.HUDHintsStart = now
        self.HUDHintsShown = (self.HUDHintsShown or 0) + 1
        HUD.DeployCount = HUD.DeployCount or {}
        HUD.DeployCount[self:GetClass()] = (HUD.DeployCount[self:GetClass()] or 0) + 1
    end
    self.HUDLastFrame = frame

    local blend = ease((now - (self.HUDDeployTime or now)) / HUD.InTime)

    // holster: HolsterTime is CurTime() + animation length while the holster animation plays
    local ht = self:GetHolsterTime()
    if ht > now then
        if !self.HUDHolsterStart then
            self.HUDHolsterStart = now
            self.HUDHolsterLen = math.max(ht - now, 0.05)
        end
        local out = ease((now - self.HUDHolsterStart) / math.min(self.HUDHolsterLen, HUD.OutTimeDefault * 2))
        blend = blend * (1 - out)
    elseif ht < 0 or self.HUDHolsterStart then
        // The deadline can expire/clear one frame before ActiveWeapon changes.
        // Stay out through that handover instead of flashing fully on again.
        blend = 0
    else
        self.HUDHolsterStart = nil
    end

    return blend
```

Key mechanics:

- **Deploy detection is frame-based, not event-based**: "first frame this weapon is drawn again" = `HUDLastFrame` nil, or `FrameNumber()` went backwards, or a gap of more than 2 frames, or `CurTime()` went backwards (map change). This works even though the deploy/holster logic itself runs on the server / in prediction (`sh_deploy.lua:115` sets `SetHolsterTime(CurTime() + t)` when a holster starts; `sh_deploy.lua:37/100` clear it to 0).
- `HUD.DeployCount` is a **per-class, per-client-session** table used only by hint mode 2 ("first deploy of each weapon").
- Holster-out is clamped to `OutTimeDefault * 2` (0.6 s) even for long holster animations, and the `elseif ht < 0 or self.HUDHolsterStart` branch keeps the HUD fully out during the one-frame handover gap.
- `GetHUDBlend` is called from both `DrawHUD` and `DoDrawCrosshair` (`cl_hud.lua:346, 414`) — so it runs every frame even when the HUD is disabled, because the crosshair fades with the same blend.

Side effect fields (all on the weapon instance, CL-only): `HUDLastFrame`, `HUDDeployTime`, `HUDHolsterStart`, `HUDHolsterLen`, `HUDHintsStart`, `HUDHintsShown`, plus `HUD.ActiveWeapon` on the module table.

### 2.4 Icon plumbing — `GetHUDIcon`, `drawIconTilted`, `drawAvailabilityIcon`, `DrawHUDAvailability`

`SWEP:GetHUDIcon()` (`cl_hud.lua:134-144`): lazily caches `self.Mat_HUDIcon` from `self.IconOverride or "entities/<class>.png"` — **only if `file.Exists("materials/"..path, "GAME")`**, else caches `false` and returns nil. Safe-by-absence: a weapon with no icon file simply has no icon behind its counter.

```lua
-- mcv/weapon_common/cl_hud.lua:146-159
// A weapon icon mirrored (the game's icons face right) and turned so it faces up-left
local iconPoly = {{u = 1, v = 0}, {u = 0, v = 0}, {u = 0, v = 1}, {u = 1, v = 1}}
local function drawIconTilted(mat, cx, cy, size, col)
    // Fixed 45-degree rotation: reuse the four vertices instead of ten tables per draw.
```

`drawIconTilted` draws a 45°-rotated square via `surface.DrawPoly` with a preallocated vertex table (BUGLIST.md:77/83 record this as a deliberate allocation optimization — "reused HUD icon vertices"). `drawAvailabilityIcon` (`cl_hud.lua:163-176`) draws one icon, or two offset by 10% of size (a pair of pistols for dual wield), dimmed to 45% alpha when the feature is *active*.

`SWEP:DrawHUDAvailability(blend, right, y)` (`cl_hud.lua:178-196`): under the ammo counter, shows what the gun *could* do right now —
- **Akimbo**: if `self.HasAkimbo` and `self:GetHasSecond()` (Bool NetworkVar 13, set by `mcv/server/sv_second_weapon.lua` when a second copy is picked up), draws this weapon's own icon twice (`self:GetAkimbo()` Bool NW 11 = currently dual-wielding, dims the icons).
- **Bayonet**: if `self.HasBayonet`, scans `owner:GetWeapons()` for a carried weapon with `w.IsBayonet` and draws *its* icon (`self:GetBayonet()` Bool NW 8 = currently attached).

### 2.5 Rolling counters — `SWEP:RollHUDNumber(key, target, rolldown)` (CL)

`cl_hud.lua:208-243`. The design note is worth quoting:

```lua
-- mcv/weapon_common/cl_hud.lua:198-203
// A count that changes rolls instead of appearing: the number on screen chases the real one
// and covers the whole jump in CountUpTime, never slower than CountUpMin a second so that a
// small pickup is not sluggish. `rolldown` also rolls a falling count, which is what the
// reserve does, so a reload empties the reserve in step with the magazine filling. The
// magazine itself is left to snap downwards: a shot has to read at once or the counter lags
// behind the gun being fired.
```

State lives on the weapon instance under `key` (`"HUDAmmoRoll"`, `"HUDReserveRoll"`). Behaviour: `target == nil` clears the state and returns nil; a state not seen for more than `CountUpResume` (0.25 s) — holstered / HUD hidden — is re-seeded at the current target (no roll on return); a *decrease* with `rolldown` false (magazine) snaps instantly downward; anything else rolls at `max(|Δ|/CountUpTime, CountUpMin)` per second, `floor`ing on the way up and `ceil`ing on the way down so the displayed number never lies past the true one. Time base is `RealTime()`/`RealFrameTime()` (menu-safe), unlike the rest of the HUD which uses `CurTime()`.

### 2.6 The ammo block — `SWEP:DrawHUDAmmo(blend)` (CL)

`cl_hud.lua:246-283`. Layout, bottom-right of the screen:

| Element | Font | Position (right = `ScrW() - ScreenScale(16) + slide`) |
|---|---|---|
| Weapon icon behind counter | — | centered at `(right - 36, sh - 30)`, `ScreenScale(72)` square, `HUD.ColorIcon` (alpha 70), **mirrored UVs** (`DrawTexturedRectUV(..., 1, 0, 0, 1)`) so the muzzle faces screen centre; the spawn icon's glyph sits in the middle 256×128 band of a 256×256 image, so a 128-wide box shows it with no dead space (`cl_hud.lua:256-257`) |
| Fire-mode label | `MCV_8` | `right`, `sh - 20` |
| Availability icons (§2.4) | — | row at `sh - 10` |
| Magazine count | `MCV_24` | `right - 28`, `sh - 40` |
| Reserve count | `MCV_14` | `right + 4`, `sh - 32` |

Data: `firemode_name = self:GetFiremodeName() or ""`; `ammocount, reserve = self:GetHUDAmmo()`, then both pass through `RollHUDNumber` (magazine without rolldown, reserve with). `if ammocount == nil then return end` — a weapon whose `GetHUDAmmo` returns nil draws the icon and fire-mode label but **no numbers** (melee, binoculars). The whole block slides right by `SlideDistance * (1 - blend)` during in/out.

`GetHUDAmmo` implementations across the bases (what the counter actually shows):

- **Guns** — `weapons/mcv_base/sh_gun.lua:66-72`: `Clip1(), Ammo1()`, or `Clip2(), Ammo2()` when `GetGrenadeLauncher()` (the UBGL/rifle-grenade mode swaps the counter to secondary ammo). Fire-mode label from `MCV.FiremodeNames[GetFiremodeValue()]` (`sh_gun.lua:60-64`, table at `mcv/shared/sh_common.lua:28-42`: Automatic, Single-Fire, 3-Round Burst, Single-Action, Double-Action, Fan Fire, Bolt-Action, Pump-Action, Fast-Fire, Slow-Fire, Volley, HE, Buckshot) or `"Launcher"`.
- **Throwables** — `weapons/mcv_throwable/sh_throw.lua:47-56`: count from `GetRoundsLeft()`, no reserve; label `"Impact"` or `"Fuse 3.0s"`.
- **Equipment boxes** — `weapons/mcv_equipment_box/sh_box.lua:3-9`: `"Medic Box"`/`"Ammo Box"`, count only.
- **Placeables** — `weapons/mcv_placeable/sh_place.lua:14-22`: contextual labels (`"Place stake"`, `"Right click: detonate"`), count only.
- **Flamethrowers** — `weapons/mcv_flamethrower/sh_flame.lua:5-11`: `Ammo1()`, label `"Fuel"`.
- **Binoculars** — `weapons/mcv_binoculars/shared.lua:39-40`: no numbers; the label is the current magnification (`"7x"`).
- **Melee** — `weapons/mcv_melee/sh_melee.lua:12-13`: nothing at all.

There is **no akimbo-specific counter** — a dual-wielded pair still shows one `Clip1` (the akimbo system alternates guns but they share the ammo pool; the dual icons of §2.4 are the only akimbo HUD indicator). Low-ammo has **no special state**: an empty magazine simply reads `0` (the counter is never tinted red etc.).

### 2.7 Control hints — `DrawHUDHints` and `GetControlHints`

`SWEP:DrawHUDHints(blend)` (`cl_hud.lua:286-333`):

- Gate on `mcv_hud_hints`: `mode <= 0` off; `mode == 2` only while `HUD.DeployCount[class] <= 1`; `mode >= 3` never fades (`life = 1`). Otherwise the hints live for `HintDuration` (6 s) then fade over `HintFade` (1 s) from `HUDHintsStart` (set at deploy, §2.3).
- Deliberate early-out: *"Most frames are past the hint timeout: don't build nested hint tables or query weapon state until there is something visible to draw"* (`cl_hud.lua:297-298`) — `self:GetControlHints()` is not even called on faded frames (BUGLIST.md:81 records this optimization).
- Layout: lines stack **upwards** from `sh - 58`, line height `ScreenScale(9)`, drawn in reverse index so each line slides in `HintStagger` after the one below it. The key column is right-aligned to the widest label (`MCV_8`, measured with `surface.GetTextSize`); the action text is right-aligned at `right`, keys in `ColorBright`, text in `ColorDim`.

`SWEP:GetControlHints()` — the default in `cl_hud.lua:336-341` is `{"+attack", "Fire"}, {"+use +attack", "Bash"}`. The comment: *"every base overrides with its own controls"*. The gun version is the richest (`weapons/mcv_base/sh_gun.lua:83-113`):

```lua
-- weapons/mcv_base/sh_gun.lua:83-113
// Controls shown by the HUD after a deploy and in the weapon selection info
function SWEP:GetControlHints()
    local h = {}
    local safe = self:GetSafe()
    if !safe then
        table.insert(h, {"+attack", "Fire"})
        table.insert(h, {"+attack2", self:UsesToggleAim() and "Toggle aim" or "Aim"})
    end
    table.insert(h, {"+reload", "Reload"})
    if #self.Firemodes > 1 and !self:GetGrenadeLauncher() then
        table.insert(h, {"+use +reload", "Fire mode"})
    elseif self.AdjustableScopes and !self:GetGrenadeLauncher() then
        table.insert(h, {"+use +reload", "Scope magnification"})
    end
    ...
    table.insert(h, {"+use +walk", safe and "Weapon Ready" or "At Ease"})
    return h
end
```

All overriders (grep `function SWEP:GetControlHints`): `mcv_base/sh_gun.lua:83`, `mcv_melee/sh_melee.lua:485`, `mcv_throwable/sh_throw.lua:327`, `mcv_flamethrower/sh_flame.lua:274`, `mcv_underbarrel_flame/shared.lua:65`, `mcv_equipment_box/sh_box.lua:219`, `mcv_placeable/sh_place.lua:488`, `mcv_binoculars/shared.lua:89`, `mcv_chainsaw.lua:153`, `mcv_fists.lua:40`, `mcv_lunge_mine.lua:29`. Note `UsesToggleAim()` reads the **userinfo convar** `mcv_toggle_aim` server-side via `owner:GetInfoNum` (`weapons/mcv_base/sh_sights.lua:96-98`) — the hint text is prediction-accurate per player.

### 2.8 `SWEP:DrawHUD()` — the frame function

```lua
-- mcv/weapon_common/cl_hud.lua:343-354
function SWEP:DrawHUD()
    if !cv_hud_enable:GetBool() then return end

    local blend = self:GetHUDBlend()

    self:DrawHUDExtra()

    if blend <= 0 then return end

    self:DrawHUDAmmo(blend)
    self:DrawHUDHints(blend)
end
```

Three things to note: (1) with `mcv_hud_enable 0` the whole HUD including `DrawHUDExtra` is skipped; (2) **`DrawHUDExtra` runs before the blend gate** — the extension hook draws even while the HUD is sliding in/out or holstered (the binocular overlay fades with its own `GetSightAmountVisual` alpha, not with the HUD blend; `weapons/mcv_binoculars/shared.lua:108-118`); (3) the only base override of `DrawHUDExtra` is the binocular mask — scope overlays are *not* here, they live in `mcv/client/cl_scopeoverlay.lua` (see sibling `docs/gun-core.md`).

### 2.9 The crosshair

FOV plumbing first: `SWEP:ScaleFOVByWidthRatio` (`cl_hud.lua:360-366`, standard Source helper) and `SWEP:WidescreenFix(target)` (`cl_hud.lua:368-370`) convert a 4:3 FOV to the current aspect. `SWEP.TrueFOV = 90` default (`cl_hud.lua:384`) is updated by `SWEP:TranslateFOV(fov)` (`cl_hud.lua:386-390`), which returns the FOV unchanged — its only job is recording what the player actually sees so the crosshair can convert spread degrees to pixels: `scale = ScrH() / WidescreenFix(TrueFOV)` (`cl_hud.lua:450-451`).

`SWEP:GetCrosshairSpread()` (`cl_hud.lua:400-405`): `self:GetSpread() * 100` if the gun defines `GetSpread` (guns do — `weapons/mcv_base/sh_shoot.lua:361`, returns **degrees**, stance/bipod/movement-multiplied), else `self.Spread or 0`. `SWEP:GetCrosshairKick()` (`cl_hud.lua:407-411`): squared decay over `CrosshairKickTime` (0.15 s) since `GetLastRecoilTime()` (Float NW 2; set on every shot, `weapons/mcv_base/sh_shoot.lua:426`).

`SWEP:DoDrawCrosshair(x, y)` (`cl_hud.lua:413-527`) — the full state machine:

1. **Reload fade**: `CrosshairReloadAlpha` approaches 0 while `GetReloading()` (Bool NW 0); when reloading stops, `CrosshairReloadUntil = GetAnimLockTime()` so the crosshair stays hidden through shotgun finishing/pump animations (BUGLIST.md:273: *"Crosshairs fade during reload, including the finishing/pump stage of shell reloads"*). Approach rate `FrameTime() * 8`.
2. **Master alpha**: `a = (1 - GetSightAmountVisual()) * 100 * blend * CrosshairReloadAlpha`; `if a <= 0 then return true end` — the crosshair is suppressed when aiming (scopes/irons), while the HUD is out, and while reloading, and returning `true` also suppresses the *engine's* default crosshair.
3. **Convar gate**: `if !cv_hud_crosshair:GetBool() then return end` — note it returns **nil** here, so with `mcv_hud_crosshair 0` and `SWEP.DrawCrosshair = true` (`weapon_common/shared.lua:179`) the engine falls back to drawing the stock HL2 crosshair at hip. The convar is "MCV crosshair off", not "no crosshair".
4. **Realistic-mode aim tracking** (`cl_hud.lua:436-445`): under `MCV.RealisticShooting()` the crosshair centre moves to follow eye angles + 2× view punch (the shot direction), projected at 4096 units — *"the crosshair follows the view punch (twice it, as the shot does) but not the hip sway: it stays put and grows by the sway's peak instead, so the shot always lands inside it"*. NaN-guarded (`scr.x == scr.x`).
5. **Gap**: `target = scale * (spread + sway + max(self.Spread or 0, 0.5) * CrosshairKick * kick)` where `sway = GetAimSwayAmplitude(true) * 1.2` (defined `weapons/mcv_base/sh_shoot.lua:317-332`, 0 unless realistic mode). `self.CrossGap` chases it with asymmetric smoothing — opens at 3× `CrosshairSmooth`, closes at 1× (`cl_hud.lua:462-468`): *"opens instantly, closes smoothly"*. BUGLIST.md:446 records that the sway amplitude (and hence the crosshair bloom) damps to 0 on a deployed bipod and during reloads, easing over a quarter second.
6. **Walk bob**: a figure-of-eight, `CrossBobPhase` advancing with `GetSpeedVisual() / SpeedSprint` (`SpeedSprint` default 273, `mcv/weapon_common/sh_think.lua:39`); zeroed in mid-air; amplitude `CrosshairBob * speed`, vertical at 0.6×.
7. **Shape**: a centre dot (`ScreenScale(1)`), then either **circles** (`surface.DrawCircle` ×2 + 2 shadow rings) when `self.CrosshairCircle` (flamethrower sets it — `weapons/mcv_flamethrower/shared.lua:10`; BUGLIST.md:139) or `GetBulletCount() > 1` (shotguns), or **four lines** (`ScreenScale(4)` long) when `self.Spread > 0`. A weapon with `Spread == 0` and one bullet gets the dot only.
8. **Developer overlay** (`cl_hud.lua:499-524`, `developer 1`): white dot, VM cycle, `GetSequenceActivityName / GetSequenceName`, and `RANGE MULT` via `MCV.BulletRangeMultiplier(self, dist)` (`mcv/shared/sh_physbullets.lua:42-49`) at the eye trace distance. BUGLIST.md:437 records a historical bug where the displayed RANGE MULT lied because the damage callback dropped the falloff.

Everything is drawn with `drawshadowrect` (`cl_hud.lua:372-377`): a filled rect plus a black outline at 100/150 of the fill alpha. The two module-level `Color` objects (`crosshair_col`, `crosshair_shadow`) are mutated per frame rather than allocated.

### 2.10 `SWEP:HUDShouldDraw(element)` — stock HUD suppression

```lua
-- mcv/weapon_common/cl_hud.lua:529-537
local shoulddraw = {
    ["CHudAmmo"] = true,
    ["CHudSecondaryAmmo"] = true,
}

function SWEP:HUDShouldDraw(element)
    if !cv_hud_enable:GetBool() then return end
    if shoulddraw[element] then return false end
end
```

Only the two stock ammo panels are hidden, and **only while `mcv_hud_enable` is on** — disabling the MCV HUD restores GMod's default ammo counter (a deliberate fallback). Health, suit, etc. are untouched.

### 2.11 Weapon selection — info rows, tags, the box, the icon

`boxes(f)` (`cl_hud.lua:543-554`): a 10-glyph bar of `■`/`□` for the 0..1 stat meters.

`SWEP:GetWeaponInfoRows()` (`cl_hud.lua:557-628`) — pure data, `"Label:"` + value pairs (comment: *"Plain data rows keep labels and values aligned independently of font metrics"*). Rows and their conditions:

| Row | Condition | Value |
|---|---|---|
| Ammo | `AmmoPerShot > 0` and `Primary.Ammo != "none"` | `language.GetPhrase(ammo .. "_ammo")` (see §8); selectable launchers use `GetSelectedAmmo()` |
| Damage | `DamageGeneric > 0`, no projectile, not smoke | `DamageGeneric × BulletRangeMultiplier(0)`–`(DamageRampDistance)` as a range when `DamageRampDistance > 0`, plus a "Full power" row in metres (`× 0.0254`); else plain damage, `×N` when `GetBulletCount() > 1` |
| Blast damage / radius | explosion damage resolves through the projectile's defaults when the weapon's own are 0 (`LaunchProjectile` fallback) | scaled by `StatMult("explosion_damage"/"explosion_radius", category)` |
| Smoke colour | throwable with `SmokeParticle` and `Hurts == false` | a colour **swatch** row instead of blast rows |
| GL/RG damage / radius | `HasRifleGrenade` | prefix `"GL "` (UBGL) or `"RG "`, category `MCV.CATEGORY_RIFLE_GRENADE` |
| Fire Rate | `FireRate > 0` | `"600 RPM"` |
| Capacity | `Primary.ClipSize > 0` | `"30 (+1)"` with `Primary.Chamber` |
| Range | `FireRate > 0`, no projectile, `0 < RangeModifier < 1` | `boxes` meter of `-346.571 / ln(RangeModifier)` clamped to 10 000 units |
| Caliber | `Caliber` set | string |
| Spread / Accuracy | `FireRate > 0` | if `SpreadIronsighted == Spread`: `boxes(log(1+Spread/3))`; else an "Accuracy" meter from both spreads |
| Recoil | `FireRate > 0` | `boxes` of the mean of the two up-slides plus both right-slides, × 0.5 |

`SWEP:GetWeaponInfoTags()` (`cl_hud.lua:630-642`): bracketed tags `[DUAL] [RG] [GL] [SD] [BI] [BAYO] [VS] [AP]` from `HasAkimbo`, `HasRifleGrenade`+`RifleGrenadeIsUBGL`, `Silencer`, `HasBipod`, `HasBayonet`, `HasScope and AdjustableScopes`, `ArmorPiercing`.

`SWEP:PrintWeaponInfo(x, y, alpha)` (`cl_hud.lua:644-702`): gated by `self.DrawWeaponInfoBox != false` (`weapon_common/shared.lua:181` default true). Builds a cached `markup.Parse` layout (title `MCV_HudSelectionTitle`, country line `MCV_HudSelectionDesc`, rows in `MCV_HudSelectionText`), keyed by `InfoLayoutKey` = textWidth + `MCV.SelectionFontRevision` + PrintName + Country + tags + all row contents — so a resolution change (font regen bumps `SelectionFontRevision`, §3) or any stat change rebuilds it. Label column width is measured then padded by `12 * scale` because *"Markup's per-glyph rounding can exceed GetTextSize's whole-string width. Leave breathing room so labels such as Accuracy do not wrap at 4K"* (`cl_hud.lua:667-669`). The box is a `draw.RoundedBox(8*scale, ..., Color(60,60,60,alpha))`, clamped inside the screen; smoke-colour rows draw a 12×scale swatch instead of text. Everything scales with `ScreenScale(1)/3` (BUGLIST.md:133 records the scaling rework: *"Weapon info box omits controls and scales fonts, wrap width, padding and bubble with ScreenScale"*).

`SWEP:DrawWeaponSelection(x, y, w, h, a)` (`cl_hud.lua:706-725`): anchors the info box at `x + w + ScreenScale(20/3), y + h * 0.95` *before* adjusting the icon bounds; loads `self.Mat_Select = Material(self.IconOverride or "entities/<class>.png", "smooth mips")` — **no `file.Exists` guard here** (unlike `GetHUDIcon`); with `IconOverride` the icon rect shrinks by 128 and shifts +64 (custom icons are full-square); the icon draws as `w × w` (square), centred vertically when `w > h`; then calls `PrintWeaponInfo`.

### 2.12 Failure modes with non-MCV / converted weapons

For a weapon that does **not** derive from an MCV base, none of this code runs at all (the hooks live on the base's SWEP table) — the engine HUD applies. For a weapon that **does** derive from an MCV base but was authored elsewhere:

- Missing `entities/<class>.png`: ammo block silently drops the icon (`GetHUDIcon` returns nil) — but the **weapon selection shows the purple/black error material** (`Material()` with no existence check, `cl_hud.lua:710`).
- All NetworkVar accessors exist automatically (shared dt layout is fixed, `weapon_common/shared.lua:194-195`: *"Derived bases must not redefine SetupDataTables"*).
- Default stubs make every accessor nil-safe (`GetFiremodeName` "", `GetHUDAmmo` nil/nil → numbers just don't draw).
- The info box reads many optional plain fields; all are `(x or 0)`-guarded except `self.Primary.Ammo`/`self.Primary.ClipSize`, which require a `Primary` table (guaranteed by `weapon_common/load.lua:23`'s `SWEP = {Primary = {}, Secondary = {}}` and every base's own `Primary`).
- A foreign `GetSpread` override with different **units** (radians, MOA, "0.02 means tight") directly corrupts the crosshair gap (`GetCrosshairSpread` multiplies by 100 and treats the result as degrees of cone); a foreign `GetReloading`/`GetAnimLockTime` override of different semantics breaks the reload fade. The translation layer should ensure these return MCV semantics or override `GetCrosshairSpread`.

---

## 3. Fonts — `mcv/client/cl_font.lua` (60 lines, CL)

```lua
-- mcv/client/cl_font.lua:2-22
local sizes_to_make = { 24, 14, 8 }

local function generatefonts()
    local font = "consolas"
    for _, i in pairs(sizes_to_make) do
        surface.CreateFont( "MCV_" .. tostring(i), {
            font = font,
            size = math.Round(ScreenScale(i)),
            weight = i < 16 and 650 or 600,
            antialias = true,
            additive = false,
            extended = true, -- Required for non-latin fonts
        } )
```

Complete font registry:

| Font name | Face | Size | Weight | Consumers |
|---|---|---|---|---|
| `MCV_24` | consolas | `ScreenScale(24)` | 600 | magazine count (`cl_hud.lua:278`) |
| `MCV_14` | consolas | `ScreenScale(14)` | 600 | reserve count (`cl_hud.lua:282`) |
| `MCV_8` | consolas | `ScreenScale(8)` | 650 | fire-mode label, hint keys/text (`cl_hud.lua:271,308,324-325`), dev HUD readout (`cl_devhud.lua:49`) |
| `MCV_HudSelectionTitle` | Verdana | `ScreenScale(20/3)` | 700 | info-box title (`cl_hud.lua:661`) |
| `MCV_HudSelectionDesc` | Verdana | `ScreenScale(14/3)` | 700 | info-box country line (`cl_hud.lua:662`) |
| `MCV_HudSelectionText` | Verdana | `ScreenScale(14/3)` | 500 | info-box rows and tag footer (`cl_hud.lua:664,671-672,676`) |

`generatefonts()` runs at load; `MCV.Regen()` (`cl_font.lua:52-54`) re-runs it, and is called by (a) the `MCV_font_reload` concommand (`cl_font.lua:56`) and (b) `OnScreenSizeChanged` (`cl_font.lua:58-60`). Every regen increments `MCV.SelectionFontRevision` (`cl_font.lua:47`), which is part of `PrintWeaponInfo`'s layout cache key (`cl_hud.lua:651`) so stale markup is discarded after a resolution change. `extended = true` is set for non-Latin glyph support — relevant if a translation layer ever localizes hint strings. All sizes are `ScreenScale`-derived, so fonts are resolution-proportional, not fixed pixels.

---

## 4. Kill Icons — `mcv/client/cl_killicons.lua` (43 lines, CL)

The whole file is one `Initialize` hook (so `weapons.GetList()` is complete):

```lua
-- mcv/client/cl_killicons.lua:10-43 (blank lines elided)
local COLOR = Color(255, 80, 0, 255)  // gamemodes/base/gamemode/cl_deathnotice.lua

// the fields a weapon names its entity in
local ENTITY_KEYS = {"ShootEntity", "ThrowEntity", "ThrownEntity", "PlacedEntityClass", "StakeEntityClass"}

// after every weapon file has been read, so weapons.GetList is complete
hook.Add("Initialize", "MCV_KillIcons", function()
    local n, aliases = 0, 0

    for _, wep in ipairs(weapons.GetList()) do
        local class = wep.ClassName

        if !class or class:sub(1, 4) != "mcv_" then continue end

        local mat = "entities/" .. class .. ".png"
        if !file.Exists("materials/" .. mat, "GAME") then continue end

        killicon.Add(class, mat, COLOR)
        n = n + 1

        for _, key in ipairs(ENTITY_KEYS) do
            local ent = wep[key]

            // first weapon wins where several fire the same projectile: the alias only shows
            // when the weapon itself is gone by the time the thing goes off
            if isstring(ent) and ent != "" and !killicon.Exists(ent) then
                killicon.AddAlias(ent, class)
                aliases = aliases + 1
            end
        end
    end

    MsgN(string.format("[mcv] %d kill icons, %d aliases for their projectiles", n, aliases))
end)
```

Semantics:

- **Tint** `Color(255, 80, 0, 255)` copies the stock death-notice icon colour from the base gamemode (BUGLIST.md:448 tells the story: *"every weapon shows its own spawn menu icon in the kill feed, tinted the colour the game's own icons use"*).
- **Registration requirements** for a weapon to get a kill icon: (1) class name starts with `"mcv_"`, (2) `materials/entities/<class>.png` exists. Both must hold — the prefix check is hard-coded.
- **Projectile aliases**: every weapon's `ShootEntity` / `ThrowEntity` / `ThrownEntity` / `PlacedEntityClass` / `StakeEntityClass` string is aliased to the weapon's class, so a grenade that detonates *after* its launcher was swapped away still shows the launcher's icon. First registrant wins.
- Why aliases are needed at all: bullets name the weapon as inflictor (nothing to do), but explosions name the weapon *while it still exists* — `ENT:GetInflictor()` in `entities/mcv_proj_base.lua:180-182` returns `self.Inflictor` (the weapon) when valid, else the projectile itself. The alias covers the "weapon gone" branch.
- A class with no icon and no alias falls back to the game's default kill icon, as before (file header, `cl_killicons.lua:7-8`).
- Console reports the count at Initialize (`[mcv] N kill icons, M aliases...`).

**Translation-critical**: a converted weapon whose class does not begin with `mcv_` gets **no** kill icon from this loop even if it ships an icon file. The translation layer must either re-run an equivalent registration for its own prefix or add its own `killicon.Add` calls (see §11).

---

## 5. Categories & Subcategories

### 5.1 Stat categories — `mcv/shared/sh_categories.lua` (99 lines, SH)

This file is *not* about the spawn menu — it defines **per-category gameplay stat multipliers**, one replicated convar per (category, stat) pair, all defaulting to 1 (`sh_categories.lua:1-11` header). Two special categories: `MCV.CATEGORY_RIFLE_GRENADE = "Rifle Grenades"` (a rifle grenade/UBGL round answers to this, *not* the host rifle's category — the rifles that carry one sit across five categories; `sh_categories.lua:15-18`) and `MCV.CATEGORY_ALL = "All"` (every weapon reads it *as well as* its own, the two multiplying; `sh_categories.lua:20-22`).

`MCV.Categories` (`sh_categories.lua:25-33`) — 20 entries, in menu order: `All`, `Pistols`, `Machine Pistols`, `Revolvers`, `Submachine Guns`, `Assault Rifles`, `Carbines`, `Battle Rifles`, `Bolt-Action Rifles`, `Sniper Rifles`, `Shotguns`, `Light-Machine Guns`, `Anti-Armor`, `Explosives`, `Grenades`, `Flamethrowers`, `Bows`, `Melee`, `Equipment`, `Rifle Grenades`.

`MCV.CategoryStats` (`sh_categories.lua:35-47`) — 9 stats: `damage`, `penetration`, `spread`, `spread_sights`, `recoil`, `firerate` ("Does not affect animation-paced weapons"), and the `projectile = true` trio `explosion_damage`, `explosion_radius`, `projectile_speed` (menu shows these only for launching categories, §7).

Helpers:
- `MCV.CategorySlug(category)` (`sh_categories.lua:50-52`): lowercase, non-alphanumerics → `_`, trimmed — `"Light-Machine Guns"` → `light_machine_guns`.
- `MCV.CategoryConVarName(category, stat)` (`sh_categories.lua:54-68`): `"mcv_cat_" .. slug .. "_" .. stat`, memoized per category in `categoryNames`.
- The registration loop (`sh_categories.lua:70-81`): 20 × 9 = **180 replicated convars**, default `"1"`, help text distinguishing the `All` variant ("on top of whatever its own category is set to").
- `readMult` / `MCV.CategoryMult(category, stat)` (`sh_categories.lua:86-99`): `All × own`; a missing convar counts as 1, and **a negative value counts as 1** (clamp in `readMult`), so a weapon with no `SubCategory` still follows `All`.

The consumer is `SWEP:StatMult(stat, category)` (`mcv/weapon_common/shared.lua:80-82`) → `MCV.CategoryMult(category or self.SubCategory, stat)` — used all over the weapon code (damage, spread, recoil, penetration, explosion stats...) and in the HUD's info-box damage/explosion rows (§2.11).

### 5.2 Spawn-menu taxonomy — `mcv/client/cl_subcategories.lua` (121 lines, CL)

Weapons themselves carry three plain fields, e.g. `weapons/mcv_rpd.lua:9-11`: `SWEP.Category = "Military Conflict: Vietnam"` (the top-level spawn-menu tab), `SWEP.Country = "Soviet Union"` (info-box line, not a menu level), `SWEP.SubCategory = "Light-Machine Guns"` (the second level — **the same string as the stat category**, which is the whole point: the stat multipliers are keyed off the spawn-menu grouping).

`cl_subcategories.lua` re-populates the sandbox weapons tab after the default populate has run. Mechanics (the file opens with the deadpan `-- Taken straight from MCV's implementation. It just works`):

- Hook `PopulateWeapons` named `"zzz_MCV_SubCategories"` (`cl_subcategories.lua:3`) — the `zzz_` name orders it after the sandbox's own populate — then `timer.Simple(0, ...)` defers one tick so the tree nodes exist (`cl_subcategories.lua:5`).
- Filters to `weapon.Spawnable` and `weapons.Get(k).MilitaryConflictVietnam` (`cl_subcategories.lua:13-14`) — the flag is set by `weapon_common/shared.lua:184`, so **every MCV-derived weapon is automatically in**.
- Builds `Categorised[Category][SubCategory]` with `SubCategory` defaulting to `"Other"` (`cl_subcategories.lua:17-37`).
- For each tree node whose text is a category containing MCV weapons, it **overwrites `node.DoPopulate`** (`cl_subcategories.lua:50-90`): a fresh `ContentContainer`, a `ContentHeader` per subcategory when the category has more than one, an optional random-weapon group icon (`MCV.CreateRandomWeaponIcon`, `mcv/client/cl_random_weapons.lua:46-51`), then each weapon sorted by `PrintName` via `SortedPairsByMemberValue`. Icon resolution: `ent.IconOverride or weapon.IconOverride or "entities/<class>.png"`, with the comment *"Spawn-list entries can omit inherited SWEP fields. Resolve the registered weapon too, so variants reuse their base icon"* (`cl_subcategories.lua:79-87`).
- Appends a `"Miscellaneous"` node (`icon16/help.png`) populated by `MCV.PopulateRandomWeaponMisc` — random-weapon groups by "Mixed groups"/"Countries"/"World War II" (`cl_subcategories.lua:97-112`, `cl_random_weapons.lua:53-63`).
- Re-selects the first node (`cl_subcategories.lua:116-119`).

**Translation hazard (verified in code)**: because `DoPopulate` is replaced wholesale for any top-level category that contains *at least one* MCV-derived weapon, a converted foreign weapon left in its original `Category` (say `"ArcCW"`) hijacks that entire spawn category node — the non-converted siblings vanish from the menu. Converted weapons should set `Category = "Military Conflict: Vietnam"` (and a sensible `SubCategory`, ideally one of the 20 in `MCV.Categories` so stat multipliers apply).

`weapon_list.md` is the upstream inventory: 244 spawnable classes grouped by these same subcategory headings (Anti-Armor, Assault Rifles, ...).

---

## 6. Convars — the Complete Registry

### 6.1 The registration helper — `mcv/shared/sh_convars.lua` (56 lines, SH)

```lua
-- mcv/shared/sh_convars.lua:9-16
function MCV.RegisterConVar(name, default, help, flags)
    local cv = GetConVar(name)
    if !cv then
        cv = CreateConVar(name, default, bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY, flags or 0), help)
    end
    MCV.ConVars[name] = cv
    return cv
end

function MCV.GetConVar(name)
    return MCV.ConVars[name]
end
```

Server gameplay convars are therefore always **archived + replicated + notify** (a listen server's choice reaches clients; predicted code reads the same value on both realms — file header `sh_convars.lua:1-5`). Idempotent: an existing convar of the same name is adopted, not duplicated. Accessors defined alongside: `MCV.RealisticShooting()`, `MCV.SpawnRifleGrenadeAmmo()`, `MCV.BulletPenetration()` (`sh_convars.lua:32-48`).

### 6.2 Server convars (SH, replicated; 11 + 180 category = 191)

| Convar | Default | What it does | Consumed where |
|---|---|---|---|
| `mcv_realistic_shooting` | 0 | Alternate handling schema (barrel-accurate hip fire, random kick, aim sway); 0 = the game's own cone/view-slide recoil | `MCV.RealisticShooting()` — shooting, spread, sway, **crosshair aim-follow + sway bloom** (`cl_hud.lua:436,458`) |
| `mcv_spawn_rifle_grenade_ammo` | 1 | Starting rifle-grenade/UBGL ammo on newly spawned rifles | `MCV.SpawnRifleGrenadeAmmo()` — deploy/give code (BUGLIST.md:299-303) |
| `mcv_bullet_penetration` | 1 | Bullets through thin cover | `MCV.BulletPenetration()` — penetration code (BUGLIST.md:277-278) |
| `mcv_surface_impacts` | 1 | MCV impact effects/decimals vs stock GMod | registered `mcv/shared/sh_impacts.lua:18`; `SWEP:DoImpactEffect` (`weapon_common/shared.lua:305-307`) |
| `mcv_physbullets` | 0 | Simulate travel time/drop from `MuzzleVelocity` | physbullet system (`sv/cl_physbullets*`) |
| `mcv_physbullets_npcs` | 0 | Physical bullets for NPC guns | physbullet system |
| `mcv_physbullets_pellets` | 0 | Individual shotgun pellets | physbullet system |
| `mcv_physbullets_velocity` | 1 | MuzzleVelocity multiplier | physbullet system |
| `mcv_physbullets_gravity` | 1 | Bullet gravity multiplier | physbullet system |
| `mcv_physbullets_drag` | 0 | Linear air resistance per second | physbullet system |
| `mcv_physbullets_lifetime` | 5 | Max flight time (s) | physbullet system |
| `mcv_cat_<category>_<stat>` ×180 | 1 | Per-category stat multiplier (9 stats × 20 categories incl. `All`) | `MCV.CategoryMult` → `SWEP:StatMult` (§5.1) |

Note: BUGLIST.md:383 mentions a historical `mcv_hybrid_reload` convar (stripper-clip rifles); **it does not exist at commit 06f4a24b** (grep-verified) — superseded.

### 6.3 Client convars (CL; 21 total)

| Convar | Default | Archived | Userinfo | Created in | Consumed where |
|---|---|---|---|---|---|
| `mcv_hud_enable` | 1 | yes | no | `cl_hud.lua:22` | `DrawHUD` gate, `HUDShouldDraw` (§2.8/§2.10) |
| `mcv_hud_hints` | 1 | yes | no | `cl_hud.lua:21` | hint mode 0–3 (§2.7) |
| `mcv_hud_crosshair` | 1 | yes | no | `cl_hud.lua:23` | `DoDrawCrosshair` (§2.9) |
| `mcv_toggle_aim` | 0 | yes | **yes** | `cl_controls.lua:2` | server-side via `owner:GetInfoNum` in `UsesToggleAim` (`sh_sights.lua:96-98`) — predicted aim + hint wording |
| `mcv_auto_reload` | 1 | yes | **yes** | `cl_controls.lua:4` | `Think_AutoReload` (`weapons/mcv_base/sh_reload.lua:15-19`) |
| `mcv_tracer_color` | 0 | yes | **yes** | `cl_tracercolor.lua:2` | tracer colour (0 default / 1 player colour / 2 weapon colour) — visible to others |
| `mcv_viewmodel_fov_offset` | 0 | yes | no | `cl_viewsettings.lua:1` | `MCV.ViewmodelFOV` hip term |
| `mcv_viewmodel_sighted_fov_offset` | 0 | yes | no | `cl_viewsettings.lua:3` | `MCV.ViewmodelFOV` sighted term |
| `mcv_ironsight_nozoom` | 0 | yes | no | `cl_viewsettings.lua:5` | `MCV.IronsightNoZoom()` — `GetScopeWorldFov`/`GetLookMagnification` (`sh_gun.lua:42-57`) |
| `mcv_viewmodel_offset_x` | 0 | yes | no | `cl_viewsettings.lua:7` | `MCV.ViewmodelPositionOffset` (fades out when aiming) |
| `mcv_viewmodel_offset_y` | 0 | yes | no | `cl_viewsettings.lua:9` | same |
| `mcv_viewmodel_offset_z` | 0 | yes | no | `cl_viewsettings.lua:11` | same |
| `mcv_shell_time` | 0.5 | yes | no | `cl_effectsettings.lua:11` | `MCV.ShellTime()` — case fade at rest |
| `mcv_shell_smoke` | 1 | yes | no | `cl_effectsettings.lua:14` | `MCV.ShellSmoke()` — case smoke trail |
| `mcv_muzzle_light` | 2 | yes | no | `cl_effectsettings.lua:23` | `MCV.MuzzleLightMode()` — 0 none / 1 dynamic / 2 projected+shadows |
| `mcv_cat_menu` | 1 | yes | no | `cl_settings.lua:74` | **Q menu only** — which category the stat sliders show |
| `mcv_wm_ang` | "" | no | no | `cl_worldmodel.lua:19` | dev tuning, deliberately not in the menu (AGENTS.md:52-53) |
| `mcv_wm_pos` | "" | no | no | `cl_worldmodel.lua:20` | dev tuning |
| `mcv_wm_left_ang` | "" | no | no | `cl_worldmodel.lua:21` | dev tuning (left hand) |
| `mcv_wm_left_pos` | "" | no | no | `cl_worldmodel.lua:22` | dev tuning |
| `mcv_wm_left_mirror` | "z" | no | no | `cl_worldmodel.lua:154` | which hand-local axis the left hand mirrors across |

Grand total: **212 convars** (191 server + 21 client). `cl_effectsettings.lua:1-5` states the policy: effect convars live together in one client file "next to the tracer colour and the control hints" with an accessor each, so shared files never guess at names. CLAUDE.md:11-53 / AGENTS.md:11-53 (identical text) codify the two-step rule: register + one `SERVER_SETTINGS`/`CLIENT_SETTINGS` entry.

---

## 7. Settings UI — `mcv/client/cl_settings.lua` (227 lines, CL)

### 7.1 Structure

File header (`cl_settings.lua:1-10`): two Q-menu pages under **Options > Military Conflict: Vietnam** — *Server* and *Client* — *"because the two kinds of convar answer to different people"*. Data-driven: an entry with `section` is a heading, `choices` a dropdown, `slider = {min, max, decimals}` a number, anything else a checkbox. `controls(panel, settings)` (`cl_settings.lua:141-172`) is the generic renderer: skips settings whose convar doesn't exist yet (`if !cv then continue end`), shows the current dropdown value without writing it back (`combo:SetValue(c[1])` only, `cl_settings.lua:161-162`), and appends `ControlHelp` text.

`SERVER_SETTINGS` (`cl_settings.lua:14-26`): realistic shooting, surface impacts, bullet penetration, starting rifle-grenade ammo. `PHYSICAL_SETTINGS` (`cl_settings.lua:28-36`): the seven physbullet convars (three with sliders). `CLIENT_SETTINGS` (`cl_settings.lua:38-71`) in four sections — *Controls* (toggle aim, auto reload), *Viewmodel* (two FOV offsets, no-zoom, three hip offsets), *Effects* (tracer colour dropdown, muzzle light dropdown, shell smoke, shell lifetime), *HUD* (enable, hints dropdown, crosshair). BUGLIST.md:10 and 477 record the history: the tab was split into Server/Client pages, client settings grouped into those sections, and duplicate hints selector removed.

### 7.2 Menu registration and presets

`PopulateToolMenu` (`cl_settings.lua:214-227`) registers three tabs: **"Physical Bullets"** (own page with an explainer line: *"Server-controlled ballistics. Particle tracers follow bullet flight; damage occurs at contact..."*), **"Server"**, **"Client"**.

`addPresets(panel, group, lists, categories)` (`cl_settings.lua:178-196`): builds a GMod `panel:ToolPresets(group, defaults)` whose defaults are read from the **registered convars themselves** (`cv:GetDefault()`), not menu copies — *"Native GMod presets: defaults come from the registered convars, not menu copies"* (`cl_settings.lua:176`). The Server page's preset group includes **every category multiplier** (`categories = true` iterates all 20 × 9). Preset groups: `mcv_server`, `mcv_client`, `mcv_physical_bullets`.

`buildServer` (`cl_settings.lua:198-205`): presets → SERVER_SETTINGS → PHYSICAL_SETTINGS → `categoryBlock`. `buildClient` (`cl_settings.lua:207-212`): presets → CLIENT_SETTINGS.

### 7.3 The category stat block

`launchingCategories()` (`cl_settings.lua:80-95`): which categories hold a weapon that launches something — scans `weapons.GetList()` for string values in `ShootEntity/ThrowEntity/ThrownEntity/PlacedEntityClass/RifleGrenadeEntity`; `CATEGORY_RIFLE_GRENADE` and `CATEGORY_ALL` are always in. *"Read off the weapons themselves rather than a list to keep"* (`cl_settings.lua:78-79`).

`categoryBlock(panel, rebuild)` (`cl_settings.lua:97-139`): a "Category stats" heading, a combo of `MCV.Categories` (selection stored in `mcv_cat_menu`, rebuild deferred via `timer.Simple(0)` — *"out of the callback before the controls it is running from are thrown away"*), a `NumSlider(0..3, 2 decimals)` per `MCV.CategoryStats` (projectile stats skipped for non-launching categories, with each stat's `help` via `ControlHelp`), and a **"Reset \<category\>"** button that `RunConsoleCommand`s every stat back to 1.

---

## 8. Localization — `mcv/client/cl_language.lua` (12 lines, CL)

Eleven `language.Add` calls naming ammo types that lack stock labels (used by the engine pickup history and by the info box's Ammo row via `language.GetPhrase(ammo .. "_ammo")`, `cl_hud.lua:566`):

`rpg_round_ammo` → "Rockets", `mcv_grenade_ammo` → "Grenades", `mcv_molotov_ammo` → "Molotov Cocktails", `mcv_mine_ammo` → "Mines", `mcv_explosive_charge_ammo` → "Explosive Charges", `mcv_flamethrower_fuel_ammo` → "Flamethrower Fuel", `mcv_flame_cartridge_ammo` → "Flame Cartridges", `mcv_crossbowbolt_ammo` → "Crossbow Bolts", `mcv_flareround_ammo` → "Flares", `mcv_ammobox_ammo` → "Ammo Boxes", `mcv_medicbox_ammo` → "Medic Boxes" (`cl_language.lua:1-12`).

Fallback behaviour: `language.Add` only supplies a phrase where none exists, so any ammo name GMod already translates keeps its stock label; `language.GetPhrase` returns the raw token when no phrase exists. Everything else in the HUD (fire-mode names, hints, info-box labels) is **hard-coded English** — `MCV.FiremodeNames` (`sh_common.lua:28-42`) and the `GetControlHints` strings are not localized, though the fonts are `extended` so non-Latin text *renders* if substituted. A custom ammo type on a converted weapon gets its `"<ammo>_ammo"` phrase looked up; without a `language.Add` it shows the raw token in the info box.

---

## 9. Dev HUD — `mcv/client/cl_devhud.lua` (50 lines, CL)

`MCV.DevHudShown()` (`cl_devhud.lua:12-16`): true when the harness screenshot marker is set (`MCV.Harness and MCV.Harness.Marker` — the harness's `shot <name> marker` command) **or** `developer > 0`. File header: *"It comes on with `developer 1`, so it is there for ordinary testing without the harness running"* — it lives here rather than in the harness file because that only loads when `data/mcv_harness/enable.txt` exists (`cl_devhud.lua:1-6`).

The `HUDPaint` hook `"MCV_DevHud"` (`cl_devhud.lua:20-50`) draws:

- A magenta cross with a gap in the middle (*"so the sights themselves stay visible through it"*): four 30-px arms plus a 6×6 outlined centre box (`cl_devhud.lua:26-31`).
- A one-line readout centred at the bottom (`MCV_8`, pink): weapon class, `GetSightAmountVisual()` (−1 if absent), VM sequence name, cycle, playback rate, sequence duration, and `CurTime()` — each field individually guarded (`wep.GetSightAmountVisual and ...`, `IsValid(vm) and ... or "?"`, `cl_devhud.lua:40-47`).

This is the quickest in-game sanity check for the translation layer: with `developer 1`, it shows whether the VM is actually playing the sequence the foreign weapon asked for.

---

## 10. Controls — `mcv/client/cl_controls.lua` (5 lines, CL)

Two archived **userinfo** client convars: `mcv_toggle_aim` (default 0) and `mcv_auto_reload` (default 1) (`cl_controls.lua:2-5`). The header: *"Archived userinfo: the server reads each player's choice for predicted input handling."* They are the only client convars the *server* consumes (via `Player:GetInfoNum`, §6.3) — this is the mechanism that lets predicted code honour a per-player preference without networking it by hand. Any converted weapon inherits the behaviour for free because `Think_Sights`/`Think_AutoReload` on `mcv_base` do the reading.

---

## 11. Translation-Layer Surface (ranked)

1. **HUD parity is automatic — and total — once the weapon derives from an MCV base.** All HUD entry points are engine SWEP hooks on the shared base table (`weapon_common/load.lua:31-33` copies them into every base), and all data accessors have nil-safe defaults (`weapon_common/shared.lua:287-347`). A converted weapon gets the slide-in/out blend, ammo block, hints, crosshair, reload fade, weapon-selection box and `CHudAmmo` suppression with zero extra work. The fields that *drive* it: `Primary` (must exist), `Firemodes`+`GetFiremode` semantics (label), `Num`/`GetBulletCount` (crosshair shape), `Spread`/`SpreadIronsighted` (crosshair gap + info rows), `SpeedSprint`, `HasAkimbo`/`HasBayonet`/`HasRifleGrenade` (icons, rows, hints), `IconOverride`, `PrintName`, `Country`, `DrawWeaponInfoBox`, `CrosshairCircle`.
2. **Weapon-selection icon is the one unguarded material load.** `DrawWeaponSelection` calls `Material("entities/<class>.png", "smooth mips")` with no `file.Exists` (`cl_hud.lua:709-711`) — ship an icon (or set `IconOverride`) or the select screen shows the error checkerboard. The HUD ammo-block icon, by contrast, degrades silently (`cl_hud.lua:134-144`).
3. **Kill icons require positive action.** `cl_killicons.lua` registers only `mcv_*`-prefixed classes with an `entities/<class>.png` on disk (`cl_killicons.lua:22-27`). A converted weapon named `weapon_*` gets the default skull icon unless the translation layer performs its own `killicon.Add` (+ `killicon.AddAlias` for any `ShootEntity`/`ThrowEntity`/`ThrownEntity`/`PlacedEntityClass`/`StakeEntityClass` it fires).
4. **Spawn-category hijack.** Inheriting `MilitaryConflictVietnam = true` puts the weapon into `cl_subcategories`' rebuild, which **replaces** `DoPopulate` for its whole top-level Category (`cl_subcategories.lua:40-90`). Converted weapons must set `Category = "Military Conflict: Vietnam"` (or the translation layer must re-scope the hijack), or they erase foreign siblings from the menu.
5. **`SubCategory` is a stat knob, not just a label.** It keys `SWEP:StatMult` → 180 replicated convars (§5.1). Set it to one of the 20 canonical names or the weapon only gets the `All` multipliers. Info-box damage/explosion rows and `boxes` meters read the same fields (`DamageGeneric`, `RangeModifier`, `DamageRamp*`, `ViewSlideRecoil*`, `Caliber`...), so populating them makes converted weapons *look* native in the select screen.
6. **`GetSpread` units are load-bearing for the crosshair.** `GetCrosshairSpread` = `GetSpread() * 100` treated as degrees (`cl_hud.lua:400-405`); a foreign override in other units breaks the gap. Override `GetCrosshairSpread` if you cannot normalize `GetSpread`.
7. **Engine-hook return values have edge cases**: `DoDrawCrosshair` returning nil (when `mcv_hud_crosshair 0`) lets the stock HL2 crosshair through (§2.9); `HUDShouldDraw` returning nil (HUD disabled) restores stock ammo counters (§2.10). A converted weapon that also defines its own `DrawHUD`/`DoDrawCrosshair` (common on foreign bases!) will **shadow** the MCV implementations unless the translation layer chains to `baseclass.Get("mcv_base").DrawHUD(self)` style calls.
8. **`DrawHUDExtra` is the sanctioned extension point** for weapon-specific HUD (binoculars use it, `mcv_binoculars/shared.lua:108`); it runs even while the HUD blend is 0 (§2.8). Scope overlays are elsewhere (`cl_scopeoverlay.lua`, see `docs/gun-core.md`).
9. **Hints are cheap to localize per weapon**: override `GetControlHints` returning `{bindspec, text}` pairs; bindspecs go through `HUD.KeyLabel` (`"+use +attack"` → `"E + LMB"`), and `"hold:+attack"` prefixes with "Hold" (`cl_hud.lua:40-56`). Mode 2 ("first deploy") keys off the per-session `HUD.DeployCount`, so re-parented weapons get sensible default behaviour.
10. **Fonts are pre-made and proportional** (`MCV_8/14/24`, Verdana selection trio, §3). Any custom HUD text should reuse them for resolution consistency; `MCV.SelectionFontRevision` invalidates markup caches on resolution change.
11. **Convar surface for parity**: the server reads `mcv_toggle_aim`/`mcv_auto_reload` per player via userinfo (§10); the crosshair reads `MCV.RealisticShooting()` live (`cl_hud.lua:436`) — realistic mode changes crosshair *behaviour* (view-punch follow + sway bloom), so a converted weapon tested under one mode should be tested under both.

---

## 12. File Map

| File | Realm | Contents (one line each) |
|---|---|---|
| `mcv/weapon_common/cl_hud.lua` | SH (CL-exec) | `MCV.HUD` constants; `HUD.KeyLabel`; `observeHUDWeapon` (PreDrawHUD); `SWEP:GetHUDBlend`, `GetHUDIcon`, `DrawHUDAvailability`, `RollHUDNumber`, `DrawHUDAmmo`, `DrawHUDHints`, `GetControlHints`, `DrawHUD`; crosshair (`ScaleFOVByWidthRatio`, `WidescreenFix`, `TranslateFOV`, `GetCrosshairSpread`, `GetCrosshairKick`, `DoDrawCrosshair`, `HUDShouldDraw`); weapon select (`boxes`, `GetWeaponInfoRows`, `GetWeaponInfoTags`, `PrintWeaponInfo`, `DrawWeaponSelection`); convars `mcv_hud_hints/enable/crosshair` |
| `mcv/client/cl_font.lua` | CL | `MCV_8/14/24` (consolas), `MCV_HudSelectionTitle/Desc/Text` (Verdana); `MCV.Regen` + `MCV_font_reload` + `OnScreenSizeChanged`; `MCV.SelectionFontRevision` |
| `mcv/client/cl_killicons.lua` | CL | Initialize-time `killicon.Add` for all `mcv_*` with icons; `killicon.AddAlias` for projectile entity keys |
| `mcv/client/cl_language.lua` | CL | 11 `language.Add` ammo phrases |
| `mcv/client/cl_subcategories.lua` | CL | PopulateWeapons rebuild: MCV-only subcategorised weapon tree + Miscellaneous/random node |
| `mcv/client/cl_settings.lua` | CL | SERVER/PHYSICAL/CLIENT_SETTINGS tables; `launchingCategories`, `categoryBlock`, `controls`, `addPresets`, `buildServer/buildClient`, `PopulateToolMenu`; `mcv_cat_menu` |
| `mcv/client/cl_devhud.lua` | CL | `MCV.DevHudShown`; HUDPaint dev cross + state readout |
| `mcv/client/cl_controls.lua` | CL | userinfo convars `mcv_toggle_aim`, `mcv_auto_reload` |
| `mcv/client/cl_effectsettings.lua` | CL | `mcv_shell_time/smoke`, `mcv_muzzle_light` + accessors `MCV.ShellTime/ShellSmoke/MuzzleLightMode` |
| `mcv/client/cl_viewsettings.lua` | CL | 6 viewmodel FOV/offset convars + `MCV.ViewmodelPositionOffset/ViewmodelFOV/IronsightNoZoom/ViewmodelRecoilProjection` |
| `mcv/client/cl_tracercolor.lua` | CL | `mcv_tracer_color` (userinfo) |
| `mcv/weapon_common/cl_worldmodel.lua` | CL | 5 unarchived `mcv_wm_*` tuning convars (not in menu) |
| `mcv/shared/sh_convars.lua` | SH | `MCV.RegisterConVar/GetConVar`; 10 gameplay/physbullet convars + accessors |
| `mcv/shared/sh_categories.lua` | SH | `MCV.Categories` (20), `CategoryStats` (9), `CategorySlug`, `CategoryConVarName`, 180 convar registrations, `MCV.CategoryMult` |
| `mcv/shared/sh_impacts.lua` | SH | registers `mcv_surface_impacts` |
| `autorun/sh_mcv_load.lua` | SH | load order: `sh_convars` first, then shared, client, server |
| `mcv/weapon_common/load.lua` | SH | mixes `weapon_common` (incl. `cl_hud`) into every weapon base |
| Supporting consumers | — | `weapons/mcv_base/sh_gun.lua` (GetFiremodeName/GetHUDAmmo/GetControlHints), `weapons/mcv_base/sh_sights.lua` (GetSightAmountVisual/UsesToggleAim), `weapons/mcv_base/sh_shoot.lua` (GetSpread/GetAimSwayAmplitude/GetFiremodeValue/SetLastRecoilTime), `weapons/mcv_base/sh_reload.lua` (Think_AutoReload), `mcv/shared/sh_common.lua` (FiremodeNames), `mcv/shared/sh_physbullets.lua` (BulletRangeMultiplier), `entities/mcv_proj_base.lua` (GetInflictor), `mcv/client/cl_random_weapons.lua` (random-weapon icons), `mcv_harness/hud_transition_tests.lua` (blend regression sampling) |

Cross-references: prediction/timeline of the NetworkVars consumed here → `docs/animation-system.md` §3; scope/overlay HUD → `docs/gun-core.md`; the stat fields shown in the info box → `docs/weapon-definitions.md`, `docs/shooting-ballistics.md`; tracer/muzzle/shell convars → `docs/effects.md`; auto-reload → `docs/reload-ammo.md`.
