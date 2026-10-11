// Bullet impacts: the game's own per-surface systems in place of the engine's dust puff.
//
// particles/vietnam_impact_effects.pcf holds impact_<surface>_1 .. _3 for 33 surfaces. Each
// numbered system is a whole impact on its own, pulling in that surface's debris, mist, smoke,
// sparks and glow as children, so one of the three played at the hit point is the entire effect.
//
// The direction comes off the control points, not off the angles the system is created with.
// The children spray along the local X of a control point (Position Within Sphere Random with
// speed_in_local_coordinate_system: 180 of them read point 1 and 86 read point 0), so both
// points have to carry the surface normal as their forward, or every impact sprays the same
// way in world space whatever it hit. Only a clientside particle handle can set point 1, which
// is why this goes out as an effect (effects/mcv_impact.lua) rather than a plain ParticleEffect.
//
// SWEP:DoImpactEffect (mcv/weapon_common/shared.lua) hands the trace here and returns what this
// returns. Returning true takes the engine's UTIL_ImpactTrace off the shot, and that call is
// what puts the bullet hole down as well, so the hole is put back here by hand.

MCV.RegisterConVar("mcv_surface_impacts", "1",
    "1: the game's own per-surface bullet impacts. 0: the engine's.")

function MCV.SurfaceImpacts()
    return MCV.ConVars.mcv_surface_impacts:GetBool()
end

// Both hitscan and physical bullets own their effects explicitly. Keep the stock
// fallback here too so their surface data, decals and recipient rules agree.
function MCV.BulletImpact(tr, damage, recipients, ricochet, color)
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    if MCV.SurfaceImpact(tr, damage, recipients, ricochet, color) then return end
    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetStart(tr.StartPos)
    fx:SetNormal(tr.HitNormal)
    fx:SetSurfaceProp(tr.SurfaceProps or 0)
    fx:SetDamageType(DMG_BULLET)
    fx:SetHitBox(tr.HitBox or 0)
    // Worldspawn fails IsValid, but the engine's Impact effect needs entity 0
    // for map geometry (and static props addressed through HitBox). Dropping it
    // leaves the effect without a target, so neither particles nor decals appear.
    if tr.Entity then fx:SetEntity(tr.Entity) end
    util.Effect("Impact", fx, true, recipients or true)
end

// The surfaces the impact pcf carries, each with three variants. Ordered, because the effect
// travels as an index into this list. The `_spike` families (dirt_spike, mud_spike,
// puddle_spike, wet_spike) have only two variants and are alternates the numbered systems pull
// in themselves, so nothing here points at them.
MCV.ImpactFamilies = {
    "asphalt", "brick", "cardboard", "carpet", "clay", "cloth", "computer", "concrete",
    "dirt", "glass", "grass", "leaves", "metal", "metalsteam", "metalwater", "mud",
    "paper", "plaster", "plastic", "puddle", "rock", "rubber", "sand", "sandbarrel",
    "sheetrock", "snow", "tile", "upholstery", "water_large", "water_medium", "water_small",
    "wet", "wood",
}

game.AddParticles("particles/mcv_scaled_impacts.pcf")
game.AddParticles("particles/mcv_scaled_impacts_cheap.pcf")
game.AddParticles("particles/mcv_ricochet.pcf")
PrecacheParticleSystem("mcv_ricochet")

local index = {}
for i, name in ipairs(MCV.ImpactFamilies) do
    index[name] = i
    for v = 1, 3 do
        PrecacheParticleSystem("mcv_scaled_impact_" .. name .. "_" .. v)
    end
end

// Coarse fallback when the surface property's own name is not one of those. Flesh is left out
// on purpose: the engine's blood is better than anything in here, so those shots keep it.
local mattype_to_family = {
    [MAT_CONCRETE] = "concrete",
    [MAT_DEFAULT] = "concrete",
    [MAT_TILE] = "tile",
    [MAT_DIRT] = "dirt",
    [MAT_SAND] = "sand",
    [MAT_GRASS] = "grass",
    [MAT_FOLIAGE] = "leaves",
    [MAT_SLOSH] = "puddle",
    [MAT_METAL] = "metal",
    [MAT_GRATE] = "metal",
    [MAT_VENT] = "metal",
    [MAT_COMPUTER] = "computer",
    [MAT_WOOD] = "wood",
    [MAT_GLASS] = "glass",
    [MAT_PLASTIC] = "plastic",
    [MAT_SNOW] = "snow",
    [MAT_EGGSHELL] = "plaster",
}

// The game's own decal materials are registered by sh_impact_decals.lua.
local decal_alias = {
    metalsteam = "metal", metalwater = "metal", sandbarrel = "sand",
    clay = "dirt", wet = "dirt", paper = "cardboard", cloth = "upholstery",
}

function MCV.ImpactDecalName(family)
    if family == "puddle" or string.StartWith(family, "water_") then return end
    family = decal_alias[family] or family
    if !MCV.SurfaceDecals[family] then family = "concrete" end
    return "MCV.Impact." .. family
end

// The surface's own property name first, since it separates brick, asphalt, rock and carpet
// from the one MAT_CONCRETE the engine reports for all of them; the material type otherwise.
function MCV.ImpactFamily(tr)
    local data = tr.SurfaceProps and util.GetSurfaceData(tr.SurfaceProps)
    local name = data and data.name
    if name and index[name] then return name end

    return mattype_to_family[tr.MatType]
end

// True when the impact was handled here, which is the weapon hook's signal to leave the
// engine's own alone.
// 40 damage is the original size. Square-root growth keeps pellet marks modest
// and caps very powerful/custom-multiplier weapons at twice the particle radius.
function MCV.ImpactScale(damage)
    return math.Clamp(math.sqrt(math.max(damage or 40, 0) / 40), 0.5, 2)
end

function MCV.SurfaceImpact(tr, damage, recipients, ricochet, color)
    if !MCV.SurfaceImpacts() then return false end
    if !tr or !tr.Hit or tr.HitSky then return false end

    local family = MCV.ImpactFamily(tr)
    local i = family and index[family]
    if !i and !ricochet then return false end
    // This hook receives authoritative client impacts (including singleplayer),
    // outside user-command prediction. IsFirstTimePredicted can be false here;
    // it is not a replay indicator for this callback. The engine gates the hook.

    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetNormal(tr.HitNormal)
    // Only incoming bullets opt in. Melee and reverse penetration-exit traces
    // share this surface effect but must never produce a bullet ricochet.
    fx:SetDamageType(ricochet and DMG_BULLET or 0)
    fx:SetStart(ricochet and tr.StartPos or tr.HitPos)
    fx:SetFlags(i or 0) // zero adds only the ricochet; stock impact/blood still runs
    fx:SetScale(MCV.ImpactScale(damage))
    if ricochet then
        color = color or MCV.TracerColor(nil, "")
        // RGB in otherwise unused payload fields; preserve Start for reflection.
        fx:SetMagnitude(color.r)
        fx:SetRadius(color.g)
        fx:SetColor(math.floor(color.b + 0.5))
    end
    // Authoritative/SP callers run outside prediction. Hitscan supplies its own
    // recipient filter and gates first-predicted dispatch at the firing callback.
    util.Effect("mcv_impact", fx, true, recipients or true)

    return i != nil
end
