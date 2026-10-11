// Gun implementations of the mcv/weapon_common hooks.

function SWEP:GetPrecacheParticles()
    return {
        self.MuzzleParticle, self.MuzzleParticleSmoke, self.MuzzleParticleIronsighted,
        self.MuzzleParticleIronsightedSmoke, self.MuzzleParticle3rdPerson, self.EjectBrassTrail,
        self.EjectBrassParticle, self.TracerParticle,
    }
end

function SWEP:IdleActivity()
    if self:GetSafe() then
        return ACT_VM_IDLE_LOWERED
    end

    if self:GetGrenadeLauncher() then
        // Rifle grenades have their own ladder-sight pose too. Using the rifle
        // idle here jumps from standard irons to the ladder when the shot starts.
        return self.RifleGrenadeIsUBGL and ACT_VM_IIDLE_M203 or ACT_VM_IDLE_M203
    elseif self:GetBipod() then
        return ACT_VM_DEPLOY
    end

    return ACT_VM_IDLE
end

function SWEP:DeployAnimation()
    if self:GetGrenadeLauncher() then
        return self:PlayAnimation(self.RifleGrenadeIsUBGL and ACT_VM_IIN_M203 or ACT_VM_DRAW_M203, 1, true)
    end

    return self:PlayAnimation(ACT_VM_DRAW, 1, true)
end

// Screen FOV while aiming. With a scope the screen zooms part of the way towards the scope
// FOV (ScopeScreenZoom times it, never wider than the ironsight FOV, never below 30 degrees):
// the lens reprojects the screen (cl_pipscope.lua), so a tighter screen gives it more pixels
// and a sharper picture; the rest of the magnification happens in the lens.
SWEP.ScopeScreenZoom = 2

function SWEP:GetScopeWorldFov()
    if CLIENT and !self.HasScope and MCV.IronsightNoZoom() then return 90 end
    if !self.HasScope or self.OEGScope then return self.IronsightFov end
    return math.Clamp(self:GetScopeFOV() * self.ScopeScreenZoom, 30, self.IronsightFov)
end

function SWEP:GetZoomMagnification()
    return self:GetScopeWorldFov()
end

// Magnification the player is looking through, for the mouse sensitivity
function SWEP:GetLookMagnification()
    if CLIENT and !self.HasScope and MCV.IronsightNoZoom() then return 1 end
    if self.HasScope and !self.OEGScope then
        return 90 / self:GetScopeFOV()
    end
    return 90 / self.IronsightFov
end

function SWEP:GetFiremodeName()
    if self:GetGrenadeLauncher() then return "Launcher" end

    return MCV.FiremodeNames[self:GetFiremodeValue()] or ""
end

function SWEP:GetHUDAmmo()
    if self:GetGrenadeLauncher() then
        return self:Clip2(), self:Ammo2()
    end

    return self:Clip1(), self:Ammo1()
end

function SWEP:SecondaryAttack()
    local owner = self:GetOwner()

    if owner:KeyPressed(IN_ATTACK2) and owner:KeyDown(IN_USE) then
        self:ToggleBayonet()
    end
end

// Controls shown by the HUD after a deploy and in the weapon selection info
function SWEP:GetControlHints()
    local h = {}
    local safe = self:GetSafe()
    if !safe then
        table.insert(h, {"+attack", "Fire"})
        table.insert(h, {"+attack2", self:UsesToggleAim() and "Toggle aim" or "Aim"})
    end
    table.insert(h, {"+reload", "Reload"})
    if #self.Firemodes > 1 and !self:GetGrenadeLauncher() then
        table.insert(h, {"+use +reload", "Fire mode"})
    elseif self.AdjustableScopes and !self:GetGrenadeLauncher() then
        table.insert(h, {"+use +reload", "Scope magnification"})
    end
    if self.HasRifleGrenade then
        table.insert(h, {"+walk +use", self.RifleGrenadeIsUBGL and "Grenade launcher" or "Rifle grenade"})
    end
    if self.HasAkimbo then
        table.insert(h, {"+walk +use", self:GetHasSecond() and "Dual wield" or "Dual wield (need another)"})
    end
    if self.HasBayonet then
        table.insert(h, {"+use +attack2", self:OwnerHasBayonet() and "Bayonet" or "Bayonet (need one)"})
    end
    if self.HasBipod then
        table.insert(h, {"+use", "Bipod (at cover)"})
    end
    if !safe then
        table.insert(h, {"+use +attack", self.HasBayonet and "Bash / stab" or "Bash"})
    end
    table.insert(h, {"+use +walk", safe and "Weapon Ready" or "At Ease"})
    return h
end

function SWEP:ToggleSafe(forceoff)
    // A supported firing stance cannot be lowered into the at-ease pose.
    if self:GetBipod() then return end
    if forceoff and !self:GetSafe() then return end
    self:SetSafe(!forceoff and !self:GetSafe())

    if !forceoff then
        self:EmitSound("MCV_Weapon_Foley_Movement.ProneCrawl")
    end

    self:SetNextPrimaryFire(CurTime() + 0.25)

    if self:GetSafe() then
        self:PlayAnimation(ACT_VM_IDLE_TO_LOWERED, 1, true)
    else
        self:PlayAnimation(ACT_VM_LOWERED_TO_IDLE, 1, true)
    end
end
