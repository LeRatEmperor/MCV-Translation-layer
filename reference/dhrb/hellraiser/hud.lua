local ammoIcons = {}
local pale = Color(238, 230, 217)
local muted = Color(186, 180, 174)
local shadow = Color(0, 0, 0, 190)
local clipColor, emptyColor, freshColor = Color(230, 237, 250), Color(235, 56, 69), Color(114, 202, 250)
local reserveColor = Color(187, 193, 216)

local showHud = CreateClientConVar("hr_hud", "1", true, false, "Show the Hellraiser HUD and weapon wheel; off restores the standard GMod HUD")
local showWeapon = CreateClientConVar("hr_hud_weapon", "1", true, false, "Show the ammo counter and the melee weapon outline")
local showHealth = CreateClientConVar("hr_hud_health", "2", true, false, "Heartbeat health bar: 0 off, 1 when hurt, 2 always")
local showDurability = CreateClientConVar("hr_hud_durability", "1", true, false, "Melee durability: 0 off, 1 faint until the weapon wears, 2 always")
local showHints = CreateClientConVar("hr_hud_hints", "1", true, false, "Show the control hints")
CreateClientConVar("hr_hud_crosshair", "1", true, false, "Crosshair: -1 weapon default, 0 off, 1 on, 2 dynamic, 3 minimal")
CreateClientConVar("hr_hud_hitmarkers", "1", true, false, "Show hit markers")
CreateClientConVar("hr_hud_prompts", "1", true, false, "Show execution and pickup prompts")
CreateClientConVar("hr_hud_lock", "1", true, false, "Show lock-on target and dodge hint")
local hideDefault = CreateClientConVar("hr_hud_hide_default", "0", true, false, "Hide the standard health, suit and ammo HUD while holding a Hellraiser weapon")
local drawGameCrosshair = SWEP.DrawGameCrosshair
local everywhere = CreateClientConVar("hr_hud_any_weapon", "1", true, false, "Show this HUD whatever you are holding. 0 shows it only with Hellraiser weapons")

local function design()
	return math.min(ScrW() / 3840, ScrH() / 2160)
end

local function gameFont(name, file, face, points, weight)
	local em = points * 4 / 3 * design()
	surface.CreateFont(name, {font = system.IsLinux() and file or face, size = 100, weight = weight, antialias = true})
	surface.SetFont(name)
	local _, tall = surface.GetTextSize("0")
	surface.CreateFont(name, {font = system.IsLinux() and file or face, size = math.max(8, math.Round(100 * em * 1.64 / tall)), weight = weight, antialias = true})
end

local function fonts()
	local s = design() * 2
	surface.CreateFont("HRControlHint", {font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.Round(21 * s), weight = 400, antialias = true})
	surface.CreateFont("HRControlKey", {font = (system.IsLinux() and "sarala-bold.ttf" or "Sarala"), size = math.Round(20 * s), weight = 700, antialias = true})
	gameFont("HRAmmoClip", "sarala-bold.ttf", "Sarala", 45, 700)
	gameFont("HRAmmoReserve", "sarala-regular.ttf", "Sarala", 40, 400)
end
fonts()
hook.Add("OnScreenSizeChanged", "hr_ammo_fonts", fonts)

function SWEP:HRHudVisible()
	local owner = self:GetOwner()
	return showHud:GetBool() and GetConVar("cl_drawhud"):GetBool() and IsValid(owner) and owner == LocalPlayer()
        and DHR.CanUseFeature(owner, "hud", self)
		and owner:Alive() and not self:GetNW2Bool("hr_executing")
end

local function bashHintSpace(w)
    if showHints:GetBool() and DHRBash.Supported(w) and GetConVar("dhr_gun_bash"):GetBool()
        and GetConVar("dhr_bash_key"):GetInt() > KEY_NONE then return 44 * design() end
    return 0
end

