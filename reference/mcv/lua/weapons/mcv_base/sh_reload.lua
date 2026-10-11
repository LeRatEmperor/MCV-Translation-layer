// Round-by-round top-up on a stripper-clip rifle: the model must have the animations and the
// server convar must be on
// Third person: the reload gesture of the hold type in use, timed to the first person
// animation. TacRP's scheme: the player animation event carries the time in milliseconds and
// the DoAnimationEvent hook (mcv/shared/sh_animevents.lua) restarts the gesture and stretches
// it; a per-round loop fires the loop event per shell (the gesture starts at the insert) and
// the end event when the action closes.
function SWEP:PlayReloadGesture(t, event)
    if !IsFirstTimePredicted() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    owner:DoCustomAnimEvent(event or PLAYERANIMEVENT_RELOAD, math.max(1, math.floor((t or 0) * 1000)))
end

function SWEP:Think_AutoReload()
    if self:GetReloading() or self:StillWaiting() or self:GetHolsterTime() != 0 then return end
    if self:GetSafe() or self:GetNeedCycle() or self:GetPrimedAttack() or self:IsBayonetCharging() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() or owner:GetInfoNum("mcv_auto_reload", 1) == 0 then return end
    if self:GetGrenadeLauncher() then
        if self:Clip2() != 0 or self:GetClip2Capacity() <= 0 or self:Ammo2() <= 0 then return end
    else
        if self:Clip1() != 0 or self:GetClip1Capacity() <= 0 or self:Ammo1() <= 0 then return end
    end
    self:Reload(true)
end

function SWEP:Reload(automatic)
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then return self:NPC_Reload() end
    if self:StillWaiting() then return end
    if self:GetReloading() then return end
    automatic = automatic == true
    if !automatic and !self:GetOwner():KeyPressed(IN_RELOAD) then return end

    if !automatic and self:GetOwner():KeyDown(IN_USE) then
        self:ChangeFiremode()
        return
    end

    if self:GetGrenadeLauncher() then
        self:Reload2()
        return
    end

    if self:Ammo1() == 0 then return end
    if self:Clip1() >= self:GetClip1Capacity() then return end


    if self.ShotgunReload then
        if self.ShotgunReloadEmptyStartAnimation and self:Clip1() == 0 then
            // locked like the other start: unlocked, the first insert cut it off on its first
            // frame (Gyrojet, Vz.24: "no empty reload start animation")
            self:PlayAnimation(ACT_VM_RELOAD_INSERT_EMPTY, 1, true, true)
        else
            self:PlayAnimation(ACT_SHOTGUN_RELOAD_START, 1, true, true)
        end
    else
        if self:GetAkimbo() then
            local act = ACT_VM_RELOAD
            if self:Clip1() == 0 then
                act = ACT_VM_RELOADEMPTY
            elseif self:Clip1() == 1 then
                act = ACT_VM_MISSRIGHT2
            elseif self:Clip1() >= (self.Primary.ClipSize * 2) + (self.Primary.Chamber * 2) - 1 then
                act = ACT_VM_MISSRIGHT
            end
            // the dual revolvers have no empty / right-only-empty reload of their own: without
            // this the reload had no animation and finished on the spot
            if !self:HasAnimation(act) then
                act = (act == ACT_VM_MISSRIGHT2 and self:HasAnimation(ACT_VM_MISSRIGHT)) and ACT_VM_MISSRIGHT or ACT_VM_RELOAD
            end
            self:PlayAnimation(act, 1, true)
        else
            if self:Clip1() == 0 and self.HasEmptyReload then
                if self:GetBipod() then
                    self:PlayAnimation(ACT_VM_DEPLOYED_RELOAD_EMPTY, 1, true)
                else
                    self:PlayAnimation(ACT_VM_RELOADEMPTY, 1, true)
                end
            else
                if self:GetBipod() then
                    self:PlayAnimation(ACT_VM_RELOAD_DEPLOYED, 1, true)
                else
                    self:PlayAnimation(ACT_VM_RELOAD, 1, true)
                end
            end
        end
    end

    self:SetLastClip(self:Clip1())
    self:EmitThirdPersonSound(self.SoundReloadThirdPerson)

    // the third person gesture: the start of the reload, timed to the animation just started
    // (the whole reload, or the start of a per-round loop; the inserts and the end follow)
    self:PlayReloadGesture(self:GetAnimLockTime() - CurTime(), PLAYERANIMEVENT_RELOAD)

    // only a pair of them loads a gun at a time: on its own the revolver is a plain
    // round-by-round reload, and the single viewmodels carry only the start, the insert and
    // the finish (asking for the dual model's stages printed INVALID ACT)
    if self.AkimboDualSingleActionReload and self:GetAkimbo() then
        self:SetEmptyReload(true)
        self:SetReloadHand(0) // the right gun loads first
    else
        self:SetEmptyReload(self:Clip1() == 0)
    end

    self:ScopeToggle(false)

    self:SetReloading(true)
    self:SetEndReload(false)
end

function SWEP:Reload2()
    if self:Ammo2() == 0 then return end
    if self:Clip2() >= self:GetClip2Capacity() then return end

    self:PlayAnimation(ACT_VM_RELOAD_M203, 1, true)

    self:ScopeToggle(false)

    self:SetReloading(true)
    self:SetEndReload(false)
end

function SWEP:GetClip2Capacity()
    return self.Secondary.ClipSize
end

function SWEP:GetClip1Capacity()
    if self:GetAkimbo() then
        return (self.Primary.ClipSize + self.Primary.Chamber) * 2
    else
        return self.Primary.ClipSize + self.Primary.Chamber
    end
