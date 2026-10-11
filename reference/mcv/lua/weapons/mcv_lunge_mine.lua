AddCSLuaFile()
SWEP.Base = "mcv_melee"
SWEP.Spawnable = true
SWEP.NPCUsable = false
SWEP.PrintName = "Lunge Mine"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Anti-Armor"
SWEP.Country = "Japan"
SWEP.Slot = 4
SWEP.ViewModel = "models/weapons/mcv/v_lunge_mine.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_lunge_mine.mdl"
SWEP.HoldType = "melee2"
SWEP.AimHoldType = "melee2"
SWEP.ShootGesture = ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE2
SWEP.MeleeRange = 90
SWEP.MeleeRangeAlt = 100
SWEP.SlashRate = 60
SWEP.StabRate = 60
SWEP.HitDelay = 0.2
SWEP.StabHitDelay = 0.25
SWEP.ExplosionDamage = 250
SWEP.ExplosionRadius = 160
SWEP.ThrowForce = 650
SWEP.ThrownEntity = "mcv_proj_lunge_mine"
SWEP.CanThrow = false // Throw animations are unfinished; contact attacks only.
SWEP.BodyGroups = ""
SWEP.SafeMovementAnimations = false

function SWEP:GetControlHints()
    return {{"+attack", "Strike / detonate"}, {"+attack2", "Thrust / detonate"}}
end

function SWEP:PrimaryAttack()
    if self:GetActionState() == 5 then return end
    return baseclass.Get("mcv_melee").PrimaryAttack(self)
end
function SWEP:SecondaryAttack()
    if self:GetActionState() == 5 then return end
    return baseclass.Get("mcv_melee").SecondaryAttack(self)
end

function SWEP:CreateMine(pos, ang)
    local owner = self:GetOwner()
    local mine = ents.Create(self.ThrownEntity)
    if !IsValid(mine) then return end
    mine.Attacker = owner
    mine.ExplosionDamage = self.ExplosionDamage * self:StatMult("explosion_damage")
    mine.ExplosionRadius = self.ExplosionRadius * self:StatMult("explosion_radius")
    mine:SetPos(pos)
    mine:SetAngles(ang)
    mine:SetOwner(owner)
    mine:SetWeapon(self)
    mine:Spawn()
    mine:Activate()
    return mine
end

function SWEP:MeleeHit(range)
    if self:GetActionState() == 5 then return false end
    local owner = self:GetOwner()
    if SERVER then owner:LagCompensation(true) end
    local tr = self:MeleeTrace(range)
    if SERVER then owner:LagCompensation(false) end
    if !tr.Hit or tr.HitSky then return false end
    self:SetActionState(5)
    self:CancelDeferred()
    if SERVER then
        local mine = self:CreateMine(tr.HitPos + tr.HitNormal * 4, self:GetAimAngle())
        if IsValid(mine) then mine:Detonate() end
        self:Remove()
    end
    return true
end

function SWEP:LaunchBlade()
    self:SetActionState(5)
    if CLIENT then return end
    local owner = self:GetOwner()
    local ang = self:GetAimAngle()
    local mine = self:CreateMine(owner:GetShootPos() + ang:Forward() * 12, ang)
    if !IsValid(mine) then self:SetActionState(0) return end
    local phys = mine:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocityInstantaneous(ang:Forward() * self.ThrowForce * self:StatMult("projectile_speed") + owner:GetVelocity())
        phys:AddAngleVelocity(Vector(0, 180, 0))
    end
    self:Remove()
end
