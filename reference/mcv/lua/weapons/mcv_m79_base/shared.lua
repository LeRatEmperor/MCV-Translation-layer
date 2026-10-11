AddCSLuaFile()

SWEP.Base = "mcv_base"
SWEP.Spawnable = false
SWEP.SelectableGrenadeAmmo = true
SWEP.Firemodes = {MCV.FIREMODE_HE, MCV.FIREMODE_BUCKSHOT}
SWEP.ShootEntity = "mcv_proj_40mm"
SWEP.DamageGeneric = 25
SWEP.DamageHeadMultiplier = 2.5
SWEP.DamageChestMultiplier = 1.5
SWEP.DamageStomachMultiplier = 1.25
SWEP.DamageLegMultiplier = 0.9
SWEP.DamageArmMultiplier = 0.85
SWEP.MagInTime = 50 / 30
SWEP.MagInTimeEmpty = 50 / 30

// The first firemode is each variant's starting cartridge. All selection state is
// predicted; never rewrite Primary or other inherited configuration tables.
function SWEP:IsBuckshotSelected()
    return self:GetFiremodeValue() == MCV.FIREMODE_BUCKSHOT
end

function SWEP:GetSelectedAmmo()
    return MCV.FiremodeAmmo[self:GetFiremodeValue()]
end

function SWEP:GetPrimaryAmmoType()
    return game.GetAmmoID(self:GetSelectedAmmo())
end

function SWEP:Ammo1()
    local owner = self:GetOwner()
    return IsValid(owner) and owner:GetAmmoCount(self:GetSelectedAmmo()) or 0
end

function SWEP:GetBulletCount()
    return self:IsBuckshotSelected() and 12 or 1
end

function SWEP:GetProjectileClass()
    if self:IsBuckshotSelected() then return nil end
    return self.ShootEntity
end

function SWEP:DoBodygroupsWeapon(vm, visual, sa, speed)
    baseclass.Get("mcv_base").DoBodygroupsWeapon(self, vm, visual, sa, speed)
    // Both M79 models name this group "ammo": 0 is the HE cartridge,
    // 1 is the buckshot cartridge. Apply after the static BodyGroups string.
    local group = vm:FindBodygroupByName("ammo")
    local mode = self:GetFiremodeValue()
    local previous = self:GetAmmoSwitchFrom()
    local now = visual and self:GetViewModelTime() or CurTime()
    // Both models eject at frame 50, before inserting the new round at frame 63.
    if self:GetReloading() and previous != 0 and now < self:GetAnimationStart() + 50 / 30 then
        mode = previous
        vm:SetPoseParameter("ammo_fraction", self:GetLastClip() > 0 and 1 or 0)
    end
    if group >= 0 then vm:SetBodygroup(group, mode == MCV.FIREMODE_BUCKSHOT and 1 or 0) end
end

function SWEP:DoEject(attachment)
    if self:GetReloading() and self:GetAmmoSwitchFrom() != 0 and self:GetLastClip() > 0 then return end
    return baseclass.Get("mcv_base").DoEject(self, attachment)
end

function SWEP:Think_Reload()
    baseclass.Get("mcv_base").Think_Reload(self)
    if !self:GetReloading() then self:SetAmmoSwitchFrom(0) end
end

function SWEP:ChangeFiremode()
    if self:StillWaiting() or self:GetReloading() then return end
    local owner = self:GetOwner()
    if !IsValid(owner) then return end

    // Unload before selecting the other cartridge. SetAmmo (not GiveAmmo) and
    // Clip1 are replayable predicted writes; a switch cannot transmute ammo.
    local loaded = math.max(self:Clip1(), 0)
    self:SetAmmoSwitchFrom(self:GetFiremodeValue())
    if loaded > 0 then
        owner:SetAmmo(self:Ammo1() + loaded, self:GetSelectedAmmo())
        self:SetClip1(0)
    end
    self:SetFiremode(self:GetFiremode() % #self.Firemodes + 1)
    self:SetLastClip(loaded)
    self:SetBurstCount(0)
    self:ScopeToggle(false)
    local duration
    if loaded > 0 then
        duration = self:PlaySequence("reload_live", 1, true)
    else
        duration = self:PlayAnimation(ACT_VM_RELOAD, 1, true)
    end
    self:EmitThirdPersonSound(self.SoundReloadThirdPerson)
    self:PlayReloadGesture(duration or 0.25, PLAYERANIMEVENT_RELOAD)
    self:SetEmptyReload(loaded == 0)
    self:SetEndReload(false)
    self:SetReloading(true)
    // The normal reload completion transfers the selected reserve into Clip1.
end

function SWEP:RestoreClip(amt)
    local before = self:Clip1()
    local added = math.min(amt, self:GetClip1Capacity() - before,
        self:GetInfiniteAmmo() and math.huge or self:Ammo1())
    added = math.max(added, 0)
    self:SetClip1(before + added)
    if !self:GetInfiniteAmmo() then
        self:GetOwner():SetAmmo(self:Ammo1() - added, self:GetSelectedAmmo())
    end
    return added
end