end

function SWEP:RestoreClip(amt)
    local reserve = self:GetInfiniteAmmo() and math.huge or (self:Clip1() + self:Ammo1())

    local lastclip1 = self:Clip1()

    self:SetClip1(math.min(self:Clip1() + amt, self:GetClip1Capacity(), reserve))

    if !self:GetInfiniteAmmo() then
        reserve = reserve - self:Clip1()
        self:GetOwner():SetAmmo(reserve, self.Primary.Ammo)
    end

    return self:Clip1() - lastclip1
end

function SWEP:RestoreClip2(amt)
    local reserve = self:GetInfiniteAmmo() and math.huge or (self:Clip2() + self:Ammo2())

    local lastclip2 = self:Clip2()

    self:SetClip2(math.min(self:Clip2() + amt, self:GetClip2Capacity(), reserve))

    if !self:GetInfiniteAmmo() then
        reserve = reserve - self:Clip2()
        self:GetOwner():SetAmmo(reserve, self.Secondary.Ammo)
    end

    return self:Clip2() - lastclip2
end

function SWEP:GetInfiniteAmmo()
    return false
end

function SWEP:RestoreReloadInsert()
    if self.ReloadInsertTime then
        self:Defer("ReloadInsert", self.ReloadInsertTime)
    else
        self:RestoreClip(self.ShotgunReloadRounds)
    end
end

function SWEP:Deferred_ReloadInsert()
    if self:GetReloading() then
        self:RestoreClip(self.ShotgunReloadRounds)
    end
end

function SWEP:Think_Reload()
    if self:GetReloading() and !self:StillWaiting() then
        if self:GetGrenadeLauncher() then
            self:SetReloading(false)
            self:RestoreClip2(self.Secondary.ClipSize)
        else
            if self.AkimboDualSingleActionReload and self:GetAkimbo() then
                // Two revolvers loaded a round at a time, the right gun first. The stages the
                // models carry: a start, an insert per round (one animation per gun), the
                // change of hands halfway, then the left gun's inserts and the finish. The
                // right gun's own finish is the put-back, for stopping while still on it, and
                // never comes between the inserts and the change of hands. GetReloadHand says
                // which gun is loading, 0 the right and 2 the left.
                local capacity = self:GetClip1Capacity()
                local half = self:GetLastClip() + (capacity - self:GetLastClip()) / 2
                local hand = self:GetReloadHand()

                if self:GetEndReload() or self:Clip1() >= capacity or (!self:GetInfiniteAmmo() and self:Ammo1() == 0) then
                    // the guns go back down from whichever hand is loading
                    self:PlayReloadGesture(self:PlayAnimation(
                        hand >= 2 and ACT_SHOTGUN_RELOAD_FINISH or ACT_VM_RELOAD_END_EMPTY, 1, true),
                        PLAYERANIMEVENT_RELOAD_END)

                    self:SetReloading(false)
                    if !self.AnimationHandlesHammer then
                        self:SetEmptyReload(false)
                    end
                elseif hand == 0 and self:Clip1() >= half then
                    // the right gun holds its share: swap the guns over
                    self:PlayReloadGesture(self:PlayAnimation(ACT_VM_RELOAD_END, 1, true, true), PLAYERANIMEVENT_RELOAD_LOOP)
                    self:SetReloadHand(2)
                    if !self.AnimationHandlesHammer then
                        self:SetEmptyReload(false)
                    end
                else
                    self:PlayReloadGesture(self:PlayAnimation(hand >= 2 and ACT_VM_RELOAD2 or ACT_VM_RELOAD, 1, true, true),
                                           PLAYERANIMEVENT_RELOAD_LOOP)

                    self:EmitThirdPersonSound(self.SoundReloadLoopThirdPerson)
                    self:RestoreReloadInsert()
                end
            elseif self.ShotgunReload then
                if self:GetEndReload() or self:Clip1() >= (self:GetEmptyReload() and self.Primary.ClipSize or self:GetClip1Capacity()) or (!self:GetInfiniteAmmo() and self:Ammo1() == 0) then
                    // a reload that started empty ends by chambering (the model's ACT_SHOTGUN_PUMP:
                    // reload_endpump) when it has one; the plain finish otherwise
                    if self:GetEmptyReload() and self:Clip1() != self:GetLastClip() and self:HasAnimation(ACT_SHOTGUN_PUMP) then
                        self:PlayReloadGesture(self:PlayAnimation(ACT_SHOTGUN_PUMP, 1, true), PLAYERANIMEVENT_RELOAD_END)
                    else
                        self:PlayReloadGesture(self:PlayAnimation(ACT_SHOTGUN_RELOAD_FINISH, 1, true), PLAYERANIMEVENT_RELOAD_END)
                    end

                    self:SetReloading(false)
                    if !self.AnimationHandlesHammer then
                        self:SetEmptyReload(false)
                    end
                else
                    self:PlayReloadGesture(self:PlayAnimation(self.ShotgunAltReload and ACT_VM_RELOAD_INSERT or ACT_VM_RELOAD, 1, true, true), PLAYERANIMEVENT_RELOAD_LOOP)

                    self:EmitThirdPersonSound(self.SoundReloadLoopThirdPerson)
                    self:RestoreReloadInsert()
                end
            else
                self:SetReloading(false)

                if self:GetAkimbo() then
                    self:RestoreClip(self.Primary.ClipSize * 2)
                else
                    self:RestoreClip(self.Primary.ClipSize)
                end
            end
        end
    end
end
