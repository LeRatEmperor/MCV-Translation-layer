// Map transitions / Source saves can retain weapons while replacing the clock.
// Clear pending actions, not inventory or the player's selected weapon modes.
function SWEP:ResetClockVisuals()
    self.VisualAnimation = nil
    self.HUDLastFrame = nil
    self.HUDDeployTime = nil
    self.HUDHintsStart = nil
    self.HUDHolsterStart = nil
    self.CrosshairReloadAlpha = nil
    self.CrosshairWasReloading = nil
    self.CrosshairReloadUntil = nil
    self.CrossGap = nil
    self.CrossBobPhase = nil
    self.VisualSpeed = nil
    self.VisualSpeedFrame = nil
    self.VisualSightRaw = nil
    self.VisualSightFrame = nil
    self.VisualStance = nil
    self.VisualStanceFrame = nil
    self.VisualSteady = nil
    self.VisualSteadyFrame = nil
    self.SmoothedMagnification = 1
    self.MuzzleLightStart = nil
    self.MuzzleLightEnd = 0
    self.NextTankCheck = 0
    if CLIENT and self.StopFlameEffect then self:StopFlameEffect() end
end

function SWEP:ResetWeaponClock()
    self:ResetClockVisuals()
    if CLIENT then return end
    local now = CurTime()
    self:CancelDeferred()
    self:SetNextPrimaryFire(now)
    self:SetNextSecondaryFire(now)
    self:SetAnimLockTime(0)
    self:SetNextIdle(now)
    self:SetAnimationStart(now)
    self:SetAnimationDuration(0)
    self:SetLastRecoilTime(now - 60)
    self:SetLastTriggerTime(now - 60)
    self:SetLastShotTimeR(now - 60)
    self:SetLastShotTimeL(now - 60)
    self:SetHolsterTime(0)
    self:SetHolsterCommand(0)
    self:SetHolsterEntity(NULL)
    self:SetActionStart(0)
    self:SetActionEnd(0)
    self:SetActionState(0)
    self:SetActionVariant(0)
    self:SetActionTarget(NULL)
    self:SetNextRepairTime(0)
    self:SetWindupEnd(0)
    self:SetHammerReleaseTime(0)
    self:SetReloading(false)
    self:SetEndReload(false)
    self:SetReloadHand(0)
    self:SetLastClip(self:Clip1())
    self:SetEmptyReload(self:Clip1() <= 0)
    self:SetBurstCount(0)
    self:SetSlashCount(0)
    self:SetPrimedAttack(false)
    self:SetNeedTriggerPress(false)
    self:SetIronsight(false)
    self:SetSighted(false)
    self:SetSightAmountRaw(0)
    self:SetMoveCommand(0)
    self:SetMoveSpeed(0)
    self:SetLastMoveSpeed(0)
    self:SetSpeed(0)
    self:SetRecoilImpulse(vector_origin)
    self:SetRecoilCommand(0)
    if self.SoundFireLoop then self:StopSound(self.SoundFireLoop) end
    self:SetClockResetSerial(self:GetClockResetSerial() + 1)
    local owner = self:GetOwner()
    if IsValid(owner) and owner:IsPlayer() and owner:GetActiveWeapon() == self then
        owner:SetSaveValue("m_flNextAttack", 0) // server save interface is relative
    end
end

function SWEP:OnRestore()
    self:ResetWeaponClock()
end

local function resetAll()
    for _, ent in ipairs(ents.GetAll()) do
        if ent.MilitaryConflictVietnam and ent.ResetWeaponClock then ent:ResetWeaponClock() end
    end
end
hook.Add("InitPostEntity", "MCV_WeaponClockReset", resetAll)

if SERVER then
    hook.Add("PlayerSpawn", "MCV_TransitionWeaponClock", function(ply, transition)
        if not transition then return end
        for _, w in ipairs(ply:GetWeapons()) do
            if w.ResetWeaponClock then w:ResetWeaponClock() end
        end
    end)
    // Sample only the global server Think clock. Predicted SWEP CurTime moves
    // backwards routinely during command replay and must never trigger a reset.
    local previous = CurTime()
    hook.Add("Think", "MCV_WeaponClockRollback", function()
        local now = CurTime()
        if now < previous - engine.TickInterval()*2 then resetAll() end
        previous = now
    end)
end
