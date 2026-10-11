// Common modules composed into every Military Conflict: Vietnam base: deploy / holster, predicted timers,
// movement blends and hold types, viewmodel pose parameters, HUD, camera, bash.
// Guns (mcv_base), throwables (mcv_throwable), melee (mcv_melee), placeables
// (mcv_placeable) and equipment copy these defaults and fill in the hooks below.
// This is a module template, not a registered SWEP or an inheritance layer.

SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.Category = "Military Conflict: Vietnam"
SWEP.Base = "weapon_base"
SWEP.NPCUsable = false

function SWEP:CanBePickedUpByNPCs()
    return self.NPCUsable
end

// Names and basic information
SWEP.PrintName = ""
SWEP.Country = ""
SWEP.SubCategory = ""
SWEP.Caliber = ""

SWEP.ViewModel = "models/weapons/mcv/v_sks.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_sks.mdl"

// The multiplier the server has set for this weapon's category and a given stat
// (mcv/shared/sh_categories.lua), 1 unless someone has turned a dial.
// A sound for everyone in earshot except the player holding the weapon: their own foley comes
// off the viewmodel's animation events, and hearing both at once is the same sound twice.
// The holder's half of the above, decided where the answer is: their viewmodel is playing the
// first person foley, so this would be the same sound twice, unless the viewmodel is off screen.
function SWEP:PlayOwnThirdPersonSound(name)
    if SERVER or !name or name == "" then return end
    if !game.SinglePlayer() and !IsFirstTimePredicted() then return end

    local owner = self:GetOwner()
    if !IsValid(owner) or owner != LocalPlayer() then return end
    if !owner:ShouldDrawLocalPlayer() then return end

    owner:EmitSound(name)
end

function SWEP:EmitThirdPersonSound(name)
    if !name or name == "" then return end

    local owner = self:GetOwner()

    // In multiplayer the holder's own client runs this, predicted, and is the one that can see
    // whether the viewmodel is on screen.
    if CLIENT then
        self:PlayOwnThirdPersonSound(name)
        return
    end

    // Out of the player rather than the weapon. A carried weapon is not where the player is as
    // far as sound is concerned, and this was going out from wherever it thought it was.
    local from = IsValid(owner) and owner or self

    local filter = RecipientFilter()
    filter:AddPVS(from:GetPos())

    // everyone near them; the holder is asked separately, just below
    if IsValid(owner) and owner:IsPlayer() then
        filter:RemovePlayer(owner)

        // Singleplayer runs none of the weapon on the client, so nothing above reached it and
        // the client has to be asked outright. This is how the muzzle light gets there too.
        if game.SinglePlayer() then
            self:CallOnClient("PlayOwnThirdPersonSound", name)
        end
    end

    if filter:GetCount() == 0 then return end

    // no level, pitch, volume or channel of our own: the soundscript carries all four, and
    // anything passed here would override it
    from:EmitSound(name, nil, nil, nil, nil, 0, 0, filter)
end

function SWEP:StatMult(stat, category)
    return MCV.CategoryMult(category or self.SubCategory, stat)
end

SWEP.BodyGroups = ""
// The same set remapped onto the world model's own bodypart order, which is not always the
// viewmodel's (work/port_weapon.py writes it by matching the bodypart names). Without it a gun
// that switches a part off shows it in the world: the M14 is the M21's model with the scope
// off, and it kept the scope in third person.
SWEP.WorldModelBodyGroups = nil

SWEP.ViewModelFOV = 80
SWEP.SightedViewModelFOV = 40

SWEP.HoldType = "ar2"
SWEP.SprintHoldType = "passive"
SWEP.AimHoldType = "rpg"

SWEP.ShootGesture = false
SWEP.ReloadGesture = false

// Third person gestures follow the hold type in use (a pistol reload on a pistol pose, the
// duel set with a gun in each hand); the two fields above are the fallback
local GESTURES = {
    ar2 = {ACT_HL2MP_GESTURE_RANGE_ATTACK_AR2, ACT_HL2MP_GESTURE_RELOAD_AR2},
    smg = {ACT_HL2MP_GESTURE_RANGE_ATTACK_SMG1, ACT_HL2MP_GESTURE_RELOAD_SMG1},
    pistol = {ACT_HL2MP_GESTURE_RANGE_ATTACK_PISTOL, ACT_HL2MP_GESTURE_RELOAD_PISTOL},
    revolver = {ACT_HL2MP_GESTURE_RANGE_ATTACK_REVOLVER, ACT_HL2MP_GESTURE_RELOAD_REVOLVER},
    duel = {ACT_HL2MP_GESTURE_RANGE_ATTACK_DUEL, ACT_HL2MP_GESTURE_RELOAD_DUEL},
    shotgun = {ACT_HL2MP_GESTURE_RANGE_ATTACK_SHOTGUN, ACT_HL2MP_GESTURE_RELOAD_SHOTGUN},
    rpg = {ACT_HL2MP_GESTURE_RANGE_ATTACK_RPG, ACT_HL2MP_GESTURE_RELOAD_RPG},
    crossbow = {ACT_HL2MP_GESTURE_RANGE_ATTACK_CROSSBOW, ACT_HL2MP_GESTURE_RELOAD_CROSSBOW},
    melee = {ACT_HL2MP_GESTURE_RANGE_ATTACK_MELEE, ACT_HL2MP_GESTURE_RELOAD_MELEE},
    grenade = {ACT_HL2MP_GESTURE_RANGE_ATTACK_GRENADE, ACT_HL2MP_GESTURE_RELOAD_AR2},
    slam = {ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM, ACT_HL2MP_GESTURE_RELOAD_AR2},
}

