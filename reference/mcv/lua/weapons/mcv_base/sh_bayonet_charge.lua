// Bayonet charge: sprint with the blade levelled and run it into someone, the way the melee
// weapons charge. The rifles animate it themselves (ChargeStart / ChargeLoop / ChargeStab on 41
// of the 50 viewmodels that take a bayonet), and it only exists with one fixed.

local STATE_IDLE = 0
local STATE_CHARGE = 1

SWEP.SequenceBayonetChargeStart = "ChargeStart"
SWEP.SequenceBayonetChargeLoop = "ChargeLoop"
SWEP.SequencesBayonetChargeAttack = {"ChargeStab", "bash_bayonet"}

// what the thrust lands over an ordinary bayonet swing
SWEP.BayonetChargeDamageMultiplier = 2

// how long before the blade is far enough forward to hit anything, and how long a charge can
// be held before it gives up on finding a target
SWEP.BayonetChargeWindup = 0.3
SWEP.BayonetChargeHitDelay = 0.1  // into the thrust, before the blade reaches anything
SWEP.BayonetChargeMaxTime = 4

function SWEP:IsBayonetCharging()
    return self:GetActionState() == STATE_CHARGE
end

function SWEP:CanBayonetCharge()
    if !self:GetBayonet() then return false end
    if self:GetBipod() or self:GetReloading() then return false end

    return self:HasSequence(self.SequenceBayonetChargeStart)
end

function SWEP:StartBayonetCharge()
    // no wind-up in this model (nine of the fifty that take a bayonet): the input still does
    // something rather than nothing, the way a melee weapon without one falls back to a stab
    if !self:CanBayonetCharge() then
        self:Bash()
        return
    end

    self:SetActionState(STATE_CHARGE)
    self:SetActionStart(CurTime())
    self:SetIronsight(false)

    local t = self:PlaySequence(self.SequenceBayonetChargeStart, 1, true) or 0.4

    // the thrust waits for the wind-up to finish, however long this model's is
    self:SetActionEnd(CurTime() + t)
    self:Defer("BayonetLoop", t)
end

function SWEP:BayonetChargeAttack()
    self:SetActionState(STATE_IDLE)
    self:SetActionEnd(0)

    local seq
    for _, s in ipairs(self.SequencesBayonetChargeAttack) do
        if self:HasSequence(s) then seq = s break end
    end

    local t = seq and self:PlaySequence(seq, 1, false) or 0.6
    self:GetOwner():DoAnimationEvent(self.BashGesture)

    // the blade has to travel before it reaches anything, so the hit lands a moment into the
    // thrust rather than on its first frame, as the melee weapons' charge does
    self:Defer("BayonetHit", math.min(self.BayonetChargeHitDelay, t))

    self:SetNextPrimaryFire(CurTime() + t)
    self:SetNextSecondaryFire(CurTime() + t)
end

// Only for a charge abandoned rather than finished: the blade gone, or a reload over the top.
function SWEP:EndBayonetCharge()
    self:SetActionState(STATE_IDLE)
    self:SetActionEnd(0)
    self:CancelDeferred()
    self:SetNextIdle(CurTime())
    self:SetNextPrimaryFire(CurTime() + 0.3)
end

// the loop holds the pose for as long as the charge is up
function SWEP:IdleSequence()
    if self:GetActionState() == STATE_CHARGE then return self.SequenceBayonetChargeLoop end

    return nil
end

function SWEP:Think_BayonetCharge()
    if !self:IsBayonetCharging() then return end

    local owner = self:GetOwner()

    // Losing the blade, or starting a reload over the top, is the one way out with no thrust:
    // there is nothing left to stab with, or both hands are busy.
    if !self:GetBayonet() or self:GetReloading() then
        self:EndBayonetCharge()
        return
    end

    // the wind-up plays out first, whatever else happens over it
    if CurTime() < self:GetActionEnd() then
        return
    end

    // Running the blade into someone thrusts on the spot. Otherwise the thrust is what ends the
    // charge: the trigger coming up, the sprint dropping, or the run going on long enough. The
    // wind-up always resolves into the stab rather than sliding back to the idle, so a charge
    // that finds nobody still finishes the move.
    local tr = self:BashTrace(self.BayonetRange)

    if (tr.Hit and IsValid(tr.Entity))
       or !owner:KeyDown(IN_ATTACK)
       or !self:GetIsSprinting()
       or CurTime() > self:GetActionStart() + self.BayonetChargeMaxTime then
        self:BayonetChargeAttack()
    end
end

function SWEP:Deferred_BayonetLoop()
    if self:GetActionState() == STATE_CHARGE and self:HasSequence(self.SequenceBayonetChargeLoop) then
        self:PlaySequence(self.SequenceBayonetChargeLoop, 1, false, true)
    end
end

function SWEP:Deferred_BayonetHit()
    self:BashStrike(self.BayonetRange, self.BayonetDamage * self.BayonetChargeDamageMultiplier, true)
end
