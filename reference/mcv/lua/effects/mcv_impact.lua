// One bullet impact, in the game's own art for the surface that was hit. The family travels as
// an index into MCV.ImpactFamilies (mcv/shared/sh_impacts.lua) and the variant is picked here,
// since which of the three plays is nobody's business but the viewer's.
//
// Getting these to face the right way is the whole job. The children put their debris, mist,
// smoke and sparks out along the local X of a control point, nearly all of them reading point 1
// and a few reading point 0, so both points have to be turned to face along the surface normal.
// The effect entity establishes CP0's launch pose inside CreateParticleSystem;
// CP1 is populated explicitly for the original surface graphs. Fixed attachments
// retain each system's pose when this owner is reused for a reflected ricochet.

// long enough for the slowest child to finish: the 3d debris lives up to 2.5 seconds
local LIFETIME = 4

// Cosmetic hardness weights. Every terminal tracer hit is eligible, including
// direct hits and soft surfaces; grazing hard surfaces remain more likely.
local ricochetSurfaces = {
    metal = {hardness = 0.9, sound = "metal"},
    metalsteam = {hardness = 0.9, sound = "metal"},
    metalwater = {hardness = 0.9, sound = "metal"},
    computer = {hardness = 0.75, sound = "metal"},
    rock = {hardness = 0.65, sound = "concrete"},
    concrete = {hardness = 0.55, sound = "concrete"},
    tile = {hardness = 0.5, sound = "concrete"},
    brick = {hardness = 0.4, sound = "concrete"},
    asphalt = {hardness = 0.35, sound = "concrete"},
}
local softSurface = {hardness = 0.1, sound = "concrete"}
local nextRicochet, lastRicochetTime = 0, 0

local function particle(self, name, pos, ang, scale, color)
    // Initialize the engine-owned CP0 at the actual launch pose. Following this
    // owner would overwrite it when the impact and ricochet use different poses.
    self:SetPos(pos)
    self:SetAngles(ang)
    local ps = CreateParticleSystem(self, name, PATTACH_ABSORIGIN, 0)
    if !IsValid(ps) then return false end
    local forward, right, up = ang:Forward(), ang:Right(), ang:Up()
    for cp = 0, 1 do
        ps:SetControlPoint(cp, pos)
        ps:SetControlPointOrientation(cp, forward, right, up)
    end
    ps:SetControlPoint(2, Vector(scale, scale, scale))
    if color then ps:SetControlPoint(3, color * (1 / 255)) end
    ps:StartEmission()
    return true
end

local function ricochet(self, data, family, pos, normal, scale)
    if data:GetDamageType() != DMG_BULLET then return end
    local surface = ricochetSurfaces[family] or softSurface
    // One addition per 125 ms per viewer bounds shotgun/automatic-fire effects
    // and positional sounds. It never throttles the normal impact or its decal.
    local now = UnPredictedCurTime()
    if now < lastRicochetTime then nextRicochet = 0 end
    lastRicochetTime = now
    if now < nextRicochet then return end
    local incoming = pos - data:GetStart()
    if incoming:LengthSqr() < 0.0001 then return end
    incoming:Normalize()
    local incidence = -incoming:Dot(normal)
    if incidence <= 0 then return end
    incidence = math.Clamp(incidence, 0, 1)
    local grazing = 1 - incidence
    local chance = (0.2 + 0.8 * surface.hardness) * (0.35 + 0.65 * grazing * grazing)
    if math.Rand(0, 1) >= chance then return end

    local reflected = incoming + normal * (2 * incidence)
    // The private graph launches from CP0, initialized by the engine at creation.
    // Surface-relative up keeps its random lift outside floors, walls and ceilings.
    // At normal incidence the reflected vector and normal are parallel:
    // AngleEx cannot use that normal to establish a distinct up axis.
    local angle = incidence > 0.999 and reflected:Angle() or reflected:AngleEx(normal)
    local color = Vector(data:GetMagnitude(), data:GetRadius(), data:GetColor())
    if !particle(self, "mcv_ricochet", pos + normal * 0.25, angle, scale, color) then return end
    nextRicochet = now + 0.125
    // Play locally at the accepted contact, using the impact's existing recipient
    // and prediction rules. These sounds do not use the firing weapon's channels.
    sound.Play("mcv/weapons/fx/rics/vietnam_rics_" .. surface.sound .. "_" .. math.random(4) .. ".wav",
        pos, 87, 100, 0.7)
    self.DieTime = CurTime() + 5 // flying spark lives up to 4 s; let its trail finish
end

function EFFECT:Init(data)
    local family = MCV.ImpactFamilies[data:GetFlags()]
    if !family and data:GetDamageType() != DMG_BULLET then return end

    local pos = data:GetOrigin()
    local normal = data:GetNormal()
    if !normal or normal:LengthSqr() < 0.5 then normal = vector_up end

    // Deliver the hole with the effect, including to the firing prediction host.
    // Decal's fourth argument excludes entities; passing the hit prop would skip it.
    local decal = family and MCV.ImpactDecalName(family)
    if decal then
        util.Decal(decal, pos + normal * 4, pos - normal * 4)
    end

    local ang = normal:Angle()

    self:SetPos(pos)
    self:SetAngles(ang)

    local scale = data:GetScale()
    if scale <= 0 then scale = 1 end
    scale = math.Clamp(scale, 0.5, 2)
    if family then
        particle(self, "mcv_scaled_impact_" .. family .. "_" .. math.random(3), pos, ang, scale)
    end

    self.DieTime = CurTime() + LIFETIME
    ricochet(self, data, family, pos, normal, scale)
end

// the owner has to outlive the particles it carries
function EFFECT:Think()
    return self.DieTime != nil and CurTime() < self.DieTime
end

function EFFECT:Render() end
