HRPose = HRPose or {}
local P = HRPose
local samplesByWeapon = {}

function P.Sample(w, key, model, sequence, cycle, pos, ang)
	local samples = samplesByWeapon[w]
	if not samples then samples = {}; samplesByWeapon[w] = samples end
	local pose = samples[key]
	if not IsValid(pose) or pose:GetModel() ~= model then
		if IsValid(pose) then pose:Remove() end
		pose = ClientsideModel(model, RENDERGROUP_OTHER)
		if not IsValid(pose) then return end
		samples[key] = pose
		pose.hr_weapon = w
		pose:SetNoDraw(true)
		pose:DrawShadow(false)
	end
	local id = pose:LookupSequence(sequence)
	if id < 0 then return end
	pose:SetSequence(id)
	pose:SetPlaybackRate(0)
	pose:SetCycle(cycle)
	pose:SetPos(pos)
	pose:SetAngles(ang)
	pose:InvalidateBoneCache()
	pose:SetupBones()
	return pose
end

function P.Reposition(model, target, weight)
	local bone = model:LookupBone('w_root')
	local from = bone and model:GetBoneMatrix(bone)
	local to = bone and target:GetBoneMatrix(bone)
	if not from or not to then return end
	local inverse = from:GetInverse()
	if not inverse then return end
	local placed = Matrix()
	placed:SetTranslation(LerpVector(weight, from:GetTranslation(), to:GetTranslation()))
	placed:SetAngles(LerpAngle(weight, from:GetAngles(), to:GetAngles()))
	placed:SetScale(from:GetScale())
	local delta = placed * inverse
	for i = 0, model:GetBoneCount()-1 do
		local matrix = model:GetBoneMatrix(i)
		if matrix and model:GetBoneName(i) ~= '__INVALIDBONE__' then model:SetBoneMatrix(i, delta * matrix) end
	end
end

function P.FirePair(w, sequence)
	local aimed = string.StartWith(sequence, 'ads_fire')
	if not aimed and not string.StartWith(sequence, 'fire') then return end
	local suffix = sequence:gsub('^ads_', '')
	local target = aimed and suffix or 'ads_'..suffix
	if not w.HR.len[target] then
		local list = w.HR.seq[aimed and 'fire' or 'ads_fire']
		target = istable(list) and list[1] or list
	end
	if target and w.HR.len[target] then return target, aimed end
end

function P.Aim(w, vm)
	if w:GetNW2Bool('hr_executing') then return end
	local target, aimed = P.FirePair(w, vm:GetSequenceName(vm:GetSequence()))
	if not target then return end
	local fraction = w:AimFraction()
	local weight = aimed and 1-fraction or fraction
	if weight >= .001 then
		local pose = P.Sample(w, 'aim', vm:GetModel(), target, vm:GetCycle(), vm:GetPos(), vm:GetAngles())
		if pose then P.Reposition(vm, pose, weight) end
	end
	local steady = (w.HR.ads_steady or 0) * fraction
	if steady > 0 and w.HR.seq.ads_idle then
		local pose = P.Sample(w, 'steady', vm:GetModel(), w.HR.seq.ads_idle, 0, vm:GetPos(), vm:GetAngles())
		if pose then P.Reposition(vm, pose, steady) end
	end
end

function P.Remove(w)
	for _, pose in pairs(samplesByWeapon[w] or {}) do if IsValid(pose) then pose:Remove() end end
	samplesByWeapon[w] = nil
end
hook.Add('EntityRemoved', 'hr_pose_samples', function(e) if samplesByWeapon[e] then P.Remove(e) end end)
hook.Add('Think', 'hr_pose_samples', function()
	for w in pairs(samplesByWeapon) do
		local p = IsValid(w) and w:GetOwner()
		if not IsValid(p) or not p:Alive() or p:GetActiveWeapon() ~= w then P.Remove(w) end
	end
end)
hook.Add('PreCleanupMap', 'hr_pose_samples', function() for w in pairs(samplesByWeapon) do P.Remove(w) end end)
hook.Add('ShutDown', 'hr_pose_samples', function() for w in pairs(samplesByWeapon) do P.Remove(w) end end)
