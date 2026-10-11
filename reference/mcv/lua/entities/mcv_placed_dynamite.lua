AddCSLuaFile()

ENT.Base                     = "mcv_grenade_base"
ENT.RoundCollision           = false
ENT.PrintName                = "Dynamite"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_dynamite.mdl"

ENT.TimeFuse = false // lit explicitly
ENT.Delay = 6
ENT.ImpactFuse = false
ENT.ExplodeOnDamage = true
ENT.BounceSounds = {"MCV_HEGrenade.Bounce"}
ENT.ExplosionFamily = "artillery" // the mortar shell family: heavier than the hand grenade, every surface variant
ENT.ExplosionDamage = 500
ENT.ExplosionRadius = 550
ENT.FuseParticle = "vietnam_weaponeffect_dynamite_fuse"
ENT.FuseSound = "MCV_Weapon_C4.FuseBurningLoop"

function ENT:PlantOn(parent)
    if CLIENT then return end
    self:SetMoveType(MOVETYPE_NONE)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end
    if IsValid(parent) then self:SetParent(parent) end
    self:ReleaseOwner() // shootable by the planter too
    self:EmitSound("MCV_Weapon_Dynamite_Demolition.Plant")
    self:Light()
end

function ENT:Light()
    if self.Lit then return end
    self.Lit = true
    self.ArmTime = CurTime()
    self.Armed = true
    if SERVER then
        if self.FuseParticle then
            // on the model's "fuse" attachment (the end of the fuse), not the stick's origin
            local att = self:LookupAttachment("fuse")
            if att > 0 then
                ParticleEffectAttach(self.FuseParticle, PATTACH_POINT_FOLLOW, self, att)
            else
                ParticleEffectAttach(self.FuseParticle, PATTACH_ABSORIGIN_FOLLOW, self, 0)
            end
        end
        // the game ships one burning-fuse loop (under the C4 name); the dynamite has no other
        self:EmitSound(self.FuseSound)
    end
end

function ENT:OnRemove()
    if SERVER then self:StopSound(self.FuseSound) end
    baseclass.Get("mcv_proj_base").OnRemove(self)
end
