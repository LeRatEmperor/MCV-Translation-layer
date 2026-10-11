HRDualBody = HRDualBody or {}
local B = HRDualBody
local states = {}
local prefix = "ValveBiped.Bip01_"
local mirror = Matrix()
mirror:SetScale(Vector(1, 1, -1))
local reflection = Matrix()
reflection:SetScale(Vector(1, -1, 1))

local function place(pose, raw, transform, side)
    if not pose.dhr_body_callback then
        pose.dhr_body_callback = pose:AddCallback("BuildBonePositions", function(model)
            if not model.dhr_body_transform then return end
            for bone, matrix in pairs(model.dhr_body_bones or {}) do
                if model:GetBoneMatrix(bone) then model:SetBoneMatrix(bone, model.dhr_body_transform * matrix) end
            end
        end)
    end
    pose.dhr_body_transform = transform
    pose.dhr_body_bones = raw
    for bone, matrix in pairs(raw) do
        if pose:GetBoneMatrix(bone) then pose:SetBoneMatrix(bone, transform * matrix) end
    end
    pose.dhr_mirrored = side == 1
    return pose
end

local function readAttachments(pose)
    pose.dhr_body_attachments = {}
    for _, attachment in ipairs(pose:GetAttachments()) do
        pose.dhr_body_attachments[attachment.name] = pose:GetAttachment(attachment.id)
    end
end

local function referenceGrip(weapon, side)
    local gun = weapon:Gun(side)
    if gun.body_grip then return gun.body_grip end
    local pose = HRPose.Sample(weapon, "dual_grip_" .. side, gun.model, gun.config.seq.idle, 0, vector_origin, angle_zero)
    if not IsValid(pose) then return end
    local bone = pose:LookupBone(prefix .. "R_Hand")
    local hand = bone and pose:GetBoneMatrix(bone)
    local muzzle = pose:GetAttachment(pose:LookupAttachment("muzzle"))
    if not hand or not muzzle then return end
    local axis = Matrix()
    axis:SetAngles(muzzle.Ang)
    gun.body_grip = axis:GetInverse() * hand
    return gun.body_grip
end

local function posePlayer(player)
    local state = states[player]
    if not state or not IsValid(state.weapon) then return end
    local base = {}
    for i = 0, player:GetBoneCount() - 1 do base[i] = player:GetBoneMatrix(i) end
    local aim = Matrix()
    aim:SetAngles(player:EyeAngles())
    for side = 1, 2 do
        local name = side == 1 and "L" or "R"
        local hand = player:LookupBone(prefix .. name .. "_Hand")
        local grip = state.grips[side]
        if base[hand] and grip then
            local orientation = side == 1 and aim * reflection * grip * mirror or aim * grip
            local goal = Matrix(base[hand])
            goal:SetAngles(orientation:GetAngles())
            HRThirdPerson.PoseArm(player, base, name, goal)
        end
    end
    if state.weight == 0 then state.fitted = FrameNumber(); return end
    if not state.raw then return end
    local active = state.side == 1 and "L" or "R"
    local other = active == "L" and "R" or "L"
    local hand = player:LookupBone(prefix .. active .. "_Hand")
    local otherHand = player:LookupBone(prefix .. other .. "_Hand")
    if not base[hand] or not base[otherHand] then return end
    local goal = Matrix(base[hand])
    local eye = player:EyePos()
    local facing = Angle(0, player:EyeAngles().y, 0)
    local direction = state.side == 1 and -1 or 1
    local target = eye + facing:Forward() * 18 + facing:Right() * direction * 7 - Vector(0, 0, 17)
    goal:SetTranslation(LerpVector(state.weight, goal:GetTranslation(), target))
    local angle = goal:GetAngles()
    angle:RotateAroundAxis(facing:Forward(), direction * 8 * state.weight)
    goal:SetAngles(angle)
    local sourceHand = state.pose:LookupBone(prefix .. "R_Hand")
    local supportHand = state.pose:LookupBone(prefix .. "L_Hand")
    local source = state.raw[sourceHand]
    local inverse = source and source:GetInverse()
    if not inverse or not state.raw[supportHand] then return end
    HRThirdPerson.PoseArm(player, base, active, goal)
    local transform = goal * (state.side == 1 and mirror or Matrix()) * inverse
    local support = transform * state.raw[supportHand]
    if state.side == 1 then support = support * mirror end
    support:SetTranslation(LerpVector(state.weight, base[otherHand]:GetTranslation(), support:GetTranslation()))
    support:SetAngles(LerpAngle(state.weight, base[otherHand]:GetAngles(), support:GetAngles()))
    HRThirdPerson.PoseArm(player, base, other, support)

    state.transform = transform
    state.fitted = FrameNumber()
    local head = player:LookupBone(prefix .. "Head1")
    if base[head] then
        local skull = Matrix(base[head])
        local look = skull:GetAngles()
        look:RotateAroundAxis(facing:Right(), -12 * state.weight)
        skull:SetAngles(look)
        player:SetBoneMatrix(head, skull)
    end
end

local function clear(player)
    local state = states[player]
    if not state then return end
    if IsValid(player) then player:RemoveCallback("BuildBonePositions", state.callback); player:InvalidateBoneCache() end
    states[player] = nil
end

