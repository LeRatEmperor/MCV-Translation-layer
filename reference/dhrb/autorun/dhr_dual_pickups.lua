if SERVER then AddCSLuaFile() end

DHR = DHR or {}
DHR.DualClasses = DHR.DualClasses or {}
DHR.PairClasses = DHR.PairClasses or {}

function DHR.PairClass(left, right)
    if left == right then return DHR.DualClasses[right] end
    if not DHR.DualClasses[left] or not DHR.DualClasses[right] then return end
    local key = left .. ":" .. right
    if DHR.PairClasses[key] then return DHR.PairClasses[key] end
    local first, second = weapons.Get(left), weapons.Get(right)
    if not first or not second then return end
    local class = "dhr_pair_" .. left .. "_" .. right
    weapons.Register({
        Base = "dhr_dual_base", PrintName = first.PrintName .. " + " .. second.PrintName,
        Spawnable = false, Category = second.Category, Slot = second.Slot, SlotPos = second.SlotPos,
        SingleClass = right, SecondClass = left, HoldType = "duel",
        ViewModel = second.ViewModel, WorldModel = second.WorldModel,
        Primary = table.Copy(first.Primary), Secondary = table.Copy(second.Primary),
        HR = {kind = "gun", seq = {}, len = {}, kill_icon = second.HR.kill_icon},
    }, class)
    DHR.PairClasses[key] = class
    return class
end

local function registerPairs()
    for left in pairs(DHR.DualClasses) do
        for right in pairs(DHR.DualClasses) do DHR.PairClass(left, right) end
    end
end

function DHR.RegisterDual(single, dual)
    DHR.DualClasses[single] = dual
    timer.Simple(0, registerPairs)
end
hook.Add("Initialize", "dhr_pair_classes", registerPairs)

