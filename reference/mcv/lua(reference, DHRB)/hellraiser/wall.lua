HRWall = HRWall or {}
local W = HRWall
local prefix = 'ValveBiped.Bip01_'
local states = setmetatable({}, {__mode = 'k'})
local oneHanded = {knife = true, machete = true, messer = true, cleaver = true, sawblade = true, tireiron = true,
	hellknife = true, colt = true, revolver = true}
local across = {knife = true, machete = true, messer = true, cleaver = true, sawblade = true, hellknife = true}
local reaches = {ak47 = 34, smg = 30, shotgun = 36, colt = 24, revolver = 26, cricketbat = 32, baseballbat = 32,
	skullcrusher = 32, plank = 34, cube = 18}
local HAND_REACH = 30
local BLADE_YAW, BLADE_ROLL = -45, 40

local function solid(e)
	return not (e:IsPlayer() or e:IsNPC() or e:IsNextBot() or e:IsWeapon())
end

local function key(w) return w.HR.pose_key or string.sub(w:GetClass(), 4) end

function W.Get(p, w)
	local s = states[p]
	if not s or s.weapon ~= w or CurTime() - s.time > 0.25 then
		s = {gun = 0, hand = 0, time = CurTime()} states[p] = s
	end
	if s.frame == FrameNumber() and s.weapon == w then return s end
	local now = CurTime()
	local dt = math.Clamp(now - s.time, 0, 0.1)
	s.time, s.frame, s.weapon = now, FrameNumber(), w
	local gun, hand = 0, 0
	local contact = s.contact
	if IsValid(w) and w.HR and DHR.HasFeature(w, "wall") and p:Alive() and not p:InVehicle() and not w:GetNW2Bool('hr_executing')
		and not (HRCombat and HRCombat.Dodging(p)) then
		local eye, ang = p:EyePos(), p:EyeAngles()
		local forward, right, up = ang:Forward(), ang:Right(), ang:Up()
		local reach = w.HR.wall_reach or reaches[key(w)] or 24
		local filter = function(e) return e ~= p and solid(e) end
		local tr = util.TraceHull({start = eye, endpos = eye + forward * reach, mins = Vector(-2, -2, -2), maxs = Vector(2, 2, 2),
			filter = filter, mask = MASK_SOLID})
		if tr.Hit and not tr.StartSolid then gun = math.Clamp((reach - tr.HitPos:Distance(eye)) / (reach * 0.65), 0, 1) end
		if (w.HR.wall_hand or oneHanded[key(w)]) and now >= w:GetBusyUntil() and not w:GetAiming() then
			local from = eye - right * 7 - up * 6
			local touch = util.TraceLine({start = from, endpos = from + forward * (contact and HAND_REACH + 4 or HAND_REACH), filter = filter, mask = MASK_SOLID})
			if touch.Hit and not touch.StartSolid and touch.HitNormal:Dot(forward) < (contact and -0.35 or -0.5) then
				hand = 1
				s.point, s.normal = touch.HitPos, touch.HitNormal
			end
		end
	end
	s.gun = s.gun + (gun - s.gun) * math.min(1, dt * 10)
	s.contact = hand == 1
	s.hand = math.Approach(s.hand, hand, dt / (s.contact and 0.2 or 0.24))
	if s.hand < 0.002 then s.point, s.bodyPoint, s.bodyNormal = nil, nil, nil end
	return s
end

local function ease(x) return x * x * (3 - 2 * x) end

function W.ViewOffset(w, pos, ang, turn)
	local owner = w:GetOwner()
	local s = IsValid(owner) and W.Get(owner, w)
	if not s or s.gun < 0.002 then return pos, turn end
	local g = ease(s.gun)
	local forward, right, up = ang:Forward(), ang:Right(), ang:Up()
	local grip = pos + forward * 12 + right * 4 - up * 6
	local before = Angle(turn.p, turn.y, turn.r)
	turn:RotateAroundAxis(right, 30 * g)
	turn:RotateAroundAxis(forward, -10 * g)
	local localGrip = WorldToLocal(grip, angle_zero, pos, before)
	local moved = LocalToWorld(localGrip, angle_zero, pos, turn)
	return pos + (grip - moved) - forward * 4 * g - up * 1.5 * g, turn
end

