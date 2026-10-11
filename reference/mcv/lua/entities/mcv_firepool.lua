AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Burning Ground"
ENT.Spawnable = false

ENT.Radius = 200
ENT.DamagePerSecond = 20
ENT.Duration = 12
ENT.Particle = "Molotov_GroundFire"
ENT.TickRate = 0.25
ENT.BurnAfter = 3 // seconds a victim keeps burning after leaving the pool
ENT.BurnAfterDPS = 8

function ENT:Initialize()
    if SERVER then
        self:SetModel("models/hunter/plates/plate.mdl")
        self:SetNoDraw(true)
        self:SetMoveType(MOVETYPE_NONE)
        self:SetSolid(SOLID_NONE)
        self:DrawShadow(false)

        self.DieTime = CurTime() + self.Duration
        self.NextTick = 0

        if self.Particle then
            ParticleEffect(self.Particle, self:GetPos(), self:GetAngles(), self)
        end

        self:EmitSound("ambient/fire/fire_med_loop1.wav", 80, 100, 0.6, CHAN_STATIC)
        self:NextThink(CurTime())
    end
end

function ENT:Think()
    if CLIENT then return end

    if CurTime() > self.DieTime then
        self:StopParticles()
        self:StopSound("ambient/fire/fire_med_loop1.wav")
        self:Remove()
        return
    end

    if CurTime() >= self.NextTick then
        self.NextTick = CurTime() + self.TickRate
        local attacker = IsValid(self.Attacker) and self.Attacker or game.GetWorld()
        local inflictor = IsValid(self.Inflictor) and self.Inflictor or self
        // fade the damage over the last quarter of the life
        local life = (self.DieTime - CurTime()) / self.Duration
        local scale = math.Clamp(life * 4, 0, 1)

        for _, ent in ipairs(ents.FindInSphere(self:GetPos(), self.Radius)) do
            if ent == self then continue end
            if !(ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_physics" or ent.LVS or ent.IsSimfphyscar) then continue end
            if ent:IsPlayer() and !ent:Alive() then continue end
            // has to be roughly on the same floor
            if math.abs(ent:GetPos().z - self:GetPos().z) > 96 then continue end

            local dmg = DamageInfo()
            dmg:SetDamage(self.DamagePerSecond * self.TickRate * scale)
            dmg:SetDamageType(DMG_BURN)
            dmg:SetAttacker(attacker)
            dmg:SetInflictor(inflictor)
            dmg:SetDamagePosition(ent:GetPos())
            ent:TakeDamageInfo(dmg)

            // a few seconds of burning after leaving the fire (sh_burn.lua, no Ignite)
            if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
                MCV.Burn(ent, self.BurnAfter, attacker, inflictor, self.BurnAfterDPS)
            end
        end
    end

    self:NextThink(CurTime() + 0.05)
    return true
end

function ENT:OnRemove()
    if SERVER then
        self:StopSound("ambient/fire/fire_med_loop1.wav")
    end
end
