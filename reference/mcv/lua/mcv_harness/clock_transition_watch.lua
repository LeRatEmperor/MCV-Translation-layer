if not SERVER or GetConVar("hostport"):GetInt() != 27016 then return end
local root = "mcv_harness/p27016/results/"
local observedTransition
hook.Add("PlayerSpawn", "MCV_ClockTransitionObserve", function(_, transition)
    observedTransition = transition
end)
hook.Add("Think", "MCV_ClockTransitionObserve", function()
    local ply = player.GetHumans()[1]
    if not IsValid(ply) or not IsValid(ply:GetActiveWeapon()) then return end
    local rows = {}
    for _, w in ipairs(ply:GetWeapons()) do
        if w.MilitaryConflictVietnam then
            rows[#rows+1] = {class=w:GetClass(),clip=w:Clip1(),mode=w:GetFiremode(),
                marker=w.MCVClockTransitionMarker,serial=w:GetClockResetSerial(),
                fire=w:GetNextPrimaryFire(),lock=w:GetAnimLockTime(),deferred=w:GetDeferredAction(),
                state=w:GetActionState(),reload=w:GetReloading()}
        end
    end
    file.Write(root .. "clock_map_" .. game.GetMap() .. ".json",util.TableToJSON({map=game.GetMap(),
        time=CurTime(),transition=observedTransition,weapons=rows},true))
    hook.Remove("Think", "MCV_ClockTransitionObserve")
end)
