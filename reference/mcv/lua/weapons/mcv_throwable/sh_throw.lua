local STATE_IDLE = 0
local STATE_WINDUP_HIGH = 1
local STATE_WINDUP_LOW = 2
local STATE_THROWING = 3

SWEP.DeferredActions = {"ThrowRelease", "ThrowEnd"}

function SWEP:Initialize()
    MCV.WeaponCommon.Initialize(self)
    if self.ModelSkin != nil then self:SetSkin(self.ModelSkin) end
end

function SWEP:DoBodygroupsWeapon(vm)
    if self.ModelSkin != nil and vm:GetSkin() != self:GetSkin() then
        vm:SetSkin(self:GetSkin())
    end
end

// Derive this from predicted/networked action state, including for remote players.
// Sprinting must not hide a pulled grenade. Both releases use the grenade throw gesture.
function SWEP:Think_HoldType()
    local state = self:GetActionState()
    local hold = "slam"
    if state == STATE_WINDUP_LOW then
        hold = "melee2"
    elseif state == STATE_WINDUP_HIGH or state == STATE_THROWING then
        hold = "grenade"
    end
    if self:GetHoldType() != hold then self:SetHoldType(hold) end
end

// GMod inherits nested tables index by index, so a weapon's shorter FuseModes still sees
// the base's later entries (the molotov's {0} read as {0, 5}); an impact-fused throwable
// has exactly one mode, with no fuse at all
function SWEP:GetFuseModes()
    if self.FuseImpact then return {0} end
    return self.FuseModes
end

