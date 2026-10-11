AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Rifle Grenade"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/shells/shell_rg_us.mdl"

ENT.IsRocket = false // projectile has a booster and will not drop.

ENT.InstantFuse = false // projectile is armed immediately after firing.
ENT.RemoteFuse = false // allow this projectile to be triggered by remote detonator.
ENT.ImpactFuse = true // projectile explodes on impact.

ENT.ExplodeOnDamage = false // projectile explodes when it takes damage.
ENT.ExplodeUnderwater = true

ENT.TrailParticle = "vietnam_weaponeffect_riflegrenade"

ENT.Delay = 0

// what it does unless the weapon that launched it says otherwise
ENT.ExplosionDamage = 100
ENT.ExplosionRadius = 250

function ENT:Detonate()
    local attacker = self.Attacker or self:GetOwner() or self
    local mult = 1
    local dmg = self.ExplosionDamage

    util.BlastDamage(self:GetInflictor(), attacker, self:GetPos(), self.ExplosionRadius, dmg * mult)
    self:FireBullets({
        Attacker = attacker,
        Damage = dmg * mult,
        Tracer = 0,
        Src = self:GetPos(),
        Dir = self:GetForward(),
        HullSize = 0,
        Distance = 32,
        IgnoreEntity = self,
        Callback = function(atk, btr, dmginfo)
            dmginfo:SetDamageType(DMG_AIRBOAT + DMG_BLAST) // airboat damage for helicopters and LVS vehicles
            dmginfo:SetDamageForce(self:GetForward() * 7500) // LVS uses this to calculate penetration!
        end,
    })

    // Game explosion effect, picked per surface (see lua/mcv/shared/sh_explosions.lua)
    MCV.ExplosionEffect("ubgl", self:GetImpactPos(), self:GetImpactNormal(), self:WaterLevel() > 0)

    self:EmitSound("MCV_BaseGrenade.Explode")

    self:Remove()
end