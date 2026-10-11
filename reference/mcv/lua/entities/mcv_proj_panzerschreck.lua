AddCSLuaFile()

ENT.Base                     = "mcv_proj_rpg"
ENT.PrintName                = "Rocket (Panzerschreck)"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/shells/panzerschreck_rocket.mdl"

ENT.TrailParticle = "rpg_missile_trail"

// Game script: ExplosionDamage 175, ExplosionRadius 250
// what it does unless the weapon that launched it says otherwise
ENT.ExplosionDamage = 175
ENT.ExplosionRadius = 250

function ENT:Detonate()
    local attacker = self.Attacker or self:GetOwner() or self
    local dmg = self.ExplosionDamage

    util.BlastDamage(self:GetInflictor(), attacker, self:GetPos(), self.ExplosionRadius, dmg)
    self:FireBullets({
        Attacker = attacker,
        Damage = dmg,
        Tracer = 0,
        Src = self:GetPos(),
        Dir = self:GetForward(),
        HullSize = 0,
        Distance = 32,
        IgnoreEntity = self,
        Callback = function(atk, btr, dmginfo)
            dmginfo:SetDamageType(DMG_AIRBOAT + DMG_BLAST)
            dmginfo:SetDamageForce(self:GetForward() * 4000)
        end,
    })

    MCV.ExplosionEffect("rpg", self:GetImpactPos(), self:GetImpactNormal(), self:WaterLevel() > 0)

    self:EmitSound("MCV_BaseGrenade.Explode")

    self:Remove()
end
