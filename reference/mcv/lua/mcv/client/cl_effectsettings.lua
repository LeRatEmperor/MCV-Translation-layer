// What the player sees of their own and other people's gunfire. Every one of these is that
// client's own: nobody else is affected by turning a light off to hold a frame rate.
//
// Registered here rather than in the effect files that read them, so the client convars sit in
// one place next to the tracer colour and the control hints. See CLAUDE.md.

MCV = MCV or {}

// Seconds a case lies still before it fades. The count restarts while it is still rolling, so
// this is time at rest rather than time since it left the gun.
CreateClientConVar("mcv_shell_time", "0.5", true, false,
    "How long an ejected case lies on the ground before it fades out, in seconds")

CreateClientConVar("mcv_shell_smoke", "1", true, false,
    "The smoke trailing a hot case out of the gun: 1 draws it, 0 does not")

MCV.MUZZLE_LIGHT_OFF = 0
MCV.MUZZLE_LIGHT_DYNAMIC = 1
MCV.MUZZLE_LIGHT_FULL = 2

// What a muzzle flash lights up. The projected light casts shadows and is the expensive one;
// the dynamic light is the engine's cheap round glow and throws none.
CreateClientConVar("mcv_muzzle_light", "2", true, false,
    "The light a muzzle flash casts: 2 projected with shadows, 1 a plain dynamic light, 0 none")

local cv_shell_time = GetConVar("mcv_shell_time")
local cv_shell_smoke = GetConVar("mcv_shell_smoke")
local cv_muzzle_light = GetConVar("mcv_muzzle_light")

function MCV.ShellTime()
    return math.max(cv_shell_time:GetFloat(), 0)
end

function MCV.ShellSmoke()
    return cv_shell_smoke:GetBool()
end

function MCV.MuzzleLightMode()
    return math.Clamp(cv_muzzle_light:GetInt(), MCV.MUZZLE_LIGHT_OFF, MCV.MUZZLE_LIGHT_FULL)
end
