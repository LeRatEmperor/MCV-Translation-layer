// Keep the dependency explicit for live Lua refresh as well as normal startup.
if !MCV.MeleeBloodColor or !MCV.MeleeBloodImpact then include("mcv/shared/sh_melee_effects.lua") end

local STATE_IDLE = 0
local STATE_CHARGE = 1
local STATE_THROW_HOLD = 2
local STATE_REPAIR = 3
local STATE_RUNNING = 4 // only marks that the run transition was played

SWEP.DeferredActions = {"SlashHit", "StabHit", "ChargeLoop", "ChargeHit", "ThrowLoop", "ThrowBlade", "RepairLoop"}

function SWEP:GetFiremodeName() return "" end
function SWEP:GetHUDAmmo() return nil, nil end

// first sequence of a list the model has
function SWEP:PickSequence(list, index)
    local have = {}
    for _, s in ipairs(list) do
        if self:HasSequence(s) then table.insert(have, s) end
    end
    if #have == 0 then return nil end
    if index then return have[((index - 1) % #have) + 1] end
    return have[1]
end

function SWEP:GetStabDamage()
    return self.DamageGenericAlt or self.DamageGeneric * 1.5
end

// ---------------------------------------------------------------------------------------
// Hitting things
// ---------------------------------------------------------------------------------------

function SWEP:MeleeTrace(range)
    local owner = self:GetOwner()
    local dir = self:GetAimVector()
    local src = owner:GetShootPos()
    local dim = self.MeleeHullSize

    local tr = util.TraceLine({start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT})
    if !tr.Hit then
        tr = util.TraceHull({start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT_HULL,
                             mins = Vector(-dim, -dim, -dim), maxs = Vector(dim, dim, dim)})
    end

    return tr
end

local function isFlesh(ent)
    return IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_ragdoll")
end

function SWEP:MeleeHit(range, damage, thrust)
    local owner = self:GetOwner()
    local tr = self:MeleeTrace(range)

    if !tr.Hit then return false end

    local dir = self:GetAimVector()
    local ent = tr.Entity
    local blood = SERVER and MCV.MeleeBloodColor(ent)

    if IsValid(ent) then
        local dmginfo = DamageInfo()
        dmginfo:SetDamage(damage)
        dmginfo:SetDamageType(thrust and DMG_SLASH or (DMG_SLASH + DMG_CLUB))
        dmginfo:SetDamageForce(dir * damage * 400)
        dmginfo:SetDamagePosition(tr.HitPos)
        dmginfo:SetAttacker(owner)
        dmginfo:SetInflictor(self)
        if SERVER then
            ent:TakeDamageInfo(dmginfo)
            MCV.MeleeBloodImpact(tr, blood)
        end
    end

    // One authoritative surface impact, using the actual melee hull contact.
    // Client replay must not fire cosmetic bullets or receive a second local effect.
    if SERVER and !isFlesh(ent) and !MCV.SurfaceImpact(tr, damage) then
        // Stock fallback only; custom effects already own the particles and decal.
        self:FireBullets({Attacker = owner, Damage = 0, Force = 0, Distance = range + 16, HullSize = 0, Tracer = 0,
                          Dir = (tr.HitPos - owner:GetShootPos()):GetNormalized(), Src = owner:GetShootPos()})
    end

    if isFlesh(ent) then
        self:EmitSound(thrust and self.SoundThrustFlesh or self.SoundHitFlesh)
    else
        self:EmitSound(thrust and self.SoundThrustWorld or self.SoundHitWorld)
    end

    owner:ViewPunch(Angle(thrust and 4 or 2, thrust and -3 or 3, 0))

    return true
end

// ---------------------------------------------------------------------------------------
// Attacks
// ---------------------------------------------------------------------------------------

// Seconds between one attack and the next. A melee weapon's cadence is its rate: the
// animations are as long as they are, and waiting on them made even a quick knife feel slow.
function SWEP:SwingDelay(rate)
    rate = math.max((rate or self.SlashRate or 150) * self:StatMult("firerate"), 1)

    return 60 / rate
end

function SWEP:Slash()
    local owner = self:GetOwner()
    self:SetSlashCount(self:GetSlashCount() + 1)

    // decide hit / miss up front so the right animation plays
    local tr = self:MeleeTrace(self.MeleeRange)
    local seq = tr.Hit and self:PickSequence(self.SequencesSlash, self:GetSlashCount()) or self:PickSequence(self.SequencesMiss, self:GetSlashCount())
    seq = seq or self:PickSequence(self.SequencesSlash, self:GetSlashCount())

    local t = seq and self:PlaySequence(seq, 1, false) or 0.5
    owner:DoAnimationEvent(self.ShootGesture)

    if self.SoundSwing != "" then self:EmitSound(self.SoundSwing) end

    if tr.Hit then
        self:Defer("SlashHit", math.min(self.HitDelay, t))
    end

    self:SetNextPrimaryFire(CurTime() + self:SwingDelay(self.SlashRate))
end

function SWEP:Stab()
    local owner = self:GetOwner()
    local seq = self:PickSequence(self.SequencesStab)
    if !seq then return self:Slash() end

    local t = self:PlaySequence(seq, 1, false) or 0.6
    owner:DoAnimationEvent(self.ShootGesture)

    self:Defer("StabHit", math.min(self.StabHitDelay, t))

    local delay = self:SwingDelay(self.StabRate)
    self:SetNextPrimaryFire(CurTime() + delay)
    self:SetNextSecondaryFire(CurTime() + delay)
end

// Sprint + attack: wind up, run with the blade forward, hit whatever comes in reach.
function SWEP:StartCharge()
    if !self:HasSequence(self.SequenceChargeStart) then return self:Stab() end

    self:SetActionState(STATE_CHARGE)
    self:SetActionStart(CurTime())
    local t = self:PlaySequence(self.SequenceChargeStart, 1, true) or 0.4
    self:Defer("ChargeLoop", t)
end

function SWEP:ChargeAttack()
    local owner = self:GetOwner()
    self:SetActionState(STATE_IDLE)

    local seq = self:PickSequence(self.SequencesChargeAttack)
    local t = seq and self:PlaySequence(seq, 1, false) or 0.6
    owner:DoAnimationEvent(self.ChargeGesture)

    self:Defer("ChargeHit", math.min(0.1, t))

    local delay = self:SwingDelay(self.StabRate)
    self:SetNextPrimaryFire(CurTime() + delay)
    self:SetNextSecondaryFire(CurTime() + delay)
end

function SWEP:EndCharge()
    self:CancelDeferred()
    self:SetActionState(STATE_IDLE)
    self:SetNextIdle(CurTime())
    self:SetNextPrimaryFire(CurTime() + 0.3)
end

// ---------------------------------------------------------------------------------------
// Throwing the blade
// ---------------------------------------------------------------------------------------

function SWEP:CanThrowNow()
    return self.CanThrow and self:HasSequence(self.SequenceThrow)
end

function SWEP:BeginThrow()
    if self:HasSequence(self.SequenceThrowStart) then
        self:SetActionState(STATE_THROW_HOLD)
        self:SetActionStart(CurTime())
        local t = self:PlaySequence(self.SequenceThrowStart, 1, true) or 0.3
        self:Defer("ThrowLoop", t)
    else
        self:ThrowBlade()
    end
end

function SWEP:CancelThrow()
    self:CancelDeferred()
    self:SetActionState(STATE_IDLE)
    if self:HasSequence(self.SequenceThrowCancel) then
        self:PlaySequence(self.SequenceThrowCancel, 1, true)
    else
        self:SetNextIdle(CurTime())
    end
end

function SWEP:ThrowBlade()
    local owner = self:GetOwner()
    self:SetActionState(STATE_IDLE)

    local t = self:PlaySequence(self.SequenceThrow, 1, true) or 0.5
    owner:DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_GRENADE)

    self:Defer("ThrowBlade", math.min(0.15, t))

    self:SetNextPrimaryFire(CurTime() + t)
end

function SWEP:LaunchBlade()
    if CLIENT then return end
    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    local ang = self:GetAimAngle()
    local ent = ents.Create(self.ThrownEntity)
    if !IsValid(ent) then return end

    ent.Model = self.WorldModel
    ent.WeaponClass = self:GetClass()
    ent.Inflictor = self // the kill icon is the weapon's, not the blade in flight
    ent.Damage = self.ThrowDamage or self:GetStabDamage()
    ent.SoundFlesh = self.SoundThrustFlesh
    ent.SoundWorld = self.SoundThrustWorld
    ent.Attacker = owner
    ent:SetPos(owner:GetShootPos() + ang:Forward() * 8)
    ent:SetAngles(ang)
    ent:SetOwner(owner)
    ent:Spawn()
    ent:Activate()

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocityInstantaneous(ang:Forward() * self.ThrowForce + owner:GetVelocity())
        phys:AddAngleVelocity(Vector(0, 1500, 0))
    end

    // the blade is gone until picked up again
    local class = self:GetClass()
    timer.Simple(0, function()
        if !IsValid(owner) then return end
        owner:StripWeapon(class)
        local other = owner:GetWeapons()[1]
        if IsValid(other) then owner:SelectWeapon(other:GetClass()) end
    end)
end

// ---------------------------------------------------------------------------------------
// Repair (wrench)
// ---------------------------------------------------------------------------------------

// Returns current, max for anything the wrench understands, else nil.
// LVS vehicles, their engines and armour plates all expose GetHP / GetMaxHP / SetHP
// (see weapon_lvsrepair in the LVS base); simfphys and plain vehicles are covered too.
function MCV_VehicleHealth(ent)
    if !IsValid(ent) then return nil end
    if ent.GetHP and ent.GetMaxHP and ent.SetHP then
        return ent:GetHP(), ent:GetMaxHP()
    end
    if ent.IsSimfphyscar and ent.GetCurHealth and ent.GetMaxHealth then
        return ent:GetCurHealth(), ent:GetMaxHealth()
    end
    if (ent:IsVehicle() or ent.IsGlideVehicle) and ent:GetMaxHealth() > 0 then
        return ent:Health(), ent:GetMaxHealth()
    end
    return nil
end

function MCV_VehicleRepair(ent, amount)
    local hp, max = MCV_VehicleHealth(ent)
    if !hp then return false end

    local destroyed = ent.GetDestroyed and ent:GetDestroyed()
    if hp >= max and !destroyed then return false end

    local new = math.min(hp + amount, max)
    if ent.SetHP then
        ent:SetHP(new)
        if destroyed and ent.SetDestroyed then ent:SetDestroyed(false) end
        if new >= max and ent.OnRepaired then ent:OnRepaired() end
    elseif ent.IsSimfphyscar and ent.SetCurHealth then
        ent:SetCurHealth(new)
    else
        ent:SetHealth(new)
    end
    return true
end

function SWEP:GetRepairTarget()
    local owner = self:GetOwner()
    local tr = util.TraceLine({start = owner:GetShootPos(), endpos = owner:GetShootPos() + self:GetAimVector() * 96, filter = owner})
    local ent = tr.Entity
    if !MCV_VehicleHealth(ent) and IsValid(ent) and IsValid(ent:GetParent()) and MCV_VehicleHealth(ent:GetParent()) then
        ent = ent:GetParent()
    end
    if !MCV_VehicleHealth(ent) then return nil end
    return ent
end

function SWEP:StartRepair()
    self:SetActionState(STATE_REPAIR)
    self:SetActionStart(CurTime())
    local t = self:HasSequence(self.SequenceRepairStart) and self:PlaySequence(self.SequenceRepairStart, 1, true) or 0.3
    self:SetNextRepairTime(CurTime() + t)
    self:Defer("RepairLoop", t)
end

function SWEP:EndRepair()
    self:CancelDeferred()
    self:SetActionState(STATE_IDLE)
    if self:HasSequence(self.SequenceRepairEnd) then
        self:PlaySequence(self.SequenceRepairEnd, 1, true)
    else
        self:SetNextIdle(CurTime())
    end
end

function SWEP:RepairTick()
    if CurTime() < self:GetNextRepairTime() then return end
    self:SetNextRepairTime(CurTime() + 0.25)

    local ent = self:GetRepairTarget()
    if !ent then self:EndRepair() return end

    if SERVER then
        if !MCV_VehicleRepair(ent, self.RepairPerSecond * 0.25) then
            self:EndRepair()
            return
        end
        local fx = EffectData()
        fx:SetOrigin(self:GetOwner():GetEyeTrace().HitPos)
        fx:SetMagnitude(1)
        fx:SetScale(1)
        fx:SetRadius(2)
        util.Effect("Sparks", fx)
    end
    self:EmitSound("physics/metal/metal_box_impact_soft" .. math.random(1, 3) .. ".wav", 65)
end

// ---------------------------------------------------------------------------------------
// Input
// ---------------------------------------------------------------------------------------

function SWEP:IdleSequence()
    if self:GetActionState() == STATE_CHARGE then return self.SequenceChargeLoop end
    if self:GetActionState() == STATE_THROW_HOLD then return self.SequenceThrowLoop end
    if self:GetActionState() == STATE_REPAIR then return self.SequenceRepairLoop end

    if self:GetSpeed() >= self.SpeedSprintThreshold and self:HasSequence(self.SequenceRun) then
        return self.SequenceRun
    end

    return nil
end

function SWEP:ThinkWeapon()
    local owner = self:GetOwner()
    local state = self:GetActionState()

    // run transitions
    local running = self:GetSpeed() >= self.SpeedSprintThreshold
    if running != self:GetWasRunning() then
        self:SetWasRunning(running)
        if state == STATE_IDLE and !self:StillWaiting() then
            local seq = running and self.SequenceIdleToRun or self.SequenceRunToIdle
            if self:HasSequence(seq) then
                self:PlaySequence(seq, 1, false)
            end
        end
    end

    if state == STATE_CHARGE then
        if !owner:KeyDown(IN_ATTACK) or !self:GetIsSprinting() then
            self:EndCharge()
        elseif CurTime() > self:GetActionStart() + 0.3 then
            local tr = self:MeleeTrace(self.MeleeRangeAlt)
            if tr.Hit and IsValid(tr.Entity) then
                self:ChargeAttack()
            elseif CurTime() > self:GetActionStart() + 4 then
                self:EndCharge()
            end
        end
    elseif state == STATE_THROW_HOLD then
        if !owner:KeyDown(IN_ATTACK) then
            if owner:KeyDown(IN_USE) then
                self:ThrowBlade()
            else
                self:CancelThrow()
            end
        end
    elseif state == STATE_REPAIR then
        if !owner:KeyDown(IN_ATTACK2) then
            self:EndRepair()
        else
            self:RepairTick()
        end
    end
end

function SWEP:PrimaryAttack()
    if self:StillWaiting() then return end
    if self:GetActionState() != STATE_IDLE then return end

    local owner = self:GetOwner()

    if owner:KeyDown(IN_USE) then
        if self:CanThrowNow() then
            self:BeginThrow()
        end
        return
    end

    if self:GetIsSprinting() then
        self:StartCharge()
        return
    end

    self:Slash()
end

function SWEP:SecondaryAttack()
    if self:StillWaiting() then return end
    if self:GetActionState() != STATE_IDLE then return end

    local owner = self:GetOwner()
    if !owner:KeyPressed(IN_ATTACK2) then return end

    if self.CanRepair and self:GetRepairTarget() then
        self:StartRepair()
        return
    end

    self:Stab()
end

function SWEP:Reload()
end

function SWEP:OnDeploy()
    self:SetActionState(STATE_IDLE)
    self:SetWasRunning(false)
end

function SWEP:Deferred_SlashHit()
    self:MeleeHit(self.MeleeRange, self.DamageGeneric, false)
end

function SWEP:Deferred_StabHit()
    self:MeleeHit(self.MeleeRangeAlt, self:GetStabDamage(), true)
end

function SWEP:Deferred_ChargeHit()
    self:MeleeHit(self.MeleeRangeAlt, self:GetStabDamage() * self.ChargeDamageMultiplier, true)
end

function SWEP:Deferred_ChargeLoop()
    if self:GetActionState() == STATE_CHARGE and self:HasSequence(self.SequenceChargeLoop) then
        self:PlaySequence(self.SequenceChargeLoop, 1, false, true)
    end
end

function SWEP:Deferred_ThrowLoop()
    if self:GetActionState() == STATE_THROW_HOLD and self:HasSequence(self.SequenceThrowLoop) then
        self:PlaySequence(self.SequenceThrowLoop, 1, false, true)
    end
end

function SWEP:Deferred_ThrowBlade()
    self:LaunchBlade()
end

function SWEP:Deferred_RepairLoop()
    if self:GetActionState() == STATE_REPAIR and self:HasSequence(self.SequenceRepairLoop) then
        self:PlaySequence(self.SequenceRepairLoop, 1, false, false)
    end
end

function SWEP:GetControlHints()
    local h = {
        {"+attack", "Slash"},
        {"+attack2", "Stab"},
        {"+speed +attack", "Charge"},
    }
    if self.CanThrow then
        table.insert(h, {"+use +attack", "Throw"})
    end
    if self.CanRepair then
        table.insert(h, {"+attack2", "Repair vehicle (aim at it)"})
    end
    return h
end
