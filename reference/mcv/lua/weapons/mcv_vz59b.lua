AddCSLuaFile()
SWEP.Base = "mcv_vz59"
SWEP.Spawnable = true
SWEP.PrintName = "Uk vz. 59 Belt"
SWEP.Category = "Military Conflict: Vietnam"
SWEP.SubCategory = "Light-Machine Guns"
SWEP.Country = "Czechoslovakia"
SWEP.ViewModel = "models/weapons/mcv/v_vz59b.mdl"
// No separate belt variant worldmodel was supplied.
SWEP.WorldModel = "models/weapons/mcv/w_vz59.mdl"
SWEP.IconOverride = "entities/mcv_vz59b.png"
SWEP.Primary.ClipSize = 100
SWEP.Primary.Chamber = 0
SWEP.Primary.DefaultClip = 200
SWEP.BulletBodygroups = {}
for i = 1, 21 do SWEP.BulletBodygroups[i] = {i, 1} end
SWEP.BeltBodygroups = {22}
SWEP.BodyGroups = ""
SWEP.MagInTime = 64 / 30
SWEP.MagInTimeEmpty = 89 / 30
SWEP.SafeMovementAnimations = true
