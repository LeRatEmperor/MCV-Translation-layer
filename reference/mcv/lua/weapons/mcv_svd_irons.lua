AddCSLuaFile()

SWEP.Base = "mcv_svd"
SWEP.Spawnable = true
SWEP.PrintName = "SVD Irons"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Battle Rifles"
SWEP.Country = "Soviet Union"
SWEP.ViewModel = "models/weapons/mcv/v_svd_irons.mdl"
SWEP.WorldModel = "models/weapons/mcv/w_svd_irons.mdl"
SWEP.IconOverride = "entities/mcv_svd_irons.png"
SWEP.SafeMovementAnimations = true

// Retain the SVD's ballistics and handling, with the scope removed from both meshes.
SWEP.HasScope = false
SWEP.AdjustableScopes = false
SWEP.ScopeMaterial = NULL
SWEP.SightedViewModelFOV = 40
// Align the bare front post/rear notch in the existing aimed pose.
SWEP.IronsightPos = Vector(-0.045, -0.1, 1.1)
SWEP.IronsightAng = Angle(0.5, 0, 0)

SWEP.Primary.Ammo = "ar2"
