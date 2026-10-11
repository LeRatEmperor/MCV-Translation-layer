AddCSLuaFile()

ENT.Base                     = "mcv_grenade_base"
ENT.RoundCollision           = false
ENT.PrintName                = "Tripwire Mine"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_mine.mdl"

ENT.TimeFuse = false
ENT.Delay = 0
ENT.ImpactFuse = false
ENT.ExplodeOnDamage = true
ENT.Defusable = true
ENT.BounceSounds = nil
ENT.ExplosionFamily = "grenade"
ENT.ExplosionDamage = 175
ENT.ExplosionRadius = 250
ENT.ArmDelay = 2 // seconds after the stake goes in before the wire is live
ENT.SelfDestructDelay = 300 // seconds from placement, including time waiting for a stake
ENT.MineBodygroups = {mine = 0, stick = 1}

function ENT:SetupDataTables()
    baseclass.Get("mcv_proj_base").SetupDataTables(self)
    self:NetworkVar("Entity", 2, "Stake")
end

function ENT:PlantOn(parent)
    if CLIENT then return end
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    if IsValid(parent) then self:SetParent(parent) end
    self:ReleaseOwner() // shootable by the planter too
    self:EmitSound("MCV_Weapon_C4_Demolition.Plant")
end

function ENT:Light()
end

function ENT:SetStakeEntity(stake)
    self:SetStake(stake)
    self.LiveTime = CurTime() + self.ArmDelay
    stake.Mine = self
    self:EmitSound("MCV_Weapon_C4_Demolition.Plant")
end

function ENT:GetWireStart()
    // Model up follows the mounting surface, including a moving/rotating parent.
    return self:GetPos() + self:GetUp() * 4
end

function ENT:WireEnds()
    local stake = self:GetStake()
    if !IsValid(stake) then return nil end
    return self:GetWireStart(), stake:GetPos()
end

function ENT:Think()
    if SERVER then
        if !self.Detonated and CurTime() >= self.SpawnTime + self.SelfDestructDelay then
            self:PreDetonate()
            return
        end
        local stake = self:GetStake()
        if IsValid(stake) and self.LiveTime and CurTime() > self.LiveTime and !self.Detonated then
            local a, b = self:WireEnds()
            // anything crossing the wire
            local tr = util.TraceHull({start = a, endpos = b, mins = Vector(-2, -2, -2), maxs = Vector(2, 2, 2),
                                       filter = {self, stake}, mask = MASK_SHOT_HULL})
            local ent = tr.Entity
            if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsVehicle() or ent.LVS or ent.IsSimfphyscar or (ent:GetClass() == "prop_physics" and ent:GetVelocity():Length() > 50)) then
                self.Attacker = self.Attacker or self:GetOwner()
                self:PreDetonate()
            end
        elseif self.StakeSet and !IsValid(stake) and !self.Detonated then
            // stake destroyed: the mine goes off
            self:PreDetonate()
        end
        if IsValid(stake) then self.StakeSet = true end
        self:OnThink()
    end
    self:NextThink(CurTime() + 0.05)
    return true
end

function ENT:Detonate()
    local stake = self:GetStake()
    if IsValid(stake) then stake:Remove() end
    baseclass.Get("mcv_grenade_base").Detonate(self)
end

function ENT:Use(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    if ply != self:GetOwner() then return end
    if IsValid(self:GetStake()) then self:GetStake():Remove() end
    ply:GiveAmmo(1, "mcv_mine", true)
    self:EmitSound("MCV_Weapon_C4_Demolition.Defuse")
    self:Remove()
end

if CLIENT then
    local wire = Material("cable/cable2")

    function ENT:Draw()
        self:DrawModel()
        local a, b = self:WireEnds()
        if a then
            render.SetMaterial(wire)
            render.DrawBeam(a, b, 1, 0, (a - b):Length() / 16, color_white)
        end
    end
end
