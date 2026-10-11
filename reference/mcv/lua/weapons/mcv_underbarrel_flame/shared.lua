AddCSLuaFile()
SWEP.Base = "mcv_base"
SWEP.Spawnable = false
SWEP.NPCUsable = false
SWEP.FlameParticle = "lpo50_flame"
SWEP.FlameAttachment = "muzzle2"
SWEP.FlameRange = 240
SWEP.FlameDamage = 8
SWEP.FlameDuration = 0.8
SWEP.FlameInterval = 0.1
SWEP.DeferredActions = {"FlamePulse"}

function SWEP:IsFlaming()
    return self:GetActionEnd() > CurTime() and self:GetGrenadeLauncher()
end

function SWEP:GetPrecacheParticles()
    local particles = baseclass.Get("mcv_base").GetPrecacheParticles(self)
    table.insert(particles, self.FlameParticle)
    return particles
end

function SWEP:RifleGrenadeAttack()
    if self:GetSpeed() > 150 or self:GetNeedTriggerPress() then return end
    if self:Clip2() < 1 then self:Reload() return end
    self:TakeSecondaryAmmo(1)
    self:SetNeedTriggerPress(true)
    self:SetActionEnd(CurTime() + self.FlameDuration)
    self:SetNextPrimaryFire(self:GetActionEnd() + 0.2)
    self:PlayAnimation(ACT_VM_ISHOOT_M203, 1, false, true)
    self:SetAnimLockTime(self:GetActionEnd())
    self:EmitSound("MCV_Weapon_LPO50.Primary_Fire_Start")
    self:Deferred_FlamePulse()
end

function SWEP:Deferred_FlamePulse()
    if !self:IsFlaming() then self:SetNextIdle(CurTime()) return end
    local owner = self:GetOwner()
    if !IsValid(owner) or owner:GetActiveWeapon() != self then return end
    if SERVER then
        owner:LagCompensation(true)
        local src = owner:GetShootPos()
        local tr = util.TraceHull({start = src, endpos = src + self:GetAimVector() * self.FlameRange,
            filter = owner, mask = MASK_SHOT_HULL, mins = Vector(-12, -12, -12), maxs = Vector(12, 12, 12)})
        owner:LagCompensation(false)
        if IsValid(tr.Entity) then
            local dmg = DamageInfo()
            dmg:SetDamage(self.FlameDamage * self:StatMult("damage"))
            dmg:SetDamageType(DMG_BURN)
            dmg:SetAttacker(owner)
            dmg:SetInflictor(self)
            dmg:SetDamagePosition(tr.HitPos)
            tr.Entity:TakeDamageInfo(dmg)
            MCV.Burn(tr.Entity, 3, owner, self, 5)
        end
    end
    self:Defer("FlamePulse", self.FlameInterval)
end

function SWEP:Deploy()
    self:SetActionEnd(0)
    return baseclass.Get("mcv_base").Deploy(self)
end

function SWEP:GetControlHints()
    return {{"+attack", self:GetGrenadeLauncher() and "Flame burst" or "Fire"},
        {"+attack2", "Aim"}, {"+reload", "Reload"}, {"+use +walk", "Rifle / flamer"}}
end

function SWEP:GetFiremodeName()
    if self:GetGrenadeLauncher() then return "Flame cartridge" end
    return baseclass.Get("mcv_base").GetFiremodeName(self)
end

function SWEP:Holster(wep)
    if self:IsFlaming() then return false end
    return baseclass.Get("mcv_base").Holster(self, wep)
end

function SWEP:OnRemove()
    if CLIENT then self:StopFlameEffect() self:RemoveWorldModels() end
end

if CLIENT then
    // Reuse the established viewmodel/worldmodel/PVS particle lifecycle.
    for _, name in ipairs({"FlameEmitter", "StartFlameEffect", "StopFlameEffect",
        "UpdateFlameControlPoints", "Think_ClientFlame", "PreDrawViewModelWeapon", "DrawWorldModel"}) do
        local method = name
        SWEP[method] = function(self, ...)
            return baseclass.Get("mcv_flamethrower")[method](self, ...)
        end
    end
end
