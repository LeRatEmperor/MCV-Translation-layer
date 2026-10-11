AddCSLuaFile()
AddCSLuaFile("dhr/dual_view.lua")
AddCSLuaFile("dhr/dual_body.lua")
AddCSLuaFile("dhr/dual_guns.lua")
AddCSLuaFile("dhr/dual_reload.lua")
include("dhr/core.lua")

SWEP.Base = "dhr_base"
SWEP.PrintName = "DHRB Dual Guns"
SWEP.Spawnable = false
SWEP.DualWield = true
SWEP.UseHands = false
SWEP.ViewModelFlip1 = true
SWEP.HoldType = "duel"
SWEP.Secondary.Automatic = true

local function base()
    return baseclass.Get("dhr_base")
end

function SWEP:SetupDataTables()
    base().SetupDataTables(self)
    self:NetworkVar("String", 3, "DualSequences")
    self:NetworkVar("Float", 11, "LeftStart")
    self:NetworkVar("Float", 12, "RightStart")
    self:NetworkVar("Float", 13, "LeftEnd")
    self:NetworkVar("Float", 14, "RightEnd")
    self:NetworkVar("Float", 15, "DualReloadAt")
    self:NetworkVar("Float", 16, "DualReloadEnd")
    self:NetworkVar("Int", 2, "DualReloadSide")
    self:NetworkVar("Int", 3, "LeftRounds")
    self:NetworkVar("Int", 4, "RightRounds")
    self:NetworkVar("Int", 5, "DualReloadStage")
    self:NetworkVar("Bool", 3, "DualReloadInterrupted")
    self:NetworkVar("Float", 17, "LeftPumpAt")
    self:NetworkVar("Float", 18, "RightPumpAt")
end

include("dhr/dual_guns.lua")

function SWEP:CanBePickedUpByNPCs()
    return false
end

function SWEP:DualClip(side)
    if CLIENT and self:GetOwner() ~= LocalPlayer() then
        return side == 1 and self:GetLeftRounds() or self:GetRightRounds()
    end
    return side == 1 and self:Clip1() or self:Clip2()
end

function SWEP:SetDualClip(side, amount)
    if side == 1 then self:SetClip1(amount) else self:SetClip2(amount) end
end

function SWEP:DualViewModel(side)
    local owner = self:GetOwner()
    if IsValid(owner) and owner:IsPlayer() then return owner:GetViewModel(side == 1 and 1 or 0) end
end

function SWEP:DualSequence(side)
    local left, right = self:GetDualSequences():match("^(.-)\n(.*)$")
    if side == 1 then return left or "", self:GetLeftStart(), self:GetLeftEnd() end
    return right or "", self:GetRightStart(), self:GetRightEnd()
end

function SWEP:PlayDualSequence(side, name, rate, silent)
    if not name then return 0 end
    local vm = self:DualViewModel(side)
    rate = rate or 1
    local duration = self:GunSequenceLength(side, name) / rate
    local now = CurTime()
    local left, right = self:DualSequence(1), self:DualSequence(2)
    self:SetDualSequences((side == 1 and name or left) .. "\n" .. (side == 2 and name or right))
    if side == 1 then
        self:SetLeftStart(now)
        self:SetLeftEnd(now + duration)
    else
        self:SetRightStart(now)
        self:SetRightEnd(now + duration)
    end
    if IsValid(vm) then
        local sequence = vm:LookupSequence(name)
        if sequence >= 0 then
            vm:SendViewModelMatchingSequence(sequence)
            vm:SetPlaybackRate(rate)
        end
    end
    if SERVER and not silent then self:QueueDualEvents(side, name, rate) end
    return duration
end

function SWEP:Deploy()
    for side, gun in ipairs(self.dhr_guns) do
        local vm = self:DualViewModel(side)
        if IsValid(vm) then
            vm:SetWeaponModel(gun.model, self)
            vm.dhr_weapon = self
            if gun.resolve then
                local resolved = self:WithGun(side, DHR.ResolveAnimations, vm, gun)
                if resolved == false then return false end
            end
        end
    end
    self:UpdateFireMode()
    self:SetAiming(false)
    self:CancelDualReload()
    for side, gun in ipairs(self.dhr_guns) do
        local duration = self:PlayDualSequence(side, gun.config.seq.draw)
        self:SetGunReady(side, CurTime() + duration)
    end
    return true
