if not CLIENT then return end

HRWheel = HRWheel or {}
local W = HRWheel
local enabled = CreateClientConVar("hr_wheel_hud", "1", true, false, "Enable the Hellraiser weapon wheel")
local key = CreateClientConVar("hr_wheel_key", tostring(MOUSE_MIDDLE), true, false, "Key code used to hold the weapon wheel open")
local backup = CreateClientConVar("hr_wheel_backup_key", tostring(KEY_T), true, false, "Backup key code for the weapon wheel")
local anyWeapon = CreateClientConVar("hr_wheel_any_weapon", "1", true, false, "Open the weapon wheel with any weapon and list every weapon you carry. 0 keeps it to Hellraiser weapons")
local replaceSelection = CreateClientConVar("hr_wheel_replace_selection", "1", true, false, "Replace normal weapon selection when fast switching is off")
local wheel = Material("hellraiser/ui/wheel")
local glow = Material("hellraiser/ui/wheel_glow")
local keyIcon = Material("hellraiser/ui/key")
local menuPattern = Material("hellraiser/ui/menu_pattern")
local icons = {}
local positions = {{0, -1}, {1, 0}, {0, 1}, {-1, 0}}
local chosen = {}
local function scale() return math.Clamp(math.min(ScrW() / 1400, ScrH() / 900), .5, 1.4) end
local function weaponName(weapon)
    return language.GetPhrase(weapon:GetPrintName())
end

local glyphs = {weapon_357 = "e", weapon_ar2 = "l", weapon_bugbait = "j", weapon_crossbow = "g", weapon_crowbar = "c",
	weapon_frag = "k", weapon_physcannon = "m", weapon_physgun = "h", weapon_pistol = "d", weapon_rpg = "i",
	weapon_shotgun = "b", weapon_slam = "o", weapon_smg1 = "a", weapon_stunstick = "n"}
local tools = {weapon_physgun = true, weapon_physcannon = true, gmod_tool = true, gmod_camera = true}
local defaultIcon = surface.GetTextureID("weapons/swep")

local function labels()
	return {"Melee", "Sidearms", "Long guns", "Tools"}
end

local function available()
	local p = LocalPlayer()
	local w = IsValid(p) and p:GetActiveWeapon()
	return cvars.Bool("hr_hud", true) and enabled:GetBool() and IsValid(w) and (w.HR or anyWeapon:GetBool()) and p:Alive() and not w:GetNW2Bool("hr_executing")
        and DHR.CanUseFeature(p, "hud", w) and DHR.CanUseFeature(p, "wheel", w)
end

local function group(w)
	if w:GetClass() == "hr_cube" then return 4 end
	if w.HR then
		if w.HR.kind == "melee" then return 1 end
		if w.HR.kind == "tool" then return 4 end
		return w.Slot == 1 and 2 or 3
	end
	if tools[w:GetClass()] then return 4 end
	local slot = w:GetSlot()
	if slot == 0 then return 1 end
	if slot == 1 then return 2 end
	if slot == 2 or slot == 3 then return 3 end
	return 4
end

function W.Groups()
	local groups = {{}, {}, {}, {}}
	for _, w in ipairs(LocalPlayer():GetWeapons()) do
		if w.HR and (w.Spawnable or w.DualWield) or not w.HR and anyWeapon:GetBool() then table.insert(groups[group(w)], w) end
	end
	for _, list in ipairs(groups) do
		table.sort(list, function(a, b)
			if a:GetSlot() ~= b:GetSlot() then return a:GetSlot() < b:GetSlot() end
			if a:GetSlotPos() ~= b:GetSlotPos() then return a:GetSlotPos() < b:GetSlotPos() end
			return a:GetClass() < b:GetClass()
		end)
	end
	return groups
end