function SWEP:GetShootGesture()
    local g = GESTURES[self:GetHoldType() or self.HoldType]
    return self.ShootGesture or (g and g[1]) or ACT_HL2MP_GESTURE_RANGE_ATTACK_AR2
end

function SWEP:GetReloadGesture()
    local g = GESTURES[self:GetHoldType() or self.HoldType]
    return self.ReloadGesture or (g and g[2]) or ACT_HL2MP_GESTURE_RELOAD_AR2
end
SWEP.BashGesture = ACT_GMOD_GESTURE_MELEE_SHOVE_2HAND

// Generic stats every kind of weapon has (guns extend these)
SWEP.DamageGeneric = 43
SWEP.Num = 1
SWEP.AmmoPerShot = 1
SWEP.FireRate = 0
SWEP.RangeModifier = 0.95
SWEP.Spread = 0
SWEP.SpreadIronsighted = 0
SWEP.ViewSlideRecoilUp = 0
SWEP.ViewSlideRecoilRight = 0
SWEP.ViewSlideRecoilIronsightUp = 0
SWEP.ViewSlideRecoilIronsightRight = 0

// Viewmodel offsets at the hip and when aimed (the aim blend is 0 for anything without sights)
SWEP.CustomPos = Vector(0, 0, 0)
SWEP.CustomAng = Angle(0, 0, 0)
SWEP.IronsightPos = Vector(0, 0, 0)
SWEP.IronsightAng = Angle(0, 0, 0)
SWEP.IronsightFov = 90 - 15
SWEP.ViewModelZNear = false // number to override the viewmodel near clip plane
SWEP.IronsightWalkBobbingStrength = -0.25

// Camera shake from recoil
SWEP.ShakeScale = 1
SWEP.ShakeFreq = 45.0
SWEP.ShakeDuration = 0.4

// Bash (USE + attack on most weapons)
SWEP.HasBayonet = false
SWEP.BashDamage = 50
SWEP.BashRange = 96
SWEP.BayonetDamage = 100
SWEP.BayonetRange = 128

SWEP.CrosshairMinDistance = 8
SWEP.CrosshairDeltaDistance = 4

SWEP.WeaponWeight = 3.85

SWEP.Primary.Ammo = "none"
SWEP.Primary.ClipSize = -1
SWEP.Primary.Chamber = 0
SWEP.Primary.DefaultClip = 0
SWEP.Primary.Automatic = true

SWEP.Secondary.Automatic = false
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.Ammo = ""
SWEP.Secondary.DefaultClip = 0

// Boilerplate
SWEP.DrawCrosshair = true
SWEP.AccurateCrosshair = false
SWEP.DrawWeaponInfoBox = true
SWEP.UseHands = true

SWEP.MilitaryConflictVietnam = true

SWEP.BobScale = 0
SWEP.SwayScale = 0.1

AddCSLuaFile()

MCV.IncludeWeaponModules("mcv/weapon_common")