end

function SWEP:CancelDualReload()
    self:SetDualReloadSide(0)
    self:SetDualReloadStage(0)
    self:SetDualReloadInterrupted(false)
    self:SetDualReloadAt(0)
    self:SetDualReloadEnd(0)
    self:SetReloadDone(0)
    self:SetReloadUntil(0)
end

function SWEP:Holster()
    self.dhr_sound_actions = nil
    self:CancelDualReload()
    local vm = self:DualViewModel(1)
    if IsValid(vm) and vm.dhr_weapon == self then vm:SetWeaponModel(self:Gun(1).model, NULL); vm.dhr_weapon = nil end
    if CLIENT then self:RemoveDualModels() end
    return true
end

function SWEP:OnDrop()
    self:CancelDualReload()
    if CLIENT then self:RemoveDualModels() end
    base().OnDrop(self)
end

function SWEP:OnRemove()
    if CLIENT then self:RemoveDualModels() end
    if IsValid(self:GetOwner()) then self:Holster() end
end

function SWEP:FireSide(side)
    local owner = self:GetOwner()
    if not IsValid(owner) or not owner:Alive() or HRCombat.Dodging(owner) then return end
    if self:GetDualReloadSide() ~= 0 then self:InterruptDualReload(); return end
    if self:GetNW2Bool("hr_executing") or self:PumpHand() ~= 0 or CurTime() < self:GunReady(side) then return end
    local gun = self:Gun(side)
    local h = gun.config
    local multiplier = self:WithGun(side, HRUpgrades.Get, "rate")
    local delay = 1 / (h.rate * multiplier)
    if self:DualClip(side) <= 0 then
        delay = 0.35
        if IsFirstTimePredicted() and h.dry_snd then self:EmitSound(h.dry_snd) end
    else
        if DHR.RunHook("DHRCanFire", self, side) == false then return end
        self.dhr_firing_side = side
        self:WithGun(side, self.ShootGun)
        self:SetDualClip(side, self:DualClip(side) - 1)
        local fire = h.seq.fire
        local name = istable(fire) and fire[1] or fire
        if self:DualClip(side) == 0 then name = h.seq.fire_last or name end
        local pump = h.crosshair == "shotgun"
        local duration = self:PlayDualSequence(side, name, pump and multiplier or 1)
        if pump then delay = math.max(delay, duration) end
        if h.seq.pump then
            local start = h.pump_delay and h.pump_delay / multiplier or duration
            if side == 1 then self:SetLeftPumpAt(CurTime() + start) else self:SetRightPumpAt(CurTime() + start) end
            delay = math.max(delay, start + self:GunSequenceLength(side, h.seq.pump) / multiplier)
        end
        if IsFirstTimePredicted() then DHR.RunHook("DHRShotFired", self, side) end
        self.dhr_firing_side = nil
    end
    self:SetGunReady(side, CurTime() + delay)
end

function SWEP:PrimaryAttack()
    self:FireSide(1)
end

function SWEP:SecondaryAttack()
    self:FireSide(2)
end

include("dhr/dual_reload.lua")

