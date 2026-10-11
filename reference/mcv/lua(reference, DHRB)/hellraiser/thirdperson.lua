HRThirdPerson = HRThirdPerson or {}
local T = HRThirdPerson
local states = {}
local clear
local prefix = 'ValveBiped.Bip01_'

local function bendDirection(pole, axis)
	local direction = pole - axis * pole:Dot(axis)
	if direction:LengthSqr() < .000001 then
		local fallback = math.abs(axis.z) < .9 and Vector(0, 0, 1) or Vector(1, 0, 0)
		direction = fallback - axis * fallback:Dot(axis)
	end
	return direction:GetNormalized()
end

local function rotateBone(matrix, from, to, position, scale)
	from, to = from:GetNormalized(), to:GetNormalized()
	local axis = from:Cross(to)
	local angle = matrix:GetAngles()
	if axis:LengthSqr() > .000001 then
		angle:RotateAroundAxis(axis:GetNormalized(), math.deg(math.acos(math.Clamp(from:Dot(to), -1, 1))))
	elseif from:Dot(to) < 0 then
		angle:RotateAroundAxis(bendDirection(Vector(0, 0, 1), from), 180)
	end
	local result = Matrix()
	result:SetTranslation(position)
	result:SetAngles(angle)
	result:SetScale(scale)
	return result
end

local function limbMatrix(matrix, from, to, oldPlane, newPlane, position)
	if oldPlane:LengthSqr() < .001 or newPlane:LengthSqr() < .001 then
		return rotateBone(matrix, from, to, position, matrix:GetScale())
	end
	local old, new = Matrix(), Matrix()
	old:SetAngles(from:AngleEx(oldPlane:GetNormalized()))
	new:SetAngles(to:AngleEx(newPlane:GetNormalized()))
	local result = new * old:GetInverse() * matrix
	result:SetTranslation(position)
	result:SetScale(matrix:GetScale())
	return result
end

local bodyData = DHR.LoadData('hellraiser/thirdperson_data.lua', {bones = {}, animations = {}})

local EYES = Vector(3.4, -4, 0)

local function carry(p, base, id, matrix)
	local inverse = base[id] and base[id]:GetInverse()
	if not inverse then return end
	local delta = matrix * inverse
	for i = id + 1, p:GetBoneCount() - 1 do
		local parent = p:GetBoneParent(i)
		while parent >= 0 and parent ~= id do parent = p:GetBoneParent(parent) end
		if parent == id and base[i] then base[i] = delta * base[i] end
	end
	base[id] = matrix
end

function T.PoseArm(player, base, side, goal)
    local upper = player:LookupBone(prefix .. side .. '_UpperArm')
    local fore = player:LookupBone(prefix .. side .. '_Forearm')
    local hand = player:LookupBone(prefix .. side .. '_Hand')
    local u, f, h = base[upper], base[fore], base[hand]
    if not u or not f or not h then return end
    local shoulder, elbow, wrist = u:GetTranslation(), f:GetTranslation(), h:GetTranslation()
    local a, b = shoulder:Distance(elbow), elbow:Distance(wrist)
    local axis = (goal:GetTranslation() - shoulder):GetNormalized()
    local distance = math.Clamp(goal:GetTranslation():Distance(shoulder), math.abs(a - b) + .01, a + b - .01)
    local target = shoulder + axis * distance
    local pole = bendDirection(Vector(0, 0, -1) + player:GetRight() * (side == 'R' and .3 or -.3), axis)
    local along = (a*a + distance*distance - b*b) / (2*distance)
    local joint = shoulder + axis * along + pole * math.sqrt(math.max(0, a*a - along*along))
    local upperPose = rotateBone(u, elbow - shoulder, joint - shoulder, shoulder, u:GetScale())
    local forePose = rotateBone(f, wrist - elbow, target - joint, joint, f:GetScale())
    local handPose = Matrix(goal)
    handPose:SetTranslation(target)
    handPose:SetScale(h:GetScale())
    carry(player, base, upper, upperPose)
    carry(player, base, fore, forePose)
    carry(player, base, hand, handPose)
    for bone, matrix in pairs(base) do
        local parent = bone
        while parent >= 0 and parent ~= upper do parent = player:GetBoneParent(parent) end
        if parent == upper and player:GetBoneName(bone) ~= '__INVALIDBONE__' then player:SetBoneMatrix(bone, matrix) end
    end
    goal:SetTranslation(target)
end

