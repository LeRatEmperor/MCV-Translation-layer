// Flamethrowers (LPO-50, M9A1). Holding the trigger pours a stream of fire: the game's
// lpo50_flame particle from the muzzle, damage and ignition along a short cone, fuel from the
// tank. No reload: the tank is the whole supply.

SWEP.Base = "mcv_base"
SWEP.Spawnable = false
SWEP.NPCUsable = false // The continuous flame needs its own AI, not the gun firing path.

SWEP.SubCategory = "Flamethrowers"
SWEP.CrosshairCircle = true
SWEP.Slot = 3

SWEP.HoldType = "ar2"
SWEP.AimHoldType = "ar2"
SWEP.SprintHoldType = "passive"

SWEP.Firemodes = {MCV.FIREMODE_AUTO}
SWEP.FireRate = 600 // ticks per minute
SWEP.DamageGeneric = 15 // per tick
SWEP.FlameRange = 420
SWEP.FlameHull = 24
SWEP.IgniteTime = 6 // seconds a target keeps burning (sh_burn.lua)
SWEP.BurnDamagePerSecond = 10
SWEP.FuelPerTick = 1

SWEP.FlameParticle = "lpo50_flame"
SWEP.PilotParticle = "lpo50_flame_pilot"
SWEP.MuzzleParticle = ""
SWEP.MuzzleParticleSmoke = ""
SWEP.MuzzleParticleIronsighted = ""
SWEP.MuzzleParticleIronsightedSmoke = ""
SWEP.MuzzleParticle3rdPerson = ""
SWEP.TracerParticle = ""
SWEP.NoEjectOnShoot = true
SWEP.EjectBrassType = 0

SWEP.SoundFireStart = "MCV_Weapon_LPO50.Primary_Fire_Start"
SWEP.SoundFireLoop = "MCV_Weapon_LPO50.Primary_Fire_Loop"
SWEP.SoundFireStop = "MCV_Weapon_LPO50.Primary_Fire_Stop"

// the tank blows up when shot
SWEP.TankExplodes = true
SWEP.TankExplosionDamage = 150
SWEP.TankExplosionRadius = 250

SWEP.Primary.Ammo = "mcv_flamethrower_fuel"
SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = 100
SWEP.Primary.Automatic = true

SWEP.HasEmptyReload = false
SWEP.LastShotAnimation = false
SWEP.Ironsight = true
SWEP.HasScope = false

AddCSLuaFile()

local searchdir = "weapons/mcv_flamethrower"

for _, filename in pairs(file.Find(searchdir .. "/*.lua", "LUA")) do
    if filename == "shared.lua" then continue end
    local luatype = string.sub(filename, 1, 2)

    if luatype == "sv" then
        if SERVER then include(searchdir .. "/" .. filename) end
    elseif luatype == "cl" then
        AddCSLuaFile(searchdir .. "/" .. filename)
        if CLIENT then include(searchdir .. "/" .. filename) end
    else
        AddCSLuaFile(searchdir .. "/" .. filename)
        include(searchdir .. "/" .. filename)
    end
end