local function handFrame(model, side)
	local bone = model:LookupBone(prefix .. side .. '_Hand')
	local ids = {}
	for _, n in ipairs({0, 1, 2, 4}) do ids[n] = model:LookupBone(prefix .. side .. '_Finger' .. n) end
	local m = bone and model:GetBoneMatrix(bone)
	if not m or not ids[0] or not ids[1] or not ids[2] or not ids[4] then return end
	local function at(id) local x = model:GetBoneMatrix(id) return x and x:GetTranslation() end
	local wrist, thumb, index, middle, pinky = m:GetTranslation(), at(ids[0]), at(ids[1]), at(ids[2]), at(ids[4])
	if not thumb or not index or not middle or not pinky then return end
	local along = (middle - wrist):GetNormalized()
	local across = (index - pinky):GetNormalized()
	across = (across - along * across:Dot(along)):GetNormalized()
	local palm = along:Cross(across)
	if palm:Dot(thumb - wrist) > 0 then palm = -palm end
	return along, across, palm
end

local function basis(a, b, c)
	local m = Matrix()
	m:SetForward(a) m:SetRight(-b) m:SetUp(c)
	return m
end

local function wallTurn(model, side, normal)
	local along, across, palm = handFrame(model, side)
	if not along then return end
	local up = Vector(0, 0, 1) - normal * normal.z
	if up:LengthSqr() < 0.01 then up = normal:Angle():Up() end
	up:Normalize()
	local into = -normal
	local handed = along:Cross(across):Dot(palm) >= 0 and 1 or -1
	local side2 = (up:Cross(into) * handed):GetNormalized()
	return basis(up, side2, into) * basis(along, across, palm):GetInverse(), up
end

local function rotateTo(matrix, from, to, position)
	from, to = from:GetNormalized(), to:GetNormalized()
	local angle = matrix:GetAngles()
	local axis = from:Cross(to)
	if axis:LengthSqr() > 1e-6 then angle:RotateAroundAxis(axis:GetNormalized(), math.deg(math.acos(math.Clamp(from:Dot(to), -1, 1)))) end
	local result = Matrix()
	result:SetAngles(angle) result:SetTranslation(position) result:SetScale(matrix:GetScale())
	return result
end

local function setBone(model, id, matrix)
	local old = model:GetBoneMatrix(id)
	if not old then return end
	local inverse = old:GetInverse()
	if not inverse then return end
	local delta = matrix * inverse
	local below = {[id] = true}
	for i = 0, model:GetBoneCount() - 1 do
		local parent = model:GetBoneParent(i)
		if parent >= 0 and below[parent] then
			below[i] = true
			local m = model:GetBoneMatrix(i)
			if m then model:SetBoneMatrix(i, delta * m) end
		end
	end
	model:SetBoneMatrix(id, matrix)
end

local function lerpMatrix(from, to, weight)
	local result = Matrix()
	result:SetAngles(LerpAngle(weight, from:GetAngles(), to:GetAngles()))
	result:SetTranslation(LerpVector(weight, from:GetTranslation(), to:GetTranslation()))
	result:SetScale(from:GetScale())
	return result
end

local function reachArm(model, side, target, normal, weight)
	local u, f, h = model:LookupBone(prefix .. side .. '_UpperArm'), model:LookupBone(prefix .. side .. '_Forearm'), model:LookupBone(prefix .. side .. '_Hand')
	local mu, mf, mh = u and model:GetBoneMatrix(u), f and model:GetBoneMatrix(f), h and model:GetBoneMatrix(h)
	if not mu or not mf or not mh then return end
	local shoulder, elbow, wrist = mu:GetTranslation(), mf:GetTranslation(), mh:GetTranslation()
	local a, b = shoulder:Distance(elbow), elbow:Distance(wrist)
	local goal = LerpVector(weight, wrist, target)
	local distance = math.Clamp(goal:Distance(shoulder), math.abs(a - b) + 0.01, a + b - 0.01)
	local axis = (goal - shoulder):GetNormalized()
	goal = shoulder + axis * distance
	local pole = elbow - shoulder
	pole = pole - axis * pole:Dot(axis)
	if pole:LengthSqr() < 1e-4 then pole = Vector(0, 0, -1) + axis * axis.z end
	if pole:LengthSqr() < 1e-4 then pole = axis:Angle():Right() end
	pole:Normalize()
	local along = (a * a + distance * distance - b * b) / (2 * distance)
	local joint = shoulder + axis * along + pole * math.sqrt(math.max(0, a * a - along * along))
	setBone(model, u, rotateTo(mu, elbow - shoulder, joint - shoulder, shoulder))
	local cf, ch = model:GetBoneMatrix(f), model:GetBoneMatrix(h)
	setBone(model, f, rotateTo(cf, ch:GetTranslation() - cf:GetTranslation(), goal - joint, joint))
	local carried = Matrix(model:GetBoneMatrix(h))
	carried:SetTranslation(goal)
	local turn = wallTurn(model, side, normal)
	if turn then
		local flat = Matrix(carried)
		flat:SetAngles((turn * carried):GetAngles())
		carried = lerpMatrix(carried, flat, weight)
	end
	setBone(model, h, carried)