local function selected(g)
	local list = W.groups and W.groups[g] or {}
	return list[math.Clamp(chosen[g] or 1, 1, math.max(#list, 1))]
end

function W.Selected() return selected(W.selected) end
function W.Select(weapon, equip)
    W.groups = W.Groups()
    for category, list in ipairs(W.groups) do
        for index, candidate in ipairs(list) do
            if candidate == weapon then
                W.selected, chosen[category], W.pairWeapon = category, index, nil
                W.changed = RealTime()
                W.selectionUntil = CurTime() + 8
                if equip then W.Close(true) end
                return
            end
        end
    end
end
function W.ChoosePair()
    local weapon = selected(W.selected)
    if not DHR.CanChangeWield(weapon) then return end
    if weapon.DualWield then
        DHR.ChangeWield(weapon)
        W.Close(false)
    else
        W.pairWeapon, W.partnerScroll = weapon, 0
        W.selectionUntil = CurTime() + 12
    end
end
function W.Click()
    local x, y = ScrW() / 2 + W.x, ScrH() / 2 + W.y
    for _, button in ipairs(W.buttons or {}) do
        if x >= button.x and x <= button.x + button.w and y >= button.y and y <= button.y + button.h then
            button.action()
            return
        end
    end
    if not W.pairWeapon then W.Close(true) end
end

function W.Open()
	if not available() or gui.IsGameUIVisible() or vgui.CursorVisible() then return end
	W.groups = W.Groups()
	local active = LocalPlayer():GetActiveWeapon()
	W.selected = group(active)
	for g, list in ipairs(W.groups) do
		for i, w in ipairs(list) do if w == active then chosen[g] = i end end
	end
	W.open, W.x, W.y = true, 0, 0
    W.pairWeapon, W.buttons = nil, {}
    W.attackDown, W.cancelDown = false, false
	W.opened = RealTime()
	if HRUpgrades then HRUpgrades.Close() end
end

function W.Close(equip)
	if not W.open then return end
	local w = selected(W.selected)
	if equip and not W.pairWeapon and available() and IsValid(w) and w:GetOwner() == LocalPlayer() then
		input.SelectWeapon(w)
		LocalPlayer():EmitSound("HR.UI_Inventory_Equip")
	end
	W.open = false
    W.pairWeapon, W.buttons = nil, {}
	W.selectionMode = false
	W.closed = RealTime()
	W.untilTime = CurTime() + 0.25
end

function W.Cycle(g, direction, equip)
	W.groups = W.Groups()
	local list = W.groups[g]
	if #list == 0 then return false end
	local active = LocalPlayer():GetActiveWeapon()
	if not W.open then
		for i, w in ipairs(list) do if w == active then chosen[g] = i end end
	end
	local i = chosen[g] or 1
	if W.open or list[i] == active then i = (i - 1 + direction) % #list + 1 end
	chosen[g], W.selected = i, g
	W.changed = RealTime()
	W.untilTime = CurTime() + 1.1
	if equip then input.SelectWeapon(list[i]) end
	LocalPlayer():EmitSound("HR.UI_Menu_InGame_SquareGridSlot_Select")
	return true
end

local function held(code)
	if code >= MOUSE_FIRST and code <= MOUSE_LAST then return input.IsMouseDown(code) end
	return code > KEY_NONE and code < MOUSE_FIRST and input.IsKeyDown(code)
end

local wasDown, gripDown = false, false
local spareDown, magazineDown = false, false
function W.ShareAmmo(loaded)
    local weapon = selected(W.selected)
    if not W.open or not DHR.AmmoGun(weapon) then return end
    if loaded and weapon ~= LocalPlayer():GetActiveWeapon() then return end
    DHR.ShareAmmo(weapon, loaded)
    W.Close(false)
end
function W.ChangeGrip()
    local weapon = selected(W.selected)
    if W.open and DHR.CanChangeGrip(weapon) then
        DHR.ChangeGrip(weapon)
        W.selectionUntil = CurTime() + 4
    end
end
hook.Add("Think", "hr_weapon_wheel", function()
    local spare, magazine = input.IsKeyDown(KEY_X), input.IsKeyDown(KEY_Z)
    if spare and not spareDown then W.ShareAmmo(false) end
    if magazine and not magazineDown then W.ShareAmmo(true) end
    spareDown, magazineDown = spare, magazine
    local grip = input.IsKeyDown(KEY_G)
    if grip and not gripDown then W.ChangeGrip() end
    gripDown = grip
	local down = held(key:GetInt()) or held(backup:GetInt())
	if down and not wasDown then W.Open() end
	if not down and wasDown and not W.commandHeld and not W.selectionMode then W.Close(true) end
	wasDown = down
	if W.selectionMode and CurTime() > W.selectionUntil then W.Close(false) end
	if W.open and (not available() or gui.IsGameUIVisible() or vgui.CursorVisible()) then W.Close(false) end
end)

hook.Add("InputMouseApply", "hr_weapon_wheel", function(cmd, x, y)
	if not W.open then return end
	W.x = math.Clamp(W.x + x, -ScrW() / 2 + 4, ScrW() / 2 - 4)
    W.y = math.Clamp(W.y + y, -ScrH() / 2 + 4, ScrH() / 2 - 4)

	return true
end)

local function normalSelection()
	return replaceSelection:GetBool() and not cvars.Bool("hud_fastswitch", false)
end

local function browse(slot, direction)
	local current = W.open and selected(W.selected) or LocalPlayer():GetActiveWeapon()
	local groups, list = W.Groups(), {}
	for g, weapons in ipairs(groups) do
		for i, weapon in ipairs(weapons) do
			if not slot or weapon:GetSlot() == slot - 1 then
				list[#list + 1] = {weapon = weapon, group = g, index = i}
			end
		end
	end
	if #list == 0 then return true end
	table.sort(list, function(a, b)
		if a.weapon:GetSlot() ~= b.weapon:GetSlot() then return a.weapon:GetSlot() < b.weapon:GetSlot() end
		if a.weapon:GetSlotPos() ~= b.weapon:GetSlotPos() then return a.weapon:GetSlotPos() < b.weapon:GetSlotPos() end
		return a.weapon:GetClass() < b.weapon:GetClass()
	end)
	if not W.open then W.Open() end
	if not W.open then return false end
	W.groups = groups
	W.selectionMode, W.selectionUntil = true, CurTime() + 4
	local index
	for i, item in ipairs(list) do if item.weapon == current then index = i; break end end
	index = index and (index - 1 + direction) % #list + 1 or direction > 0 and 1 or #list
	local item = list[index]
	W.selected, chosen[item.group], W.changed = item.group, item.index, RealTime()
	return true
end

hook.Add("PlayerBindPress", "hr_weapon_wheel", function(p, bind, pressed, code)
	if p ~= LocalPlayer() or not available() or gui.IsGameUIVisible() or vgui.CursorVisible() then return end
	if code == key:GetInt() or code == backup:GetInt() or (W.open and (code == KEY_G or code == KEY_X or code == KEY_Z)) then return true end
	bind = string.lower(string.Trim(input.TranslateAlias(bind) or bind))
	if not pressed then
		if (normalSelection() or W.open) and (bind == "invnext" or bind == "invprev") then return true end
		return
	end
    if W.open and bind == "+reload" then W.ChoosePair(); return true end
    if W.open and (bind == "+attack" or bind == "+attack2") then
        if bind == "+attack" then W.Click()
        elseif W.pairWeapon then W.pairWeapon = nil
        else W.Close(false) end
        return true
    end
	local slot = tonumber(bind:match("^slot(%d+)$"))
    if IsValid(W.pairWeapon) and (bind == "invnext" or bind == "invprev") then
        W.partnerScroll = math.Clamp((W.partnerScroll or 0) + (bind == "invnext" and 1 or -1), 0, math.max(0, #DHR.PairChoices(W.pairWeapon) - 8))
        W.selectionUntil = CurTime() + 12
        return true
    end
    if W.selectionMode and (bind == "invnext" or bind == "invprev") then
        return browse(nil, bind == "invprev" and -1 or 1)
    end
    if W.open and (bind == "invnext" or bind == "invprev") then
        W.Cycle(W.selected, bind == "invnext" and 1 or -1, false)
        W.pairWeapon = nil
        W.selectionUntil = CurTime() + 8
        return true
    end
    if W.open and slot and slot <= 4 then W.Cycle(slot, 1, false); return true end
    if normalSelection() and (slot or bind == "invnext" or bind == "invprev") then
        return browse(slot, bind == "invprev" and -1 or 1)
    end
end)

hook.Add("CreateMove", "hr_weapon_wheel", function(cmd)
	if not W.open then return end
	if cmd:KeyDown(IN_ATTACK) and not W.attackDown then W.Click()
    elseif cmd:KeyDown(IN_ATTACK2) and not W.cancelDown then
        if W.pairWeapon then W.pairWeapon = nil else W.Close(false) end
    end
    W.attackDown, W.cancelDown = cmd:KeyDown(IN_ATTACK), cmd:KeyDown(IN_ATTACK2)
	cmd:RemoveKey(IN_ATTACK)
	cmd:RemoveKey(IN_ATTACK2)
	cmd:RemoveKey(IN_RELOAD)
end)

concommand.Add("+hr_wheel", function() W.commandHeld = true W.Open() end)
concommand.Add("-hr_wheel", function() W.commandHeld = false if not W.selectionMode then W.Close(true) end end)

local function font()
	local scale = scale()
	surface.CreateFont("HRWheel", {font = (system.IsLinux() and "elmessiri-regular.ttf" or "El Messiri"), size = math.Round(36 * scale), weight = 400, antialias = true})
	surface.CreateFont("HRWheelSmall", {font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.Round(28 * scale), weight = 400, antialias = true})
	surface.CreateFont("HRWheelIcon", {font = "HalfLife2", size = math.Round(104 * scale), weight = 0, antialias = true, additive = true})
	surface.CreateFont("HRWheelIconGlow", {font = "HalfLife2", size = math.Round(104 * scale), weight = 0, antialias = true, additive = true, blur = 6})
end
font()
hook.Add("OnScreenSizeChanged", "hr_wheel_font", font)

hook.Add("HUDDrawPickupHistory", "hr_weapon_wheel", function()
    if W.open then return true end
end)

hook.Add("HUDShouldDraw", "hr_weapon_wheel", function(name)
	if name == "CHudWeaponSelection" and available() and (normalSelection() or W.open or CurTime() < (W.untilTime or 0)) then return false end
end)

local function entityIcon(cls)
	if icons[cls] == nil then
		local m = Material("entities/" .. cls .. ".png", "smooth")
		icons[cls] = not m:IsError() and m or false
	end
	return icons[cls]
end

local function drawIcon(w, x, y, scale, current, alpha)
    if w.DualWield and w.DrawDualIcon then w:DrawDualIcon(x, y, scale, current, alpha); return end
	local cls = w:GetClass()
	if w.HR and w.HR.stock_icon and HRStockIcons.Draw(w.HR.stock_icon, x, y, 210 * scale, 118 * scale, current and "selected" or "", alpha) then return end
	if w.HR and (w.HR.wheel_icon or file.Exists("materials/hellraiser/ui/wheel/" .. cls .. ".vmt", "GAME")) then
		local path = w.HR.wheel_icon and (current and w.HR.wheel_icon_selected or w.HR.wheel_icon) or "hellraiser/ui/wheel/" .. cls .. (current and "_g" or "")
		icons[path] = icons[path] or Material(path)
		surface.SetMaterial(icons[path])
		surface.SetDrawColor(255, 255, 255, alpha)
		local dimensions = w.HR.wheel_icon_size
		local k = math.min(210 / dimensions[1], 118 / dimensions[2]) * scale
		surface.DrawTexturedRect(x - dimensions[1] * k / 2, y - dimensions[2] * k / 2, dimensions[1] * k, dimensions[2] * k)
		return
	end
	if HRStockIcons.Draw(cls, x, y, 210 * scale, 118 * scale, current and "selected" or "", alpha) then return end
	if glyphs[cls] then
		if current then draw.SimpleText(glyphs[cls], "HRWheelIconGlow", x, y, Color(255, 236, 214, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER) end
		draw.SimpleText(glyphs[cls], "HRWheelIcon", x, y, Color(238, 230, 217, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
		return
	end
	local icon = entityIcon(cls)
	if icon then
		local size = 112 * scale
		surface.SetMaterial(icon)
		surface.SetDrawColor(255, 255, 255, alpha)
		surface.DrawTexturedRect(x - size / 2, y - size / 2, size, size)
	elseif w.WepSelectIcon and w.WepSelectIcon ~= defaultIcon then
		surface.SetTexture(w.WepSelectIcon)
		surface.SetDrawColor(255, 255, 255, alpha)
		surface.DrawTexturedRect(x - 105 * scale, y - 52 * scale, 210 * scale, 105 * scale)
	end
end

hook.Add("HUDPaint", "hr_weapon_wheel", function()
	if not available() or not W.groups or (not W.open and CurTime() >= (W.untilTime or 0)) then return end
	if not GetConVar("cl_drawhud"):GetBool() then return end
	local s = scale()
	local progress = math.Clamp((RealTime() - (W.opened or 0)) / 0.22, 0, 1)
	local opening = 1 - (1 - progress) ^ 3
	local closing = W.open and 1 or math.Clamp(((W.untilTime or 0) - CurTime()) / 0.25, 0, 1)
	local zoom = (0.88 + 0.12 * opening) * (0.97 + 0.03 * closing)
	s = s * zoom
	local x, y = ScrW() / 2, ScrH() / 2
	local size = 160 * s
	local alpha = (W.open and 255 or 220) * opening * closing
	if W.open then
		surface.SetDrawColor(5, 8, 12, 210 * opening)
		surface.DrawRect(0, 0, ScrW(), ScrH())
	end
	surface.SetDrawColor(255, 255, 255, alpha)
	surface.SetMaterial(wheel)
	surface.DrawTexturedRect(x - size / 2, y - size / 2, size, size)
    if W.open then W.buttons = {} end
	for g, pos in ipairs(positions) do
		local px, py = x + pos[1] * 165 * s, y + pos[2] * 165 * s
		local w = selected(g)
		local current = g == W.selected
		W.focus = W.focus or {0, 0, 0, 0}
		W.focus[g] = Lerp(1 - math.exp(-RealFrameTime() * 16), W.focus[g], current and 1 or 0)
		local emphasis = W.focus[g]
		if emphasis > 0.002 then
			surface.SetMaterial(glow)
			surface.SetDrawColor(255, 255, 255, alpha * emphasis * (0.7 + 0.05 * math.sin(RealTime() * 2)))
			local scale = size / 242
			local radius = size / 2 - 117 * scale / 2
			surface.DrawTexturedRectRotated(x + pos[1] * radius, y + pos[2] * radius,
				117 * scale, 231 * scale, 90 * (2 - g))
		end
		if IsValid(w) then
			local bump = current and 0.05 * math.exp(-(RealTime() - (W.changed or 0)) * 12) or 0
			drawIcon(w, px, py, s * (.66 + 0.05 * emphasis + bump), current, alpha)
        end
        draw.SimpleText(labels()[g], "HRWheelSmall", px, py + 45 * s,
            Color(190, 204, 219, alpha * (current and 1 or .75)), TEXT_ALIGN_CENTER)
        draw.SimpleText(g, "HRWheel", x + pos[1] * 33 * s, y + pos[2] * 33 * s,
            Color(219, 231, 245, alpha * (current and 1 or .55)), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        if W.open then
            W.buttons[#W.buttons + 1] = {
                label = labels()[g], x = px - 115 * s, y = py - 90 * s, w = 230 * s, h = 180 * s,
                action = function()
                    W.selected, W.pairWeapon = g, nil
                    W.changed, W.selectionUntil = RealTime(), CurTime() + 8
                    LocalPlayer():EmitSound("HR.UI_Menu_InGame_SquareGridSlot_Select")
                end
            }
            local category = W.buttons[#W.buttons]
            W.buttons[#W.buttons + 1] = {
                label = labels()[g], x = x + pos[1] * 33 * s - 24 * s, y = y + pos[2] * 33 * s - 24 * s,
                w = 48 * s, h = 48 * s, action = category.action,
            }
        end
	end
    if W.open then
        local cursorX, cursorY = x + W.x, y + W.y
        local width, row = 300 * s, 46 * s
        local function text(label, tx, ty, color, align, face)
            draw.SimpleTextOutlined(label, face or "HRWheelSmall", tx, ty, color,
                align or TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, alpha * .65))
        end
        local function fit(label, maximum, face)
            surface.SetFont(face or "HRWheelSmall")
            while surface.GetTextSize(label) > maximum and #label > 4 do label = label:sub(1, -5) .. "..." end
            return label
        end
        local function button(label, bx, by, action, active, item, shortcut)
            local hovered = cursorX >= bx and cursorX <= bx + width and cursorY >= by and cursorY <= by + row
            local lit = hovered or active
            local inset = item and 80 * s or 14 * s
            if lit then
                surface.SetMaterial(menuPattern)
                surface.SetDrawColor(69, 107, 156, alpha * .8)
                local height = width * 122 / 641
                surface.DrawTexturedRect(bx, by + (row - height) / 2, width, height)
            end
            if item then drawIcon(item, bx + 37 * s, by + row / 2, .32 * s, lit, alpha) end
            local color = lit and Color(237, 245, 255, alpha) or Color(181, 196, 213, alpha)
            text(fit(label, width - inset - (shortcut and 44 or 4) * s), bx + inset, by + row / 2, color)
            if shortcut then
                local size = 25 * s
                surface.SetMaterial(keyIcon)
                surface.SetDrawColor(66, 83, 108, alpha)
                surface.DrawTexturedRect(bx + width - size, by + (row - size) / 2, size, size)
                text(shortcut, bx + width - size / 2, by + row / 2, color, TEXT_ALIGN_CENTER)
            end
            W.buttons[#W.buttons + 1] = {label = label, x = bx, y = by, w = width, h = row, action = action}
        end
        local left, right, top = x - 590 * s, x + 300 * s, y - 180 * s
        local weapon = selected(W.selected)
        local list = W.groups[W.selected] or {}
        text(labels()[W.selected], left, top - 30 * s, Color(235, 240, 246, alpha), nil, "HRWheel")
        local first = math.Clamp((chosen[W.selected] or 1) - 4, 1, math.max(1, #list - 8))
        for index = first, math.min(#list, first + 8) do
            local item = list[index]
            button(weaponName(item), left, top + (index - first) * row, function() W.Select(item, true) end, item == weapon, item)
        end
        if #list > 9 then text("Scroll for more", left, top + 9 * row + 10 * s, Color(181, 196, 213, alpha)) end
        if IsValid(W.pairWeapon) then
            text("Other hand", right + 14 * s, top - 30 * s, Color(235, 240, 246, alpha), nil, "HRWheel")
            local choices = DHR.PairChoices(W.pairWeapon)
            local offset = math.Clamp(W.partnerScroll or 0, 0, math.max(0, #choices - 8))
            for index = offset + 1, math.min(#choices, offset + 8) do
                local partner = choices[index]
                local label = partner == W.pairWeapon and "Second " .. weaponName(partner) or weaponName(partner)
                button(label, right, top + (index - offset - 1) * row, function()
                    DHR.ChangeWield(W.pairWeapon, partner)
                    W.Close(false)
                end, false, partner)
            end
            button("Back", right, top + math.min(8, #choices) * row + 12 * s, function() W.pairWeapon = nil end)
        elseif IsValid(weapon) then
            text(fit(weaponName(weapon), width - 14 * s, "HRWheel"), right + 14 * s, top - 30 * s, Color(235, 240, 246, alpha), nil, "HRWheel")
            local index = 0
            local function action(label, callback, shortcut)
                button(label, right, top + index * row, callback, false, nil, shortcut)
                index = index + 1
            end
            action("Equip", function() W.Close(true) end)
            local reloadKey = string.upper(input.LookupBinding("+reload", true) or "")
            reloadKey = #reloadKey > 0 and #reloadKey <= 2 and reloadKey or nil
            if weapon.DualWield then
                action("Use one gun", W.ChoosePair, reloadKey)
            elseif DHR.CanChangeWield(weapon) then
                action("Dual wield", W.ChoosePair, reloadKey)
            end
            if DHR.CanChangeGrip(weapon) then
                action(weapon:GetNW2Bool("dhr_one_hand") and "Use two-handed grip" or "Use one-handed grip", W.ChangeGrip, "G")
            end
            if DHR.AmmoGun(weapon) and cvars.Bool("dhr_ammo_sharing", true) then
                index = index + .4
                action("Throw spare ammo", function() W.ShareAmmo(false) end, "X")
                if weapon == LocalPlayer():GetActiveWeapon() then action("Throw loaded ammo", function() W.ShareAmmo(true) end, "Z") end
            end
        end
        local instructions = W.pairWeapon and "LMB  Choose other gun     RMB  Back"
            or W.selectionMode and "LMB  Select     RMB  Cancel     Scroll  Browse"
            or "LMB  Select     RMB  Cancel     Release  Equip"
        text(instructions, x, y + 310 * s, Color(207, 220, 234, alpha), TEXT_ALIGN_CENTER)
        draw.NoTexture()
        surface.SetDrawColor(224, 236, 250, alpha)
        surface.DrawPoly({{x = cursorX, y = cursorY}, {x = cursorX + 12 * s, y = cursorY + 10 * s}, {x = cursorX + 5 * s, y = cursorY + 15 * s}})
    end
end)

hook.Add("HUDShouldDraw", "hr_wheel_crosshair", function(name)
	if name == "CHudCrosshair" and W.open and available() then return false end
end)
