// Picking up another copy of a weapon the player already carries (a second pistol) is what
// allows dual wielding. The engine calls this on the copy being picked up, not on the carried
// one, so the flag goes on the carried one (lua/mcv/server/sv_second_weapon.lua does the same
// from the pickup and spawn-menu hooks).
function SWEP:EquipAmmo(ply)
    if SERVER and self.HasAkimbo and MCV.UnlockSecondWeapon then
        MCV.UnlockSecondWeapon(ply, self:GetClass())
    end
end

function SWEP:ToggleAkimbo()
    if self:StillWaiting() then return end
    if !self:GetHasSecond() and !self:GetAkimbo() then return end // one pistol only

    self:ScopeToggle(false)

    local t = self:PlayAnimation(ACT_VM_HOLSTER, 1, true, true)
    self:SetAnimLockTime(CurTime() + t + 0.75)

    self:Defer("AkimboSwap", t + 0.5)
end

// The gun is swapped for its dual (or back) part way through the holster it plays for it
function SWEP:Deferred_AkimboSwap()
    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    local vm = owner:GetViewModel()
    if IsValid(vm) then
        if !self:GetAkimbo() then
            self:SetAkimbo(true)
            self:SyncViewModel(true)

            // the dual model animates fewer modes than the single one (no fanning on either
            // revolver, and the dual Blackhawk has no double action either)
            if !self:FiremodeAvailable(self.Firemodes[self:GetFiremode()]) then
                self:ChangeFiremode()
            end
        else
            self:SetAkimbo(false)
            self:SyncViewModel(true)

            self:RestoreClip(0)
        end
    end

    // Draw carries SlidePosition's one-side-empty pose; ready racks both slides.
    local oneEmpty = self:GetAkimbo() and self.LastShotAnimation and self:Clip1() == 1
    if self:Clip1() > 0 and !oneEmpty then
        self:PlayAnimation(ACT_VM_READY, 1, true)
    else
        self:PlayAnimation(ACT_VM_DRAW, 1, true)
    end
end
