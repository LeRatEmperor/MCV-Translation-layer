AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Rocket (M202)"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/shells/rpg7_rocket.mdl"

ENT.IsRocket = false // projectile has a booster and will not drop.
ENT.CollisionSphere = 2

ENT.InstantFuse = false // projectile is armed immediately after firing.
ENT.RemoteFuse = false // allow this projectile to be triggered by remote detonator.
ENT.ImpactFuse = true // projectile explodes on impact.

ENT.ExplodeOnDamage = false // projectile explodes when it takes damage.
ENT.ExplodeUnderwater = true

ENT.SmokeTrail = false
ENT.TrailParticle = "rpg_missile_trail"

ENT.Delay = 0

ENT.Detonated = false

ENT.DieTime = 0
ENT.BurnTime = 3

// what it does unless the weapon that launched it says otherwise
ENT.ExplosionDamage = 100
ENT.ExplosionRadius = 70

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
            dmginfo:SetDamageForce(self:GetForward() * 500) // LVS uses this to calculate penetration!
        end,
    })

    // Game explosion effect, picked per surface (see lua/mcv/shared/sh_explosions.lua)
    MCV.ExplosionEffect("xm202", self:GetImpactPos(), self:GetImpactNormal(), self:WaterLevel() > 0)

    self:EmitSound("MCV_XM202MissileExplosionEffect.Sound")

    self:SetRenderMode(RENDERMODE_NONE)
    self:StopParticles()
    self:DrawShadow(false)

    SafeRemoveEntityDelayed(self, self.BurnTime)
    self:SetMoveType(MOVETYPE_NONE)
    self.DieTime = CurTime()
end

function ENT:OnThink()
    if self.Detonated then
        local d = (CurTime() - self.DieTime) / self.BurnTime
        d = 1 - d

        local dmginfo = DamageInfo()
        dmginfo:SetDamageType(DMG_BURN)
        dmginfo:SetAttacker(self:GetOwner())
        dmginfo:SetInflictor(self:GetInflictor())
        dmginfo:SetDamage(engine.TickInterval() * 500)
        dmginfo:SetDamagePosition(self:GetPos())
        dmginfo:SetDamageForce(Vector(0, 0, 0))
        dmginfo:SetReportedPosition(self:GetPos())

        util.BlastDamageInfo(dmginfo, self:GetPos(), d * 512)
    end
end