local function executionBody(p, state, base)
	local body = state.body
	if not body or not state.eye or not state.weapon:GetNW2Bool('hr_executing') then return end
	local pelvis, chest, head = p:LookupBone(prefix..'Pelvis'), p:LookupBone(prefix..'Spine4'), p:LookupBone(prefix..'Head1')
	if not base[pelvis] or not base[chest] or not base[head] then return end
	local hip, top = base[pelvis], base[chest]
	local direction = LerpVector(body.weight, top:GetTranslation()-hip:GetTranslation(), body.spine_03-body.pelvis)
	local placed = rotateBone(hip, top:GetTranslation()-hip:GetTranslation(), direction, hip:GetTranslation(), hip:GetScale())
	local inverse = hip:GetInverse()
	if not inverse then return end
	local feet = {}
	for _, side in ipairs({'L', 'R'}) do
		local id = p:LookupBone(prefix..side..'_Foot')
		if base[id] then feet[side] = Matrix(base[id]) end
	end
	local delta = placed * inverse
	for i, matrix in pairs(base) do base[i] = delta * matrix end

	local skull = base[head]
	local face = skull * Vector(0, -1, 0) - skull:GetTranslation()
	local look = state.look:Forward()
	if face:Dot(look) < math.cos(math.rad(70)) then look = face*math.cos(math.rad(70)) + bendDirection(look, face)*math.sin(math.rad(70)) end
	carry(p, base, head, rotateBone(skull, face, LerpVector(body.weight, face, look), skull:GetTranslation(), skull:GetScale()))
	local shift = (state.eye - base[head] * EYES) * body.weight

	local highest
	for _, side in ipairs({'L', 'R'}) do
		local thigh, calf, foot = p:LookupBone(prefix..side..'_Thigh'), p:LookupBone(prefix..side..'_Calf'), p:LookupBone(prefix..side..'_Foot')
		if base[thigh] and base[calf] and base[foot] then
			local leg = base[thigh]:GetTranslation():Distance(base[calf]:GetTranslation()) + base[calf]:GetTranslation():Distance(base[foot]:GetTranslation())
			local limit = body['ground_'..side].z + leg*.97 - base[thigh]:GetTranslation().z
			highest = highest and math.min(highest, limit) or limit
		end
	end
	if highest and shift.z > highest then shift.z = highest end
	for _, matrix in pairs(base) do matrix:SetTranslation(matrix:GetTranslation() + shift) end

	for _, side in ipairs({'L', 'R'}) do
		local thigh, calf, foot = p:LookupBone(prefix..side..'_Thigh'), p:LookupBone(prefix..side..'_Calf'), p:LookupBone(prefix..side..'_Foot')
		local u, f, h = base[thigh], base[calf], base[foot]
		if not u or not f or not h then continue end
		local start, knee, ankle = u:GetTranslation(), f:GetTranslation(), h:GetTranslation()
		local target = LerpVector(body.weight, ankle, body['ground_'..side])
		local lengthA, lengthB = start:Distance(knee), knee:Distance(ankle)
		local reach, drop = (lengthA+lengthB)*.99, start.z-target.z
		local flat = Vector(target.x-start.x, target.y-start.y, 0)
		if drop < reach and flat:Length() > math.sqrt(reach*reach-drop*drop) then
			flat = flat:GetNormalized() * math.sqrt(reach*reach-drop*drop)
			target = Vector(start.x+flat.x, start.y+flat.y, target.z)
		end
		local distance = math.Clamp(start:Distance(target), math.abs(lengthA-lengthB)+.01, lengthA+lengthB-.01)
		local axis = (target-start):GetNormalized()
		target = start + axis * distance
		local sourceThigh, sourceKnee, sourceFoot = body['thigh_'..side:lower()], body['calf_'..side:lower()], body['foot_'..side:lower()]
		local sourceAxis = (sourceFoot-sourceThigh):GetNormalized()
		local pole = bendDirection(sourceKnee-sourceThigh, sourceAxis)
		pole = bendDirection(pole, axis)
		local along = (lengthA*lengthA+distance*distance-lengthB*lengthB)/(2*distance)
		local joint = start + axis * along + pole * math.sqrt(math.max(0, lengthA*lengthA-along*along))
		local oldPlane = (knee-start):Cross(ankle-knee)
		local newPlane = (joint-start):Cross(target-joint)
		base[thigh] = limbMatrix(u, knee-start, joint-start, oldPlane, newPlane, start)
		base[calf] = limbMatrix(f, ankle-knee, target-joint, oldPlane, newPlane, joint)
		local oldFoot = Matrix(h)
		base[foot] = feet[side] or Matrix(h)
		base[foot]:SetTranslation(target)
		local footInverse = oldFoot:GetInverse()
		if footInverse then
			local moved = base[foot] * footInverse
			for i = foot+1, p:GetBoneCount()-1 do
				local parent = p:GetBoneParent(i)
				while parent >= 0 and parent ~= foot do parent = p:GetBoneParent(parent) end
				if parent == foot and base[i] then base[i] = moved * base[i] end
			end
		end
	end
	for i, matrix in pairs(base) do
		if p:GetBoneName(i) ~= '__INVALIDBONE__' then p:SetBoneMatrix(i, matrix) end
	end
