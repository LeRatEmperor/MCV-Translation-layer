include("mcv/weapon_common/load.lua")

// Planted explosives: C4 (remote), dynamite (lit fuse) and tripwire mines placed in two
// steps, the mine first and then the stake the wire runs to. A translucent ghost shows where
// the piece will go.

SWEP.Base = "weapon_base"
SWEP.Spawnable = false

SWEP.SubCategory = "Explosives"
SWEP.Slot = 4

SWEP.HoldType = "slam"
SWEP.SprintHoldType = "normal"
SWEP.AimHoldType = "slam"

// "c4" (plant, right click detonates), "dynamite" (plant lit, or throw lit), "mine" (two steps)
SWEP.PlaceKind = "c4"
SWEP.PlacedEntityClass = "mcv_placed_c4"
SWEP.StakeEntityClass = "mcv_mine_stake"
SWEP.PlaceRange = 72
SWEP.PlaceDelay = 0.5 // seconds into the plant animation at which the charge appears
SWEP.ThrowForce = 700
SWEP.FuseTime = 6 // dynamite
SWEP.WireLength = 256 // max mine to stake distance

SWEP.ExplosionDamage = 500
SWEP.ExplosionRadius = 500

SWEP.SequencePlant = "plant"
SWEP.SequencePlaceMine = "placemine"
SWEP.SequencePlaceStick = "placestick"
SWEP.SequenceWindup = "drawbackhigh"
SWEP.SequenceThrow = "throw"

// world model of the placed piece and of the stake (defaults to the weapon's world model)
SWEP.PlacedModel = nil
SWEP.StakeModel = nil
SWEP.MineBodygroups = {mine = 0, stick = 1} // bodygroup indices on the mine world model
// creator-side placement angles: the piece is set model-up on the surface facing the player,
// then turned by these (pitch, yaw, roll in its own frame). The stake mesh is authored point
// up, so it is rolled over and its origin (now the top) lifted StakeRaise units off the surface
SWEP.PlacedAngleOffset = nil
SWEP.StakeAngleOffset = Angle(0, 0, 180)
SWEP.StakeRaise = 6

SWEP.Primary.Ammo = "mcv_explosive_charge"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = 1
SWEP.Primary.Automatic = false

// A fuse burning in the player's own hand, between lighting the charge and throwing it. The
// viewmodel grows a flame over the same stretch (SWEP:IsLit drives both); this is what it
// sounds like. Only the dynamite is ever held lit.
SWEP.SoundFuseLoop = ""

SWEP.RemoveWhenEmpty = true

AddCSLuaFile()

MCV.IncludeWeaponModules("weapons/mcv_placeable")
