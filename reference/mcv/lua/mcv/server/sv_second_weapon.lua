// Dual wield unlocks when the player gets hold of a second copy of a weapon they already carry.
// The engine never hands that copy over: a touched pickup goes through PlayerCanPickupWeapon and
// EquipAmmo on the *ground* entity and is removed, and the spawn menu asks PlayerGiveSWEP first
// (sandbox) and then only gives ammo. All three paths land here and flag the carried weapon.
local function unlockSecond(ply, class)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    local have = ply:GetWeapon(class)
    if !IsValid(have) or !have.HasAkimbo or !have.SetHasSecond then return end
    if !have:GetHasSecond() then
        have:SetHasSecond(true)
        ply:EmitSound("MCV_Weapon_Foley_AK47.DrawMetal")
    end
end
MCV.UnlockSecondWeapon = unlockSecond

hook.Add("PlayerCanPickupWeapon", "mcv_second_weapon", function(ply, wep)
    if IsValid(wep) and wep.HasAkimbo and ply:HasWeapon(wep:GetClass()) then
        unlockSecond(ply, wep:GetClass())
    end
end)

// sandbox passes the list.Get("Weapon") entry here (class name, print name, category...), not
// the weapon table, so the stored SWEP table is what says whether the gun can be dual wielded
hook.Add("PlayerGiveSWEP", "mcv_second_weapon", function(ply, class, swep)
    local stored = weapons.GetStored(class)
    if stored and stored.HasAkimbo and ply:HasWeapon(class) then
        unlockSecond(ply, class)
    end
end)