end

local function clearBlade(vm, forward, up, weight)
	local id = vm:LookupBone('hand_r')
	local m = id and vm:GetBoneMatrix(id)
	if not m then return end
	local angle = m:GetAngles()
	angle:RotateAroundAxis(up, BLADE_YAW * weight)
	angle:RotateAroundAxis(forward, BLADE_ROLL * weight)
	local turned = Matrix(m)
	turned:SetAngles(angle)
	setBone(vm, id, turned)
end

function W.Hand(w, vm)
	local owner = w:GetOwner()
	local s = IsValid(owner) and W.Get(owner, w)
	if not s or s.hand < 0.01 or not s.point then return end
	local view = render.GetViewSetup()
	local ratio = math.tan(math.rad(view.fovviewmodel_unscaled) / 2) / math.tan(math.rad(view.fov_unscaled) / 2)
	local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
	local function toModel(point)
		local offset = point - view.origin
		return view.origin + forward * offset:Dot(forward) + (right * offset:Dot(right) + up * offset:Dot(up)) * ratio
	end
	local wall = s.normal
	local fingersUp = (Vector(0, 0, 1) - wall * wall.z):GetNormalized()
	local wrist = toModel(s.point + wall * 2 - fingersUp * 2)
	reachArm(vm, 'L', wrist, wall, ease(s.hand))
	if across[key(w)] then clearBlade(vm, forward, up, ease(s.hand)) end
end

function W.Body(p, w)
	local s = W.Get(p, w)
	if s.hand < 0.01 or not s.point then return end
	local id = p:LookupBone(prefix .. 'L_UpperArm')
	local shoulder = id and p:GetBoneMatrix(id)
	if not shoulder then return end
	local yaw = Angle(0, p:EyeAngles().y, 0)
	local from = shoulder:GetTranslation() - yaw:Right() * 3 - Vector(0, 0, 4)
	local touch = util.TraceLine({start = from, endpos = from + yaw:Forward() * 30,
		filter = function(e) return e ~= p and solid(e) end, mask = MASK_SOLID})
	if touch.Hit and not touch.StartSolid and touch.HitNormal:Dot(yaw:Forward()) < -0.35 then
		s.bodyPoint, s.bodyNormal = touch.HitPos, touch.HitNormal
	end
	if not s.bodyPoint then return end
	local wall = s.bodyNormal
	local fingersUp = (Vector(0, 0, 1) - wall * wall.z):GetNormalized()
	reachArm(p, 'L', s.bodyPoint + wall * 1.5 - fingersUp * 3, wall, ease(s.hand))
end

local function bodyReach(p)
	local w = p:GetActiveWeapon()
	if not IsValid(w) or not w.HR or w.HR.kind ~= 'melee' or w:GetNW2Bool('hr_executing') then return end
	if p == LocalPlayer() and not p:ShouldDrawLocalPlayer() then return end
	W.Body(p, w)
end
hook.Add('PrePlayerDraw', 'hr_wall', function(p)
	if p.hr_wall_callback then return end
	p.hr_wall_callback = p:AddCallback('BuildBonePositions', bodyReach)
end)

function W.Placement(p, w, placement, pivot)
	local s = W.Get(p, w)
	if s.gun < 0.002 then return placement end
	local g = ease(s.gun)
	local turn = Matrix()
	local ang = Angle(0, 0, 0)
	ang:RotateAroundAxis(p:EyeAngles():Right(), 28 * g)
	turn:SetAngles(ang)
	local shift = Matrix()
	shift:SetTranslation(pivot - p:EyeAngles():Forward() * 3 * g)
	local back = Matrix()
	back:SetTranslation(-pivot)
	return shift * turn * back * placement
end