local function prepare(player, weapon)
    if not IsValid(player) or not player:IsPlayer() or not IsValid(weapon) or not weapon.DualWield or not player:Alive() or player:InVehicle()
        or player == LocalPlayer() and not player:ShouldDrawLocalPlayer() then clear(player); return end
    local side = weapon:ServiceHand()
    local state = states[player]
    if state and state.frame == FrameNumber() then return state end
    if not state then
        state = {weight = 0, weapon = weapon, side = side, grips = {}}
        states[player] = state
        state.callback = player:AddCallback("BuildBonePositions", posePlayer)
    end
    if state.weapon ~= weapon then clear(player); return end
    state.weight = math.Approach(state.weight, side ~= 0 and 1 or 0, FrameTime() * 6)
    for hand = 1, 2 do state.grips[hand] = referenceGrip(weapon, hand) end
    state.frame = FrameNumber()
    if state.weight == 0 then
        state.raw = nil
        player:InvalidateBoneCache()
        return state
    end
    if side ~= 0 then state.side = side end
    local gun = weapon:Gun(state.side)
    local sequence, started, finish = weapon:DualSequence(state.side)
    local cycle = math.Clamp((CurTime() - started) / math.max(finish - started, .01), 0, 1)
    if IsValid(state.pose) then state.pose.dhr_body_transform = nil end
    local pose = HRPose.Sample(weapon, "dual_body_" .. state.side, gun.model, sequence, cycle, player:EyePos(), player:EyeAngles())
    if not IsValid(pose) then clear(player); return end
    for _, group in ipairs(pose:GetBodyGroups()) do
        if string.StartWith(group.name, "aidan_") then pose:SetBodygroup(group.id, 1) end
    end
    weapon:WithGun(state.side, weapon.ApplyAnimatedParts, pose)
    pose:InvalidateBoneCache(); pose:SetupBones()
    readAttachments(pose)
    state.raw = {}
    for i = 0, pose:GetBoneCount() - 1 do state.raw[i] = pose:GetBoneMatrix(i) end
    state.pose, state.frame = pose, FrameNumber()
    state.fitted = nil
    player:AnimResetGestureSlot(GESTURE_SLOT_ATTACK_AND_RELOAD)
    player:InvalidateBoneCache()
    return state
end

hook.Add("PrePlayerDraw", "dhr_dual_reload", function(player) prepare(player, player:GetActiveWeapon()) end)

function B.Model(weapon, side)
    local player = weapon:GetOwner()
    if not IsValid(player) or not player:IsPlayer() then return end
    local state = prepare(player, weapon)
    if not state or state.weight == 0 or not state.raw or state.side ~= side then return end
    if state.fitted ~= FrameNumber() then player:SetupBones() end
    if state.fitted ~= FrameNumber() or not state.transform then return end
    return place(state.pose, state.raw, state.transform, side)
end

function B.Held(weapon, side, hand)
    local gun = weapon:Gun(side)
    local sequence, started, finish = weapon:DualSequence(side)
    weapon.dhr_held_pose = weapon.dhr_held_pose or {}
    local previous = weapon.dhr_held_pose[side]
    if IsValid(previous) then previous.dhr_body_transform = nil end
    local cycle = math.Clamp((CurTime() - started) / math.max(finish - started, .01), 0, 1)
    local owner = weapon:GetOwner()
    local pose = HRPose.Sample(weapon, "dual_held_" .. side, gun.model, sequence, cycle, owner:EyePos(), owner:EyeAngles())
    if not IsValid(pose) then return end
    weapon.dhr_held_pose[side] = pose
    for _, group in ipairs(pose:GetBodyGroups()) do
        if string.StartWith(group.name, "aidan_") then pose:SetBodygroup(group.id, 1) end
    end
    readAttachments(pose)
    local raw = {}
    for i = 0, pose:GetBoneCount() - 1 do raw[i] = pose:GetBoneMatrix(i) end
    local grip = pose:LookupBone(prefix .. "R_Hand")
    local inverse = raw[grip] and raw[grip]:GetInverse()
    if not inverse then return end
    weapon:WithGun(side, weapon.ApplyUpgradeParts, pose)
    local transform = hand * (side == 1 and mirror or Matrix()) * inverse
    return place(pose, raw, transform, side)
end

function B.Hidden(weapon, side)
    local state = prepare(weapon:GetOwner(), weapon)
    return state and state.weight > 0 and state.side ~= side
end

function B.Attachment(model, name)
    local attachment = model.dhr_body_attachments and model.dhr_body_attachments[name]
    local transform = model.dhr_body_transform
    if not attachment or not transform then return model:GetAttachment(model:LookupAttachment(name)) end
    local position = transform * attachment.Pos
    local forward = transform * (attachment.Pos + attachment.Ang:Forward()) - position
    local up = transform * (attachment.Pos + attachment.Ang:Up()) - position
    return {Pos = position, Ang = forward:AngleEx(up)}
end

hook.Add("Think", "dhr_dual_reload", function()
    for player, state in pairs(states) do
        if not IsValid(player) or not player:Alive() or not IsValid(state.weapon) or player:GetActiveWeapon() ~= state.weapon
            or player:InVehicle() then clear(player) end
    end
end)
hook.Add("PreCleanupMap", "dhr_dual_reload", function() for player in pairs(states) do clear(player) end end)