local function drawCounter(w, clip, reserve, path, size, right, y, side)
	local k = design()
	right = right or ScrW() / 2 + 1740 * k
	y = y or ScrH() - 161 * k - bashHintSpace(w)
	local clipKey, freshKey = "hr_hud_clip" .. (side or ""), "hr_hud_fresh" .. (side or "")
	if clip > (w[clipKey] or clip) then w[freshKey] = CurTime() end
	w[clipKey] = clip

	local x = right
	if path then
		ammoIcons[path] = ammoIcons[path] or Material(path)
		local fit = math.min(73 / size[1], 65 / size[2]) * k
		surface.SetMaterial(ammoIcons[path])
		surface.SetDrawColor(clipColor)
		surface.DrawTexturedRect(right - 36.5 * k - size[1] * fit / 2, y - size[2] * fit / 2, size[1] * fit, size[2] * fit)
		x = right - 81 * k
	end
	local outline = math.max(1, math.Round(2 * k))
	if reserve then
		draw.SimpleTextOutlined(reserve, "HRAmmoReserve", x, y, reserve == 0 and emptyColor or reserveColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, outline, color_black)
		surface.SetFont("HRAmmoReserve")
		x = x - surface.GetTextSize(tostring(reserve)) - 14 * k
		surface.SetDrawColor(reserveColor)
		surface.DrawRect(x, y - 22.5 * k, math.max(1, 4 * k), 45 * k)
		x = x - 10 * k
	end
	local color = clip == 0 and emptyColor or clipColor
	local fresh = 1 - math.Clamp((CurTime() - (w[freshKey] or 0) - 0.6) / 0.6, 0, 1)
	if clip > 0 and fresh > 0 then
		color = Color(Lerp(fresh, clipColor.r, freshColor.r), Lerp(fresh, clipColor.g, freshColor.g), Lerp(fresh, clipColor.b, freshColor.b))
	end
	draw.SimpleTextOutlined(clip, "HRAmmoClip", x, y, color, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, outline, color_black)
	surface.SetFont("HRAmmoClip")
	return x - surface.GetTextSize(tostring(clip))
end

local function drawDualAmmo(w)
	local k = design()
	local right, y = ScrW() / 2 + 1740 * k, ScrH() - 220 * k
	local x = right
	for side = 2, 1, -1 do
		local h = w:Gun(side).config
		x = drawCounter(w, math.max(0, w:DualClip(side)), nil, h.ammo_icon, h.ammo_icon_size, x, y, side) - 18 * k
		local label = side == 1 and "L" or "R"
		draw.SimpleTextOutlined(label, "HRControlHint", x, y, muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, 1, shadow)
		surface.SetFont("HRControlHint")
		x = x - surface.GetTextSize(label) - 50 * k
	end
	local owner = w:GetOwner()
	local left, rightAmmo = w:Gun(1).primary.Ammo, w:Gun(2).primary.Ammo
	local leftReserve, rightReserve = owner:GetAmmoCount(left), owner:GetAmmoCount(rightAmmo)
	local text = left == rightAmmo and "Shared reserve  " .. leftReserve
		or "L reserve  " .. leftReserve .. "     R reserve  " .. rightReserve
	draw.SimpleTextOutlined(text, "HRControlHint", right, ScrH() - 160 * k,
		leftReserve + rightReserve == 0 and emptyColor or reserveColor, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, 1, shadow)
end

function SWEP:DrawHRAmmo()
	if not showWeapon:GetBool() then return end
	if self.DualWield then return drawDualAmmo(self) end
	if self.HR.hud_icon then
		local k = design()
		ammoIcons[self.HR.hud_icon] = ammoIcons[self.HR.hud_icon] or Material(self.HR.hud_icon)
		local w, h = self.HR.hud_icon_size[1] * k, self.HR.hud_icon_size[2] * k
		surface.SetMaterial(ammoIcons[self.HR.hud_icon])
		surface.SetDrawColor(255, 255, 255, 235)
		surface.DrawTexturedRect(ScrW() / 2 + 1740 * k - w, ScrH() - 150 * k - h / 2, w, h)
		return
	end
	if not self.HR.ammo_icon then return end
	drawCounter(self, math.max(0, self:Clip1()), self:GetOwner():GetAmmoCount(self.Primary.Ammo), self.HR.ammo_icon, self.HR.ammo_icon_size)
end

local beats, glows = {}, {}
for i = 1, 3 do
	beats[i] = Material("hellraiser/ui/hud/beat" .. i)
	glows[i] = Material("hellraiser/ui/hud/beat_glow" .. i)
end
local sweepGlow = Material("hellraiser/ui/hud/sweep_glow")
local blur = Material("pp/blurscreen")
local tints = {Color(244, 69, 71), Color(233, 114, 84), Color(211, 156, 104), heal = Color(90, 187, 178)}
local lastHealth, healthChanged, healing = nil, -10, -10