function SWEP:GetFuseTime()
    local modes = self:GetFuseModes()
    local fm = math.Clamp(self:GetFiremode(), 1, #modes)

    return modes[fm]
end

function SWEP:GetFiremodeName()
    if self.FuseImpact then return "Impact" end
    if #self:GetFuseModes() <= 1 then return "" end

    return string.format("Fuse %gs", self:GetFuseTime())
end

function SWEP:GetHUDAmmo()
    return self:GetRoundsLeft(), nil
end

// The molotov's rag burns from the pull of the trigger until the bottle leaves the hand
// (the game has no rag flame of its own; the zippo's is the one small flame it ships)
function SWEP:GetLitParticle()
    if !self.FuseImpact then return nil end
    return self.LitParticle or "vietnam_entityeffect_zippo_flame"
end

function SWEP:IsLit()
    local state = self:GetActionState()
    if state == STATE_WINDUP_HIGH or state == STATE_WINDUP_LOW then return true end
    return state == STATE_THROWING and self:DeferPending("ThrowRelease")
end

function SWEP:GetPrecacheParticles()
    local p = self:GetLitParticle()
    return p and {p} or {}
end

function SWEP:CanStartThrow()
    if self:StillWaiting() then return false end
    if self:GetActionState() != STATE_IDLE then return false end
    if self:GetRoundsLeft() <= 0 then return false end

    return true
end

// The fuse runs from the pin pull (start of the windup): hold it and it goes off sooner after
// the throw; hold it past the fuse and it goes off in the hand. Impact-fused ones do not cook.
function SWEP:GetCookTime()
    if self.FuseImpact then return 0 end
    local state = self:GetActionState()
    if state == STATE_IDLE then return 0 end
    return CurTime() - self:GetActionStart()
end

function SWEP:Windup(low)
    self:SetActionState(low and STATE_WINDUP_LOW or STATE_WINDUP_HIGH)
    self:Think_HoldType()
    self:SetActionStart(CurTime())

    local seq = low and self.SequenceWindupLow or self.SequenceWindupHigh
    if !self:HasSequence(seq) then seq = self.SequenceWindupHigh end

    // hold the last frame until the button is released
    local t = self:PlaySequence(seq, 1, false, true) or 0.5
    self:SetWindupEnd(CurTime() + t)
end

// overcooked: the throw is forced and the grenade goes off as it leaves the hand
function SWEP:Throw(low, overcooked)
    local owner = self:GetOwner()
    local roll = low and owner:Crouching() and self:HasSequence(self.SequenceRoll)

    local seq = self.SequenceThrowHigh
    if low then
        seq = roll and self.SequenceRoll or self.SequenceThrowLow
        if !self:HasSequence(seq) then seq = self.SequenceThrowHigh end
    end

    self:SetActionState(STATE_THROWING)
    self:Think_HoldType()

    local t = self:PlaySequence(seq, 1, true) or 0.5
    local release = math.min(low and self.ThrowReleaseTimeUnderhand or self.ThrowReleaseTime, t)
    self:SetActionEnd(CurTime() + t)
    self:SetActionVariant(roll and 2 or (low and 1 or 0))
    local kind = roll and "roll" or (low and "low" or "high")
    local fuse = self:GetFuseTime()
    local cookstart = self:GetActionStart()

    owner:DoAnimationEvent(self.ShootGesture)

    if overcooked then
        self:LaunchThrowable(kind, fuse, cookstart)
        self:Defer("ThrowEnd", t)
    else
        self:Defer("ThrowRelease", release)
    end

    self:SetNextPrimaryFire(CurTime() + t)
end

function SWEP:Deferred_ThrowRelease()
    local variant = self:GetActionVariant()
    self:LaunchThrowable(variant == 2 and "roll" or (variant == 1 and "low" or "high"),
                         self:GetFuseTime(), self:GetActionStart())
    self:Defer("ThrowEnd", math.max(self:GetActionEnd() - CurTime(), 0))
end

function SWEP:Deferred_ThrowEnd()
    self:SetActionState(STATE_IDLE)
    self:Think_HoldType()
    self:AfterThrow()
end

// Spawns the projectile. Runs from a predicted deadline; only the server creates.
// `cookstart` is when the pin came out: the time already spent comes off the fuse.
function SWEP:LaunchThrowable(kind, fuse, cookstart)
    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    self:TakeRound(1)

    if CLIENT then return end

    local remaining = fuse
    if !self.FuseImpact and cookstart then
        remaining = math.max(fuse - (CurTime() - cookstart), 0)
    end

    local ang = self:GetAimAngle()
    local fwd, right, up = ang:Forward(), ang:Right(), ang:Up()

    local pos = owner:GetShootPos() + fwd * 12 + right * 6
    local force = self.ThrowForceOverhand
    local dir = (fwd + up * 0.12):GetNormalized()

    if kind == "low" then
        pos = pos - up * 12
        force = self.ThrowForceUnderhand
        dir = (fwd + up * 0.25):GetNormalized()
    elseif kind == "roll" then
        // Keep the cylinder axle horizontal even when aiming up/down. Local Z
        // points to the player's right, perpendicular to the roll direction.
        ang = Angle(0, ang.y, 90)
        fwd = ang:Forward()
        pos = owner:GetShootPos() + fwd * 12 + ang:Up() * 6 - vector_up * 20
        force = self.ThrowForceRoll
        dir = (fwd - vector_up * 0.15):GetNormalized()
    end

    // do not spawn inside a wall
    local tr = util.TraceLine({start = owner:GetShootPos(), endpos = pos, filter = owner, mask = MASK_SOLID})
    if tr.Hit then pos = tr.HitPos - fwd * 2 end

    local ent = ents.Create(self.ThrowEntity)
    if !IsValid(ent) then return end

    ent.Model = self.ThrowModel or self.WorldModel
    ent.Delay = remaining
    if self.FuseImpact then
        ent.ImpactFuse = true
        ent.ExplodeOnImpact = true
        ent.TimeFuse = false
    end
    ent.ExplosionDamage = self.ExplosionDamage * self:StatMult("explosion_damage")
    ent.ExplosionRadius = self.ExplosionRadius * self:StatMult("explosion_radius")
    ent.IgniteRadius = self.IgniteRadius
    ent.EffectDuration = self.EffectDuration
    ent.SmokeColor = self.SmokeColor
    ent.Attacker = owner
    ent.Inflictor = self

    ent:SetPos(pos)
    ent:SetAngles(ang)
    ent:SetOwner(owner)
    ent:Spawn()
    ent:SetSkin(self:GetSkin())
    ent:Activate()

    // held too long: it goes off in the hand
    if remaining <= 0 and !self.FuseImpact then
        ent.ArmTime = CurTime()
        ent.Armed = true
        ent:PreDetonate()
        return
    end

    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        local velocity = dir * force + owner:GetVelocity()
        phys:SetVelocityInstantaneous(velocity)
        if kind == "roll" and ent.RollRadius then
            // Angular velocity is local degrees/sec. Match the forward surface
            // speed to the launch speed, including the thrower's movement.
            local spin = math.deg(velocity:Dot(fwd) / ent.RollRadius)
            phys:AddAngleVelocity(Vector(0, 0, spin) - phys:GetAngleVelocity())
        else
            phys:AddAngleVelocity(VectorRand() * self.ThrowSpin)
        end
    end
end

function SWEP:AfterThrow()
    if self:GetRoundsLeft() > 0 or !self.RemoveWhenEmpty then
        self:PlayAnimation(ACT_VM_DRAW, 1, true)
        return
    end
    if CLIENT then return end

    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    // out of grenades: put it away and drop the weapon
    local class = self:GetClass()
    timer.Simple(0, function()
        if !IsValid(owner) then return end
        local wep = owner:GetWeapon(class)
        if !IsValid(wep) then return end
        owner:StripWeapon(class)
        local other = owner:GetWeapons()[1]
        owner:SelectWeapon(other and other:GetClass() or "")
    end)
end

function SWEP:ChangeFuseMode()
    if #self:GetFuseModes() <= 1 then return end
    if self:StillWaiting() or self:GetActionState() != STATE_IDLE then return end

    local fm = self:GetFiremode() + 1
    if fm > #self:GetFuseModes() then fm = 1 end
    self:SetFiremode(fm)

    if self:HasSequence(self.SequenceFiremode) then
        self:PlaySequence(self.SequenceFiremode, 1, true)
    else
        self:SetAnimLockTime(CurTime() + 0.25)
    end
end

function SWEP:ThinkWeapon()
    local owner = self:GetOwner()
    local state = self:GetActionState()

    if state == STATE_IDLE then
        if owner:KeyDown(IN_USE) then return end

        if owner:KeyPressed(IN_ATTACK) and self:CanStartThrow() then
            self:Windup(false)
        elseif owner:KeyPressed(IN_ATTACK2) and self:CanStartThrow() then
            self:Windup(self.HasUnderhand and self:HasSequence(self.SequenceWindupLow))
        end
    elseif state == STATE_WINDUP_HIGH or state == STATE_WINDUP_LOW then
        local low = state == STATE_WINDUP_LOW
        if !self.FuseImpact and self:GetCookTime() >= self:GetFuseTime() then
            self:Throw(low, true)
        // the pin has to be out (windup animation over) before it can leave the hand
        elseif !owner:KeyDown(low and IN_ATTACK2 or IN_ATTACK) and CurTime() >= self:GetWindupEnd() then
            self:Throw(low)
        end
    end
end

function SWEP:PrimaryAttack()
    local owner = self:GetOwner()

    if owner:KeyDown(IN_USE) and self:GetActionState() == STATE_IDLE and !self:StillWaiting() then
        self:Bash()
        self:SetNextPrimaryFire(CurTime() + 0.6)
    end
end

function SWEP:SecondaryAttack()
end

function SWEP:Reload()
    local owner = self:GetOwner()
    if !owner:KeyPressed(IN_RELOAD) then return end

    if owner:KeyDown(IN_USE) then
        self:ChangeFuseMode()
    end
end

function SWEP:OnDeploy()
    self:SetActionState(STATE_IDLE)
    self:Think_HoldType()
end

function SWEP:GetControlHints()
    local h = {{"hold:+attack", "Overhand throw"}}
    if self.HasUnderhand then
        table.insert(h, {"hold:+attack2", "Underhand throw (roll when crouched)"})
    end
    if #self:GetFuseModes() > 1 then
        table.insert(h, {"+use +reload", "Fuse time"})
    end
    table.insert(h, {"+use +attack", "Bash"})
    return h
end
