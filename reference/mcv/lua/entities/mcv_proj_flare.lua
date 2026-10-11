AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Flare"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/shells/flare.mdl"

ENT.InstantFuse = false
ENT.TimeFuse = false
ENT.Delay = 0
ENT.Sticky = false
ENT.ImpactDamage = 0
ENT.ImpactFuse = false

ENT.Damage = 50 // on a direct hit, plus fire
ENT.BurnTime = 25
// the game's env_flare effects (trail in flight, burning on the ground); vietnam_lensflare_flaregun
// is only the lens glow and showed as nothing but the dynamic light
ENT.TrailParticle = "env_flare_us_trail"
ENT.GroundParticle = "env_flare_us_ground"
ENT.LightColor = Color(40, 255, 40)
ENT.BounceSounds = {"MCV_Bounce.Shell"}

function ENT:OnInitialize()
    if SERVER then
        self.DieTime = CurTime() + self.BurnTime
        self:EmitSound("ambient/fire/ignite.wav", 70)
        // the flare burns from the moment it leaves the gun, not only once it has landed
        ParticleEffectAttach(self.GroundParticle, PATTACH_ABSORIGIN_FOLLOW, self, 0)
    end
end

function ENT:Impact(data, collider)
    local ent = data.HitEntity
    if !self.HitDone and IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then
        self.HitDone = true
        local dmg = DamageInfo()
        dmg:SetDamage(self.Damage)
        dmg:SetDamageType(DMG_BURN)
        dmg:SetAttacker(IsValid(self:GetOwner()) and self:GetOwner() or self)
        dmg:SetInflictor(self:GetInflictor())
        dmg:SetDamagePosition(data.HitPos)
        ent:TakeDamageInfo(dmg)
        MCV.Burn(ent, 6, dmg:GetAttacker(), self, 10)
    end
    if !self.Landed and data.HitEntity:IsWorld() then
        self.Landed = true
        // the burning effect is already on it; the flight trail keeps going a moment and dies
        // with the client's trail check (mcv_proj_base)
    end
end

function ENT:OnThink()
    if CLIENT then
        local dl = DynamicLight(self:EntIndex())
        if dl then
            dl.pos = self:GetPos()
            dl.r, dl.g, dl.b = self.LightColor.r, self.LightColor.g, self.LightColor.b
            dl.brightness = 3
            dl.decay = 2048
            dl.size = 2048
            dl.dietime = CurTime() + 1
        end
        return
    end

    if CurTime() > self.DieTime then
        self:Remove()
        return
    end

    // sets fire to whatever it lies on
    if self.Landed and (self.NextIgnite or 0) < CurTime() then
        self.NextIgnite = CurTime() + 0.5
        for _, ent in ipairs(ents.FindInSphere(self:GetPos(), 48)) do
            if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
                MCV.Burn(ent, 4, IsValid(self:GetOwner()) and self:GetOwner() or self, self, 10)
            end
        end
    end
end

function ENT:Draw()
    self:DrawModel()
end