local function blurBox(x, y, w, h)
	surface.SetMaterial(blur)
	surface.SetDrawColor(255, 255, 255)
	for i = 1, 2 do
		blur:SetFloat("$blur", i * 2)
		blur:Recompute()
		render.UpdateScreenEffectTexture()
		surface.DrawTexturedRectUV(x, y, w, h, x / ScrW(), y / ScrH(), (x + w) / ScrW(), (y + h) / ScrH())
	end
end

local function drawHealth(owner)
	local mode = showHealth:GetInt()
	if mode == 0 then return end
	local health, maximum = math.max(owner:Health(), 0), math.max(owner:GetMaxHealth(), 1)
	if lastHealth and health ~= lastHealth then
		if health > lastHealth then healing = CurTime() end
		healthChanged = CurTime()
	end
	lastHealth = health
	local alpha = 1
	if mode == 1 and health >= maximum then alpha = 1 - math.Clamp((CurTime() - healthChanged - 3) / 0.5, 0, 1) end
	if alpha <= 0 then return end

	local k = design()
	local w, h = 382 * k, 90 * k
	local weapon = owner:GetActiveWeapon()
	local offset = IsValid(weapon) and weapon.DualWield and 365 or 285
	local x, y = ScrW() / 2 + 1358 * k, ScrH() - offset * k - bashHintSpace(weapon)
	blurBox(x, y, w, h)
	draw.RoundedBox(10 * k, x, y, w, h, Color(0, 0, 0, 26 * alpha))

	local fraction = health / maximum
	local level = fraction > 0.66 and 3 or fraction > 0.33 and 2 or 1
	local tint = CurTime() - healing < 1.5 and tints.heal or tints[level]
	local beat = 4 - level
	local tile = 148 * k
	local head = x + (CurTime() / (0.6 + 0.3 * level) % 1) * (w + 120 * k)
	render.SetScissorRect(x, y, x + w, y + h, true)

	surface.SetDrawColor(tint.r, tint.g, tint.b, 110 * alpha)
	surface.DrawRect(x, y + h * 0.613 - k, w, math.max(1, 2.5 * k))
	local strips = 24
	for left = x, x + w, tile do
		for i = 0, strips - 1 do
			local sx = left + tile * i / strips
			local behind = head - sx
			if behind > 0 and behind < 375 * k then
				local fade = (1 - behind / (375 * k)) ^ 5.75
				surface.SetMaterial(beats[beat])
				surface.SetDrawColor(tint.r, tint.g, tint.b, 255 * fade * alpha)
				surface.DrawTexturedRectUV(sx, y, tile / strips + 0.5, h, i / strips, 0, (i + 1) / strips, 1)
				surface.SetMaterial(glows[beat])
				surface.SetDrawColor(255, 235, 225, 255 * fade * alpha)
				surface.DrawTexturedRectUV(sx, y, tile / strips + 0.5, h, i / strips, 0, (i + 1) / strips, 1)
			end
		end
	end
	surface.SetMaterial(sweepGlow)
	surface.SetDrawColor(tint.r, tint.g, tint.b, 170 * alpha)
	surface.DrawTexturedRect(head - 375 * k, y, 375 * k, h)
	render.SetScissorRect(0, 0, 0, 0, false)
end

function SWEP:DrawHRHealth()
	drawHealth(self:GetOwner())
end

local function arc(cx, cy, inner, outer, from, to)
	draw.NoTexture()
	local steps = math.max(1, math.ceil((to - from) / 3))
	for i = 0, steps - 1 do
		local a, b = math.rad(from + (to - from) * i / steps), math.rad(from + (to - from) * (i + 1) / steps)
		surface.DrawPoly({
			{x = cx + math.cos(a) * outer, y = cy + math.sin(a) * outer},
			{x = cx + math.cos(b) * outer, y = cy + math.sin(b) * outer},
			{x = cx + math.cos(b) * inner, y = cy + math.sin(b) * inner},
			{x = cx + math.cos(a) * inner, y = cy + math.sin(a) * inner},
		})
	end
end

