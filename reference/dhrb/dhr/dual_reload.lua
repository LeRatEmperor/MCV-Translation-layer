function SWEP:NeedsDualReload(side)
    local gun = self:Gun(side)
    return self:DualClip(side) < gun.primary.ClipSize and self:GetOwner():GetAmmoCount(gun.primary.Ammo) > 0
end

function SWEP:CanReload()
    local owner = self:GetOwner()
    return IsValid(owner) and owner:IsPlayer() and self:GetDualReloadSide() == 0
        and CurTime() >= math.max(self:GetNextPrimaryFire(), self:GetNextSecondaryFire())
        and (self:NeedsDualReload(1) or self:NeedsDualReload(2))
end

function SWEP:ReloadSection(side, name, stage)
    local gun = self:Gun(side)
    local rate = HRCombat.ReloadSpeed()
    local now = CurTime()
    self:SetReloadRate(rate)
    self:SetDualReloadSide(side)
    self:SetDualReloadStage(stage or 0)
    self:SetNW2Int("dhr_reload_rounds", self:DualClip(side))
    local duration = self:PlayDualSequence(side, name, rate)
    local event = (gun.config.reload_events or {})[name] or {}
    local insert = event.insert and event.insert / rate or duration * 0.8
    if stage == 1 or stage == 3 then insert = 0 end
    self:SetDualReloadAt(insert > 0 and now + insert or 0)
    self:SetDualReloadEnd(now + duration)
    self:SetReloadDone(self:GetDualReloadAt())
    self:SetReloadUntil(self:GetDualReloadEnd())
    self:SetNextPrimaryFire(self:GetDualReloadEnd())
    self:SetNextSecondaryFire(self:GetDualReloadEnd())
end

function SWEP:StartDualReload(side)
    local gun = self:Gun(side)
    if gun.config.seq.reload_start then
        self:ReloadSection(side, gun.config.seq.reload_start, 1)
    else
        local extended = self:WithGun(side, HRUpgrades.Get, "reload") == "ext" and "_ext" or ""
        local name = gun.config.seq["reload" .. extended] or gun.config.seq.reload
        if self:DualClip(side) > 0 then name = gun.config.seq["reload_half" .. extended] or name end
        self:ReloadSection(side, name, 0)
    end
    self:GetOwner():SetAnimation(PLAYER_RELOAD)
end

function SWEP:Reload()
    if not self:CanReload() or DHR.RunHook("DHRCanReload", self) == false then return end
    self:SetDualReloadInterrupted(false)
    self:StartDualReload(self:NeedsDualReload(1) and 1 or 2)
    if IsFirstTimePredicted() then DHR.RunHook("DHRReloadStarted", self) end
end

function SWEP:InterruptDualReload()
    local side, stage = self:GetDualReloadSide(), self:GetDualReloadStage()
    if side == 0 or (stage ~= 1 and stage ~= 2) or self:DualClip(side) <= 0 then return end
    self:SetDualReloadInterrupted(true)
    self:ReloadSection(side, self:Gun(side).config.seq.reload_end, 3)
end

function SWEP:ThinkDualReload(now)
    local side = self:GetDualReloadSide()
    if side == 0 then return end
    local gun, owner = self:Gun(side), self:GetOwner()
    local stage = self:GetDualReloadStage()
    if self:GetDualReloadAt() > 0 and now >= self:GetDualReloadAt() then
        local wanted = stage == 2 and 1 or gun.primary.ClipSize - self:DualClip(side)
        local count = math.max(0, math.min(wanted, gun.primary.ClipSize - self:DualClip(side), owner:GetAmmoCount(gun.primary.Ammo)))
        self:SetDualClip(side, self:DualClip(side) + count)
        owner:RemoveAmmo(count, gun.primary.Ammo)
        self:SetDualReloadAt(0)
        self:SetReloadDone(0)
    end
    if now < self:GetDualReloadEnd() then return end
    if stage == 1 or stage == 2 then
        if self:NeedsDualReload(side) then self:ReloadSection(side, gun.config.seq.reload_loop, 2)
        else self:ReloadSection(side, gun.config.seq.reload_end, 3) end
        return
    end
    local interrupted = self:GetDualReloadInterrupted()
    self:CancelDualReload()
    if not interrupted and side == 1 and self:NeedsDualReload(2) then self:StartDualReload(2) end
end

function SWEP:UpgradeReload()
    self:SyncDualUpgrades()
    self:CancelDualReload()
    for side, gun in ipairs(self.dhr_guns) do
        local excess = self:DualClip(side) - gun.primary.ClipSize
        if excess > 0 then
            self:GetOwner():GiveAmmo(excess, gun.primary.Ammo, true)
            self:SetDualClip(side, gun.primary.ClipSize)
        end
    end
    self:Reload()
    return true
end