function SWEP:Think()
    self:UpdateFireMode()
    self:SyncDualUpgrades()
    if SERVER then
        self:SetLeftRounds(self:Clip1())
        self:SetRightRounds(self:Clip2())
    end
    local owner = self:GetOwner()
    if CLIENT and IsValid(owner) and owner == LocalPlayer() and owner:GetActiveWeapon() == self then
        for side, gun in ipairs(self.dhr_guns) do
            local vm = self:DualViewModel(side)
            if IsValid(vm) and (vm.dhr_weapon ~= self or vm:GetModel() ~= gun.model) then
                vm:SetWeaponModel(gun.model, self)
                vm.dhr_weapon = self
            end
        end
    end
    if CLIENT and game.SinglePlayer() then return end
    if not IsValid(owner) or not owner:IsPlayer() or not owner:Alive() then return end
    local now = CurTime()
    if HRCombat.Dodging(owner) then return end
    if self:GetDualReloadSide() ~= 0 and (owner:KeyDown(IN_ATTACK) or owner:KeyDown(IN_ATTACK2)) then
        self:InterruptDualReload()
    end
    self:ThinkDualReload(now)
    if self:GetDualReloadSide() == 0 and self:Clip1() == 0 and self:Clip2() == 0
        and owner:GetInfoNum("hr_auto_reload", 1) ~= 0 then self:Reload() end
    local moving = owner:OnGround() and owner:GetVelocity():Length2D() > 30
    local running = self:IsRunning()
    local moveState = moving and (running and 2 or 1) or 0
    local changed = self.dhr_move_state ~= moveState
    self.dhr_move_state = moveState
    for side, gun in ipairs(self.dhr_guns) do
        local pump = side == 1 and self:GetLeftPumpAt() or self:GetRightPumpAt()
        if pump > 0 and now >= pump then
            self:PlayDualSequence(side, gun.config.seq.pump, self:WithGun(side, HRUpgrades.Get, "rate"))
            if side == 1 then self:SetLeftPumpAt(0) else self:SetRightPumpAt(0) end
        end
        local current, _, finish = self:DualSequence(side)
        local seq = gun.config.seq
        local locomotion = current == seq.idle or current == seq.walk
            or current == seq.idle_empty or current == seq.walk_empty
        if self:GetDualReloadSide() ~= side and (now >= finish or (changed and locomotion)) then
            local name = moving and seq.walk or seq.idle
            if self:DualClip(side) == 0 then name = seq[name .. "_empty"] or name end
            local rate = (gun.config.movement_rates or {})[name] or 1
            if running then rate = rate * (gun.config.dual_sprint_rate or 1.35) end
            self:PlayDualSequence(side, name, rate)
        end
    end
end

function SWEP:QueueDualEvents(side, sequence, rate)
    local owner = self:GetOwner()
    local action = {}
    self.dhr_sound_actions = self.dhr_sound_actions or {}
    self.dhr_sound_actions[side] = action
    for _, cue in ipairs((self:Gun(side).config.world_events or {})[sequence] or {}) do
        timer.Simple(cue.time / rate, function()
            if not IsValid(self) or not IsValid(owner) or not owner:Alive() or self:GetOwner() ~= owner
                or owner:GetActiveWeapon() ~= self or self:GetNW2Bool("hr_executing") then return end
            if not self.dhr_sound_actions or self.dhr_sound_actions[side] ~= action then return end
            if cue.sound and cue.sound ~= "" and (cue.event == nil or cue.event == 5004) then
                if side == 2 or sequence ~= self:Gun(side).config.seq.draw then self:EmitSound(cue.sound, 70, 100, 1, CHAN_AUTO) end
            end
        end)
    end
end

function SWEP:MuzzleFx()
    local side = self.dhr_firing_side or 2
    if CLIENT then
        if IsFirstTimePredicted() then self:DualShot(side) end
        return
    end
    local owner = self:GetOwner()
    net.Start("dhr_dual_shot")
    net.WriteEntity(self)
    net.WriteUInt(side, 2)
    net.SendPAS(owner:GetShootPos())
    local listeners = RecipientFilter()
    listeners:AddPAS(owner:GetShootPos())
    listeners:RemovePlayer(owner)
    self:EmitSound(self:GetShotSound(false), nil, nil, nil, CHAN_AUTO, nil, nil, listeners)
end

if SERVER then
    util.AddNetworkString("dhr_dual_shot")
    hook.Add("PlayerFootstep", "dhr_dual_movement", function(player)
        local weapon = player:GetActiveWeapon()
        if not IsValid(weapon) or not weapon.DualWield or not weapon:IsRunning() or weapon:ServiceHand() ~= 0 then return end
        local cue = weapon:Gun(2).config.movement_snd or weapon:Gun(1).config.movement_snd
        if cue then weapon:EmitSound(cue, 65, 100, 0.8, CHAN_BODY) end
    end)
else
    include("dhr/dual_view.lua")
end
