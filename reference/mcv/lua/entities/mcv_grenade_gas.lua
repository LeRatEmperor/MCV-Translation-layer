AddCSLuaFile()

ENT.Base                     = "mcv_grenade_smoke"
ENT.PrintName                = "Gas Grenade"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_m18.mdl"
ENT.ModelSkin                = 7

ENT.SmokeParticle = "vietnam_gasgrenade_attached"
ENT.SmokeParticleColored = "vietnam_gasgrenade_attached"
ENT.SmokeSound = "MCV_Weapon_M6A1.Sound"
ENT.SmokeLoop = "MCV_Weapon_M6A1.SoundLoop"
ENT.Hurts = true

// damage per second to anyone in the cloud without a gas mask (game: ExplosionDamage)
ENT.ExplosionDamage = 125
ENT.ExplosionRadius = 500
ENT.TickRate = 0.5

function ENT:OnPop()
    self.NextHurt = CurTime() + 1.5 // the cloud needs a moment to spread
end

// Gas masks (later) set ply.MCV_GasMask = true; the check lives here so it is one place.
function MCV_HasGasProtection(ent)
    return ent.MCV_GasMask == true
end

function ENT:HurtTick()
    if CurTime() < (self.NextHurt or 0) then return end
    self.NextHurt = CurTime() + self.TickRate

    local attacker = self:GetAttacker()
    local inflictor = self:GetInflictor()
    // the cloud grows over the first seconds and thins out at the end
    local age = CurTime() - self.PopTime
    local radius = self.ExplosionRadius * 0.5 * math.Clamp(age / 4, 0.3, 1)
    local left = (self.StopTime - CurTime()) / self.EffectDuration
    local scale = math.Clamp(left * 3, 0.2, 1)

    for _, ent in ipairs(ents.FindInSphere(self:GetPos(), radius)) do
        if !(ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then continue end
        if ent:IsPlayer() and !ent:Alive() then continue end
        if MCV_HasGasProtection(ent) then continue end
        if math.abs(ent:GetPos().z - self:GetPos().z) > 128 then continue end

        local dmg = DamageInfo()
        dmg:SetDamage(self.ExplosionDamage * self.TickRate * scale * 0.5)
        dmg:SetDamageType(DMG_NERVEGAS)
        dmg:SetAttacker(attacker)
        dmg:SetInflictor(inflictor)
        dmg:SetDamagePosition(ent:GetPos())
        ent:TakeDamageInfo(dmg)

        if ent:IsPlayer() then
            ent:ScreenFade(SCREENFADE.IN, Color(0, 0, 0, 40), 0.4, 0.2)
        end
    end
end
