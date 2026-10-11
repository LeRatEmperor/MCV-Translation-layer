// HUD for every MCV weapon: crosshair, the ammo block bottom right with the weapon's icon
// behind it, control hints that fade out after a deploy, and in / out animations on switching.
//
// Deploy need not run clientside. Observe the actual active weapon before drawing;
// holster-out still follows the predicted HolsterTime.

MCV.HUD = MCV.HUD or {}
local HUD = MCV.HUD

HUD.Color = Color(255, 255, 255, 150)
HUD.ColorBright = Color(255, 255, 255, 230)
HUD.ColorDim = Color(255, 255, 255, 140)
HUD.ColorIcon = Color(255, 255, 255, 70) // the spawn icon, mirrored to face left, behind the counter
HUD.InTime = 0.35 // seconds the elements take to slide in
HUD.OutTimeDefault = 0.3
HUD.SlideDistance = 24 // ScreenScale units the elements travel while animating
HUD.HintDuration = 6 // seconds the hints stay before fading
HUD.HintFade = 1
HUD.HintStagger = 0.06 // extra delay per hint line

local cv_hints = CreateClientConVar("mcv_hud_hints", "1", true, false, "Control hints on deploy: 0 off, 1 every deploy, 2 first deploy of each weapon; 3 always")
local cv_hud_enable = CreateClientConVar("mcv_hud_enable", "1", true, false, "Whether to enable the weapon HUD")
local cv_hud_crosshair = CreateClientConVar("mcv_hud_crosshair", "1", true, false, "Whether to enable the crosshair")


local function ease(p)
    p = math.Clamp(p, 0, 1)
    return 1 - (1 - p) * (1 - p) * (1 - p) // ease out cubic
end

// ---------------------------------------------------------------------------------------
// Key names
// ---------------------------------------------------------------------------------------

local key_labels = {
    ["mouse1"] = "LMB", ["mouse2"] = "RMB", ["mouse3"] = "MMB",
    ["shift"] = "SHIFT", ["alt"] = "ALT", ["ctrl"] = "CTRL", ["space"] = "SPACE",
}

// "+use" -> "E", "+use +attack" -> "E + LMB"; "hold:+attack" -> "Hold LMB"
function HUD.KeyLabel(spec)
    local hold = false
    if string.sub(spec, 1, 5) == "hold:" then
        hold = true
        spec = string.sub(spec, 6)
    end
    local parts = {}
    for bind in string.gmatch(spec, "%S+") do
        local key = input.LookupBinding(bind, true) or input.LookupBinding(bind) or bind
        key = string.lower(key)
        table.insert(parts, key_labels[key] or string.upper(key))
    end
    local s = table.concat(parts, " + ")
    if hold then s = "Hold " .. s end
    return s
end

// ---------------------------------------------------------------------------------------
// Per-weapon animation state (client side, this weapon instance only)
// ---------------------------------------------------------------------------------------

// 0..1 how far the HUD is "in". Combines the deploy slide-in with the holster slide-out.
local function observeHUDWeapon()
    local player = LocalPlayer()
    local active = IsValid(player) and player:GetActiveWeapon() or NULL
    if HUD.ActiveWeapon == active then return end
    HUD.ActiveWeapon = active
    if IsValid(active) and active.MilitaryConflictVietnam then
        active.HUDLastFrame = nil
        active.CrosshairReloadAlpha = 1
        active.CrosshairWasReloading = false
        active.CrosshairReloadUntil = nil
    end
end
hook.Add("PreDrawHUD", "MCV_HUDWeaponSwitch", observeHUDWeapon)

function SWEP:GetHUDBlend()
    observeHUDWeapon()
    if HUD.ActiveWeapon != self then return 0 end
    local now = CurTime()
    local frame = FrameNumber()

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
end

// ---------------------------------------------------------------------------------------
// Elements
// ---------------------------------------------------------------------------------------

