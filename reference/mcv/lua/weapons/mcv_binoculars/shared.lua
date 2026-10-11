// Binoculars: right click looks through them (the sight blend of the gun base), USE + reload
// steps the magnification. Nothing to fire.

SWEP.Base = "mcv_base"
SWEP.Spawnable = false
SWEP.NPCUsable = false // Optical equipment inherits the gun base but cannot fire.

SWEP.SubCategory = "Equipment"
SWEP.Slot = 4

SWEP.HoldType = "slam"
SWEP.SprintHoldType = "normal"
SWEP.AimHoldType = "slam"

SWEP.Ironsight = true
SWEP.IronsightSpeedScale = 0.7
SWEP.ZoomLevels = {4, 8} // magnifications (the base treats GetZoomMagnification as a FOV: 90 / this)
SWEP.OverlayMaterial = "effects/screen_overlay_binoculars_01" // the game's binocular mask (Refract)
SWEP.SightedViewModelFOV = 60

SWEP.HasScope = false
SWEP.Firemodes = {MCV.FIREMODE_SEMI}
SWEP.FireRate = 0
SWEP.DamageGeneric = 0
SWEP.Spread = 0
SWEP.SpreadIronsighted = 0
SWEP.DrawCrosshair = false

SWEP.Primary.Ammo = "none"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false

SWEP.SequenceFiremode = "firemode"

AddCSLuaFile()

function SWEP:GetPrecacheParticles() return {} end
function SWEP:GetHUDAmmo() return nil, nil end
function SWEP:GetFiremodeName() return string.format("%dx", self:GetMagnification()) end

function SWEP:GetMagnification()
    local lvl = math.Clamp(self:GetScopeLevel(), 1, #self.ZoomLevels)
    return self.ZoomLevels[lvl]
end

// what the camera code wants is the FOV
function SWEP:GetZoomMagnification()
    return 90 / self:GetMagnification()
end

// mouse sensitivity follows the magnification (it followed the ironsight FOV: full speed at 8x)
function SWEP:GetLookMagnification()
    return self:GetMagnification()
end

function SWEP:PrimaryAttack()
    local owner = self:GetOwner()
    if owner:KeyDown(IN_USE) and !self:StillWaiting() then
        self:Bash()
        self:SetNextPrimaryFire(CurTime() + 0.6)
    end
end

function SWEP:Reload()
    local owner = self:GetOwner()
    if !owner:KeyPressed(IN_RELOAD) then return end
    if self:StillWaiting() then return end

    local lvl = self:GetScopeLevel() + 1
    if lvl > #self.ZoomLevels then lvl = 1 end
    self:SetScopeLevel(lvl)

    if !self:GetIronsight() and self:HasSequence(self.SequenceFiremode) then
        self:PlaySequence(self.SequenceFiremode, 1, true)
    else
        self:EmitSound("MCV_Weapon_Foley_AK47.DrawMetal")
        self:SetAnimLockTime(CurTime() + 0.2)
    end
end

function SWEP:ThinkWeapon()
    self:Think_Sights()
end

function SWEP:ToggleUBGL() end
function SWEP:ToggleBayonet() end

function SWEP:GetControlHints()
    return {
        {"+attack2", "Look"},
        {"+use +reload", "Magnification"},
        {"+use +attack", "Bash"},
    }
end

// Looking through them: the model would sit in front of the camera, so it fades out and a
// binocular mask takes its place.
function SWEP:PreDrawViewModelBlend(vm, sa)
    if sa > 0.3 then
        render.SetBlend(math.Clamp(1 - (sa - 0.3) / 0.3, 0, 1))
    end
end

if CLIENT then
    // Looking through them: the game's binocular overlay (a Refract material tinted by its own
    // mask texture: black outside the two eyepieces, a little distortion inside)
    function SWEP:DrawHUDExtra()
        local a = self:GetSightAmountVisual()
        if a < 0.5 then return end
        local alpha = math.Clamp((a - 0.5) / 0.3, 0, 1) * 255

        self.OverlayMat = self.OverlayMat or Material(self.OverlayMaterial)
        render.UpdateScreenEffectTexture()
        surface.SetMaterial(self.OverlayMat)
        surface.SetDrawColor(255, 255, 255, alpha)
        surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    end
end
