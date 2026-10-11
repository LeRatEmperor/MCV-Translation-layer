AddCSLuaFile()

ENT.Base                     = "mcv_proj_rpg"
ENT.PrintName                = "Rocket (Kolos)"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/shells/kolos_rocket.mdl"

ENT.TrailParticle = "kolos_missile_trail"

// Game script: ExplosionDamage 125, ExplosionRadius 200 per rocket (seven leave at once)
// what it does unless the weapon that launched it says otherwise
ENT.ExplosionDamage = 60
ENT.ExplosionRadius = 200

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
            dmginfo:SetDamageForce(self:GetForward() * 3000)
        end,
    })

    MCV.ExplosionEffect("kolos", self:GetImpactPos(), self:GetImpactNormal(), self:WaterLevel() > 0)

    self:EmitSound("MCV_BaseGrenade.Explode")

    self:Remove()
end
