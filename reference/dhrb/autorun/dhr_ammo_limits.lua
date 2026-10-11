if SERVER then AddCSLuaFile() end
DHR = DHR or {}

local settings = {
    {ammo = "Pistol", label = "Pistol", key = "pistol"},
    {ammo = "357", label = "Revolver", key = "revolver"},
    {ammo = "SMG1", label = "SMG", key = "smg"},
    {ammo = "AR2", label = "Rifle", key = "rifle"},
    {ammo = "Buckshot", label = "Shotgun", key = "shotgun"},
    {label = "Other ammo types", key = "other"},
}
local byAmmo, byKey = {}, {}
for _, setting in ipairs(settings) do
    setting.convar = CreateConVar("dhr_reserve_" .. setting.key, "-1", FCVAR_ARCHIVE + FCVAR_REPLICATED,
        "Reserve ammo limit for DHRB guns. -1 uses the game limit; 0 allows loaded rounds only.", -1, 10000)
    byKey[setting.key] = setting
    if setting.ammo then byAmmo[string.lower(setting.ammo)] = setting end
end

local function usesAmmo(player, ammo)
    for _, weapon in ipairs(player:GetWeapons()) do
        if weapon.HR and weapon.HR.kind == "gun"
            and (weapon:GetPrimaryAmmoType() == ammo or weapon:GetSecondaryAmmoType() == ammo) then return true end
    end
    return false
end

local function configuredLimit(player, ammo)
    local name = game.GetAmmoName(ammo)
    if not name then return end
    local limit = (byAmmo[string.lower(name)] or byKey.other).convar:GetInt()
    if limit >= 0 and usesAmmo(player, ammo) then return math.min(limit, game.GetAmmoMax(ammo)) end
end

function DHR.AmmoLimit(player, ammo)
    local id = isstring(ammo) and game.GetAmmoID(ammo) or ammo
    if not game.GetAmmoName(id) then return 0 end
    return configuredLimit(player, id) or game.GetAmmoMax(id)
end

if CLIENT then
    hook.Add("PopulateToolMenu", "dhr_ammo_limits", function()
        spawnmenu.AddToolMenuOption("Options", "Hellraiser", "DHRAmmoLimits", "Ammo limits", "", "", function(panel)
            panel:Help("Host/admin settings for players carrying DHRB guns. Limits apply to reserve ammo shared by weapons of that type; magazine sizes stay unchanged.")
            panel:Help("-1 keeps the game limit. 0 allows loaded rounds only. Lowering a limit removes reserve rounds above it. The game's ammo caps still apply.")
            local fields = {}
            for _, setting in ipairs(settings) do
                local row = vgui.Create("DPanel", panel)
                row:SetTall(28)
                row:SetPaintBackground(false)
                local number = vgui.Create("DNumberWang", row)
                number:Dock(RIGHT)
                number:SetWide(78)
                number:SetMinMax(-1, 10000)
                number:SetDecimals(0)
                number:SetValue(setting.convar:GetInt())
                fields[setting.key] = number
                local label = vgui.Create("DLabel", row)
                label:Dock(FILL)
                label:SetText(setting.label)
                label:SetDark(true)
                panel:AddItem(row)
            end
            local apply = panel:Button("Apply reserve limits")
            apply.DoClick = function()
                net.Start("dhr_ammo_limits")
                for _, setting in ipairs(settings) do net.WriteInt(math.Clamp(math.Round(fields[setting.key]:GetValue()), -1, 10000), 16) end
                net.SendToServer()
            end
            apply.Think = function(self) self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin()) end
            local reset = panel:Button("Use game limits")
            reset.DoClick = function() for _, field in pairs(fields) do field:SetValue(-1) end end
            panel:Help("Press Apply after changing values. Settings are saved on the server.")
        end)
    end)
    return
end

local function clampAmmo(player, ammo)
    local maximum = configuredLimit(player, ammo)
    if maximum and player:GetAmmoCount(ammo) > maximum then player:SetAmmo(maximum, ammo) end
end
local function clampPlayer(player)
    for ammo in pairs(player:GetAmmo()) do clampAmmo(player, ammo) end
end

util.AddNetworkString("dhr_ammo_limits")
net.Receive("dhr_ammo_limits", function(_, player)
    if not game.SinglePlayer() and not player:IsAdmin() then return end
    for _, setting in ipairs(settings) do setting.convar:SetInt(math.Clamp(net.ReadInt(16), -1, 10000)) end
end)
for _, setting in ipairs(settings) do
    cvars.AddChangeCallback(setting.convar:GetName(), function()
        for _, player in ipairs(player.GetAll()) do clampPlayer(player) end
    end, "dhr_ammo_limits")
end
hook.Add("PlayerAmmoChanged", "dhr_ammo_limits", function(player, ammo, before, after)
    if after > before then clampAmmo(player, ammo) end
end)
hook.Add("WeaponEquip", "dhr_ammo_limits", function(weapon, player)
    if not weapon.HR or weapon.HR.kind ~= "gun" then return end
    timer.Simple(0, function() if IsValid(player) and player:IsPlayer() then clampPlayer(player) end end)
end)

local pickups = {
    item_ammo_pistol = "Pistol", item_ammo_pistol_large = "Pistol",
    item_ammo_357 = "357", item_ammo_357_large = "357",
    item_ammo_smg1 = "SMG1", item_ammo_smg1_large = "SMG1",
    item_ammo_ar2 = "AR2", item_ammo_ar2_large = "AR2", item_box_buckshot = "Buckshot",
}
hook.Add("PlayerCanPickupItem", "dhr_ammo_limits", function(player, item)
    local ammo = pickups[item:GetClass()]
    if ammo and player:GetAmmoCount(ammo) >= DHR.AmmoLimit(player, ammo) then return false end
end)
