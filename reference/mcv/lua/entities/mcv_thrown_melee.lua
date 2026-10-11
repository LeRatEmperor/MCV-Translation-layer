AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Thrown Blade"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_m1942_machete.mdl"

ENT.InstantFuse = false
ENT.TimeFuse = false
ENT.Delay = 0
ENT.Sticky = true
ENT.StickyPlace = false
ENT.ImpactDamage = 0

ENT.Damage = 60
ENT.WeaponClass = "mcv_m1942_machete"
ENT.SoundFlesh = "MCV_Weapon_M1942.ThrustStab"
ENT.SoundWorld = "MCV_Weapon_M1942.ThrustHit"

function ENT:OnInitialize()
    if SERVER then
        self:SetUseType(SIMPLE_USE)
    end
end

function ENT:Impact(data, collider)
    if self.HitDone then return end
    self.HitDone = true

    local ent = data.HitEntity
    if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:Health() > 0) then
        local dmg = DamageInfo()
        dmg:SetDamage(self.Damage)
        dmg:SetDamageType(DMG_SLASH)
        dmg:SetAttacker(IsValid(self.Attacker) and self.Attacker or self)
        dmg:SetInflictor(self:GetInflictor())
        dmg:SetDamageForce(data.OurOldVelocity)
        dmg:SetDamagePosition(data.HitPos)
        ent:TakeDamageInfo(dmg)
        self:EmitSound(self.SoundFlesh)
    else
        self:EmitSound(self.SoundWorld)
    end
end

// The blade sticks where it lands; pressing USE takes it back.
function ENT:Stuck()
    self:SetUseType(SIMPLE_USE)
end

function ENT:Use(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    if ply:HasWeapon(self.WeaponClass) then return end

    ply:Give(self.WeaponClass)

    // back in the hand rather than just in the inventory: fetching a thrown blade is a
    // deliberate walk over to it, so it is what you meant to be holding
    ply:SelectWeapon(self.WeaponClass)
    self:Remove()
end

function ENT:Think()
    // no fuse logic; keep the projectile base's smoke / think hooks quiet
    if SERVER and !self.Stuck2 and self:GetMoveType() == MOVETYPE_NONE then
        self.Stuck2 = true
    end
    self:NextThink(CurTime() + 0.5)
    return true
end
