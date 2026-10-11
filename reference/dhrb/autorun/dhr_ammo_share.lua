if SERVER then AddCSLuaFile() end

include("dhr/core.lua")
local enabled = CreateConVar("dhr_ammo_sharing", "1", FCVAR_ARCHIVE + FCVAR_REPLICATED, "Allow players to throw carried ammunition")
local ammoModels = {
    Pistol = "models/Items/BoxSRounds.mdl",
    SMG1 = "models/Items/BoxMRounds.mdl",
    AR2 = "models/Items/combine_rifle_cartridge01.mdl",
    Buckshot = "models/Items/BoxBuckshot.mdl",
    ["357"] = "models/Items/357ammo.mdl",
}

function DHR.AmmoGun(weapon, side)
    if not IsValid(weapon) or not weapon.HR or weapon.HR.kind ~= "gun" then return end
    if weapon.DualWield then return weapon:Gun(side or 2) end
    return {class = weapon:GetClass(), config = weapon.HR, primary = weapon.Primary, name = weapon:GetPrintName()}
end

function DHR.AmmoSide(weapon, target)
    if not weapon.DualWield or not IsValid(target) or not target.GetActiveWeapon then return 2 end
    local held = target:GetActiveWeapon()
    if not IsValid(held) then return 2 end
    local ammo = held:GetPrimaryAmmoType()
    for side = 1, 2 do
        if game.GetAmmoID(weapon:Gun(side).primary.Ammo) == ammo then return side end
    end
    return 2
end

if CLIENT then
    local key = CreateClientConVar("dhr_share_key", tostring(KEY_H), true, false, "Key used to throw spare ammunition")
    function DHR.ShareAmmo(weapon, loaded)
        if not enabled:GetBool() or not DHR.AmmoGun(weapon) then return end
        net.Start("dhr_share_ammo")
        net.WriteEntity(weapon)
        net.WriteBool(loaded == true)
        net.SendToServer()
    end

    function DHR.SetAmmoSharing(on)
        net.Start("dhr_ammo_sharing")
        net.WriteBool(on)
        net.SendToServer()
    end

    local wasDown = false
    hook.Add("Think", "dhr_share_ammo", function()
        local code = key:GetInt()
        local down = code >= MOUSE_FIRST and code <= MOUSE_LAST and input.IsMouseDown(code)
            or code > KEY_NONE and code < MOUSE_FIRST and input.IsKeyDown(code)
        if down and not wasDown and not gui.IsGameUIVisible() and not vgui.CursorVisible()
            and not IsValid(vgui.GetKeyboardFocus()) and not (HRWheel and HRWheel.open) then
            local player = LocalPlayer()
            if IsValid(player) then DHR.ShareAmmo(player:GetActiveWeapon(), false) end
        end
        wasDown = down
    end)
    hook.Add("PlayerBindPress", "dhr_share_ammo", function(player, bind, pressed, code)
        if code == key:GetInt() and enabled:GetBool() and DHR.AmmoGun(player:GetActiveWeapon())
            and not gui.IsGameUIVisible() and not vgui.CursorVisible() then return true end
    end)
    return
end

util.AddNetworkString("dhr_share_ammo")
util.AddNetworkString("dhr_ammo_sharing")
net.Receive("dhr_ammo_sharing", function(_, player)
    if not game.SinglePlayer() and not player:IsAdmin() then return end
    enabled:SetBool(net.ReadBool())
end)

function DHR.CanReceiveAmmo(target, donor, ammo)
    if not IsValid(target) or target:Health() <= 0 then return false end
    local allowed = DHR.RunHook("DHRCanReceiveAmmo", target, donor, ammo)
    if allowed ~= nil then return allowed == true end
    if target:IsPlayer() then
        if not target:Alive() then return false end
        local id = game.GetAmmoID(ammo)
        for _, weapon in ipairs(target:GetWeapons()) do
            if weapon:GetPrimaryAmmoType() == id or weapon:GetSecondaryAmmoType() == id then return true end
        end
    elseif target:IsNPC() and IsValid(donor) and target:Disposition(donor) == D_LI then
        local weapon = target:GetActiveWeapon()
        return IsValid(weapon) and weapon:GetPrimaryAmmoType() == game.GetAmmoID(ammo)
            and weapon:Clip1() < weapon:GetMaxClip1()
    end
    return false
end

