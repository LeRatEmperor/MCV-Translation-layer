// Fractured func_breakable_surf becomes a non-solid trigger. MASK_SHOT no
// longer hits it, but FireBullets' TraceAttackToTriggers still shatters its panes.
local surfaces = {}
local function track(ent)
    if IsValid(ent) and ent:GetClass() == "func_breakable_surf" then surfaces[ent] = true end
end
local function scan()
    surfaces = {}
    for _, ent in ipairs(ents.FindByClass("func_breakable_surf")) do track(ent) end
end
scan()
hook.Add("InitPostEntity", "MCV_PhysicalGlass", scan)
hook.Add("PostCleanupMap", "MCV_PhysicalGlass", scan)
hook.Add("OnEntityCreated", "MCV_PhysicalGlass", track)
hook.Add("EntityRemoved", "MCV_PhysicalGlass", function(ent) surfaces[ent] = nil end)

local function noSolidHit() return {damage = false, effects = false} end

function MCV.PhysicalBulletGlass(b, from, to)
    if !next(surfaces) then return end
    // Spatial partition query, clipped to this collision-free flight segment.
    // Do not fire a hitscan all the way to the target or scan every map entity.
    for _, ent in ipairs(ents.FindAlongRay(from, to)) do
        if surfaces[ent] and IsValid(ent) and bit.band(ent:GetSolidFlags(), FSOLID_TRIGGER) != 0 then
            local delta = to - from
            b.owner:FireBullets({Src = from, Dir = delta:GetNormalized(), Distance = delta:Length(),
                Num = 1, Spread = vector_origin, Tracer = 0,
                Damage = b.damage * MCV.BulletRangeMultiplier(b.wep, b.distance),
                Attacker = b.owner, Inflictor = b.wep, IgnoreEntity = b.wep,
                Callback = noSolidHit})
            // The engine handles all trigger panes on this segment in one call.
            return
        end
    end
end
