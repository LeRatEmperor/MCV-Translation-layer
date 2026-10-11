// The weapon scripts supply depths in Hammer units and damage-loss modifiers.
// All continuation state belongs to one pellet, never to the weapon's Lua table.
local materials = {
    [MAT_METAL] = "Metal", [MAT_GRATE] = "Metal", [MAT_VENT] = "Metal",
    [MAT_GLASS] = "Glass",
    [MAT_CONCRETE] = "Concrete", [MAT_TILE] = "Concrete",
    [MAT_WOOD] = "Wood",
}
local epsilon = 0.03125
local maxLayers = 4

function SWEP:GetPenetrationStats(mat)
    local name = materials[mat] or "Other"
    return math.max(self[name .. "PenetrationDepth"] or 0, 0) * self:StatMult("penetration"),
        math.max(self[name .. "DamageModifier"] or 1, 1), name
end

// Keep the original range/hitgroup handling on every segment. Passing total
// travelled distance avoids resetting range falloff after a wall.
function SWEP:ApplyBulletDamage(tr, dmginfo, distance, bulletCount)
    if (bulletCount or self:GetBulletCount()) > 1 then
        dmginfo:SetDamageType(bit.bor(dmginfo:GetDamageType(), DMG_BUCKSHOT))
    end
    dmginfo:SetDamage(dmginfo:GetDamage() * MCV.BulletRangeMultiplier(self, distance))
    if !IsValid(tr.Entity) then return end
    if self.ArmorPiercing then
        local target = tr.Entity
        // Strider limb collisions can be represented by a physics bone follower.
        if target:GetClass() == "phys_bone_follower" and IsValid(target:GetOwner()) then
            target = target:GetOwner()
        end
        local class = target:GetClass()
        if class == "npc_helicopter" then
            dmginfo:SetDamageType(DMG_AIRBOAT)
            return
        elseif class == "npc_strider" or class == "npc_combinegunship" then
            // These NPCs reject ordinary bullets. This is still one direct hit,
            // not a radius explosion; retain the engine's armor/difficulty rules.
            dmginfo:SetDamageType(DMG_BLAST)
            return
        end
    end
    MCV.CancelBodyDamage(tr.Entity, dmginfo, tr.HitGroup)
    local hitgroup = tr.HitGroup
    if hitgroup == HITGROUP_HEAD then
        dmginfo:ScaleDamage(self.DamageHeadMultiplier)
    elseif hitgroup == HITGROUP_CHEST then
        dmginfo:ScaleDamage(self.DamageChestMultiplier)
    elseif hitgroup == HITGROUP_STOMACH then
        dmginfo:ScaleDamage(self.DamageStomachMultiplier)
    elseif hitgroup == HITGROUP_LEFTARM or hitgroup == HITGROUP_RIGHTARM then
        dmginfo:ScaleDamage(self.DamageArmMultiplier)
    elseif hitgroup == HITGROUP_LEFTLEG or hitgroup == HITGROUP_RIGHTLEG then
        dmginfo:ScaleDamage(self.DamageLegMultiplier)
    end
end

// Exit probing is shared for cosmetic physical-bullet prediction. Only the
// server damage path applies damage; these functions only trace and queue state.

function SWEP:FindPenetrationExit(tr, dir, limit)
    // Displacements and sky are not closed volumes. Characters are terminal
    // hits in this first material-cover implementation; no arm/torso double hits.
    local ent = tr.Entity
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    if tr.HitTexture == "**displacement**" then return end
    // Entity 0 is the world and does not pass the ordinary IsValid test.
    if !tr.HitWorld and (!IsValid(ent) or ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) then return end
    if tr.MatType == MAT_FLESH or tr.MatType == MAT_BLOODYFLESH or tr.MatType == MAT_ALIENFLESH then return end
    if limit <= epsilon or dir:LengthSqr() < 0.5 then return end

    // Probe outward, then trace back from the first point outside the collision
    // volume. The reverse hit is its real exit face, not an AABB approximation.
    // Incremental probes avoid skipping a second wall further down the ray.
    local td = {endpos = tr.HitPos - dir * epsilon, mask = MASK_SHOT}
    if tr.HitWorld then
        td.filter = self:GetOwner()
    else
        td.filter = {ent}
        td.whitelist = true
    end
    for i = 1, math.ceil(limit) do
        td.start = tr.HitPos + dir * (math.min(i, limit) + epsilon)
        local back = util.TraceLine(td)
        if back.Hit and !back.StartSolid and !back.AllSolid and back.Entity == ent
                and back.HitNormal:Dot(dir) > 0 then
            local thickness = (back.HitPos - tr.HitPos):Dot(dir)
            if thickness > epsilon and thickness < limit then
                return back.HitPos + dir * epsilon, thickness, back
            end
        end
    end
end

function SWEP:QueuePenetration(tr, state, queue)
    if !MCV.BulletPenetration() or state.layers >= maxLayers then return end
    local depth, modifier = self:GetPenetrationStats(tr.MatType)
    local dir = (tr.HitPos - tr.StartPos):GetNormalized()
    local exit, thickness, back = self:FindPenetrationExit(tr, dir, depth * state.budget)
    if !exit then return end
    local budget = state.budget - thickness / depth
    // First-pass loss curve: higher script modifiers lose more damage, and
    // spending the entire depth budget stops the bullet. The original C++ loss
    // formula is not supplied with the scripts, so this is an explicit port rule.
    local damage = state.damage * math.pow(budget / state.budget, modifier)
    local distance = state.distance + (tr.HitPos - tr.StartPos):Length() + thickness + epsilon
    if damage < 1 or distance >= 56756 then return end
    // Retain the real far face for a cosmetic impact/decal. Consumers dispatch
    // it through their normal prediction/recipient path, without another damage hit.
    queue[#queue + 1] = {src = exit, dir = dir, damage = damage,
        distance = distance, budget = budget, layers = state.layers + 1,
        exitTrace = back, exitDamage = damage * MCV.BulletRangeMultiplier(self, distance - epsilon)}
end