function DHR.GiveSharedAmmo(target, donor, ammo, rounds)
    if not DHR.CanReceiveAmmo(target, donor, ammo) then return 0 end
    local given = DHR.RunHook("DHRReceiveAmmo", target, donor, ammo, rounds)
    if given ~= nil then return math.Clamp(math.floor(tonumber(given) or 0), 0, rounds) end
    if target:IsPlayer() then
        local before = target:GetAmmoCount(ammo)
        local room = math.max(0, DHR.AmmoLimit(target, ammo) - before)
        if room == 0 then return 0 end
        target:GiveAmmo(math.min(rounds, room), ammo, true)
        return math.max(0, target:GetAmmoCount(ammo) - before)
    end
    if not target.GetActiveWeapon then return 0 end
    local weapon = target:GetActiveWeapon()
    if not IsValid(weapon) then return 0 end
    local count = math.min(rounds, math.max(0, weapon:GetMaxClip1() - weapon:Clip1()))
    weapon:SetClip1(weapon:Clip1() + count)
    return count
end

function DHR.ThrowAmmo(player, weapon, loaded)
    if not enabled:GetBool() or not IsValid(player) or not player:IsPlayer() or not player:Alive() then return end
    if not IsValid(weapon) or weapon:GetOwner() ~= player or not DHR.AmmoGun(weapon) then return end
    if CurTime() < (player.dhr_next_share or 0) or player:IsFrozen() then return end
    local held = player:GetActiveWeapon()
    if IsValid(held) and held:GetNW2Bool("hr_executing") then return end
    if weapon:GetNW2Bool("hr_executing") or weapon:GetReloadDone() > 0 or weapon:GetReloadStage() > 0
        or CurTime() < weapon:GetReloadUntil() then return end
    if loaded and player:GetActiveWeapon() ~= weapon then return end
    local active = 0
    for _, entity in ipairs(ents.FindByClass("dhr_shared_ammo")) do
        if entity:GetDonor() == player then active = active + 1 end
    end
    if active >= 8 then return end
    local target = player:GetEyeTrace().Entity
    local side = DHR.AmmoSide(weapon, target)
    local gun = DHR.AmmoGun(weapon, side)
    local ammo = gun.primary.Ammo
    local clip = weapon.DualWield and weapon:DualClip(side) or weapon:Clip1()
    local count = loaded and clip or math.min(gun.primary.ClipSize, player:GetAmmoCount(ammo))
    if count <= 0 or game.GetAmmoID(ammo) < 0 then return end
    local model = gun.config.ammo_world_model or ammoModels[ammo] or ammoModels.Pistol
    local original = "models/weapons/hellraiser/w_hr_ammo_" .. gun.class:gsub("^hr_", "") .. ".mdl"
    if file.Exists(original, "GAME") and util.IsValidModel(original) then model = original end
    local magazine
    if loaded then
        local part
        if weapon.DualWield then
            local index = weapon:WithGun(side, weapon.MagazinePart)
            part = index and gun.config.magazines[index]
        else
            local index = weapon:MagazinePart()
            part = index and (gun.config.magazines or {})[index]
        end
        if part then model, magazine = part.model, true end
    end
    local entity = ents.Create("dhr_shared_ammo")
    if not IsValid(entity) then return end
    local origin = player:GetShootPos()
    local start = origin + player:GetAimVector() * 14 - player:EyeAngles():Right() * 7 - Vector(0, 0, 9)
    local trace = util.TraceHull({start = origin, endpos = start, mins = Vector(-2, -2, -2), maxs = Vector(2, 2, 2),
        filter = {player, weapon}, mask = MASK_SOLID_BRUSHONLY})
    entity:SetModel(model)
    entity:SetPos(trace.HitPos)
    entity:SetAngles(player:EyeAngles())
    entity:SetDonor(player)
    entity:SetAmmoName(ammo)
    entity:SetRounds(count)
    entity.Magazine = magazine
    entity.ThrowVelocity = player:GetAimVector() * 460 + Vector(0, 0, 125) + player:GetVelocity()
    entity:Spawn()
    if not IsValid(entity) then return end
    if loaded then
        if weapon.DualWield then weapon:SetDualClip(side, 0) else weapon:SetClip1(0) end
    else player:RemoveAmmo(count, ammo) end
    player.dhr_next_share = CurTime() + 0.8
    player:DoAnimationEvent(ACT_GMOD_GESTURE_ITEM_THROW)
    DHR.RunHook("DHRAmmoThrown", player, weapon, entity)
    return entity
end

net.Receive("dhr_share_ammo", function(_, player)
    DHR.ThrowAmmo(player, net.ReadEntity(), net.ReadBool())
end)
