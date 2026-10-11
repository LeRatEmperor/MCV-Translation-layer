// User kitbash: PTRD-41 with the canted Meopta optic.
SWEP.Base = "mcv_ptrd"
SWEP.Spawnable = true
AddCSLuaFile()

SWEP.PrintName = "PTRD-41 Sniper"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Sniper Rifles"
SWEP.ViewModel = "models/weapons/mcv/v_ptrd41_s.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_ptrd41_s.mdl"

SWEP.HoldType = "passive"

SWEP.BodyGroups = "00" // gun and the separately animated PTRD cartridge
SWEP.WorldModelBodyGroups = "00"
// Match the donor's frame-13 cartridge reveal through shared predicted state.
SWEP.BulletBodygroups = {{1, 1}}
SWEP.MagInTime = 13 / 30
SWEP.MagInTimeEmpty = 13 / 30

SWEP.HasScope = true
SWEP.ScopeMaterial = Material("models/weapons/mcv/optics/crosshair_meopta256")
SWEP.ScopeIdleLensMaterial = "models/weapons/mcv/optics/lens_meopta"
SWEP.ScopeFOV = 12.5
SWEP.ScopeFOV2 = 23.5
SWEP.RTScopeMaterialIndex = 2
SWEP.IronsightPos = Vector(-2.38, 5, 0.755)
SWEP.IronsightAng = Angle(0, 0, 0)

SWEP.SightedViewModelFOV = 25