// All networked state lives here so every derived base shares one layout. Unused slots
// cost nothing. Derived bases must not redefine SetupDataTables.
function SWEP:SetupDataTables()
    self:NetworkVar("Float", 0, "AnimLockTime")
    self:NetworkVar("Float", 1, "NextIdle")
    self:NetworkVar("Float", 2, "LastRecoilTime")
    self:NetworkVar("Float", 3, "LastTriggerTime")
    self:NetworkVar("Float", 4, "HolsterTime")

    // The sight blend is the predicted state itself, integrated a tick at a time in
    // Think_Sights and held here. It is deliberately not a start time and a start value with
    // the blend derived from CurTime(): a stamped curve turns any disagreement about *when*
    // into a step in the amount, and the stamp then keeps the two realms apart until the next
    // transition. An integrated amount is restored to the server's on a prediction error and
    // simply carries on from there, so an error costs one tick of travel and heals itself.
    // What is drawn chases this rather than reading it (mcv_base/sh_sights.lua).
    self:NetworkVar("Float", 5, "SightAmountRaw")
    // the movement blend, for the same reason and in the same way
    self:NetworkVar("Float", 6, "Speed")
    self:NetworkVar("Float", 7, "LastShotTimeR")
    self:NetworkVar("Float", 8, "LastShotTimeL")
    // equipment: when the current hold / charge / plant started (0 = none)
    self:NetworkVar("Float", 9, "ActionStart")
    // the one deferred action waiting to run, and when it is due (sh_timers.lua)
    self:NetworkVar("Float", 10, "DeferredTime")
    self:NetworkVar("Float", 11, "ActionEnd")
    self:NetworkVar("Float", 12, "NextRepairTime")
    self:NetworkVar("Float", 13, "WindupEnd")
    self:NetworkVar("Float", 14, "HammerReleaseTime")
    // Completed movement samples, restored with the weapon on command replay.
    // sh_movement.lua selects N-1 across the different client/server Think ordering.
    self:NetworkVar("Float", 15, "MoveSpeed")
    self:NetworkVar("Float", 16, "LastMoveSpeed")
    self:NetworkVar("Float", 17, "AnimationStart")
    self:NetworkVar("Float", 18, "AnimationDuration") // negative for reverse playback

    self:NetworkVar("Int", 0, "ScopeLevel")
    self:NetworkVar("Int", 1, "LastClip")
    self:NetworkVar("Int", 2, "Firemode")
    // equipment: small state machine (throw wind-up, mine placement step...)
    self:NetworkVar("Int", 3, "ActionState")
    self:NetworkVar("Int", 4, "BurstCount") // rounds fired on this trigger pull (a burst-fire gun keeps it until the burst is done)
    // which gun a dual revolver's round-by-round reload is loading: 0 the right, 1 the right
    // one just closed (the hands swap next), 2 the left (mcv_base/sh_reload.lua)
    self:NetworkVar("Int", 6, "ReloadHand")
    self:NetworkVar("Int", 5, "DeferredAction") // index into SWEP.DeferredActions, 0 = nothing
    self:NetworkVar("Int", 7, "ActionVariant")
    self:NetworkVar("Int", 8, "SlashCount")
    self:NetworkVar("Int", 9, "RecoilCommand")
    self:NetworkVar("Int", 10, "HolsterCommand")
    self:NetworkVar("Int", 11, "MoveCommand")
    self:NetworkVar("Int", 12, "SupplyCursor")
    self:NetworkVar("Int", 13, "ClockResetSerial")
    self:NetworkVar("Int", 14, "AmmoSwitchFrom") // outgoing cartridge during an ammo-change reload
    if CLIENT then
        self:NetworkVarNotify("ClockResetSerial", function(w, _, old, new)
            if old != new then w:ResetClockVisuals() end
        end)
    end

    self:NetworkVar("Bool", 0, "Reloading")
    self:NetworkVar("Bool", 1, "EndReload")
    self:NetworkVar("Bool", 2, "Ready")
    self:NetworkVar("Bool", 3, "Bipod")
    self:NetworkVar("Bool", 4, "EmptyReload")
    self:NetworkVar("Bool", 5, "NeedTriggerPress")
    self:NetworkVar("Bool", 6, "Ironsight") // player wants to aim (input state)
    self:NetworkVar("Bool", 7, "Sighted") // sights are actually up (Ironsight and not sprinting)
    self:NetworkVar("Bool", 8, "Bayonet")
    self:NetworkVar("Bool", 9, "GrenadeLauncher")
    self:NetworkVar("Bool", 10, "NeedCycle")
    self:NetworkVar("Bool", 11, "Akimbo")
    self:NetworkVar("Bool", 12, "PrimedAttack")
    self:NetworkVar("Bool", 13, "HasSecond") // a second copy of this weapon was picked up: dual wield allowed
    self:NetworkVar("Bool", 14, "WasRunning")
    self:NetworkVar("Bool", 15, "MoveGrounded")
    self:NetworkVar("Bool", 16, "LastMoveGrounded")
    self:NetworkVar("Bool", 17, "MoveCrouched")
    self:NetworkVar("Bool", 18, "LastMoveCrouched")
    self:NetworkVar("Bool", 19, "Safe")

    self:NetworkVar("Vector", 0, "RecoilImpulse")
    self:NetworkVar("Entity", 2, "ActionTarget")

    self:NetworkVar("Entity", 0, "HolsterEntity")
    // Slot 1 was the server-created mine handle; it now uses a non-predicted NWEntity.

    // Setup runs again for retained entities on a Source map transition.
    // Only seed zero-initialized slots; keep the existing mode and bolt state.
    if self:GetFiremode() < 1 then self:SetFiremode(1) end
    if self:GetScopeLevel() < 1 then self:SetScopeLevel(1) end
