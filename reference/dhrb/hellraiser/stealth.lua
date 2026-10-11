if SERVER then AddCSLuaFile() end
HRStealth=HRStealth or {}
local S=HRStealth
local enabled=CreateConVar('hr_stealth','1',bit.bor(FCVAR_ARCHIVE,FCVAR_REPLICATED),'Let NPCs lose the player after losing sight')

function S.Aware(npc,player)
    if not enabled:GetBool() then return npc:GetEnemy()==player or table.HasValue(npc:GetKnownEnemies(),player) end
    if npc.HRIsAware then return npc:HRIsAware(player) end
    if npc:GetEnemy()~=player and not table.HasValue(npc:GetKnownEnemies(),player) then return false end
    if npc:Visible(player) then return true end
    return not npc.hr_last_sight or CurTime()-npc.hr_last_sight<6
end

if not SERVER then
    function S.SetEnabled(on)net.Start('hr_stealth_option');net.WriteBool(on);net.SendToServer()end
    return
end
util.AddNetworkString('hr_stealth_option')
net.Receive('hr_stealth_option',function(_,p)
    if not game.SinglePlayer() and not p:IsAdmin() then return end
    enabled:SetBool(net.ReadBool())
end)
local nextCheck=0
hook.Add('Think','hr_stealth_memory',function()
    if not enabled:GetBool() or CurTime()<nextCheck or GetConVar('ai_disabled'):GetBool() then return end
    nextCheck=CurTime()+.25
    for _,npc in ipairs(ents.GetAll()) do
        if npc:IsNPC() and not npc.HellraiserNPC and not npc.hr_execution and not npc.hr_execution_proxy then
            local p=npc:GetEnemy()
            if IsValid(p) and p:IsPlayer() and p:Alive() then
                if npc.hr_sight_target~=p then npc.hr_sight_target=p;npc.hr_last_sight=CurTime()end
                if npc:Visible(p) then npc.hr_last_sight=CurTime()
                elseif CurTime()-npc.hr_last_sight>=6 then
                    npc:ClearEnemyMemory(p);npc:SetEnemy(NULL);npc:ClearGoal();npc:SetSchedule(SCHED_ALERT_SCAN)
                    npc.hr_sight_target=nil
                end
            else npc.hr_sight_target=nil end
        end
    end
end)
