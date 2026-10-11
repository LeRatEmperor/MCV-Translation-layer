AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.Spawnable = false

function ENT:Initialize()
	if CLIENT then return end
	self:SetModel(self.Model)
	self:PhysicsInit(SOLID_VPHYSICS)
	self:SetMoveType(MOVETYPE_VPHYSICS)
	self:SetSolid(SOLID_VPHYSICS)
	self:SetUseType(SIMPLE_USE)
	local phys = self:GetPhysicsObject()
	if IsValid(phys) then phys:Wake() end
end

function ENT:Use(p)
	if not IsValid(p) or not p:IsPlayer() or not p:Alive() then return end
	if p:EyePos():DistToSqr(self:WorldSpaceCenter()) > 128 * 128 then return end
	local owned = HRUpgrades.Owned(p, self.WeaponClass, self.UpgradeID)
	if owned and HRUpgrades.Parse((p.hr_upgrades or {})[self.WeaponClass])[self.UpgradeID] then
		if CurTime() >= (self.nextNotice or 0) then
			self.nextNotice = CurTime() + 1
			p:PrintMessage(HUD_PRINTTALK, self.PrintName .. " is already fitted.")
		end
		return
	end
	if not owned and not HRUpgrades.Grant(p, self.WeaponClass, self.UpgradeID) then return end
	p:EmitSound("HR.UI_ItemPickUp_Inventory")
	net.Start("hr_upgrade_collected")
	net.WriteString(self.PrintName)
	net.WriteString(self.WeaponClass)
	net.WriteString(HRUpgrades.Install(p, self.WeaponClass, self.UpgradeID))
	net.Send(p)
	if not owned then self:Remove() end
end

function ENT:SpawnFunction(p, tr, cls)
	if not tr.Hit then return end
	local e = ents.Create(cls)
	e:SetPos(tr.HitPos + tr.HitNormal * 10)
	e:SetAngles(Angle(0, p:EyeAngles().y, 0))
	e:Spawn()
	e:Activate()
	return e
end

if CLIENT then
	function ENT:Draw()
		self:DrawModel()
	end
end
