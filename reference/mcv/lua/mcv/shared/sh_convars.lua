// Console variables. Gameplay toggles are server convars, replicated and archived, so the
// predicted weapon code reads the same value on both realms and a listen server's choice reaches
// its clients; register them here (not in the weapon files, which load per weapon) with
// MCV.RegisterConVar and read them through the accessors below. Client-only preferences (HUD)
// stay CreateClientConVar in the client files.
MCV = MCV or {}
MCV.ConVars = MCV.ConVars or {}

function MCV.RegisterConVar(name, default, help, flags)
    local cv = GetConVar(name)
    if !cv then
        cv = CreateConVar(name, default, bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY, flags or 0), help)
    end
    MCV.ConVars[name] = cv
    return cv
end

function MCV.GetConVar(name)
    return MCV.ConVars[name]
end

// ------------------------------------------------------------------------------------------
// Shooting mechanics. 1: the addon's own recoil and spread (the bullet leaves the barrel where
// it points, so hip fire is inaccurate because the gun is not lined up with the eye rather than
// through a cone; recoil kicks randomly up or down from the hip and settles; the view zooms out
// a little as a burst goes on). 0: the game's numbers as they are in the weapon scripts (a hip
// fire cone that narrows to the sighted spread as the sights come up, stance multipliers on it,
// a fixed view slide up and to one side per shot, the optional random ViewKick).
MCV.RegisterConVar("mcv_realistic_shooting", "0",
    "1: the addon's recoil and spread (barrel-accurate hip fire, random kick). 0: the game's own recoil and spread cone.")

function MCV.RealisticShooting()
    return MCV.ConVars.mcv_realistic_shooting:GetBool()
end

MCV.RegisterConVar("mcv_spawn_rifle_grenade_ammo", "1",
    "Give newly spawned rifles their starting rifle-grenade or underbarrel-launcher ammo.")

function MCV.SpawnRifleGrenadeAmmo()
    return MCV.ConVars.mcv_spawn_rifle_grenade_ammo:GetBool()
end

MCV.RegisterConVar("mcv_bullet_penetration", "1",
    "Allow bullets through thin cover using each weapon's material penetration stats.")

function MCV.BulletPenetration()
    return MCV.ConVars.mcv_bullet_penetration:GetBool()
end

MCV.RegisterConVar("mcv_physbullets", "0", "Simulate bullet travel time and drop using weapon MuzzleVelocity stats.")
MCV.RegisterConVar("mcv_physbullets_npcs", "0", "Use physical bullets for NPC guns too.")
MCV.RegisterConVar("mcv_physbullets_pellets", "0", "Simulate individual shotgun and buckshot pellets; increases simulation work.")
MCV.RegisterConVar("mcv_physbullets_velocity", "1", "Multiply weapon MuzzleVelocity for physical bullets.")
MCV.RegisterConVar("mcv_physbullets_gravity", "1", "Physical bullet gravity multiplier; 1 is Earth gravity.")
MCV.RegisterConVar("mcv_physbullets_drag", "0", "Physical bullet linear air resistance per second; 0 disables drag.")
MCV.RegisterConVar("mcv_physbullets_lifetime", "5", "Maximum physical bullet flight time in seconds.")
