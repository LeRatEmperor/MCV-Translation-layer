if not CLIENT then return end
MCVHUDTest = {samples={},switches={}}
local T = MCVHUDTest
local previous
hook.Add("PostDrawHUD", "MCV_HUDTransitionTest", function()
    local w = LocalPlayer():GetActiveWeapon()
    if not IsValid(w) then return end
    if not w.MilitaryConflictVietnam then previous=w return end
    local blend = w:GetHUDBlend()
    local row = {class=w:GetClass(),frame=FrameNumber(),time=CurTime(),blend=blend,
        reloading=w:GetReloading(),crosshair=w.CrosshairReloadAlpha,
        holster=w:GetHolsterTime(),lock=w:GetAnimLockTime()}
    if previous != w then T.switches[#T.switches+1] = row end
    T.samples[#T.samples+1] = row
    previous = w
end)
function T.Finish()
    hook.Remove("PostDrawHUD", "MCV_HUDTransitionTest")
    file.Write("mcv_harness/p27016/results/hud_transitions.json",util.TableToJSON({samples=T.samples,switches=T.switches},true))
end
