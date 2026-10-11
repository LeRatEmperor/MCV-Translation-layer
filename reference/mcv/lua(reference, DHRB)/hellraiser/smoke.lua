HRSmoke = HRSmoke or {}
local S = HRSmoke
local material = Material("hellraiser/effects/gun_smoke")
local streams = {}
local LIFETIME, EMIT, SPACING, LIMIT = 1.8, 0.9, 1 / 45, 24

local function muzzle(w, side)
	local owner = w:GetOwner()
	if not IsValid(owner) then return end
	if owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer() then
		local point = side and w.dhr_smoke_muzzles and w.dhr_smoke_muzzles[side] or w.hr_smoke_muzzle
		return point and CurTime() - point.time < 0.1 and point.pos or nil
	end
	local a = w.GetWorldAttachment and w:GetWorldAttachment("muzzle", nil, side)
	return a and a.Pos
end

function S.MuzzleRendered(w, vm, side)
	local a = vm:GetAttachment(vm:LookupAttachment("muzzle"))
	if a then
        local point = {pos = w:ViewModelEffectPosition(a.Pos), time = CurTime()}
        if side then
            w.dhr_smoke_muzzles = w.dhr_smoke_muzzles or {}
            w.dhr_smoke_muzzles[side] = point
        else w.hr_smoke_muzzle = point end
    end
end

function S.Shot(w, side)
	if not IsValid(w) or not w.HR or w.HR.kind ~= "gun" then return end
	if w.AimZoom and w:AimZoom() and w:GetAiming() then return end
	local now = CurTime()
	for _, stream in ipairs(streams) do
		if stream.weapon == w and stream.side == side then stream.stop = math.min(stream.stop, now) end
	end
	if #streams >= LIMIT then table.remove(streams, 1) end
	streams[#streams + 1] = {weapon = w, side = side, points = {}, stop = now + EMIT, next = 0, phase = math.Rand(0, 100), tile = w.HR.crosshair == "shotgun" and 30 / 2.54 or 10 / 2.54}
end

local function update(stream, now, dt)
	local w = stream.weapon
	local owner = IsValid(w) and w:GetOwner()
	if not IsValid(owner) or owner:GetActiveWeapon() ~= w or (owner:IsPlayer() and not owner:Alive())
		or (w.AimZoom and w:AimZoom() and w:GetAiming()) then stream.stop = math.min(stream.stop, now) end
	if now < stream.stop and IsValid(w) and now >= stream.next then
		local pos = muzzle(w, stream.side)
		if pos then
			stream.next = now + SPACING
			table.insert(stream.points, 1, {pos = pos, born = now, velocity = Vector(math.Rand(-1.5, 1.5), math.Rand(-1.5, 1.5), math.Rand(9, 13))})
		end
	end
	for i = #stream.points, 1, -1 do
		local p = stream.points[i]
		local age = now - p.born
		if age >= LIFETIME then
			table.remove(stream.points, i)
		else
			local t = now * 1.7 + stream.phase + i * 0.35
			p.velocity = p.velocity * (1 - math.min(1, dt * 0.6)) + Vector(math.sin(t) * 6, math.cos(t * 1.3) * 6, 2) * dt
			p.pos = p.pos + p.velocity * dt
		end
	end
	return #stream.points > 0 or now < stream.stop
end

hook.Add("Think", "hr_smoke", function()
	local now, dt = CurTime(), FrameTime()
	for i = #streams, 1, -1 do
		if not update(streams[i], now, dt) then table.remove(streams, i) end
	end
end)

hook.Add("PostDrawTranslucentRenderables", "hr_smoke", function(depth, sky)
	if depth or sky or #streams == 0 then return end
	local now = CurTime()
	render.SetMaterial(material)
	for _, stream in ipairs(streams) do
		local points = stream.points
		if #points >= 2 then
			render.StartBeam(#points)
			local distance = 0
			for i, p in ipairs(points) do
				if i > 1 then distance = distance + p.pos:Distance(points[i - 1].pos) end
				local age = math.Clamp((now - p.born) / LIFETIME, 0, 1)
				local alpha = 150 * math.min(1, (now - p.born) / 0.12) * (1 - age) ^ 1.5
				render.AddBeam(p.pos, Lerp(age, 0.4, 5.9), distance / stream.tile - now * 0.67, Color(210, 210, 210, alpha))
			end
			render.EndBeam()
		end
	end
end)

hook.Add("PostCleanupMap", "hr_smoke", function() streams = {} end)