end

// ---------------------------------------------------------------------------------------
// Hooks for derived bases (defaults are the "no such feature" behaviour)
// ---------------------------------------------------------------------------------------

// Aim blend 0..1. Guns derive it from the sight transition stamps; nothing else aims.
function SWEP:GetSightAmount() return 0 end
function SWEP:GetSightAmountRaw() return 0 end
function SWEP:GetSightAmountVisual() return 0 end
function SWEP:GetSightAmountRawVisual() return 0 end
function SWEP:ScopeToggle(on) end

// World FOV divisor while aimed (see cl_camera.lua)
function SWEP:GetZoomMagnification() return 1 end

// The game's own impact for the surface a shot hit, in place of the engine's dust puff
// (mcv/shared/sh_impacts.lua). Returning true is what takes the engine's off, and its bullet
// hole with it, so that file puts a hole back; returning false leaves the shot to the engine,
// which is what the convar being off and a hit on flesh both do.
function SWEP:DoImpactEffect(tr, dmgtype)
    return MCV.SurfaceImpact(tr, (self.DamageGeneric or 40) * self:StatMult("damage"))
end

// Text shown above the ammo counter, and the two numbers of the counter (nil hides them)
function SWEP:GetFiremodeName() return "" end

// Cartridge-dependent metadata is derived from predicted state by selectable launchers.
function SWEP:GetBulletCount() return self.Num or 1 end
function SWEP:GetProjectileClass() return self.ShootEntity end
function SWEP:GetHUDAmmo() return nil, nil end

// Activity the idle loop uses, or a sequence name that takes precedence when not nil
function SWEP:IdleActivity() return ACT_VM_IDLE end
function SWEP:IdleSequence() return nil end
// Sequence played when the weapon comes up after the first READY
function SWEP:DeployAnimation() return self:PlayAnimation(ACT_VM_DRAW, 1, true) end
function SWEP:OnDeploy() end

// Particle systems to precache in Initialize
function SWEP:GetPrecacheParticles() return {} end

// Empty hands: nothing drawn, no deploy animation (the C4 kept as a detonator)
function SWEP:ViewModelHidden() return false end

// A flame or fuse on the viewmodel while the thing in hand is lit (molotov rag, dynamite
// fuse): the particle and the attachment it burns on, and whether it is lit right now
SWEP.LitAttachment = "Wick"
function SWEP:GetLitParticle() return nil end
function SWEP:IsLit() return false end

// Called from Think after the shared work (movement, hold type, timers, idle)
function SWEP:ThinkWeapon() end
// Called from DoBodygroups after the shared pose parameters
function SWEP:DoBodygroupsWeapon(vm, visual, sa, speed) end
// Called from PreDrawViewModel before the viewmodel is set up (render targets...)
function SWEP:PreDrawViewModelWeapon(vm) end
// Called after cam.Start3D in PreDrawViewModel; sa is the cubed visual aim blend
function SWEP:PreDrawViewModelBlend(vm, sa) end
// after the viewmodel is drawn and its 3D context closed
function SWEP:PostDrawViewModelWeapon(vm) end
// Extra HUD drawn under the ammo counter
function SWEP:DrawHUDExtra() end

function SWEP:SecondaryAttack()
end

// ---------------------------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------------------------

function SWEP:StillWaiting()
    if self:GetNextPrimaryFire() > CurTime() then return true end
    if self:GetAnimLockTime() > CurTime() then return true end

    return false
end

function SWEP:GetAimAngle()
    local owner = self:GetOwner()

    return owner:EyeAngles() + owner:GetViewPunchAngles()
end

function SWEP:GetAimVector()
    return self:GetAimAngle():Forward()
end

function SWEP:RandomSpread(spread, seed)
    seed = (seed or 0) + self:EntIndex() + engine.TickCount()
    local a = util.SharedRandom("mcv_randomspread", 0, 360, seed)
    local angleRand = Angle(math.sin(a), math.cos(a), 0)
    angleRand:Mul(spread * util.SharedRandom("mcv_randomspread2", 0, 45, seed) * 1.4142135623730)

    return angleRand
end

// Clip-less weapons (grenades, mines, boxes) count their rounds in the reserve directly.
function SWEP:GetRoundsLeft()
    if self.Primary.ClipSize and self.Primary.ClipSize > 0 then
        return self:Clip1()
    end

    return self:Ammo1()
end

function SWEP:TakeRound(n)
    n = n or 1

    if self.Primary.ClipSize and self.Primary.ClipSize > 0 then
        self:TakePrimaryAmmo(n)
    else
        local owner = self:GetOwner()
        owner:SetAmmo(math.max(owner:GetAmmoCount(self:GetPrimaryAmmoType()) - n, 0), self:GetPrimaryAmmoType())
    end
end
