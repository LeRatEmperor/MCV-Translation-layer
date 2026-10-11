// Explosion particle systems ripped from the game. Every family has one system per surface
// type (Vietnam_Explosion_<Family>_<Surface>); pick one from the material hit.

MCV.ExplosionFamilies = {
    rpg = "Vietnam_Explosion_RPGRocket",
    ubgl = "Vietnam_Explosion_UnderBarrelGrenade",
    grenade = "Vietnam_Explosion_HandGrenade",
    mortar = "Vietnam_Explosion_MortarShell",
    artillery = "Vietnam_Explosion_Artillery",
    kolos = "Vietnam_Explosion_KolosMissile",
    xm202 = "Vietnam_Explosion_XM202Rocket", // no surface variants
    m34 = "Vietnam_Explosion_M34Grenade", // no surface variants
    phosphorus = "Vietnam_Explosion_Phosphorus_Default",
}

// Families that have no per-surface variant
local single = {
    xm202 = true,
    m34 = true,
    phosphorus = true,
}

local mattype_to_surface = {
    [MAT_CONCRETE] = "Asphalt",
    [MAT_TILE] = "Tile",
    [MAT_DIRT] = "Dirt",
    [MAT_SAND] = "Sand",
    [MAT_GRASS] = "Foliage",
    [MAT_FOLIAGE] = "Foliage",
    [MAT_SLOSH] = "Mud",
    [MAT_METAL] = "Metal",
    [MAT_GRATE] = "Metal",
    [MAT_VENT] = "Metal",
    [MAT_COMPUTER] = "Metal",
    [MAT_WOOD] = "Wood",
    [MAT_GLASS] = "Glass",
    [MAT_PLASTIC] = "Plastic",
    [MAT_FLESH] = "Flesh",
    [MAT_BLOODYFLESH] = "Flesh",
    [MAT_ALIENFLESH] = "Flesh",
    [MAT_ANTLION] = "Flesh",
    [MAT_CLIP] = "Default",
    [MAT_DEFAULT] = "Default",
    [MAT_SNOW] = "Snow",
    [MAT_EGGSHELL] = "Plaster",
}

// Surfaces the pcfs actually contain (HandGrenade / RPG / UBGL / Mortar / Kolos share the full set)
local have = {
    Asphalt = true, Brick = true, Cloth = true, Default = true, Dirt = true, Flesh = true, Foliage = true,
    Glass = true, Metal = true, Mud = true, Paper = true, Plaster = true, Plastic = true, Sand = true,
    Snow = true, Tile = true, Water = true, Wood = true,
}

for _, base in pairs(MCV.ExplosionFamilies) do
    PrecacheParticleSystem(base)
    for surface in pairs(have) do
        PrecacheParticleSystem(base .. "_" .. surface)
    end
end

// In-flight projectile trails
for _, name in ipairs({"rpg_missile_trail", "kolos_missile_trail", "vietnam_weaponeffect_ubgrenade",
                       "vietnam_weaponeffect_riflegrenade", "vietnam_weaponeffect_handgrenade"}) do
    PrecacheParticleSystem(name)
end

// Returns the particle system name for a family at a position. `normal` is the impact normal
// (used to orient the effect and to probe the surface).
function MCV.GetExplosionSystem(family, pos, normal, inwater)
    local base = MCV.ExplosionFamilies[family] or MCV.ExplosionFamilies.grenade

    if single[family] then return base end
    if inwater then return base .. "_Water" end

    local tr = util.TraceLine({
        start = pos + (normal or vector_up) * 8,
        endpos = pos - (normal or vector_up) * 24,
        mask = MASK_SOLID,
    })

    local surface = "Default"

    if tr.Hit then
        surface = mattype_to_surface[tr.MatType] or "Default"

        // brick/plaster/paper come from the surfaceprop name rather than a MAT_ type
        local sp = tr.SurfaceProps and util.GetSurfacePropName(tr.SurfaceProps) or ""
        if sp:find("brick") then surface = "Brick"
        elseif sp:find("plaster") or sp:find("drywall") then surface = "Plaster"
        elseif sp:find("paper") or sp:find("cardboard") then surface = "Paper"
        elseif sp:find("cloth") or sp:find("carpet") then surface = "Cloth"
        elseif sp:find("mud") then surface = "Mud"
        end
    end

    if !have[surface] then surface = "Default" end

    return base .. "_" .. surface
end

// Angle whose up axis is the surface normal. The game's explosion and fire systems build their
// column along the control point's up, so a normal passed as the angle's forward (normal:Angle())
// had them shooting sideways.
function MCV.SurfaceAngle(normal)
    local ang = (normal or vector_up):Angle()
    ang:RotateAroundAxis(ang:Right(), -90) // +90 put the normal on the angle's down axis
    return ang
end

// Spawns the explosion effect for a projectile. Shared: calling it on the server dispatches
// the particle system to every client.
function MCV.ExplosionEffect(family, pos, normal, inwater)
    normal = normal or vector_up

    local name = MCV.GetExplosionSystem(family, pos, normal, inwater)

    ParticleEffect(name, pos, MCV.SurfaceAngle(normal))
end