local function textRight(font, text, right, y, col)
    surface.SetFont(font)
    local tw, th = surface.GetTextSize(text)
    surface.SetTextPos(right - tw, y)
    surface.SetTextColor(col)
    surface.DrawText(text)
    return tw, th
end

local function withAlpha(col, mult)
    return Color(col.r, col.g, col.b, col.a * mult)
end

function SWEP:GetHUDIcon()
    if self.Mat_HUDIcon == nil then
        local path = self.IconOverride or ("entities/" .. self:GetClass() .. ".png")
        if file.Exists("materials/" .. path, "GAME") then
            self.Mat_HUDIcon = Material(path, "smooth")
        else
            self.Mat_HUDIcon = false
        end
    end
    return self.Mat_HUDIcon or nil
end

// A weapon icon mirrored (the game's icons face right) and turned so it faces up-left
local iconPoly = {{u = 1, v = 0}, {u = 0, v = 0}, {u = 0, v = 1}, {u = 1, v = 1}}
local function drawIconTilted(mat, cx, cy, size, col)
    // Fixed 45-degree rotation: reuse the four vertices instead of ten tables per draw.
    local radius = size * 0.7071067811865476
    local poly = iconPoly
    poly[1].x, poly[1].y = cx, cy - radius
    poly[2].x, poly[2].y = cx + radius, cy
    poly[3].x, poly[3].y = cx, cy + radius
    poly[4].x, poly[4].y = cx - radius, cy
    surface.SetMaterial(mat)
    surface.SetDrawColor(col)
    surface.DrawPoly(poly)
end

// Icons under the ammo counter for what this gun could do right now: dual wield (its own icon,
// once a second one has been picked up) and a bayonet (the carried bayonet's icon)
local function drawAvailabilityIcon(icon, active, dual, blend, x, y, size)
    if icon then
        local col = withAlpha(HUD.Color, blend * (active and 0.45 or 1))
        if dual then
            local off = size * 0.1
            drawIconTilted(icon, x - off, y - off, size, withAlpha(HUD.Color, blend * (active and 0.3 or 0.6)))
            drawIconTilted(icon, x + off * 1.25, y + off, size, col)
            x = x - off * 2
        else
            drawIconTilted(icon, x, y, size, col)
        end
    end
    return x - size - ScreenScale(2)
end

function SWEP:DrawHUDAvailability(blend, right, y)
    if !self.HasAkimbo and !self.HasBayonet then return end
    local size = ScreenScale(14)
    local x = right - size / 2
    if self.HasAkimbo and self.GetHasSecond and self:GetHasSecond() then
        // two of them, one a little behind the other: a pair of pistols
        x = drawAvailabilityIcon(self:GetHUDIcon(), self:GetAkimbo(), true, blend, x, y, size)
    end
    if self.HasBayonet then
        local owner = self:GetOwner()
        if !IsValid(owner) or !owner.GetWeapons then return end
        for _, w in ipairs(owner:GetWeapons()) do
            if w.IsBayonet and w.GetHUDIcon then
                drawAvailabilityIcon(w:GetHUDIcon(), self:GetBayonet(), false, blend, x, y, size)
                break
            end
        end
    end
end

// A count that changes rolls instead of appearing: the number on screen chases the real one
// and covers the whole jump in CountUpTime, never slower than CountUpMin a second so that a
// small pickup is not sluggish. `rolldown` also rolls a falling count, which is what the
// reserve does, so a reload empties the reserve in step with the magazine filling. The
// magazine itself is left to snap downwards: a shot has to read at once or the counter lags
// behind the gun being fired.
HUD.CountUpTime = 0.25
HUD.CountUpMin = 30
HUD.CountUpResume = 0.25 // a longer gap means the weapon was away: start from the count it has now

