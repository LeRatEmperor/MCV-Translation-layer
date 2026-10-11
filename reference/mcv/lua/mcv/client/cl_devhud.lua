// The development readout: a centre cross and the weapon's animation state.
//
// It comes on with `developer 1`, so it is there for ordinary testing without the harness
// running, and the harness turns it on by itself for a marked screenshot (`shot <name> marker`
// sets MCV.Harness.Marker) whatever `developer` is set to. It lives here rather than in the
// harness file because that one only loads when data/mcv_harness/enable.txt exists.

MCV = MCV or {}

local cv_developer = GetConVar("developer")

function MCV.DevHudShown()
    if MCV.Harness and MCV.Harness.Marker then return true end

    return cv_developer and cv_developer:GetInt() > 0
end

local PINK = Color(255, 0, 255)

hook.Add("HUDPaint", "MCV_DevHud", function()
    if !MCV.DevHudShown() then return end

    local x, y = ScrW() / 2, ScrH() / 2

    // a cross with a gap in the middle, so the sights themselves stay visible through it
    surface.SetDrawColor(255, 0, 255, 255)
    surface.DrawRect(x - 1, y - 40, 2, 30)
    surface.DrawRect(x - 1, y + 10, 2, 30)
    surface.DrawRect(x - 40, y - 1, 30, 2)
    surface.DrawRect(x + 10, y - 1, 30, 2)
    surface.DrawOutlinedRect(x - 3, y - 3, 6, 6)

    local ply = LocalPlayer()
    if !IsValid(ply) then return end

    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) then return end

    local vm = ply:GetViewModel()
    local txt = string.format("%s  sight %.2f  seq %s  cycle %.2f  rate %.2f  dur %.2f  t %.2f",
        wep:GetClass(),
        wep.GetSightAmountVisual and wep:GetSightAmountVisual() or -1,
        IsValid(vm) and vm:GetSequenceName(vm:GetSequence()) or "?",
        IsValid(vm) and vm:GetCycle() or -1,
        IsValid(vm) and vm:GetPlaybackRate() or -1,
        IsValid(vm) and vm:SequenceDuration() or -1,
        CurTime())

    draw.SimpleText(txt, "MCV_8", x, ScrH() - ScreenScale(4), PINK, TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
end)
