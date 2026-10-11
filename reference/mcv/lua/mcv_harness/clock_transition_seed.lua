if not SERVER or GetConVar("hostport"):GetInt() != 27016 then return end
local ply = player.GetHumans()[1]
ply:StripWeapons()
for _, class in ipairs({"mcv_m16a1", "mcv_m37", "mcv_m16a1_m203"}) do ply:Give(class) end
timer.Simple(2, function()
    local rows = {}
    for _, w in ipairs(ply:GetWeapons()) do
        if w.MilitaryConflictVietnam then
            w:SetClip1(7)
            w:SetFiremode(w.Firemodes and #w.Firemodes > 1 and 2 or 1)
            w.MCVClockTransitionMarker = "retained:" .. w:GetClass()
            w:SetNextPrimaryFire(CurTime()+36000)
            w:SetNextSecondaryFire(CurTime()+36000)
            w:SetAnimLockTime(CurTime()+36000)
            w:SetNextIdle(CurTime()+36000)
            w:SetReloading(true)
            rows[#rows+1] = {class=w:GetClass(), clip=w:Clip1(), mode=w:GetFiremode(),
                marker=w.MCVClockTransitionMarker, serial=w:GetClockResetSerial(),
                fire=w:GetNextPrimaryFire(), lock=w:GetAnimLockTime()}
        end
    end
    file.Write("mcv_harness/p27016/results/clock_map_before.json", util.TableToJSON({time=CurTime(),
        map=game.GetMap(), singleplayer=game.SinglePlayer(), weapons=rows},true))
end)