function SWEP:RollHUDNumber(key, target, rolldown)
    if target == nil then
        self[key] = nil
        return nil
    end

    local now = RealTime()
    local st = self[key]
    // nothing drawn for a while (the gun was holstered, the HUD was hidden): no roll, the
    // count that comes back is simply the count
    if !st or now - (st.seen or 0) > HUD.CountUpResume then
        st = {shown = target, target = target, rate = 0, seen = now}
        self[key] = st
    end
    st.seen = now

    if target != st.target then
        st.target = target
        if target < st.shown and !rolldown then
            st.shown = target
        else
            st.rate = math.max(math.abs(target - st.shown) / HUD.CountUpTime, HUD.CountUpMin)
        end
    end

    local step = st.rate * RealFrameTime()
    if st.shown < st.target then
        st.shown = math.min(st.shown + step, st.target)
        return math.floor(st.shown)
    elseif st.shown > st.target then
        st.shown = math.max(st.shown - step, st.target)
        return math.ceil(st.shown)
    end

    return st.target
end

// The ammo block: firemode label, big count, reserve, icon behind it all
function SWEP:DrawHUDAmmo(blend)
    local sw, sh = ScrW(), ScrH()
    local slide = HUD.SlideDistance * ScreenScale(1) * (1 - blend)
    local right = sw - ScreenScale(16) + slide

    local firemode_name = self:GetFiremodeName() or ""
    local ammocount, reserve = self:GetHUDAmmo()
    ammocount = self:RollHUDNumber("HUDAmmoRoll", ammocount)
    reserve = self:RollHUDNumber("HUDReserveRoll", reserve, true)

    // icon: the spawn icon has its glyph in the middle 256x128 band of a 256x256 image, so
    // a 128 wide box shows the whole band with no dead space
    local icon = self:GetHUDIcon()
    if icon then
        local w = ScreenScale(72)
        local h = w
        local cx = right - ScreenScale(36)
        local cy = sh - ScreenScale(30)
        surface.SetMaterial(icon)
        surface.SetDrawColor(withAlpha(HUD.ColorIcon, blend))
        // the game's icons all point right; mirrored so the muzzle faces the screen centre
        surface.DrawTexturedRectUV(cx - w / 2, cy - h / 2, w, h, 1, 0, 0, 1)
    end

    if firemode_name != "" then
        textRight("MCV_8", firemode_name, right, sh - ScreenScale(20), withAlpha(HUD.Color, blend))
    end

    self:DrawHUDAvailability(blend, right, sh - ScreenScale(10))

    if ammocount == nil then return end

    textRight("MCV_24", tostring(ammocount), right - ScreenScale(28), sh - ScreenScale(40), withAlpha(HUD.Color, blend))

    if reserve == nil then return end

    textRight("MCV_14", tostring(reserve), right + ScreenScale(4), sh - ScreenScale(32), withAlpha(HUD.Color, blend))
end