function SWEP:DrawHRDurability()
	local maximum = self.HR.durability or -1
	local mode = showDurability:GetInt()
	if mode == 0 or maximum <= 0 or HRCombat.Infinite() then return end
	local remaining = HRCombat.Remaining(self)
	if remaining ~= self.hr_hud_wear then
		if self.hr_hud_wear and remaining < self.hr_hud_wear then self.hr_hud_worn = CurTime() end
		self.hr_hud_wear = remaining
	end
	local fade = 1 - math.Clamp((CurTime() - (self.hr_hud_worn or -10) - 2) / 0.5, 0, 1)
	local alpha = mode == 2 and 1 or Lerp(fade, 0.18, 1)
	local k = design()
	local cx, cy = ScrW() / 2, ScrH() / 2
	local pitch = 360 / maximum
	for i = 0, maximum - 1 do
		local filled = math.Clamp(remaining - i, 0, 1)
		if filled > 0 then
			local from = i * pitch + 2.5
			local to = from + (pitch - 5) * filled
			surface.SetDrawColor(0, 0, 0, 100 * alpha)
			arc(cx, cy, 116 * k, 132 * k, from - 0.5, to + 0.5)
			surface.SetDrawColor(255, 255, 255, 220 * alpha)
			arc(cx, cy, 118 * k, 130 * k, from, to)
		end
	end
end

local standard = {CHudAmmo = true, CHudSecondaryAmmo = true, CHudHealth = true, CHudBattery = true}
local function replaceCrosshair(p, w)
	return IsValid(w) and not w.HR and everywhere:GetBool() and showHud:GetBool()
		and GetConVar("hr_hud_crosshair"):GetInt() >= 0
		and p:Alive() and not p:InVehicle() and w.DrawCrosshair ~= false and not w.DoDrawCrosshair
end
hook.Add("HUDShouldDraw", "hr_weapon_ammo", function(name)
	if not showHud:GetBool() then return end
	if not standard[name] and name ~= "CHudCrosshair" then return end
	local p = LocalPlayer()
	local w = IsValid(p) and p:GetActiveWeapon()
	if not DHR.CanUseFeature(p, "hud", w) then return end
	local ours = IsValid(w) and w.HR
	if not ours and not everywhere:GetBool() then return end
	if name == "CHudCrosshair" then
		if replaceCrosshair(p, w) then return false end
		return
	end
	if hideDefault:GetBool() then return false end
	if not showHud:GetBool() or name == "CHudBattery" then return end
	if name == "CHudHealth" then
		if showHealth:GetInt() > 0 then return false end
	elseif ours then
		if w.HR.ammo_icon and showWeapon:GetBool() then return false end
	elseif name == "CHudAmmo" and showWeapon:GetBool() then
		return false
	end
end)

local iconsByAmmo
local function ammoIcon(kind)
	if not iconsByAmmo then
		iconsByAmmo = {}
		for _, t in ipairs(weapons.GetList()) do
			if t.HR and t.HR.ammo_icon and t.Primary and t.Primary.Ammo then iconsByAmmo[string.lower(t.Primary.Ammo)] = t.HR end
		end
	end
	return iconsByAmmo[string.lower(game.GetAmmoName(kind) or "")]
end

hook.Add("HUDPaint", "hr_hud_any_weapon", function()
	if not everywhere:GetBool() or not showHud:GetBool() or not GetConVar("cl_drawhud"):GetBool() then return end
	local p = LocalPlayer()
	if not IsValid(p) or not p:Alive() then return end
	local w = p:GetActiveWeapon()
	if not DHR.CanUseFeature(p, "hud", w) then return end
	if IsValid(w) and w.HR then return end
	drawHealth(p)
	if not IsValid(w) or p:InVehicle() then return end
	local kind = w:GetPrimaryAmmoType()
	local k = design()
	local iconRight = ScrW() / 2 + 1740 * k
	if showWeapon:GetBool() and kind >= 0 then
		local art = ammoIcon(kind)
		local clip, reserve = w:Clip1(), p:GetAmmoCount(kind)
		if clip >= 0 then
			iconRight = drawCounter(w, clip, reserve, art and art.ammo_icon, art and art.ammo_icon_size) - 28 * k
		else
			iconRight = drawCounter(w, reserve, nil, art and art.ammo_icon, art and art.ammo_icon_size) - 28 * k
		end
	end
	if showWeapon:GetBool() then
		HRStockIcons.Draw(w:GetClass(), iconRight - 100 * k, ScrH() - 161 * k, 200 * k, 100 * k, "hud", 235)
	end
	local style = GetConVar("hr_hud_crosshair"):GetInt()
	if replaceCrosshair(p, w) and style > 0 and GetConVar("crosshair"):GetBool()
		and not gui.IsGameUIVisible() and not vgui.CursorVisible() then
		local clip = w:Clip1()
		if clip < (w.hr_hud_shot_clip or clip) then w.hr_hud_shot = CurTime() end
		w.hr_hud_shot_clip = clip
		local quiet = style == 2 and CurTime() - (w.hr_hud_shot or -10) > 1.5
		local shape = (kind < 0 or style == 3 or quiet) and "dot" or string.lower(game.GetAmmoName(kind) or "") == "buckshot" and "shotgun" or "cross"
		local motion = math.min(p:GetVelocity():Length2D() / 180, 1)
		drawGameCrosshair(ScrW() / 2, ScrH() / 2, shape, motion * 12, 220)
	end
end)

