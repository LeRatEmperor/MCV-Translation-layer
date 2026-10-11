if SERVER then AddCSLuaFile() end
local X = HRExecutions
local P = {}
X.Players = P
local enabled = CreateConVar('hr_player_executions', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), 'Allow Hellraiser melee finishers against other players')

function P.Allowed(attacker, victim)
    if not enabled:GetBool() or not victim:Alive() or victim:IsFrozen() or victim:InVehicle()
        or not victim:OnGround() or victim:GetMoveType() ~= MOVETYPE_WALK then return false end
    if SERVER and (victim:HasGodMode() or hook.Run('PlayerShouldTakeDamage', victim, attacker) == false) then return false end
    return DHR.RunHook('HRCanExecutePlayer', attacker, victim) ~= false
end

function P.Aware(victim, attacker)
    local recent = victim.hr_execution_combat
    if recent and CurTime() < (recent[attacker] or 0) then return true end
    local direction = (attacker:EyePos() - victim:EyePos()):GetNormalized()
    return victim:GetAimVector():Dot(direction) > .25 and victim:Visible(attacker)
end

function P.SetEnabled(on)
    if CLIENT then net.Start('hr_player_executions'); net.WriteBool(on); net.SendToServer() end
end

if SERVER then
    util.AddNetworkString('hr_player_executions')
    net.Receive('hr_player_executions', function(_, p)
        if not p:IsAdmin() then return end
        if CurTime() < (p.hr_execution_setting or 0) then return end
        p.hr_execution_setting = CurTime()+.2
        enabled:SetBool(net.ReadBool())
    end)

    hook.Add('PostEntityTakeDamage', 'hr_player_execution_combat', function(victim, damage, taken)
        local attacker = damage:GetAttacker()
        if not taken or damage:GetDamage() <= 0 or not victim:IsPlayer() or not IsValid(attacker)
            or not attacker:IsPlayer() or attacker == victim then return end
        for _, pair in ipairs({{victim,attacker},{attacker,victim}}) do
            pair[1].hr_execution_combat = pair[1].hr_execution_combat or setmetatable({}, {__mode='k'})
            pair[1].hr_execution_combat[pair[2]] = CurTime()+6
        end
    end)

    function P.Start(w, st)
        local victim, attacker = st.victim, st.player
        st.victimPosition, st.victimAngles = Vector(victim:GetPos()), victim:EyeAngles()
        st.victimCrouching = victim:Crouching()
        st.start = CurTime()+math.Clamp(math.max(attacker:Ping(),victim:Ping())/1000+.08,.12,.35)
        st.weapon = w
        victim:SetNW2Vector('hr_execution_entry_eye',victim:EyePos())
        victim:SetNW2Angle('hr_execution_entry_angle',st.victimAngles)
        victim:SetNW2Entity('hr_execution_controller',w)
        attacker:SetNW2Entity('hr_execution_controller',w)
        w:SetNW2Entity('hr_execution_victim',victim)
        st.body:SetNW2Entity('hr_execution_subject',victim)
        st.body:SetNWVector('hr_player_color',victim:GetPlayerColor()*255)
        victim:SetLocalVelocity(vector_origin)
        attacker:SetLocalVelocity(vector_origin)
        victim:Freeze(true)
    end

    function P.Finish(w, st)
        for _, p in ipairs({st.player,st.victim}) do
            if IsValid(p) and p:IsPlayer() then p:SetNW2Entity('hr_execution_controller',NULL) end
        end
        local victim = st.victim
        if IsValid(victim) and victim:IsPlayer() then
            victim:SetNoDraw(st.oldDraw)
            victim:Freeze(false)
            if victim:Alive() then victim:SetMoveType(st.oldMove) end
            local gun = victim:GetActiveWeapon()
            if IsValid(gun) then gun:SetNoDraw(st.oldGunDraw or false) end
        end
        if IsValid(w) then w:SetNW2Entity('hr_execution_victim',NULL) end
    end

    function P.Valid(st)
        local victim, attacker = st.victim, st.player
        if not IsValid(victim) or not enabled:GetBool() then return false end
        if not st.killed and (not victim:Alive() or victim:HasGodMode()
            or hook.Run('PlayerShouldTakeDamage',victim,attacker) == false
            or DHR.RunHook('HRCanExecutePlayer',attacker,victim) == false) then return false end
        return attacker:GetPos():DistToSqr(st.origin)<64^2 and victim:GetPos():DistToSqr(st.victimPosition)<64^2
    end

    local function cancel(p)
        local st = p.hr_execution
        if st and st.weapon then X.Finish(st.weapon,true) end
    end
    hook.Add('PlayerDeath', 'hr_player_execution', function(victim)
        local st = victim.hr_execution
        if not st or not st.weapon then return end
        if st.victim == victim and st.applyingDamage then
            st.killed = true
            if st.voicePath and IsValid(st.body) then st.body:StopSound(st.voicePath); st.voicePath=nil end
            local rag = victim:GetRagdollEntity()
            if IsValid(rag) then rag:Remove() end
        else cancel(victim) end
    end)
    hook.Add('PlayerSilentDeath','hr_player_execution',cancel)
    hook.Add('PlayerDisconnected','hr_player_execution',cancel)
    hook.Add('PlayerSpawn','hr_player_execution',function(p) cancel(p); p.hr_execution_combat=nil end)
    hook.Add('PlayerDeathThink','hr_player_execution',function(p) if p.hr_execution then return true end end)
    hook.Add('PlayerSwitchWeapon','hr_player_execution',function(p) if p.hr_execution then return true end end)
    hook.Add('PlayerNoClip','hr_player_execution',function(p) if p.hr_execution then return false end end)
    hook.Add('PlayerDeathSound','hr_player_execution',function(p) if p.hr_execution then return true end end)
    return
