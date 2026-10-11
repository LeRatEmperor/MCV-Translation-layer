// Like TacRP, NPCs fire through a server-only path. They have no user commands,
// viewmodel, reserve-ammo pool or player reload state. Source owns their schedules
// and reload animation; its reload event refills the clip.
function SWEP:GetNPCSpread()
    return (self.NPCSpread or self.Spread) * self:StatMult("spread") / 100
end

function SWEP:GetNPCBulletSpread(proficiency)
    // This is the AI's aim error in degrees, on top of the weapon's dispersion.
    return 8 / (math.Clamp(proficiency or 0, 0, 4) + 1)
end

local semiAutoRPM = {
    [WEAPON_PROFICIENCY_POOR] = 60,
    [WEAPON_PROFICIENCY_AVERAGE] = 90,
    [WEAPON_PROFICIENCY_GOOD] = 120,
    [WEAPON_PROFICIENCY_VERY_GOOD] = 180,
    [WEAPON_PROFICIENCY_PERFECT] = 240,
}

function SWEP:GetNPCShotInterval()
    local mode = self:GetFiremodeValue()
    local delay = 60 / self:GetFiremodeRate(mode)
    local owner = self:GetOwner()
    if SERVER and (mode == MCV.FIREMODE_SEMI or mode == MCV.FIREMODE_HE or mode == MCV.FIREMODE_BUCKSHOT)
        and IsValid(owner) and owner:IsNPC() then
        local proficiency = math.Clamp(owner:GetCurrentWeaponProficiency(),
            WEAPON_PROFICIENCY_POOR, WEAPON_PROFICIENCY_PERFECT)
        // Read proficiency each time so skill changes take effect without re-equipping.
        // Cap after stat multipliers; the weapon's own slower rate still wins.
        delay = math.max(delay, 60 / semiAutoRPM[proficiency])
    end
    // A 600-RPM script value on a pump/bolt gun describes the shot, not working
    // the action. NPCs don't play the first-person cycling animation.
    if self.PlayCycleAnimation then
        delay = math.max(delay, mode == MCV.FIREMODE_PUMP and 0.6 or 0.9)
    end
    return math.max(delay, self.NPCShotInterval or 0)
end

function SWEP:GetNPCBurstSettings()
    local mode = self:GetFiremodeValue()
    local delay = self:GetNPCShotInterval()
    local clip = math.max(1, math.min(self:Clip1(), self.Primary.ClipSize))
    if mode == MCV.FIREMODE_BURST then
        local count = math.min(clip, self.BurstRounds)
        return count, count, delay
    elseif !self.PlayCycleAnimation and !self:GetProjectileClass() and
            (mode == MCV.FIREMODE_AUTO or mode == MCV.FIREMODE_FAST or mode == MCV.FIREMODE_SLOW) then
        return math.min(clip, math.max(2, math.ceil(0.3 / delay))),
            math.min(clip, math.max(3, math.ceil(0.8 / delay))), delay
    end
    return 1, 1, delay
end

function SWEP:GetNPCRestTimes()
    local delay = self:GetNPCShotInterval()
    if self:GetFiremodeValue() == MCV.FIREMODE_BURST then
        return math.max(delay, self.BurstRecovery), math.max(delay, self.BurstRecovery) + 0.3
    end
    return math.max(delay, 0.3), math.max(delay, 0.6)
end

if CLIENT then return end

