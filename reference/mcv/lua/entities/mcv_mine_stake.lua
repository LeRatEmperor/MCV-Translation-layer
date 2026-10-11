AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Tripwire Stake"
ENT.Spawnable = false

ENT.Model = "models/weapons/mcv/w_mine.mdl"
ENT.MineBodygroups = {mine = 0, stick = 1}

function ENT:SetupDataTables()
    self:NetworkVar("Entity", 0, "Planter")
end

function ENT:Initialize()
    if SERVER then
        self:SetModel(self.Model)
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_NONE)
        self:SetSolid(SOLID_VPHYSICS)
        self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then phys:EnableMotion(false) end
        // shootable by the planter too: a bullet passes through what its shooter owns
        if IsValid(self:GetOwner()) then
            self:SetPlanter(self:GetOwner())
            self:SetOwner(NULL)
        end
        // the mine world model carries both pieces as bodygroups: show only the stake (the
        // mine group is m16m, vc, blank: option 1 was the VC mine, not a blank)
        self:SetBodygroup(self.MineBodygroups.mine, math.max(self:GetBodygroupCount(self.MineBodygroups.mine) - 1, 0))
        self:SetBodygroup(self.MineBodygroups.stick, 0)
    end
end

function ENT:OnTakeDamage(dmg)
    if !IsValid(self.Mine) then return end
    if dmg:GetDamage() > 10 then
        self:Remove() // the mine notices and goes off
    end
end