end

local function sampleBody(p, w, pose, profile, cycle)
	local frames = bodyData.animations[profile.player_animation]
	if not frames then return end
	local frame = cycle*(#frames-1)
	local index = math.floor(frame)+1
	local a, b = frames[index], frames[math.min(index+1, #frames)]
	local scale = profile.player_scale or 1
	local elapsed = CurTime()-w:GetNW2Float('hr_execution_start')
	local weight = math.Clamp(elapsed/.22, 0, 1)
	local body = {weight=weight*weight*(3-2*weight)}
	for i, name in ipairs(bodyData.bones) do
		local point = LerpVector(frame%1, Vector(a[i][1], a[i][2], a[i][3]), Vector(b[i][1], b[i][2], b[i][3])) * scale
		body[name] = LocalToWorld(point, angle_zero, w:GetNW2Vector('hr_execution_origin'), w:GetNW2Angle('hr_execution_angle'))
		if name == 'foot_l' or name == 'foot_r' then
			local target = Vector(body[name])
			local trace = util.TraceLine({start=target+Vector(0,0,48), endpos=target-Vector(0,0,80),
				filter={p, w, w:GetNW2Entity('hr_execution_body'), w:GetNW2Entity('hr_execution_driver')}, mask=MASK_PLAYERSOLID_BRUSHONLY})
			if trace.Hit then target.z = trace.HitPos.z + 3.5*p:GetModelScale() + Lerp(frame%1, a[i][4], b[i][4])*scale end
			body['ground_'..string.upper(name:sub(-1))] = target
		end
	end
	return body
end

local function posePlayer(p)
	local state = states[p]
	if not state or not IsValid(state.weapon) or not IsValid(state.pose) or not p:Alive() then return end
	if p == LocalPlayer() and not p:ShouldDrawLocalPlayer() then return end
	local source, base, posed = state.pose, {}, {}
	for i = 0, p:GetBoneCount()-1 do base[i] = p:GetBoneMatrix(i) end
	executionBody(p, state, base)
	local right = p:LookupBone(prefix..'R_Hand')
	local sourceRight = source:LookupBone('w_root')
	local grip = state.raw[sourceRight]
	if not base[right] or not grip or not state.reference or not state.referenceHand then return end

	local inverse = state.reference:GetInverse()
	local gripInverse = grip:GetInverse()
	if not inverse or not gripInverse then return end
	local relative = inverse * grip
	local motion = Matrix()
	local strength = .3
	motion:SetTranslation(relative:GetTranslation() * strength)
	motion:SetAngles(LerpAngle(strength, angle_zero, relative:GetAngles()))
	local anchor = Matrix()
	anchor:SetTranslation(base[right]:GetTranslation() - state.referenceHand:GetTranslation())
	local placement = state.executing and Matrix() or anchor * state.reference * motion * gripInverse
	if not state.executing and HRWall then placement = HRWall.Placement(p, state.weapon, placement, base[right]:GetTranslation()) end
	placement = DHRBash.Placement(p, state.weapon, placement, base[right]:GetTranslation())
	local targets = {}
	for _, side in ipairs({'R', 'L'}) do
		local id = source:LookupBone(prefix..side..'_Hand')
		if state.raw[id] then targets[side] = (placement * state.raw[id]):GetTranslation() end
	end

	local shift = Vector()
	if not state.body then
		for _ = 1, 6 do
			for _, side in ipairs({'R', 'L'}) do
				local u, f, h = p:LookupBone(prefix..side..'_UpperArm'), p:LookupBone(prefix..side..'_Forearm'), p:LookupBone(prefix..side..'_Hand')
				if base[u] and base[f] and base[h] and targets[side] then
					local reach = base[u]:GetTranslation():Distance(base[f]:GetTranslation()) + base[f]:GetTranslation():Distance(base[h]:GetTranslation()) - .2
					local toward = targets[side] + shift - base[u]:GetTranslation()
					local excess = toward:Length() - reach
					if excess > 0 then shift = shift - toward:GetNormalized() * excess * .75 end
				end
			end
		end
		local upper, fore = p:LookupBone(prefix..'R_UpperArm'), p:LookupBone(prefix..'R_Forearm')
		local shoulder = base[upper]:GetTranslation()
		local reach = shoulder:Distance(base[fore]:GetTranslation()) + base[fore]:GetTranslation():Distance(base[right]:GetTranslation()) - .01
		local toward = targets.R + shift - shoulder
		if toward:Length() > reach then shift = shift - toward:GetNormalized() * (toward:Length()-reach) end
	end
	placement:SetTranslation(placement:GetTranslation() + shift)
	source.hr_thirdperson_transform = placement
	source.hr_thirdperson_bones = state.raw
	for i, matrix in pairs(state.raw) do
		if source:GetBoneName(i) ~= '__INVALIDBONE__' then source:SetBoneMatrix(i, placement * matrix) end
	end

	for _, side in ipairs({'L', 'R'}) do
		local upper, fore, hand = p:LookupBone(prefix..side..'_UpperArm'), p:LookupBone(prefix..side..'_Forearm'), p:LookupBone(prefix..side..'_Hand')
		local su, sf, sh = source:LookupBone(prefix..side..'_UpperArm'), source:LookupBone(prefix..side..'_Forearm'), source:LookupBone(prefix..side..'_Hand')
		local u, f, h = base[upper], base[fore], base[hand]
		local a, b, c = source:GetBoneMatrix(su), source:GetBoneMatrix(sf), source:GetBoneMatrix(sh)
		if not u or not f or not h or not a or not b or not c then continue end
		local shoulder, elbow, wrist = u:GetTranslation(), f:GetTranslation(), h:GetTranslation()
		local lengthA, lengthB = shoulder:Distance(elbow), elbow:Distance(wrist)
		local goal = c:GetTranslation()
		local distance = math.Clamp(goal:Distance(shoulder), math.abs(lengthA-lengthB)+.001, lengthA+lengthB-.001)
		local axis = (goal-shoulder):GetNormalized()
		goal = shoulder + axis * distance
		local pole = Vector(0, 0, -1) + p:GetRight() * (side == 'R' and .2 or -.2)
		if state.executing then
			local sourceAxis = (c:GetTranslation()-a:GetTranslation()):GetNormalized()
			pole = bendDirection(b:GetTranslation()-a:GetTranslation(), sourceAxis)
		end
		pole = bendDirection(pole, axis)
		local reach = (lengthA*lengthA + distance*distance - lengthB*lengthB)/(2*distance)
		local joint = shoulder + axis * reach + pole * math.sqrt(math.max(0, lengthA*lengthA - reach*reach))
		local oldPlane = (elbow-shoulder):Cross(wrist-elbow)
		local newPlane = (joint-shoulder):Cross(goal-joint)
		if state.executing then
			posed[upper] = limbMatrix(u, elbow-shoulder, joint-shoulder, oldPlane, newPlane, shoulder)
			posed[fore] = limbMatrix(f, wrist-elbow, goal-joint, oldPlane, newPlane, joint)
		else
			posed[upper] = rotateBone(u, elbow-shoulder, joint-shoulder, shoulder, u:GetScale())
			posed[fore] = rotateBone(f, wrist-elbow, goal-joint, joint, f:GetScale())
		end
		posed[hand] = Matrix(c)
		posed[hand]:SetTranslation(goal)
		posed[hand]:SetScale(h:GetScale())
	end

	local head = p:LookupBone(prefix..'Head1')
	local root = source:LookupBone('w_root')
	local gun = root and source:GetBoneMatrix(root)
	if head and base[head] and gun and state.reload > .001 then
		local direction = (gun:GetTranslation()-base[head]:GetTranslation()):Angle()
		local yaw = math.Clamp(math.AngleDifference(direction.y, p:GetAngles().y), -20, 20)
		local pitch = math.Clamp(direction.p, 0, 35)
		local angle = base[head]:GetAngles()
		angle:RotateAroundAxis(p:GetRight(), -pitch * state.reload)
		angle:RotateAroundAxis(Vector(0, 0, 1), yaw * state.reload)
		posed[head] = Matrix(base[head])
		posed[head]:SetAngles(angle)
	end

	for i = 0, p:GetBoneCount()-1 do
		local name, parent = p:GetBoneName(i), p:GetBoneParent(i)
		if name == '__INVALIDBONE__' then continue end
		if not posed[i] and posed[parent] and base[parent] and base[i] then
			local inverse = base[parent]:GetInverse()
			if inverse then
				local localBone = inverse * base[i]
				local target = source:LookupBone(name)
				local targetParent = target and source:GetBoneParent(target)
				local matrix, ancestor = target and source:GetBoneMatrix(target), targetParent and source:GetBoneMatrix(targetParent)
				if name:find('_Finger', 1, true) and matrix and ancestor then
					local inv = ancestor:GetInverse()
					if inv then localBone:SetAngles((inv * matrix):GetAngles()) end
				end
				posed[i] = posed[parent] * localBone
			end
		end
		if posed[i] then p:SetBoneMatrix(i, posed[i]) end
	end
	if not state.executing and HRWall then HRWall.Body(p, state.weapon) end
	state.fitted = FrameNumber()
end

local function prepare(p, w)
	if IsValid(w) and not DHR.HasFeature(w, "thirdperson") then
        if states[p] then clear(p) end
        return
    end
	if not IsValid(w) or not w.HR or not w.HR.world or not w.GetPoseSequence or not p:Alive() or p:InVehicle() then return end
	if p == LocalPlayer() and not p:ShouldDrawLocalPlayer() then return end
	if w.HR.kind == 'melee' and not w:GetNW2Bool('hr_executing') then
		if states[p] then clear(p) end
		return
	end
	for _, side in ipairs({'L', 'R'}) do
		for _, bone in ipairs({'UpperArm', 'Forearm', 'Hand'}) do
			if not p:LookupBone(prefix..side..'_'..bone) then return end
		end
	end
	local state = states[p]
	if not state then state = {reload=0}; states[p] = state; state.callback = p:AddCallback('BuildBonePositions', posePlayer) end
	if state.frame == FrameNumber() and state.weapon == w and state.executing == w:GetNW2Bool('hr_executing') then return state end
	local model, sequence, cycle = w.ViewModel, w:GetPoseSequence(), 0
	local pos, ang = p:EyePos(), p:EyeAngles()
	local executing = w:GetNW2Bool('hr_executing')
	local reference = w.HR.seq.idle
	if istable(reference) then reference = reference[1] end
	if executing then
		local profile = HRExecutions.Profile(w)
		if not profile then return end
		model, sequence = profile.view_model, profile.sequence
		local t = math.Clamp(CurTime()-w:GetNW2Float('hr_execution_start'), 0, profile.length)
		cycle = t/profile.length
		local frame = cycle*(#profile.camera-1)
		local i = math.floor(frame)+1
		local a, b = profile.camera[i], profile.camera[math.min(i+1, #profile.camera)]
		local scale = profile.player_scale or 1
		local offset = LerpVector(frame%1, Vector(a[1], a[2], a[3]), Vector(b[1], b[2], b[3]))*scale
		local rotation = LerpAngle(frame%1, Angle(a[4], a[5], a[6]), Angle(b[4], b[5], b[6]))
		pos, ang = LocalToWorld(offset, rotation, w:GetNW2Vector('hr_execution_origin')+Vector(0, 0, profile.eye_height*scale), w:GetNW2Angle('hr_execution_angle'))
		local entry = math.Clamp(t/.18, 0, 1); entry = entry*entry*(3-2*entry)
		pos = LerpVector(entry, w:GetNW2Vector('hr_execution_entry_eye'), pos)
		ang = LerpAngle(entry, w:GetNW2Angle('hr_execution_entry_angle'), ang)

		reference = sequence
	else
		if sequence == '' then return end
		local duration = math.max(w:SeqLen(sequence), .01)
		cycle = (CurTime()-w:GetPoseStart()) * math.max(w:GetPoseRate(), .01)/duration
		if sequence == w:GetBaseSeq() then cycle = cycle%1 else cycle = math.Clamp(cycle, 0, 1) end
	end
	if IsValid(state.pose) then state.pose.hr_thirdperson_transform = nil end
	local pose = HRPose.Sample(w, 'thirdperson', model, sequence, cycle, pos, ang)
	local idle = HRPose.Sample(w, 'thirdperson_reference', model, reference, 0, pos, ang)
	if not pose or not idle then return end
	if not pose.hr_thirdperson_callback then
		pose.hr_thirdperson_callback = pose:AddCallback('BuildBonePositions', function(model)
			local transform = model.hr_thirdperson_transform
			if not transform then return end
			for i, matrix in pairs(model.hr_thirdperson_bones or {}) do
				if model:GetBoneName(i) ~= '__INVALIDBONE__' then model:SetBoneMatrix(i, transform * matrix) end
			end
		end)
	end
	for _, group in ipairs(pose:GetBodyGroups()) do
		if string.StartWith(group.name, 'aidan_') then pose:SetBodygroup(group.id, 1) end
	end
	pose:SetModelScale(executing and (HRExecutions.Profile(w).player_scale or 1) or 1, 0)
	w:ApplyAnimatedParts(pose)
	pose:InvalidateBoneCache(); pose:SetupBones()
	if executing then
		pose.hr_hand_mode = true
		HRExecutions.FitHeadGrip(pose, w:GetNW2Entity('hr_execution_body'), HRExecutions.Profile(w), CurTime()-w:GetNW2Float('hr_execution_start'))
	end
	state.raw = {}
	for i = 0, pose:GetBoneCount()-1 do state.raw[i] = pose:GetBoneMatrix(i) end
	local root = idle:LookupBone('w_root')
	state.reference = root and idle:GetBoneMatrix(root)
	local hand = idle:LookupBone(prefix..'R_Hand')
	state.referenceHand = hand and idle:GetBoneMatrix(hand)
	state.body = executing and sampleBody(p, w, pose, HRExecutions.Profile(w), cycle) or nil
	state.eye, state.look = executing and pos or nil, executing and ang or nil
	state.weapon, state.pose, state.executing = w, pose, executing
	state.reload = math.Approach(state.reload, string.StartWith(sequence, 'reload') and 1 or 0, FrameTime()*4)
	p:AnimResetGestureSlot(GESTURE_SLOT_ATTACK_AND_RELOAD)
	state.frame = FrameNumber()
	p:InvalidateBoneCache()
	return state
end
hook.Add('PrePlayerDraw', 'hr_thirdperson', function(p) prepare(p, p:GetActiveWeapon()) end)

function T.Model(w)
	local owner = w:GetOwner()
	local state = states[owner]
	if not state or state.frame ~= FrameNumber() then state = IsValid(owner) and owner:IsPlayer() and prepare(owner, w) end
	if state and state.weapon == w and IsValid(state.pose) then
		if state.fitted ~= FrameNumber() then owner:SetupBones() end
		if state.fitted == FrameNumber() then return state.pose end
	end
end
hook.Add('PostPlayerDraw', 'hr_thirdperson_weapon', function(p)
	local state = states[p]
	if not state or state.fitted ~= FrameNumber() or not IsValid(state.pose) then return end
	state.pose:SetupBones()
	state.pose:DrawModel()
	local drop = state.pose.hr_magazine_drop
	state.pose.hr_magazine_drop = nil
	if drop and IsValid(drop.weapon) and drop.weapon == state.weapon then
		drop.weapon:EjectMagazine(drop.index, drop.sequence, drop.rounds, state.pose)
	end
end)
function T.Active(w)
	local owner = IsValid(w) and w:GetOwner()
	local state = IsValid(owner) and states[owner]
	return state and state.weapon == w and IsValid(state.pose) and state.fitted ~= nil and FrameNumber() - state.fitted < 4 or false
end
function T.Draw(w)
	local owner = w:GetOwner()
	return IsValid(owner) and owner:IsPlayer() and prepare(owner, w) ~= nil
end
clear = function(p)
	local state = states[p]
	if state and IsValid(p) then p:RemoveCallback('BuildBonePositions', state.callback); p:InvalidateBoneCache() end
	states[p] = nil
end
hook.Add('Think', 'hr_thirdperson', function()
	for p, state in pairs(states) do
		if not IsValid(p) or not p:Alive() or not IsValid(state.weapon) or p:GetActiveWeapon() ~= state.weapon or p:InVehicle()
			or (p == LocalPlayer() and not p:ShouldDrawLocalPlayer()) then clear(p) end
	end
end)
hook.Add('PreCleanupMap', 'hr_thirdperson', function() for p in pairs(states) do clear(p) end end)
hook.Add('ShutDown', 'hr_thirdperson', function() for p in pairs(states) do clear(p) end end)
