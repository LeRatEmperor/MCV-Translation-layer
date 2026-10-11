local function profile(class)
    local source = weapons.Get(class)
    assert(source and source.HR and source.HR.kind == "gun", "DHR: invalid paired gun " .. tostring(class))
    local gun = {
        class = class,
        name = source.PrintName,
        model = source.ViewModel,
        world = source.WorldModel,
        primary = table.Copy(source.Primary),
        config = table.Copy(source.HR),
        resolve = source.DHRWeapon,
    }
    gun.config.features = {executions = false, thirdperson = false, wall = false}
    gun.config.dual = true
    gun.config.aim = nil
    gun.config.spread = gun.config.spread * 1.35
    gun.config.reflection_key = gun.config.reflection_key or class:gsub("^hr_", "")
    gun.config.recoil_class = class
    return gun
end

function SWEP:Initialize()
    self.dhr_guns = {profile(self.SecondClass or self.SingleClass), profile(self.SingleClass)}
    local right = self.dhr_guns[2]
    self.HR = right.config
    self.Primary = self.dhr_guns[1].primary
    self.Secondary = right.primary
    for key, value in pairs(self.DualConfig or {}) do self.HR[key] = value end
    self.dhr_use_hands = false
    self:SetHoldType("duel")
end

function SWEP:Gun(side)
    side = side == 1 and 1 or side == 2 and 2 or self.dhr_side or 2
    return self.dhr_guns[side]
end

-- Shared gun helpers read HR and Primary; select this hand's data for the call.
function SWEP:WithGun(side, callback, ...)
    local config, primary, previous = self.HR, self.Primary, self.dhr_side
    local gun = self:Gun(side)
    self.HR, self.Primary, self.dhr_side = gun.config, gun.primary, side
    local result = callback(self, ...)
    self.HR, self.Primary, self.dhr_side = config, primary, previous
    return result
end

function SWEP:GunUpgradeString(side)
    return self:GetNW2String(side == 1 and "dhr_left_upgrades" or "hr_upgrades", "")
end

function SWEP:SyncDualUpgrades()
    if not self.dhr_guns then return end
    for side, gun in ipairs(self.dhr_guns) do
        gun.primary.ClipSize = self:WithGun(side, HRUpgrades.Get, "clip") or gun.config.clip or gun.primary.ClipSize
    end
end

function SWEP:GunSequenceLength(side, name)
    local gun, vm = self:Gun(side), self:DualViewModel(side)
    if gun.config.len[name] then return gun.config.len[name] end
    local sequence = IsValid(vm) and vm:LookupSequence(name) or -1
    return sequence >= 0 and vm:SequenceDuration(sequence) or 0.5
end

function SWEP:GunReady(side)
    return side == 1 and self:GetNextPrimaryFire() or self:GetNextSecondaryFire()
end

function SWEP:SetGunReady(side, time)
    if side == 1 then self:SetNextPrimaryFire(time) else self:SetNextSecondaryFire(time) end
end

function SWEP:UpdateFireMode(owner)
    if not self.dhr_guns then return end
    owner = owner or self:GetOwner()
    for _, gun in ipairs(self.dhr_guns) do
        if gun.config.hold_fire then
            gun.primary.Automatic = IsValid(owner) and owner:IsPlayer() and owner:GetInfoNum("hr_pistol_hold_fire", 1) ~= 0
        end
    end
end

function SWEP:PumpHand()
    for side, gun in ipairs(self.dhr_guns) do
        local sequence, _, finish = self:DualSequence(side)
        if gun.config.crosshair == "shotgun" and CurTime() < finish then
            for _, name in ipairs(gun.config.seq.fire or {}) do
                if name == sequence then return side end
            end
            if sequence == gun.config.seq.pump then return side end
        end
    end
    return 0
end

function SWEP:ServiceHand()
    local reload = self:GetDualReloadSide()
    return reload ~= 0 and reload or self:PumpHand()
end

function SWEP:ApplyDualUpgrades(value, class, fresh)
    class = class or self.SingleClass
    local changed = false
    for side, gun in ipairs(self.dhr_guns) do
        if gun.class == class then
            changed = changed or self:GunUpgradeString(side) ~= (value or "")
            self:SetNW2String(side == 1 and "dhr_left_upgrades" or "hr_upgrades", value or "")
        end
    end
    self:SyncDualUpgrades()
    if changed and not fresh then self:UpgradeReload() end
end

function SWEP:PlayDualDodge(name, duration)
    self:CancelDualReload()
    self.dhr_sound_actions = nil
    self:SetLeftPumpAt(0)
    self:SetRightPumpAt(0)
    local mirrored = {evade_left = "evade_right", evade_right = "evade_left"}
    for side, gun in ipairs(self.dhr_guns) do
        local movement = side == 1 and (mirrored[name] or name) or name
        local sequence = gun.config.seq[movement] or gun.config.seq.evade_back or gun.config.seq.idle
        local rate = self:GunSequenceLength(side, sequence) / duration
        self:PlayDualSequence(side, sequence, rate, true)
    end
    return duration
end
