local hip = CreateClientConVar("mcv_viewmodel_fov_offset", "0", true, false,
    "Degrees added to the weapon's normal viewmodel FOV", -25, 25)
local sight = CreateClientConVar("mcv_viewmodel_sighted_fov_offset", "0", true, false,
    "Degrees added to the weapon's sighted viewmodel FOV", -25, 25)
local nozoom = CreateClientConVar("mcv_ironsight_nozoom", "0", true, false,
    "Keep the normal world FOV when using iron sights")
local offsetX = CreateClientConVar("mcv_viewmodel_offset_x", "0", true, false,
    "Hip viewmodel position: positive moves right, negative moves left", -10, 10)
local offsetY = CreateClientConVar("mcv_viewmodel_offset_y", "0", true, false,
    "Hip viewmodel position: positive moves forward, negative moves backward", -10, 10)
local offsetZ = CreateClientConVar("mcv_viewmodel_offset_z", "0", true, false,
    "Hip viewmodel position: positive moves up, negative moves down", -10, 10)

function MCV.ViewmodelPositionOffset(aim)
    local amount = 1 - math.Clamp(aim, 0, 1)
    return math.Clamp(offsetX:GetFloat(), -10, 10) * amount,
        math.Clamp(offsetY:GetFloat(), -10, 10) * amount,
        math.Clamp(offsetZ:GetFloat(), -10, 10) * amount
end

function MCV.ViewmodelFOV(weapon, amount)
    return Lerp(amount,
        math.Clamp(weapon.ViewModelFOV + math.Clamp(hip:GetFloat(), -25, 25), 1, 179),
        math.Clamp(weapon.SightedViewModelFOV + math.Clamp(sight:GetFloat(), -25, 25), 1, 179))
end

function MCV.IronsightNoZoom()
    return nozoom:GetBool()
end

// Project a camera-relative direction from world FOV into viewmodel FOV.
// Preserve its screen coordinates, not its angle in degrees. Pitch and yaw are
// coupled: scaling Euler angles independently is inaccurate for diagonal recoil.
function MCV.ViewmodelRecoilProjection(pitch, yaw, viewFOV, worldFOV, riseScale)
    local p, y = math.rad(pitch), math.rad(yaw)
    local forward = math.cos(p) * math.cos(y)
    if forward <= 0 then return pitch, yaw end
    local ratio = math.tan(math.rad(math.Clamp(viewFOV, 1, 179)) * 0.5)
        / math.tan(math.rad(math.Clamp(worldFOV, 1, 179)) * 0.5)
    local side = math.cos(p) * math.sin(y) * ratio
    // Optional visual rise multiplier in screen space; horizontal recoil is unchanged.
    local up = math.sin(p) * ratio * (riseScale or 1)
    return math.deg(math.atan2(up, math.sqrt(forward * forward + side * side))),
        math.deg(math.atan2(side, forward))
end
