AddCSLuaFile()

ENT.Base                     = "mcv_grenade_base"
ENT.PrintName                = "White Phosphorus Grenade"
ENT.Spawnable                = false

ENT.ExplosionFamily = "m34"
// the game's IgniteRadius: everything within ExplosionRadius + this burns. The M34 effect is a
// single burst of phosphorus with no lingering fire, so the patch is as short as the M202's.
ENT.IgniteRadius = 200
ENT.BurnDuration = 3
ENT.BurnDamagePerSecond = 40