end

local function controller(p)
    local w = p:GetNW2Entity('hr_execution_controller')
    if IsValid(w) and w:GetNW2Bool('hr_executing') then return w end
end
local function victimWeapon(p)
    local w = controller(p)
    if w and w:GetNW2Entity('hr_execution_victim') == p then return w end
end
hook.Add('StartCommand','hr_player_execution',function(p,cmd)
    local w = controller(p)
    if not w then return end
    cmd:ClearMovement(); cmd:ClearButtons()
    if victimWeapon(p) then cmd:SetViewAngles(p:GetNW2Angle('hr_execution_entry_angle'))
    else cmd:SetViewAngles(w:GetNW2Angle('hr_execution_angle')) end
end)
hook.Add('PreDrawViewModel','hr_player_execution',function() if victimWeapon(LocalPlayer()) then return true end end)
hook.Add('PreDrawPlayerHands','hr_player_execution',function() if victimWeapon(LocalPlayer()) then return true end end)
hook.Add('CalcView','hr_player_execution',function(p,pos,ang,fov)
    local w = victimWeapon(p)
    if not w then return end
    local profile, driver = X.Profile(w), w:GetNW2Entity('hr_execution_driver')
    if not profile or not IsValid(driver) then return {origin=pos,angles=ang,fov=fov,drawviewer=false} end
    local elapsed = math.Clamp(CurTime()-w:GetNW2Float('hr_execution_start'),0,profile.length)
    driver:SetCycle(elapsed/profile.length); driver:InvalidateBoneCache(); driver:SetupBones()
    local head = driver:LookupBone('ValveBiped.Bip01_Head1')
    local matrix = head and driver:GetBoneMatrix(head)
    if not matrix then return end
    local forward = driver:GetAngles():Forward()
    local eye = matrix:GetTranslation()+forward*4+Vector(0,0,3)
    local target = w:GetOwner()
    local look = IsValid(target) and (target:EyePos()-eye):Angle() or ang
    if profile.approach == 'rear' then look = p:GetNW2Angle('hr_execution_entry_angle') end
    look.r = math.Clamp(matrix:GetAngles().r,-12,12)
    local blend = math.Clamp(elapsed/.2,0,1); blend=blend*blend*(3-2*blend)
    return {origin=LerpVector(blend,p:GetNW2Vector('hr_execution_entry_eye'),eye),angles=LerpAngle(blend,p:GetNW2Angle('hr_execution_entry_angle'),look),fov=fov,drawviewer=false}
end)
return P