function DHR.PairChoices(weapon)
    if not IsValid(weapon) or weapon.DualWield or not DHR.DualClasses[weapon:GetClass()] then return {} end
    local owner = weapon:GetOwner()
    if not IsValid(owner) then return {} end
    local choices = {}
    if weapon:GetNW2Int("dhr_spare_rounds", -1) >= 0 then choices[1] = weapon end
    for _, other in ipairs(owner:GetWeapons()) do
        if other ~= weapon and not other.DualWield and DHR.DualClasses[other:GetClass()] then choices[#choices + 1] = other end
    end
    table.sort(choices, function(a, b) return a:GetClass() < b:GetClass() end)
    return choices
end

function DHR.CanChangeWield(weapon)
    return IsValid(weapon) and weapon.HR and (weapon.DualWield or #DHR.PairChoices(weapon) > 0)
end

function DHR.CanChangeGrip(weapon)
    return IsValid(weapon) and weapon.HR and weapon.HR.kind == "gun" and not weapon.DualWield
        and (weapon.HoldType == "pistol" or weapon.HoldType == "revolver")
end

function DHR.SupportWithdrawal(weapon)
    if not DHR.CanChangeGrip(weapon) or not weapon:GetNW2Bool("dhr_one_hand")
        or weapon:GetNW2Bool("hr_executing") then return 0 end
    local sequence = weapon:GetPoseSequence()
    if sequence == weapon.HR.seq.draw then return 0 end
    if string.StartWith(sequence, "reload") then
        local release = (weapon.HR.support_release or {})[sequence]
        if not release then return 0 end
        local elapsed = (CurTime() - weapon:GetPoseStart()) * math.max(weapon:GetPoseRate(), .01)
        local fraction = math.Clamp((elapsed - release) / .12, 0, 1)
        return fraction * fraction * (3 - 2 * fraction)
    end
    return 1
end

function DHR.OneHanded(weapon)
    return DHR.SupportWithdrawal(weapon) >= 1
end

if CLIENT then
    function DHR.ChangeGrip(weapon)
        if not DHR.CanChangeGrip(weapon) then return end
        net.Start("dhr_grip")
        net.WriteEntity(weapon)
        net.SendToServer()
    end

    function DHR.ChangeWield(weapon, partner)
        if not DHR.CanChangeWield(weapon) then return end
        net.Start("dhr_wield_mode")
        net.WriteEntity(weapon)
        net.WriteEntity(IsValid(partner) and partner or DHR.PairChoices(weapon)[1] or NULL)
        net.SendToServer()
    end
    return
end

util.AddNetworkString("dhr_wield_mode")
util.AddNetworkString("dhr_grip")
net.Receive("dhr_grip", function(_, player)
    local weapon = net.ReadEntity()
    if not player:Alive() or not DHR.CanChangeGrip(weapon) or weapon:GetOwner() ~= player then return end
    if CurTime() < (weapon.dhr_grip_changed or 0) then return end
    weapon.dhr_grip_changed = CurTime() + 0.2
    weapon:SetNW2Bool("dhr_one_hand", not weapon:GetNW2Bool("dhr_one_hand"))
end)

local function ready(player, weapon)
    return IsValid(player) and player:IsPlayer() and player:Alive() and IsValid(weapon) and weapon.HR
        and weapon:GetOwner() == player and not weapon:GetNW2Bool("hr_executing")
        and weapon:GetReloadDone() == 0 and weapon:GetReloadStage() == 0
        and CurTime() >= weapon:GetReloadUntil()
        and (weapon:GetPoseSequence() == weapon.HR.seq.draw
            or CurTime() >= math.max(weapon:GetNextPrimaryFire(), weapon:GetNextSecondaryFire()))
end

local function loadSide(player, pair, side, rounds, upgrades)
    local gun = pair:Gun(side)
    pair:SetNW2String(side == 1 and "dhr_left_upgrades" or "hr_upgrades", upgrades)
    pair:SyncDualUpgrades()
    local size = gun.primary.ClipSize
    local excess = math.max(0, rounds - size)
    pair:SetDualClip(side, math.Clamp(rounds, 0, size))
    if excess > 0 then player:GiveAmmo(excess, gun.primary.Ammo, true) end
end

function DHR.EquipPair(player, single, rounds, partner)
    if not ready(player, single) then return false end
    local leftClass = IsValid(partner) and partner:GetClass() or single:GetClass()
    if IsValid(partner) and (partner == single or not ready(player, partner)) then return false end
    local class = DHR.PairClass(leftClass, single:GetClass())
    if not class or player:HasWeapon(class) then return false end
    local pair = player:Give(class, true)
    if not IsValid(pair) then return false end
    pair.dhr_preserve_upgrades = true
    if IsValid(partner) then
        pair:SetNW2Int("dhr_right_spare", single:GetNW2Int("dhr_spare_rounds", -1))
        pair:SetNW2Int("dhr_left_spare", partner:GetNW2Int("dhr_spare_rounds", -1))
    end
    pair:SetNW2Bool("dhr_one_hand", single:GetNW2Bool("dhr_one_hand"))
    loadSide(player, pair, 2, single:Clip1(), single:GetNW2String("hr_upgrades", ""))
    local leftUpgrades = IsValid(partner) and partner:GetNW2String("hr_upgrades", "") or single:GetNW2String("hr_upgrades", "")
    loadSide(player, pair, 1, rounds, leftUpgrades)
    player:SelectWeapon(class)
    single:Remove()
    if IsValid(partner) then partner:Remove() end
    return true
end

function DHR.EquipSingle(player, pair)
    if not ready(player, pair) or not pair.SingleClass then return false end
    local mixed = pair:Gun(1).class ~= pair:Gun(2).class
    local carried = player:GetWeapon(pair.SingleClass)
    if not IsValid(carried) and mixed then carried = player:GetWeapon(pair:Gun(1).class) end
    if IsValid(carried) then
        player:SelectWeapon(carried:GetClass())
        return true
    end
    local single = player:Give(pair.SingleClass, true)
    if not IsValid(single) then return false end
    single.dhr_preserve_upgrades = true
    local left
    if mixed then
        left = player:Give(pair:Gun(1).class, true)
        if not IsValid(left) then single:Remove(); return false end
        left.dhr_preserve_upgrades = true
        left:SetNW2Int("dhr_spare_rounds", pair:GetNW2Int("dhr_left_spare", -1))
        single:SetNW2Int("dhr_spare_rounds", pair:GetNW2Int("dhr_right_spare", -1))
        left:SetNW2String("hr_upgrades", pair:GunUpgradeString(1))
        HRUpgrades.Sync(left)
        left:SetClip1(pair:Clip1())
        left:SetNW2Int("hr_rev_loaded", pair:Clip1())
    else single:SetNW2Int("dhr_spare_rounds", pair:Clip1()) end
    single:SetNW2String("hr_upgrades", pair:GunUpgradeString(2))
    HRUpgrades.Sync(single)
    single:SetNW2Bool("dhr_one_hand", pair:GetNW2Bool("dhr_one_hand"))
    single:SetClip1(pair:Clip2())
    single:SetNW2Int("hr_rev_loaded", pair:Clip2())
    player:SelectWeapon(pair.SingleClass)
    pair:Remove()
    return true
end

net.Receive("dhr_wield_mode", function(_, player)
    local weapon, partner = net.ReadEntity(), net.ReadEntity()
    if not DHR.CanChangeWield(weapon) or weapon:GetOwner() ~= player then return end
    local changed
    if weapon.DualWield then
        changed = DHR.EquipSingle(player, weapon)
    elseif partner == weapon and weapon:GetNW2Int("dhr_spare_rounds", -1) >= 0 then
        changed = DHR.EquipPair(player, weapon, weapon:GetNW2Int("dhr_spare_rounds", 0))
    elseif IsValid(partner) and partner:GetOwner() == player then
        changed = DHR.EquipPair(player, weapon, partner:Clip1(), partner)
    end
    if not changed then player:ChatPrint("Finish the current weapon action before changing guns.") end
end)

hook.Add("PlayerCanPickupWeapon", "dhr_dual_pickup", function(player, incoming)
    if not IsValid(incoming) or not DHR.DualClasses[incoming:GetClass()] then return end
    local single = player:GetWeapon(incoming:GetClass())
    if not IsValid(single) or single == incoming or single:GetNW2Int("dhr_spare_rounds", -1) >= 0 then return end
    if DHR.EquipPair(player, single, incoming:Clip1()) then incoming:Remove(); return false end
end)

local checkingGive = false
hook.Add("PlayerGiveSWEP", "dhr_dual_give", function(player, class, info)
    if checkingGive or not DHR.DualClasses[class] then return end
    local single = player:GetWeapon(class)
    if not IsValid(single) or single:GetNW2Int("dhr_spare_rounds", -1) >= 0 then return end
    -- Let Sandbox finish selecting the single gun before replacing it.
    timer.Simple(0, function()
        if not ready(player, single) then return end
        checkingGive = true
        local allowed = gamemode.Call("PlayerGiveSWEP", player, class, info)
        checkingGive = false
        if allowed then DHR.EquipPair(player, single, single.HR.clip or single.Primary.ClipSize) end
    end)
end)