// Control hints: lines of "KEY  what it does", above the ammo block, fading after a while
function SWEP:DrawHUDHints(blend)
    local mode = cv_hints:GetInt()
    if mode <= 0 then return end
    if mode == 2 and (HUD.DeployCount[self:GetClass()] or 1) > 1 then return end

    local now = CurTime()
    local age = now - (self.HUDHintsStart or now)
    local life = 1 - math.Clamp((age - HUD.HintDuration) / HUD.HintFade, 0, 1)
    if mode >= 3 then life = 1 end
    if life <= 0 then return end

    // Most frames are past the hint timeout: don't build nested hint tables or
    // query weapon state until there is something visible to draw.
    local hints = self:GetControlHints()
    if !hints or #hints == 0 then return end

    local sw, sh = ScrW(), ScrH()
    local right = sw - ScreenScale(16)
    local y = sh - ScreenScale(58)
    local lh = ScreenScale(9)

    // width of the widest key column so the actions line up
    surface.SetFont("MCV_8")
    local keyw = 0
    local labels = {}
    for i, h in ipairs(hints) do
        labels[i] = HUD.KeyLabel(h[1])
        keyw = math.max(keyw, (surface.GetTextSize(labels[i])))
    end
    local gap = ScreenScale(6)

    for i = #hints, 1, -1 do
        local h = hints[i]
        // each line slides in slightly after the one below it
        local p = ease((age - (#hints - i) * HUD.HintStagger) / HUD.InTime) * blend * life
        if p > 0 then
            local slide = HUD.SlideDistance * ScreenScale(1) * (1 - p)
            local ly = y - (#hints - i) * lh
            textRight("MCV_8", h[2], right + slide, ly, withAlpha(HUD.ColorDim, p))
            surface.SetFont("MCV_8")
            local aw = surface.GetTextSize(h[2])
            local kx = right + slide - aw - gap
            surface.SetTextPos(kx - keyw + (keyw - surface.GetTextSize(labels[i])), ly)
            surface.SetTextColor(withAlpha(HUD.ColorBright, p))
            surface.DrawText(labels[i])
        end
    end
end

// Default hints; every base overrides with its own controls (see GetControlHints in each base)
function SWEP:GetControlHints()
    return {
        {"+attack", "Fire"},
        {"+use +attack", "Bash"},
    }
end

function SWEP:DrawHUD()
    if !cv_hud_enable:GetBool() then return end

    local blend = self:GetHUDBlend()

    self:DrawHUDExtra()

    if blend <= 0 then return end

    self:DrawHUDAmmo(blend)
    self:DrawHUDHints(blend)
end

// ---------------------------------------------------------------------------------------
// Crosshair
// ---------------------------------------------------------------------------------------

function SWEP:ScaleFOVByWidthRatio( fovDegrees, ratio )
    local halfAngleRadians = fovDegrees * ( 0.5 * math.pi / 180 )
    local t = math.tan( halfAngleRadians )
    t = t * ratio
    local retDegrees = ( 180 / math.pi ) * math.atan( t )
    return retDegrees * 2
end

function SWEP:WidescreenFix(target)
    return self:ScaleFOVByWidthRatio(target, ((ScrW and ScrW() or 4) / (ScrH and ScrH() or 3)) / (4 / 3))
end

local function drawshadowrect(x, y, w, h, col)
    surface.SetDrawColor(col)
    surface.DrawRect(x, y, w, h)
    surface.SetDrawColor(0, 0, 0, col.a * 100 / 150)
    surface.DrawOutlinedRect(x - 1, y - 1, w + 2, h + 2)
end

local cv_developer = GetConVar("developer")
local crosshair_col = Color(255, 255, 255, 100)
local crosshair_shadow = Color(0, 0, 0, 0)
local white = Color(255, 255, 255, 255)

SWEP.TrueFOV = 90

function SWEP:TranslateFOV(fov)
    self.TrueFOV = fov

    return fov
end

// Crosshair gap follows the weapon's live spread (stance, movement, air, aim), kicks open on
// each shot and settles back, and the whole thing bobs with the walk cycle. Purely visual: the
// spread itself is what GetSpread returns, this only shows it.
HUD.CrosshairSmooth = 12 // how fast the gap follows the target (per second)
HUD.CrosshairKick = 0.75 // extra gap right after a shot, in units of the base spread
HUD.CrosshairKickTime = 0.15
HUD.CrosshairBob = 2.5 // ScreenScale units of sway at a full sprint

function SWEP:GetCrosshairSpread()
    if self.GetSpread then
        return self:GetSpread() * 100
    end
    return self.Spread or 0
end

function SWEP:GetCrosshairKick()
    local since = CurTime() - self:GetLastRecoilTime()
    local kick = math.Clamp(1 - since / HUD.CrosshairKickTime, 0, 1)
    return kick * kick
end

function SWEP:DoDrawCrosshair(x, y)
    local blend = self:GetHUDBlend()
    local reloading = self:GetReloading()
    if reloading then
        self.CrosshairReloadUntil = nil
    elseif self.CrosshairWasReloading then
        // Shotgun Reloading clears as the finishing/pump animation starts.
        self.CrosshairReloadUntil = self:GetAnimLockTime()
    end
    self.CrosshairWasReloading = reloading
    local reloadTarget = (reloading or (self.CrosshairReloadUntil or 0) > CurTime()) and 0 or 1
    self.CrosshairReloadAlpha = math.Approach(self.CrosshairReloadAlpha or 1,
        reloadTarget, FrameTime() * 8)
    local a = (1 - self:GetSightAmountVisual()) * 100 * blend * self.CrosshairReloadAlpha
    if a <= 0 then return true end

    local col = crosshair_col
    col.a = a

    if !cv_hud_crosshair:GetBool() then return end

    // The crosshair follows the view punch (twice it, as the shot does) but not the hip sway:
    // it stays put and grows by the sway's peak instead, so the shot always lands inside it
    if self.GetAimSway and MCV.RealisticShooting() then
        local owner = self:GetOwner()
        if IsValid(owner) then
            local aim = owner:EyeAngles() + owner:GetViewPunchAngles() * 2
            local scr = (owner:EyePos() + aim:Forward() * 4096):ToScreen()
            if scr.visible and scr.x == scr.x then
                x, y = scr.x, scr.y
            end
        end
    end

    local dot_size = ScreenScale(1)
    local line_size = ScreenScale(4)

    local trueFOV = self:WidescreenFix(self.TrueFOV)
    local scale = ScrH() / trueFOV

    // target gap from the live spread, plus a kick that decays after each shot
    local spread = self:GetCrosshairSpread()
    local kick = self:GetCrosshairKick()
    // the hip sway's peak (degrees, both axes: 1.2 covers the diagonal) widens the gap so the
    // wandering barrel stays inside the crosshair
    local sway = self.GetAimSwayAmplitude and self:GetAimSwayAmplitude(true) * 1.2 or 0
    local target = scale * (spread + sway + math.max(self.Spread or 0, 0.5) * HUD.CrosshairKick * kick)

    local ft = FrameTime()
    if self.CrossGap == nil then self.CrossGap = target end
    // opens instantly, closes smoothly
    if target > self.CrossGap then
        self.CrossGap = Lerp(math.min(ft * HUD.CrosshairSmooth * 3, 1), self.CrossGap, target)
    else
        self.CrossGap = Lerp(math.min(ft * HUD.CrosshairSmooth, 1), self.CrossGap, target)
    end
    local gap_size = math.max(self.CrossGap, dot_size)

    // walk bob: a figure of eight scaled by how fast the player moves
    local speed = self:GetSpeedVisual() / math.max(self.SpeedSprint, 1)
    local owner = self:GetOwner()
    if IsValid(owner) and !owner:IsOnGround() then speed = 0 end
    self.CrossBobPhase = (self.CrossBobPhase or 0) + ft * (6 + speed * 6) * math.min(speed * 3, 1)
    local bob = HUD.CrosshairBob * ScreenScale(1) * speed
    x = x + math.sin(self.CrossBobPhase) * bob
    y = y + math.abs(math.cos(self.CrossBobPhase)) * bob * 0.6

    drawshadowrect(x - (dot_size / 2), y - (dot_size / 2), dot_size, dot_size, col)

    if self.CrosshairCircle or self:GetBulletCount() > 1 then
        local shadow = crosshair_shadow
        shadow.a = a * 100 / 150

        surface.DrawCircle(x, y, gap_size, col)
        surface.DrawCircle(x, y, gap_size - 1, col)
        surface.DrawCircle(x, y, gap_size + 1, shadow)
        surface.DrawCircle(x, y, gap_size - 2, shadow)
    elseif (self.Spread or 0) > 0 then
        drawshadowrect(x - (dot_size / 2), y + (dot_size / 4) + gap_size, dot_size, line_size, col)

        drawshadowrect(x - (dot_size / 2), y - (dot_size / 4) - gap_size - line_size, dot_size, line_size, col)

        drawshadowrect(x + gap_size, y - (dot_size / 2), line_size, dot_size, col)
        drawshadowrect(x - gap_size - line_size, y - (dot_size / 2), line_size, dot_size, col)
    end

    if cv_developer:GetBool() then
        drawshadowrect(x - (dot_size / 2), y - (dot_size / 2), dot_size, dot_size, white)

        local vm = self:GetOwner():GetViewModel()
        surface.SetFont("TargetID")

        local txt = "CYCLE: " .. math.Round(vm:GetCycle(), 2)
        local tw = surface.GetTextSize(txt)
        surface.SetTextPos(x - (tw / 2), y + 100)
        surface.SetTextColor(col)
        surface.DrawText(txt)

        local txt2 = vm:GetSequenceActivityName(vm:GetSequence()) .. " / " .. vm:GetSequenceName(vm:GetSequence())
        local tw2 = surface.GetTextSize(txt2)
        surface.SetTextPos(x - (tw2 / 2), y + 100 + 16)
        surface.SetTextColor(col)
        surface.DrawText(txt2)

        local tr = self:GetOwner():GetEyeTrace()
        local dist = (tr.HitPos - self:GetOwner():EyePos()):Length()
        local txt3 = "RANGE MULT: " .. math.Round(MCV.BulletRangeMultiplier(self, dist), 3)
        local tw3 = surface.GetTextSize(txt3)
        surface.SetTextPos(x - (tw3 / 2), y + 100 + 16 * 2)
        surface.SetTextColor(col)
        surface.DrawText(txt3)
    end

    return true
end

local shoulddraw = {
    ["CHudAmmo"] = true,
    ["CHudSecondaryAmmo"] = true,
}

function SWEP:HUDShouldDraw(element)
    if !cv_hud_enable:GetBool() then return end
    if shoulddraw[element] then return false end
end

// ---------------------------------------------------------------------------------------
// Weapon selection
// ---------------------------------------------------------------------------------------

local function boxes(f)
    local str = ""
    local boxc = math.Round(f * 10)
    for i = 1, 10 do
        if i <= boxc then
            str = str .. "■"
        else
            str = str .. "□"
        end
    end
    return str
end

// Plain data rows keep labels and values aligned independently of font metrics.
function SWEP:GetWeaponInfoRows()
    local rows = {}
    local thrown = self.ThrowEntity and baseclass.Get(self.ThrowEntity)
    local smoke = thrown and thrown.SmokeParticle and thrown.Hurts == false
    local function row(label, value)
        rows[#rows + 1] = {label .. ":", tostring(value)}
    end
    if self.AmmoPerShot > 0 and self.Primary.Ammo and self.Primary.Ammo != "none" then
        local ammo = self.SelectableGrenadeAmmo and self:GetSelectedAmmo() or self.Primary.Ammo
        row("Ammo", language.GetPhrase(ammo .. "_ammo"))
    end
    if (self.DamageGeneric or 0) > 0 and !self:GetProjectileClass() and !smoke then
        local pellets = self:GetBulletCount()
        if (self.DamageRampDistance or 0) > 0 then
            row("Damage", math.Round(self.DamageGeneric * MCV.BulletRangeMultiplier(self, 0), 1)
                .. " - " .. math.Round(self.DamageGeneric * MCV.BulletRangeMultiplier(self, self.DamageRampDistance), 1))
            row("Full power", math.Round(self.DamageRampDistance * 0.0254, 1) .. " m")
        else
            row("Damage", self.DamageGeneric .. (pellets > 1 and ("x" .. pellets) or ""))
        end
    end
    local function explosive(entity, prefix, category)
        local projectile = entity and baseclass.Get(entity) or {}
        projectile = projectile or {}
        local damage, radius = self.ExplosionDamage, self.ExplosionRadius
        // LaunchProjectile falls back on the projectile for zero/missing values.
        // Throwables/placed charges deliberately allow zero damage (smoke/gas).
        if self:GetProjectileClass() or category then
            damage = (damage or 0) > 0 and damage or projectile.ExplosionDamage
            radius = (radius or 0) > 0 and radius or projectile.ExplosionRadius
        end
        if (damage or 0) > 0 then
            row(prefix .. "damage", math.Round(damage * self:StatMult("explosion_damage", category), 1))
            if (radius or 0) > 0 then
                row(prefix .. "radius", math.Round(radius * self:StatMult("explosion_radius", category) * 0.0254, 1) .. " m")
            end
        end
    end
    if smoke then
        local color = self.SmokeColor or thrown.SmokeColor
        rows[#rows + 1] = {"Smoke colour:", "", swatch = color and Color(color.x, color.y, color.z) or Color(255, 255, 255)}
    else
        explosive(self:GetProjectileClass() or self.ThrowEntity or self.PlacedEntityClass, "Blast ")
    end
    if self.HasRifleGrenade then
        explosive(self.RifleGrenadeEntity, self.RifleGrenadeIsUBGL and "GL " or "RG ", MCV.CATEGORY_RIFLE_GRENADE)
    end
    if (self.FireRate or 0) > 0 then row("Fire Rate", self.FireRate .. " RPM") end
    if self.Primary.ClipSize > 0 then
        local bonus = self.Primary.Chamber or 0
        row("Capacity", self.Primary.ClipSize .. (bonus > 0 and " (+" .. bonus .. ")" or ""))
    end
    if (self.FireRate or 0) > 0 and !self:GetProjectileClass() and (self.RangeModifier or 0) > 0 and self.RangeModifier < 1 then
        local range = math.floor(-346.571 / math.log(self.RangeModifier))
        row("Range", boxes(math.Clamp(range / 10000, 0, 1)))
    end
    if self.Caliber and self.Caliber != "" then row("Caliber", self.Caliber) end
    if (self.FireRate or 0) > 0 then
        local d
        if self.SpreadIronsighted == self.Spread then
            d = math.log(1 + self.Spread / 3)
            row("Spread", boxes(math.Clamp(d, 0, 1)))
        else
            d = 1 - math.log(1 + (self.SpreadIronsighted + self.Spread) / 15)
            row("Accuracy", boxes(math.Clamp(d, 0, 1)))
        end
        local recoil = ((self.ViewSlideRecoilUp + self.ViewSlideRecoilIronsightUp) / 2)
            + self.ViewSlideRecoilRight + self.ViewSlideRecoilIronsightRight
        row("Recoil", boxes(math.Clamp(recoil * 0.5, 0, 1)))
    end
    return rows
end

function SWEP:GetWeaponInfoTags()
    local tags = {}
    local function tag(enabled, name) if enabled then tags[#tags + 1] = "[" .. name .. "]" end end
    tag(self.HasAkimbo, "DUAL")
    tag(self.HasRifleGrenade and !self.RifleGrenadeIsUBGL, "RG")
    tag(self.HasRifleGrenade and self.RifleGrenadeIsUBGL, "GL")
    tag(self.Silencer, "SD")
    tag(self.HasBipod, "BI")
    tag(self.HasBayonet, "BAYO")
    tag(self.HasScope and self.AdjustableScopes, "VS")
    tag(self.ArmorPiercing, "AP")
    return table.concat(tags, " ")
end

function SWEP:PrintWeaponInfo(x, y, alpha)
    if self.DrawWeaponInfoBox == false then return end
    local scale = ScreenScale(1) / 3
    local padding = 10 * scale
    local width = math.min(300 * scale, ScrW() - padding * 2)
    local textWidth = width - padding * 2
    local rows, tags = self:GetWeaponInfoRows(), self:GetWeaponInfoTags()
    local key = {tostring(textWidth), tostring(MCV.SelectionFontRevision), self.PrintName, self.Country or "", tags}
    for _, row in ipairs(rows) do
        key[#key + 1] = row[1] .. row[2] .. (row.swatch and tostring(row.swatch) or "")
    end
    key = table.concat(key, "\n")
    if self.InfoLayoutKey != key then
        local function parse(text, font, color, w)
            return markup.Parse("<font=" .. font .. "><color=" .. color .. ">" .. text .. "</color></font>", w)
        end
        local layout = {}
        local title = parse(self.PrintName, "MCV_HudSelectionTitle", "230,230,230", textWidth)
        local country = parse(self.Country or "", "MCV_HudSelectionDesc", "150,150,150", textWidth)
        local height = title:GetHeight() + country:GetHeight() + padding
        surface.SetFont("MCV_HudSelectionText")
        local labelWidth = 0
        for _, row in ipairs(rows) do labelWidth = math.max(labelWidth, surface.GetTextSize(row[1])) end
        // Markup's per-glyph rounding can exceed GetTextSize's whole-string width.
        // Leave breathing room so labels such as Accuracy do not wrap at 4K.
        labelWidth = math.min(labelWidth + 12 * scale, textWidth * 0.55)
        for _, row in ipairs(rows) do
            local label = parse(row[1], "MCV_HudSelectionText", "230,230,230", labelWidth)
            local value = parse(row[2], "MCV_HudSelectionText", "150,150,150", textWidth - labelWidth - padding)
            layout[#layout + 1] = {label = label, value = value, swatch = row.swatch, y = height}
            height = height + math.max(label:GetHeight(), value:GetHeight(), row.swatch and 14 * scale or 0)
        end
        local footer = tags != "" and parse(tags, "MCV_HudSelectionText", "230,230,230", textWidth) or nil
        self.InfoLayout = {title = title, country = country, rows = layout, footer = footer, footerY = height + padding,
            height = height + (footer and padding + footer:GetHeight() or 0) + padding * 2}
        self.InfoLayoutKey = key
    end
    local layout = self.InfoLayout
    x = math.Clamp(x, padding, math.max(padding, ScrW() - width - padding))
    y = math.Clamp(y, padding, math.max(padding, ScrH() - layout.height - padding))
    draw.RoundedBox(8 * scale, x, y, width, layout.height, Color(60, 60, 60, alpha))
    local left, top = x + padding, y + padding
    layout.title:Draw(left, top, nil, nil, alpha)
    layout.country:Draw(left, top + layout.title:GetHeight(), nil, nil, alpha)
    for _, row in ipairs(layout.rows) do
        row.label:Draw(left, top + row.y, nil, nil, alpha)
        if row.swatch then
            local size = 12 * scale
            local sx, sy = x + width - padding - size, top + row.y + scale
            surface.SetDrawColor(row.swatch.r, row.swatch.g, row.swatch.b, alpha)
            surface.DrawRect(sx, sy, size, size)
            surface.SetDrawColor(230, 230, 230, alpha)
            surface.DrawOutlinedRect(sx, sy, size, size)
        else
            row.value:Draw(x + width - padding, top + row.y, TEXT_ALIGN_RIGHT, nil, alpha, TEXT_ALIGN_RIGHT)
        end
    end
    if layout.footer then layout.footer:Draw(left, top + layout.footerY, nil, nil, alpha) end
end

SWEP.Mat_Select = nil

function SWEP:DrawWeaponSelection(x, y, w, h, a)
    // Anchor the info box to the selection slot, before adjusting the icon's bounds.
    local infoX, infoY = x + w + ScreenScale(20 / 3), y + h * 0.95
    if !self.Mat_Select then
        self.Mat_Select = Material(self.IconOverride or  "entities/" .. self:GetClass() .. ".png", "smooth mips")
    end

    surface.SetDrawColor(255, 255, 255, a)
    surface.SetMaterial(self.Mat_Select)
    if self.IconOverride then
        w = w - 128
        x = x + 64
    end
    if w > h then
        y = y - ((w - h) / 2)
    end

    surface.DrawTexturedRect(x, y, w, w)
    self:PrintWeaponInfo(infoX, infoY, a)
end
