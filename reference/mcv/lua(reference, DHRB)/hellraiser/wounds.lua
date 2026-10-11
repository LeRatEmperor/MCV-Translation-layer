if SERVER then return end
HRWounds = HRWounds or {}
local W = HRWounds
local materials = {
	burst = Material("hellraiser/decals/wound_burst"),
	spatter = Material("hellraiser/decals/wound_spatter"),
	smear = Material("hellraiser/decals/wound_smear"),
}
local pending = {}

local function nearestBone(ent, pos)
	local best, distance
	for i = 0, ent:GetBoneCount() - 1 do
		local matrix = not string.find(ent:GetBoneName(i) or '', 'Head', 1, true) and ent:GetBoneMatrix(i)
		if matrix then
			local d = matrix:GetTranslation():DistToSqr(pos)
			if not distance or d < distance then best, distance = i, d end
		end
	end
	return best
end

local function stamp(ent, kind, pos, normal, size)
	util.DecalEx(materials[kind] or materials.burst, ent, pos, normal, color_white, size, size)
end

function W.Add(body, kind, pos, normal, size)
	if not IsValid(body) then return end
	body:SetupBones()
	stamp(body, kind, pos, normal, size)
	local bone = nearestBone(body, pos)
	local matrix = bone and body:GetBoneMatrix(bone)
	if not matrix then return end
	local inverse = matrix:GetInverse()
	local localPos = inverse * pos
	pending[#pending + 1] = {model = body:GetModel(), bone = body:GetBoneName(bone), pos = localPos, normal = inverse * (pos + normal) - localPos,
		kind = kind, size = size, origin = body:GetPos(), world = pos, time = CurTime()}
end

local function transfer(rag)
	if not IsValid(rag) then return false end
	rag:InvalidateBoneCache()
	rag:SetupBones()
	local model, now, waiting = rag:GetModel(), CurTime(), false
	for i = #pending, 1, -1 do
		local wound = pending[i]
		if now - wound.time > 20 then
			table.remove(pending, i)
		elseif wound.model == model and wound.origin:DistToSqr(rag:GetPos()) < 250 * 250 then
			local bone = rag:LookupBone(wound.bone)
			local matrix = bone and rag:GetBoneMatrix(bone)
			local pos = matrix and matrix * wound.pos
			if pos and pos:DistToSqr(wound.world) < 80 * 80 then
				stamp(rag, wound.kind, pos, (matrix * (wound.pos + wound.normal) - pos):GetNormalized(), wound.size)
				table.remove(pending, i)
			else
				waiting = true
			end
		end
	end
	return waiting
end

hook.Add("OnEntityCreated", "hr_wounds", function(e)
	if #pending == 0 or not IsValid(e) or e:GetClass() ~= "prop_ragdoll" then return end
	local name = "hr_wounds_" .. e:EntIndex()
	timer.Create(name, 0.1, 20, function()
		if not transfer(e) then timer.Remove(name) end
	end)
end)
