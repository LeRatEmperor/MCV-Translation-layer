if SERVER then AddCSLuaFile() end
HRBlood = HRBlood or {}
local B = HRBlood
local DRY = 150

function B.Amount(w)
	if not IsValid(w) then return 0 end
	local amount = w:GetNW2Float('hr_blood', 0)
	if amount <= 0 then return 0 end
	return math.max(0, amount - (CurTime() - w:GetNW2Float('hr_blood_time', 0)) / DRY)
end

if SERVER then
	function B.Add(w, amount)
		if not IsValid(w) or not w.HR or amount <= 0 then return end
		w:SetNW2Float('hr_blood', math.min(1, B.Amount(w) + amount))
		w:SetNW2Float('hr_blood_time', CurTime())
	end
	return
end

local function weaponOf(ent)
	if not IsValid(ent) then return end
	if ent:IsWeapon() then return ent end
	if ent.hr_weapon then return ent.hr_weapon end
	local owner = ent:GetOwner()
	if IsValid(owner) and owner:IsPlayer() and owner:GetViewModel() == ent then return owner:GetActiveWeapon() end
end

matproxy.Add({
	name = 'HRBlood',
	init = function() end,
	bind = function(_, mat, ent)
		mat:SetFloat('$detailblendfactor', B.Amount(weaponOf(ent)) * 0.9)
	end
})