local keyNames = {MOUSE1 = "LMB", MOUSE2 = "RMB", MOUSE3 = "MMB", MOUSE4 = "M4", MOUSE5 = "M5"}
local function keyLabel(name)
	if not name or name == "" then return end
	name = string.upper(name)
	return keyNames[name] or name
end

function SWEP:DrawHRControls()
	if not showHints:GetBool() or gui.IsGameUIVisible() or vgui.CursorVisible() or (HRWheel and HRWheel.open) then return end
	local hints = {}
	if self.HR.crosshair == "cube" then
		for _, control in ipairs({{"+attack", "Hellshot"}, {"+attack2", "Push & Pull"}, {"+reload", "Hellvision"}}) do
			hints[#hints + 1] = {keyLabel(input.LookupBinding(control[1], true)) or "Unbound", control[2]}
		end
	end
	if self.HR.upgrades and #self.HR.upgrades > 0 then
		local key = keyLabel(HRUpgrades.KeyName())
		hints[#hints + 1] = {key or "Unbound", key and "Hold for upgrades" or "Upgrades"}
	end
	if GetConVar("hr_wheel_hud"):GetBool() then
		local keys, seen = {}, {}
		local function add(name)
			local key = keyLabel(name)
			if key and not seen[key] then keys[#keys + 1] = key seen[key] = true end
		end
		for _, cvar in ipairs({"hr_wheel_key", "hr_wheel_backup_key"}) do
			local code = GetConVar(cvar):GetInt()
			if code > KEY_NONE and code <= MOUSE_LAST then add(input.GetKeyName(code)) end
		end
		add(input.LookupBinding("+hr_wheel", true))
		hints[#hints + 1] = {#keys > 0 and table.concat(keys, " / ") or "Unbound", "Hold for weapon wheel"}
	end
    if DHR.AmmoGun(self) and cvars.Bool("dhr_ammo_sharing", true) then
        local code = GetConVar("dhr_share_key"):GetInt()
        if code > KEY_NONE and code <= MOUSE_LAST then
            hints[#hints + 1] = {keyLabel(input.GetKeyName(code)) or "Unbound", "Throw spare ammo"}
        end
    end
    if DHRBash.Supported(self) and GetConVar("dhr_gun_bash"):GetBool() then
        local code = GetConVar("dhr_bash_key"):GetInt()
        if code > KEY_NONE and code <= MOUSE_LAST then
            hints[#hints + 1] = {keyLabel(input.GetKeyName(code)) or "Unbound", "Gun bash"}
        end
    end
	local s = design() * 2
	local right = ScrW() / 2 + 870 * s
	local y = ScrH() - 14 * s - (#hints - 1) * 22 * s
	for _, hint in ipairs(hints) do
		surface.SetFont("HRControlHint")
		local labelWidth = surface.GetTextSize(hint[2])
		draw.SimpleTextOutlined(hint[2], "HRControlHint", right, y, muted, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER, 1, shadow)
		surface.SetFont("HRControlKey")
		local keyWidth = surface.GetTextSize(hint[1]) + 14 * s
		local x = right - labelWidth - keyWidth - 10 * s
		surface.SetDrawColor(19, 17, 19, 220)
		surface.DrawRect(x, y - 10 * s, keyWidth, 20 * s)
		surface.SetDrawColor(141, 123, 112, 140)
		surface.DrawOutlinedRect(x, y - 10 * s, keyWidth, 20 * s, 1)
		draw.SimpleText(hint[1], "HRControlKey", x + keyWidth / 2, y, pale, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		y = y + 22 * s
	end
end
