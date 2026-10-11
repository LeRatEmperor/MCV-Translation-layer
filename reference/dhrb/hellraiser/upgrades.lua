if SERVER then AddCSLuaFile() end

HRUpgrades = HRUpgrades or {}
local U = HRUpgrades

function U.Class(cls)
    local weapon = weapons.GetStored(cls)
    return weapon and weapon.SingleClass or cls
end

local function equipped(player, class)
    local single = player:GetWeapon(class)
    if IsValid(single) then return single end
    for _, weapon in ipairs(player:GetWeapons()) do
        if weapon.DualWield and (weapon.SingleClass == class or weapon.SecondClass == class) then return weapon end
    end
end

function U.Owned(p, cls, id)
    cls = U.Class(cls)
	return string.find("," .. p:GetNW2String("hr_owned_" .. cls, "") .. ",", "," .. id .. ",", 1, true) ~= nil
end

function U.PickupTarget(p)
	if not IsValid(p) or not p:Alive() then return end
	local e = p:GetEyeTrace().Entity
	if IsValid(e) and e.Base == "hr_upgrade_pickup"
		and p:EyePos():DistToSqr(e:WorldSpaceCenter()) <= 128 * 128 then return e end
end

local MULTIPLIERS = { spread = true, recoil = true, rate = true, damage = true, sensitivity = true }

local parsed = {}
function U.Parse(s)
	s = s or ""
	if not parsed[s] then
		local set = {}
		for id in string.gmatch(s, "[^,]+") do set[id] = true end
		parsed[s] = set
	end
	return parsed[s]
end

function U.Installed(w)
	return U.Parse(w.DualWield and w.dhr_guns and w:GunUpgradeString(w.dhr_side or 2) or w:GetNW2String("hr_upgrades", ""))
end

function U.Get(w, key)
	local installed, value = U.Installed(w), MULTIPLIERS[key] and 1 or nil
	for _, u in ipairs(w.HR.upgrades or {}) do
		if installed[u.id] and u[key] ~= nil then
			if MULTIPLIERS[key] then value = value * u[key] else value = u[key] end
		end
	end
	return value
end

