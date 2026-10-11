// One resolver for visible tracers and the ricochets made by those rounds.
MCV.TRACER_COLOR_GUN = 0
MCV.TRACER_COLOR_PLAYER = 1
MCV.TRACER_COLOR_WEAPON = 2

function MCV.TracerColorMode(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return MCV.TRACER_COLOR_GUN end
    return math.Clamp(math.floor(tonumber(ply:GetInfo("mcv_tracer_color")) or 0), 0, 2)
end

function MCV.BrightColor(v)
    local m = math.max(v.x, v.y, v.z)
    if m < 0.004 then return Color(255, 255, 255) end
    local s = 255 / m
    return Color(v.x * s, v.y * s, v.z * s)
end

local standard, green = Color(235, 175, 51), Color(96, 235, 51)
local streaks = {assaultrifle=true, gyrojet=true, machinegun=true, pistol=true,
    ptrd=true, rifle=true, shotgun=true, smg=true, sniperrifle=true}

function MCV.HasTracerStreak(tracer)
    local family = (tracer or ""):gsub("^vietnam_tracer_", ""):gsub("_primary$", "")
        :gsub("_secondary$", ""):gsub("_green", "")
    return streaks[family] == true
end

function MCV.TracerColor(owner, tracer)
    local mode = MCV.TracerColorMode(owner)
    if mode == MCV.TRACER_COLOR_PLAYER then return MCV.BrightColor(owner:GetPlayerColor()) end
    if mode == MCV.TRACER_COLOR_WEAPON then return MCV.BrightColor(owner:GetWeaponColor()) end
    return (tracer or ""):find("_green", 1, true) and green or standard
end
