AddCSLuaFile()

ENT.Base                     = "mcv_grenade_base"
ENT.RoundCollision           = false
ENT.PrintName                = "C4 Charge"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_c4.mdl"

ENT.TimeFuse = false
ENT.Delay = 0
ENT.RemoteFuse = true
ENT.ImpactFuse = false
ENT.ExplodeOnDamage = true
ENT.Defusable = true
ENT.BounceSounds = nil
ENT.ExplosionFamily = "artillery"
ENT.ExplosionDamage = 500
ENT.ExplosionRadius = 500
ENT.BlinkParticle = "vietnam_weaponeffect_c4_blinklight"

// Stick to the surface / entity it was planted on
function ENT:PlantOn(parent)
    if CLIENT then return end
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    if IsValid(parent) then
        self:SetParent(parent)
    end
    self:ReleaseOwner() // shootable by the planter too
    self:EmitSound("MCV_Weapon_C4_Demolition.Plant")
    if self.BlinkParticle then
        ParticleEffectAttach(self.BlinkParticle, PATTACH_ABSORIGIN_FOLLOW, self, 0)
    end
end

function ENT:Light()
end

function ENT:RemoteDetonate()
    self.ArmTime = CurTime() - 1
    self.Delay = 0
    self.Armed = true
    self:PreDetonate()
end

function ENT:Use(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    if ply != self:GetPlanter() then return end
    // the planter can pick a planted charge back up
    ply:GiveAmmo(1, "mcv_explosive_charge", true)
    self:EmitSound("MCV_Weapon_C4_Demolition.Defuse")
    self:Remove()
end

function ENT:Think()
    // no timer: waits for the remote
    if self.ExplodeUnderwater and self:WaterLevel() > 0 then self:PreDetonate() end
    self:OnThink()
    self:NextThink(CurTime() + 0.1)
    return true
end
