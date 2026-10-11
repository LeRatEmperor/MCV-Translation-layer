AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Supply Box"
ENT.Spawnable = false

ENT.Model = "models/weapons/mcv/w_box.mdl"
ENT.BoxKind = "ammo"
ENT.HealAmount = 50
ENT.AmmoMagazines = 1
ENT.Uses = 3
ENT.Lifetime = 120
ENT.TouchRadius = 48 // units from the box within which a player is served
ENT.TouchCooldown = 3 // seconds before the same player is served again by touching

function ENT:Initialize()
    if SERVER then
        self:SetModel(self.Model)
        self:PhysicsInit(SOLID_VPHYSICS)
        self:SetMoveType(MOVETYPE_VPHYSICS)
        self:SetSolid(SOLID_VPHYSICS)
        self:SetUseType(SIMPLE_USE)
        self.DieTime = CurTime() + self.Lifetime
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then phys:Wake() end
        self.NextTouch = {}
    end
end

// walking up to it is enough: anyone within TouchRadius is served (trigger bounds on a
// physics prop never fired for players, so this polls from Think)
function ENT:TouchTick()
    for _, ent in ipairs(ents.FindInSphere(self:GetPos(), self.TouchRadius)) do
        if !ent:IsPlayer() or !ent:Alive() then continue end
        if (self.NextTouch[ent] or 0) > CurTime() then continue end
        self.NextTouch[ent] = CurTime() + self.TouchCooldown
        self:Use(ent)
        if !IsValid(self) then return end
    end
end

function ENT:Use(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    if (self.NextUse or 0) > CurTime() then return end
    self.NextUse = CurTime() + 0.5

    local gave, cursor = MCV_ApplySupply(self.BoxKind, ply, self.HealAmount, self.AmmoMagazines, self.SupplyCursor)
    if gave then
        self.SupplyCursor = cursor
        self:EmitSound(self.BoxKind == "medic" and "items/medshot4.wav" or "items/ammocrate_close.wav", 70)
        self.Uses = self.Uses - 1
        if self.Uses <= 0 then self:Remove() end
    else
        self:EmitSound("items/medshotno1.wav", 60)
    end
end

function ENT:Think()
    if SERVER then
        if CurTime() > self.DieTime then
            self:Remove()
            return
        end
        self:TouchTick()
    end
    self:NextThink(CurTime() + 0.25)
    return true
end
