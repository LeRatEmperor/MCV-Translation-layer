AddCSLuaFile()

// A weapon can Lua-refresh before a newly added shared file has been included.
if !MCV.MeleeBloodColor or !MCV.MeleeBloodImpact then include("mcv/shared/sh_melee_effects.lua") end

SWEP.Base = "mcv_melee"
SWEP.Spawnable = true
SWEP.NPCUsable = false
SWEP.PrintName = "Chainsaw"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Melee"
SWEP.Country = ""
SWEP.Slot = 0
SWEP.ViewModel = "models/weapons/mcv/v_chainsaw.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_chainsaw.mdl"
SWEP.BodyGroups = "00"
SWEP.HoldType = "physgun"
SWEP.AimHoldType = "physgun"
SWEP.SprintHoldType = "passive"
SWEP.MovementPoseWalk = 167
SWEP.MovementPoseSprint = 268
SWEP.SafeMovementAnimations = false
SWEP.WeaponWeight = 7
SWEP.CanThrow = false
SWEP.CanRepair = false

// Provisional balance: 120 damage/second at close range, after a short spin-up.
// The available model has no refuel, slash, stab or throw animations.
SWEP.DamageGeneric = 12
SWEP.MeleeRange = 128
SWEP.MeleeHullSize = 6
SWEP.SawRate = 600
SWEP.SawSpinUp = 0.15
SWEP.SoundSawIdle = "mcv/weapons/weapon_l4d2_chainsaw/chainsaw_idle_lp_01.wav"
SWEP.SoundSawCut = "mcv/weapons/weapon_l4d2_chainsaw/chainsaw_high_speed_lp_01.wav"
SWEP.SoundSawStart = "mcv/weapons/weapon_l4d2_chainsaw/chainsaw_start_02.wav"
SWEP.SoundSawStop = "mcv/weapons/weapon_l4d2_chainsaw/chainsaw_die_01.wav"
SWEP.Primary.Ammo = "none"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = true

function SWEP:Initialize()
    baseclass.Get("mcv_melee").Initialize(self)
    if CLIENT then MCV.TrackChainsaw(self) end
end

function SWEP:OnDeploy()
    self:SetPrimedAttack(false)
    self:SetActionState(0)
    self:SetActionStart(0)
    self:SetSkin(1) // slow chain material; skin 2 is full speed
end

function SWEP:IdleSequence()
    return self:GetPrimedAttack() and "shootloop" or "idle"
end

function SWEP:StopSaw(animate)
    if !self:GetPrimedAttack() then return end
    self:SetPrimedAttack(false)
    if animate then self:PlaySequence("shootend", 1, true) end
end

function SWEP:SawTick()
    if CLIENT then return end
    local owner = self:GetOwner()
    owner:LagCompensation(true)
    local tr = self:MeleeTrace(self.MeleeRange)
    owner:LagCompensation(false)
    if !tr.Hit or tr.HitSky or tr.StartSolid then return end

    local damage = self.DamageGeneric * self:StatMult("damage")
    local ent = tr.Entity
    // Capture before damage: a lethal hit can remove the target immediately.
    local blood = MCV.MeleeBloodColor(ent)
    if IsValid(ent) then
        local dmg = DamageInfo()
        dmg:SetDamage(damage)
        dmg:SetDamageType(DMG_SLASH)
        dmg:SetDamageForce(self:GetAimVector() * damage * 30)
        dmg:SetDamagePosition(tr.HitPos)
        dmg:SetAttacker(owner)
        dmg:SetInflictor(self)
        ent:TakeDamageInfo(dmg)
    end
    // One authoritative contact effect; no zero-damage cosmetic bullet or replay.
    if blood != nil then
        MCV.MeleeBloodImpact(tr, blood)
    else
        MCV.BulletImpact(tr, damage, true)
    end
end

function SWEP:ThinkWeapon()
    local owner = self:GetOwner()
    local now = CurTime()
    local rate = self.SawRate * self:StatMult("firerate")
    local wants = owner:Alive() and owner:GetActiveWeapon() == self and owner:KeyDown(IN_ATTACK)
        and !owner:KeyDown(IN_USE) and !self:GetIsSprinting() and !self:GetSafe()
        and self:GetHolsterTime() == 0 and self:GetAnimLockTime() <= now and rate > 0

    if wants and !self:GetPrimedAttack() then
        self:SetPrimedAttack(true)
        self:SetActionStart(now)
        self:SetNextPrimaryFire(math.max(self:GetNextPrimaryFire(), now + self.SawSpinUp))
        self:PlaySequence("shootloop", 1, false)
    elseif !wants then
        self:StopSaw(self:GetHolsterTime() == 0 and owner:Alive())
    end

    local skin = self:GetHolsterTime() != 0 and 0 or (self:GetPrimedAttack() and 2 or 1)
    if self:GetSkin() != skin then self:SetSkin(skin) end
    if self:GetPrimedAttack() and self:GetNextPrimaryFire() <= now then
        self:SetNextPrimaryFire(now + 60 / rate)
        self:SawTick()
    end
end

function SWEP:PrimaryAttack() end // Held input is serviced by the predicted Think path.
function SWEP:SecondaryAttack() end
function SWEP:Reload() end

function SWEP:Holster(wep)
    local result = baseclass.Get("mcv_melee").Holster(self, wep)
    if SERVER or (!game.SinglePlayer() and GetPredictionPlayer() == self:GetOwner()) then
        self:StopSaw(false) // Do not replace the holster animation with shootend.
        self:SetSkin(0)
    end
    return result
end

function SWEP:OwnerChanged()
    if SERVER then
        self:SetPrimedAttack(false)
        self:SetSkin(0)
    else
        MCV.StopChainsawSound(self)
    end
end

function SWEP:OnDrop()
    self:OwnerChanged()
end

function SWEP:OnRemove()
    if CLIENT then
        MCV.UntrackChainsaw(self)
        self:RemoveWorldModels()
    end
end

function SWEP:GetControlHints()
    return {{"+attack", "Hold to saw"}}
end

if CLIENT then
    function SWEP:GetWeaponInfoRows()
        return {
            {"Damage:", tostring(self.DamageGeneric * self:StatMult("damage")) .. " / tick"},
            {"Cut rate:", tostring(self.SawRate * self:StatMult("firerate") / 60) .. " / s"},
            {"Reach:", tostring(math.Round(self.MeleeRange * 0.0254, 2)) .. " m"},
        }
    end
end