function SWEP:NPC_Deploy()
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsNPC() then return end
    self:CancelDeferred()
    self:SetReloading(false)
    self:SetNeedCycle(false)
    self:SetNeedTriggerPress(false)
    self:SetPrimedAttack(false)
    self:SetGrenadeLauncher(false)
    self:SetAkimbo(false)
    // Fresh SWEPs carry DefaultClip (magazine plus starting reserve) in Clip1 until
    // player pickup distributes it. NPCs have no reserve pool: give them only a magazine.
    self.MCVWasNPCWeapon = true
    self:ClampNPCAmmo()
    self:SetFiremode(math.Clamp(self:GetFiremode(), 1, #self.Firemodes))
    local hold = self.HoldTypeNPC or self.HoldType
    self:SetHoldType(hold)
    // Combine/Citizen models lack some pistol/crossbow/RPG animations. Give
    // those models a usable rifle activity instead of a missing firing sequence.
    local activity = self.ActivityTranslateAI[ACT_RANGE_ATTACK1]
    if !activity or owner:SelectWeightedSequence(activity) < 0 then
        self:SetHoldType("ar2")
    end
    self:Think_WorldBodygroups()
end

// Only call on the NPC ownership/drop path, never on a fresh player pickup.
function SWEP:ClampNPCAmmo()
    local primary = self:GetClip1Capacity()
    local secondary = self:GetClip2Capacity()
    if self.Primary.ClipSize >= 0 and primary >= 0 and self:Clip1() > primary then
        self:SetClip1(primary)
    end
    if self.Secondary.ClipSize >= 0 and secondary >= 0 and self:Clip2() > secondary then
        self:SetClip2(secondary)
    end
end

function SWEP:Equip(newOwner)
    if newOwner:IsPlayer() then
        self.MCVWasNPCWeapon = nil
        return
    end
    if !newOwner:IsNPC() or !self.NPCUsable then return end
    self:NPC_Deploy()
end

function SWEP:OnDrop()
    // Also contain any excess left by an NPC/third-party reload before it becomes loot.
    if self.MCVWasNPCWeapon then
        self:ClampNPCAmmo()
        self.MCVWasNPCWeapon = nil
    end
end

function SWEP:NPCShoot_Primary(shootPos, shootDir)
    self:NPC_PrimaryAttack(shootPos, shootDir)
end

function SWEP:NPC_PrimaryAttack(shootPos, shootDir)
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsNPC() or !self.NPCUsable then return end
    if self:GetNextPrimaryFire() > CurTime() then return end

    local rounds = math.max(1, self.AmmoPerShot or 1)
    if self:Clip1() < rounds then
        local enemy = owner:GetEnemy()
        local armed = IsValid(enemy) and enemy.GetActiveWeapon and IsValid(enemy:GetActiveWeapon())
        owner:SetSchedule(armed and SCHED_HIDE_AND_RELOAD or SCHED_RELOAD)
        return
    end

    local volley = self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY
    if volley then rounds = math.min(self:Clip1(), self.VolleyCount) end
    local delay = self:GetNPCShotInterval()
    self:SetNextPrimaryFire(CurTime() + delay)
    if delay < 0.1 then owner:NextThink(CurTime() + delay) end

    shootPos = shootPos or owner:GetShootPos()
    shootDir = shootDir or owner:GetAimVector()
    // Effects use the same pre-shot clip parity as player fire. Do not apply
    // view punch, gestures, trigger latches or predicted animation state here.
    self:EmitShotSound(volley and rounds > 1 and self.SoundDoubleShot or self.SoundSingleShot)
    self:DoMuzzle()
    if !self.NoEjectOnShoot or self.PlayCycleAnimation then self:DoEject() end
    if self:GetProjectileClass() then
        local enemy = owner:GetEnemy()
        if IsValid(enemy) then shootDir = (enemy:WorldSpaceCenter() - shootPos):GetNormalized() end
        self:RocketAttack(false, shootPos, shootDir)
    else
        self:BulletAttack(shootPos, shootDir)
    end
    if !IsValid(self) then return end // A nearby blast can remove the weapon.
    self:SetClip1(math.max(0, self:Clip1() - rounds))
    self:Think_WorldBodygroups()
end

function SWEP:NPC_Reload()
    // Refilling here would give ammunition before the NPC finishes reloading.
    // The engine performs that transfer when its animation reaches the reload event.
end