function U.Sanitize(stored, ids)
	local valid, groups, out = {}, {}, {}
	for _, u in ipairs(stored.HR and stored.HR.upgrades or {}) do valid[u.id] = u end
	for _, id in ipairs(ids) do
		local u = valid[id]
		if u and not table.HasValue(out, id) and not (u.group and groups[u.group]) then
			if u.group then groups[u.group] = true end
			out[#out + 1] = id
		end
	end
	return table.concat(out, ",")
end

function U.Sync(w)
    if w.DualWield and w.dhr_guns then w:SyncDualUpgrades(); return end
	local s = w:GetNW2String("hr_upgrades", "")
	if w.hr_upgrade_clip == s then return end
	w.hr_upgrade_clip = s
	if not w.HR.clip then return end
	w.Primary.ClipSize = U.Get(w, "clip") or w.HR.clip
end

if SERVER then
	util.AddNetworkString("hr_upgrades")
	util.AddNetworkString("hr_upgrade_collected")

	function U.Grant(p, cls, id)
        cls = U.Class(cls)
		local stored = weapons.GetStored(cls)
		if not IsValid(p) or not p:IsPlayer() or not p:Alive() or not stored or not stored.HR then return false end
		if U.Sanitize(stored, {id}) == "" or U.Owned(p, cls, id) then return false end
		local owned = p:GetNW2String("hr_owned_" .. cls, "")
		p:SetNW2String("hr_owned_" .. cls, owned == "" and id or owned .. "," .. id)
		return true
	end

	function U.Install(p, cls, id)
        cls = U.Class(cls)
		local stored = weapons.GetStored(cls)
		p.hr_upgrades = p.hr_upgrades or {}
		local installed, target = U.Parse(p.hr_upgrades[cls]), nil
		for _, u in ipairs(stored.HR.upgrades) do if u.id == id then target = u end end
		local ids = {}
		for _, u in ipairs(stored.HR.upgrades) do
			if u.id == id or installed[u.id] and not (target.group and u.group == target.group) then ids[#ids + 1] = u.id end
		end
		local str = U.Sanitize(stored, ids)
		p.hr_upgrades[cls] = str
		local w = equipped(p, cls)
		if IsValid(w) then U.Apply(w, str, false, cls) end
		return str
	end

	function U.Apply(w, str, fresh, cls)
        if w.DualWield and w.dhr_guns then w:ApplyDualUpgrades(str, cls, fresh); return end
		local old = w:GetNW2String("hr_upgrades", "")
		w:SetNW2String("hr_upgrades", str or "")
		U.Sync(w)
		local owner = w:GetOwner()
		local size = w.Primary.ClipSize
        local spare = w:GetNW2Int("dhr_spare_rounds", -1)
        if size > 0 and spare > size then
            if IsValid(owner) and owner:IsPlayer() then owner:GiveAmmo(spare - size, w.Primary.Ammo, true) end
            w:SetNW2Int("dhr_spare_rounds", size)
        end
		if not fresh and old ~= (str or "") and w.UpgradeReload and w:UpgradeReload(old) then return end
		if size > 0 and w:Clip1() > size then
			if IsValid(owner) and owner:IsPlayer() then owner:GiveAmmo(w:Clip1() - size, w.Primary.Ammo, true) end
			w:SetClip1(size)
		end
	end

	net.Receive("hr_upgrades", function(_, ply)
		local count = net.ReadUInt(5)
		ply.hr_upgrades = ply.hr_upgrades or {}
		for _ = 1, count do
			local cls, ids = U.Class(net.ReadString()), net.ReadString()
			local stored = weapons.GetStored(cls)
			if stored and stored.HR and stored.HR.upgrades then
				local allowed = {}
				for _, id in ipairs(string.Explode(",", ids)) do
					if U.Owned(ply, cls, id) then allowed[#allowed + 1] = id end
				end
				local str = U.Sanitize(stored, allowed)
				ply.hr_upgrades[cls] = str
				local w = equipped(ply, cls)
				if IsValid(w) then U.Apply(w, str, false, cls) end
			end
		end
	end)

	hook.Add("WeaponEquip", "hr_upgrades", function(w, owner)
		if not w.HR or not w.HR.upgrades then return end
		timer.Simple(0, function()
			if not IsValid(w) or not IsValid(owner) or w:GetOwner() ~= owner or w.dhr_preserve_upgrades then return end
			if w.DualWield then
                for _, gun in ipairs(w.dhr_guns) do
                    U.Apply(w, owner:IsPlayer() and (owner.hr_upgrades or {})[gun.class] or "", true, gun.class)
                end
            else
                U.Apply(w, owner:IsPlayer() and (owner.hr_upgrades or {})[U.Class(w:GetClass())] or "", true)
            end
		end)
	end)
	return
end

local function saved(cls)
	return cookie.GetString("hr_upgrades_" .. cls, "")
end

function U.Send(list)
	local classes = table.GetKeys(list)
	for first = 1, #classes, 31 do
		local last = math.min(first + 30, #classes)
		net.Start("hr_upgrades")
		net.WriteUInt(last - first + 1, 5)
		for index = first, last do
			local class = classes[index]
			net.WriteString(class)
			net.WriteString(list[class])
		end
		net.SendToServer()
	end
end

hook.Add("InitPostEntity", "hr_upgrades", function()
	local list = {}
	for _, t in ipairs(weapons.GetList()) do
		if t.HR and t.HR.upgrades then list[t.ClassName] = saved(t.ClassName) end
	end
	U.Send(list)
end)

function U.Toggle(w, id, side)
    local gun = w.DualWield and w:Gun(side or 2)
    local config = gun and gun.config or w.HR
	local cls = gun and gun.class or U.Class(w:GetClass())
	local installed = table.Copy(gun and U.Parse(w:GunUpgradeString(side or 2)) or U.Installed(w))
	local target
	for _, u in ipairs(config.upgrades) do if u.id == id then target = u end end
	if not target or not U.Owned(LocalPlayer(), cls, id) then return end
	if installed[id] then
		installed[id] = nil
	else
		for _, u in ipairs(config.upgrades) do
			if target.group and u.group == target.group then installed[u.id] = nil end
		end
		installed[id] = true
	end
	local ids = {}
	for _, u in ipairs(config.upgrades) do if installed[u.id] then ids[#ids + 1] = u.id end end
	local str = table.concat(ids, ",")
	cookie.Set("hr_upgrades_" .. cls, str)
	U.Send({ [cls] = str })
	LocalPlayer():EmitSound(installed[id] and "HR.UI_Inventory_ItemUpgrade" or "HR.UI_Inventory_Unequip")
end

local icons = {}
local function icon(path)
	icons[path] = icons[path] or Material(path)
	return icons[path]
end

local panel
function U.Close()
	if IsValid(panel) then panel:Remove() end
	panel = nil
end

function U.Open(w, side)
	U.Close()
	if not IsValid(w) or not w.HR then return end
    side = side or 2
    local gun = w.DualWield and w:Gun(side)
    local config = gun and gun.config or w.HR
    if not config.upgrades then return end
    local class = gun and gun.class or w:GetClass()
	local s = math.Clamp(ScrH() / 1080, 0.65, 1.5)
	local cardH, pad = math.Round(92 * s), math.Round(8 * s)
	local width = math.Round(440 * s)
	local header = w.DualWield and 114 or 84
	local height = math.Round(header * s) + (#config.upgrades) * (cardH + pad) + pad
	panel = vgui.Create("DPanel")
	panel:SetSize(width, height)
	panel:SetPos(ScrW() - width - math.Round(24 * s), (ScrH() - height) / 2)
	panel:MakePopup()
	panel:SetKeyboardInputEnabled(false)
	panel.Think = function()
		local owner = LocalPlayer()
		if not IsValid(w) or not IsValid(owner) or not owner:Alive()
			or owner:GetActiveWeapon() ~= w or w:GetNW2Bool("hr_executing") then U.Close() end
	end
	panel.Paint = function(self, pw, ph)
		if not IsValid(w) then return end
		surface.SetDrawColor(8, 10, 14, 248)
		surface.DrawRect(0, 0, pw, ph)

		if config.upgrade_image then
			surface.SetMaterial(icon(config.upgrade_image))
			surface.SetDrawColor(255, 255, 255, 255)
			local dimensions = config.upgrade_image_size
			local k = math.min(pw * 0.36 / dimensions[1], 54 * s / dimensions[2])
			local iw, ih = dimensions[1] * k, dimensions[2] * k
			surface.DrawTexturedRect(pw - iw - pad, pad, iw, ih)
		end
		draw.SimpleText("Upgrades", "HRUpgradeTitle", pad * 2, pad * 2, Color(230, 237, 250))
		draw.SimpleText(config.caption or (gun and gun.name or w.PrintName), "HRUpgradeSmall", pad * 2, pad * 2 + 32 * s, Color(163, 172, 186))
	end
	if w.DualWield then
        for hand = 1, 2 do
            local button = vgui.Create("DButton", panel)
            button:SetPos(pad * 2 + (hand - 1) * (width / 2 - pad), 78 * s)
            button:SetSize(width / 2 - pad * 3, 27 * s)
            button:SetText("")
            button.Paint = function(self, bw, bh)
                if hand == side or self:IsHovered() then
                    surface.SetDrawColor(116, 151, 192, 230)
                    surface.DrawOutlinedRect(0, 0, bw, bh, 1)
                end
                draw.SimpleText(hand == 1 and "Left hand" or "Right hand", "HRUpgradeSmall", bw / 2, bh / 2,
                    hand == side and Color(230, 237, 250) or Color(150, 169, 190), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
            end
            button.DoClick = function() U.Open(w, hand) end
        end
    end
	local y = math.Round(header * s)
	for _, u in ipairs(config.upgrades) do
		local card = vgui.Create("DButton", panel)
		card:SetText("")
		card:SetPos(pad * 2, y)
		card:SetSize(width - pad * 4, cardH)
		card.DoClick = function() if IsValid(w) then U.Toggle(w, u.id, side) end end
		card.Paint = function(self, cw, ch)
			if not IsValid(w) then return end
			local on = IsValid(w) and (gun and U.Parse(w:GunUpgradeString(side)) or U.Installed(w))[u.id]
			local owned = U.Owned(LocalPlayer(), class, u.id)
			surface.SetDrawColor(19, 25, 34, self:IsHovered() and 245 or 170)
			surface.DrawRect(0, 0, cw, ch)
            if on or self:IsHovered() then
                surface.SetMaterial(icon("hellraiser/ui/menu_pattern"))
                surface.SetDrawColor(67, 111, 165, 180)
                local height = cw * 122 / 641
                surface.DrawTexturedRect(0, (ch - height) / 2, cw, height)
                surface.SetDrawColor(116, 151, 192, 230)
                surface.DrawOutlinedRect(0, 0, cw, ch, 1)
            end
			local m = icon(u.icon)
			local iconSize = 44 * s
			local mw, mh = u.icon_size[1], u.icon_size[2]
			local k = iconSize / math.max(mw, mh)
			surface.SetMaterial(m)
			surface.SetDrawColor(255, 255, 255, on and 255 or 170)
			surface.DrawTexturedRect(8 * s + (iconSize - mw * k) / 2, 8 * s + (iconSize - mh * k) / 2, mw * k, mh * k)
			draw.SimpleText(u.name, "HRUpgradeText", 64 * s, 7 * s, Color(230, 237, 250, on and 255 or 200))
			if on or not owned then
				draw.SimpleText(on and "Installed" or "Find pickup", "HRUpgradeStatus", 8 * s, ch - 20 * s, Color(164, 187, 215), TEXT_ALIGN_LEFT)
			end
		end
		local description = vgui.Create("DLabel", card)
		description:SetPos(64 * s, 29 * s)
		description:SetSize(width - pad * 4 - 74 * s, 54 * s)
		description:SetFont("HRUpgradeSmall")
		description:SetTextColor(Color(163, 172, 186))
		description:SetText(u.desc)
		description:SetWrap(true)
		description:SetContentAlignment(7)
		description:SetMouseInputEnabled(false)
		y = y + cardH + pad
	end
end

local function createFonts()
	local s = math.Clamp(ScrH() / 1080, 0.65, 1.5)
	surface.CreateFont("HRUpgradeTitle", { font = (system.IsLinux() and "elmessiri-bold.ttf" or "El Messiri"), size = math.Round(38 * s), weight = 700, antialias = true })
	surface.CreateFont("HRUpgradeText", { font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.Round(28 * s), weight = 400, antialias = true })
	surface.CreateFont("HRUpgradeSmall", { font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.Round(24 * s), weight = 400, antialias = true })
	surface.CreateFont("HRUpgradeStatus", { font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.Round(20 * s), weight = 400, antialias = true })
end
createFonts()
hook.Add("OnScreenSizeChanged", "hr_upgrade_fonts", createFonts)

local function holdingUpgradable()
	local p = LocalPlayer()
	local w = IsValid(p) and p:GetActiveWeapon()
	return IsValid(w) and w.HR and w.HR.upgrades and not w:GetNW2Bool("hr_executing") and w
end

hook.Add("OnContextMenuOpen", "hr_upgrades", function()
	local w = holdingUpgradable()
	if not w then return end
	U.Open(w)
	return true
end)

hook.Add("OnContextMenuClose", "hr_upgrades", function()
	if not IsValid(panel) then return end
	U.Close()
	return true
end)

concommand.Add("hr_upgrades", function()
	if IsValid(panel) then U.Close() return end
	local w = holdingUpgradable()
	if w then U.Open(w) end
end)

local upgradesKey = CreateClientConVar("hr_upgrades_key", "0", true, false, "Key held to open the upgrade menu. 0 uses the context menu key")
function U.KeyName()
	local code = upgradesKey:GetInt()
	if code > KEY_NONE then return string.upper(input.GetKeyName(code) or "") end
	local key = input.LookupBinding("+menu_context", true)
	return key and string.upper(key)
end
local wasHeld = false
hook.Add("Think", "hr_upgrades_key", function()
	local code = upgradesKey:GetInt()
	local held = code > KEY_NONE and (code >= MOUSE_FIRST and code <= MOUSE_LAST and input.IsMouseDown(code) or code < MOUSE_FIRST and input.IsKeyDown(code))
	if held and not wasHeld and not gui.IsGameUIVisible() and not IsValid(vgui.GetKeyboardFocus()) then
		local w = holdingUpgradable()
		if w then U.Open(w) end
	elseif not held and wasHeld and IsValid(panel) then
		U.Close()
	end
	wasHeld = held
end)

local function binding(command)
	return string.upper(input.LookupBinding(command) or command:gsub("^%+", ""))
end

net.Receive("hr_upgrade_collected", function()
	local name, cls, installed = net.ReadString(), net.ReadString(), net.ReadString()
	cookie.Set("hr_upgrades_" .. cls, installed)
	local key = U.KeyName()
	local instruction = key and (" Hold [" .. key .. "] with the weapon out to take it off again.")
		or " Enter hr_upgrades in the console with the weapon out to take it off again."
	chat.AddText(Color(230, 190, 155), name .. " fitted.", Color(238, 230, 217), instruction)
end)

hook.Add("HUDPaint", "hr_upgrade_pickup", function()
	if not GetConVar("cl_drawhud"):GetBool() or not cvars.Bool("hr_hud", true) or not cvars.Bool("hr_hud_prompts", true) or gui.IsGameUIVisible() then return end
	local p = LocalPlayer()
	local e = U.PickupTarget(p)
	if not IsValid(e) then return end
	local owned = U.Owned(p, e.WeaponClass, e.UpgradeID)
	local fitted = owned and U.Parse(saved(e.WeaponClass))[e.UpgradeID]
	local text = fitted and "Already fitted" or "[" .. binding("+use") .. "]  " .. (owned and "Fit" or "Collect")
	local x, y = ScrW() / 2, ScrH() * 0.62
	draw.SimpleTextOutlined(e.PrintName, "HRUpgradeText", x, y, Color(230, 237, 250), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
	draw.SimpleTextOutlined(text, "HRUpgradeSmall", x, y + 34 * ScrH() / 1080, Color(164, 187, 215), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, color_black)
end)
