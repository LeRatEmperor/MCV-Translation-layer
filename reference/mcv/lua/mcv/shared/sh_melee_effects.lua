AddCSLuaFile()

// Private copies of the game's blood impacts avoid Source's blood_impact_red_01
// name collision. Only the used systems/children are copied; all art stays original.
game.AddParticles("particles/mcv_melee_blood.pcf")
MCV.MeleeBloodParticles = {
    [BLOOD_COLOR_RED] = "mcv_melee_blood_impact_red_01",
    [BLOOD_COLOR_YELLOW] = "mcv_melee_orangeblood_impact_red_01",
    [BLOOD_COLOR_ANTLION] = "mcv_melee_orangeblood_impact_red_01",
    [BLOOD_COLOR_GREEN] = "mcv_melee_greenblood_impact_red_01",
    [BLOOD_COLOR_ZOMBIE] = "mcv_melee_greenblood_impact_red_01",
    [BLOOD_COLOR_ANTLION_WORKER] = "mcv_melee_greenblood_impact_red_01",
}
for _, name in pairs(MCV.MeleeBloodParticles) do PrecacheParticleSystem(name) end

function MCV.MeleeBloodColor(ent)
    if !IsValid(ent) then return end
    if !ent:IsPlayer() and !ent:IsNPC() and !ent:IsNextBot() and ent:GetClass() != "prop_ragdoll" then return end
    local color = ent:GetBloodColor() or BLOOD_COLOR_RED
    if color == DONT_BLEED or color == BLOOD_COLOR_MECH then return end
    return color
end

function MCV.MeleeBloodImpact(tr, color)
    if color == nil then return end
    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetNormal(tr.HitNormal)
    fx:SetColor(color)
    fx:SetScale(1)
    local custom = MCV.SurfaceImpacts() and MCV.MeleeBloodParticles[color]
    // Called once by server damage, including the predicting shooter in delivery.
    util.Effect(custom and "mcv_melee_blood" or "BloodImpact", fx, true, true)
end
