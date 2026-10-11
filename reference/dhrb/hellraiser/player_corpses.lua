if SERVER then AddCSLuaFile() end

if SERVER then
    local deaths = setmetatable({}, {__mode = 'k'})
    local corpses = {}

    hook.Add('DoPlayerDeath', 'hr_player_corpse', function(p, attacker, damage)
        deaths[p] = nil
        local eligible, wound = HRDismember.DeathWound(p, damage)
        if not eligible then return end
        deaths[p] = {time = CurTime(), wound = wound, velocity = p:GetVelocity(), force = damage:GetDamageForce(),
            replace = DHR.RunHook('HRCanCreatePlayerCorpse', p, damage) ~= false}
    end)

    function DHR.PlayerCorpseReady(p, rag)
        local state = deaths[p]
        if not IsValid(p) or not p:IsPlayer() or p:Alive() or not state or p.hr_execution
            or not IsValid(rag) or not rag:IsRagdoll() then return false end
        local body = DHR.GetBodyState(rag)
        if body.alive or body.owner and body.owner ~= p then return false end
        if state.corpse then return state.corpse == rag end
        if not GetConVar('hr_dismember_players'):GetBool()
            or DHR.RunHook('DHRCanDismember', rag, nil, 'corpse') == false then return false end
        state.corpse = rag
        rag:SetNWInt('hr_blood_color', HRDismember.BloodColor(p))
        rag:SetNWBool('hr_player_corpse', true)
        rag:SetNWVector('hr_player_color', p:GetPlayerColor()*255)
        if state.wound and GetConVar('hr_dismember_living'):GetBool() then
            for part in pairs(state.wound.parts) do
                HRDismember.Apply(rag, part, state.force:GetNormalized()*130 + Vector(0,0,75), nil, false, state.wound.destroyed)
            end
        end
        DHR.RunHook('DHRPlayerCorpseReady', p, rag)
        return true
    end

    hook.Add('PostPlayerDeath', 'hr_player_corpse', function(p)
        local state = deaths[p]
        if not state or not state.replace or state.corpse or state.time ~= CurTime() or p:Alive() or p.hr_execution then return end
        local previous = p:GetRagdollEntity()
        -- Custom gamemodes may provide their own corpse or deliberately omit it.
        if not IsValid(previous) or previous:GetClass() ~= 'hl2mp_ragdoll' then return end
        local rag = ents.Create('prop_ragdoll')
        if not IsValid(rag) then return end
        rag:SetModel(p:GetModel())
        rag:SetModelScale(p:GetModelScale(), 0)
        rag:SetPos(p:GetPos())
        rag:SetAngles(p:GetAngles())
        rag:SetSkin(p:GetSkin())
        rag:SetColor(p:GetColor())
        rag:SetMaterial(p:GetMaterial())
        for _, group in ipairs(p:GetBodyGroups()) do rag:SetBodygroup(group.id, p:GetBodygroup(group.id)) end
        for slot = 0, #p:GetMaterials() - 1 do rag:SetSubMaterial(slot, p:GetSubMaterial(slot)) end
        rag:SetNWInt('hr_blood_color', HRDismember.BloodColor(p))
        rag:SetNWBool('hr_player_corpse', true)
        rag:SetNWVector('hr_player_color', p:GetPlayerColor()*255)
        rag:Spawn()
        rag:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
        if rag:GetPhysicsObjectCount() == 0 then rag:Remove() return end
        local velocity = state.velocity + state.force:GetNormalized() * 60
        if velocity:LengthSqr() > 400^2 then velocity = velocity:GetNormalized() * 400 end
        for index = 0, rag:GetPhysicsObjectCount() - 1 do
            local physics = rag:GetPhysicsObjectNum(index)
            local bone = p:LookupBone(rag:GetBoneName(rag:TranslatePhysBoneToBone(index)))
            if IsValid(physics) and bone then
                local pos, ang = p:GetBonePosition(bone)
                if pos then
                    physics:SetPos(pos)
                    physics:SetAngles(ang)
                    physics:SetVelocity(velocity)
                    physics:Wake()
                end
            end
        end
        if not DHR.PlayerCorpseReady(p, rag) then rag:Remove() return end
        p:SetNW2Entity('hr_dismember_corpse', rag)
        previous:Remove()
        rag:SetCreator(p)
        p:AddCleanup('ragdolls', rag)
        for index = #corpses, 1, -1 do
            if not IsValid(corpses[index]) then table.remove(corpses, index) end
        end
        corpses[#corpses+1] = rag
        if #corpses > 32 then table.remove(corpses, 1):Remove() end
        timer.Simple(120, function() if IsValid(rag) then rag:Remove() end end)
    end)

    hook.Add('PlayerSpawn', 'hr_player_corpse', function(p)
        deaths[p] = nil
        p:SetNW2Entity('hr_dismember_corpse', NULL)
    end)
    hook.Add('PlayerDisconnected', 'hr_player_corpse', function(p)
        deaths[p] = nil
        for _, rag in ipairs(corpses) do
            if IsValid(rag) and rag:GetCreator() == p then rag:Remove() end
        end
    end)
    hook.Add('PostCleanupMap', 'hr_player_corpse', function()
        deaths = setmetatable({}, {__mode = 'k'})
        corpses = {}
        for _, p in ipairs(player.GetAll()) do p:SetNW2Entity('hr_dismember_corpse', NULL) end
    end)
    return
end

local function playerColor(rag)
    return rag:GetNWVector('hr_player_color', Vector(255,255,255))/255
end
local nextScan = 0
hook.Add('Think', 'hr_player_corpse_color', function()
    if CurTime() < nextScan then return end
    nextScan = CurTime() + .2
    for _, rag in ipairs(ents.FindByClass('prop_ragdoll')) do
        if rag:GetNWBool('hr_player_corpse') then rag.GetPlayerColor = playerColor end
    end
end)

hook.Add('CalcView', 'hr_player_corpse', function(p, origin, angles, fov)
    if p:Alive() or p:GetViewEntity() ~= p or IsValid(p:GetNW2Entity('hr_execution_controller')) then return end
    local mode = p:GetObserverMode()
    if mode ~= OBS_MODE_NONE and mode ~= OBS_MODE_DEATHCAM then return end
    local rag = p:GetNW2Entity('hr_dismember_corpse')
    if not IsValid(rag) or not DHR.CanUseFeature(p, 'death_camera', p:GetActiveWeapon()) then return end
    local focus = rag:WorldSpaceCenter() + Vector(0,0,16)
    local tr = util.TraceHull({start = focus, endpos = focus - angles:Forward()*90,
        mins = Vector(-4,-4,-4), maxs = Vector(4,4,4), filter = {p,rag}, mask = MASK_SOLID})
    return {origin = tr.HitPos, angles = angles, fov = fov, drawviewer = false}
end)
