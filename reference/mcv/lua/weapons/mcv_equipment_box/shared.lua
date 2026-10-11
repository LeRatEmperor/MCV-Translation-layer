include("mcv/weapon_common/load.lua")

// Ammo and medic boxes. Left click hands the box to the player you are looking at, right
// click uses it on yourself, USE + attack throws it down for anyone to pick up.

SWEP.Base = "weapon_base"
SWEP.Spawnable = false

SWEP.SubCategory = "Equipment"
SWEP.Slot = 4

SWEP.HoldType = "slam"
SWEP.SprintHoldType = "normal"
SWEP.AimHoldType = "slam"

SWEP.BoxKind = "ammo" // "ammo" or "medic"
SWEP.HealAmount = 50
SWEP.AmmoMagazines = 1 // total magazine-equivalent budget shared across the inventory
SWEP.GiveRange = 96
SWEP.DroppedEntity = "mcv_supply_box"

SWEP.SequenceGive = "give"
SWEP.SequenceSelf = "self"
SWEP.SequenceThrow = "throw"
SWEP.SequenceDraw = "draw"
SWEP.GiveDelay = 0.4
SWEP.ThrowDelay = 0.3

SWEP.Primary.Ammo = "mcv_ammobox"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = 3
SWEP.Primary.Automatic = false

AddCSLuaFile()

MCV.IncludeWeaponModules("weapons/mcv_equipment_box")
