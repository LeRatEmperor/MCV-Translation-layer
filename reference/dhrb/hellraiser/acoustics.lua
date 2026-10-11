local directions = {}
for i = 0, 7 do
	local angle = math.rad(i * 45)
	directions[#directions + 1] = Vector(math.cos(angle), math.sin(angle), 0)
end
local roofDirections = {Vector(0, 0, 1), Vector(0.3, 0, 1), Vector(-0.3, 0, 1), Vector(0, 0.3, 1), Vector(0, -0.3, 1)}

function SWEP:GetShotEnvironment()
	local owner = self:GetOwner()
	if not IsValid(owner) then return "outdoor" end
	local pos = owner:GetShootPos()
	local cached = self.hr_acoustics
	if cached and cached.owner == owner and CurTime() < cached.expires and pos:DistToSqr(cached.pos) < 4096 then
		return cached.environment
	end
	local walls, distance, roof, height = 0, 0, 0, 0
	local reflections = {}
	local trace = {start = pos, filter = {owner, self}, mask = MASK_SOLID_BRUSHONLY}
	for _, direction in ipairs(directions) do
		trace.endpos = pos + direction * 4096
		local hit = util.TraceLine(trace)
		local enclosed = hit.Hit and not hit.HitSky and not hit.StartSolid
		local length = enclosed and pos:Distance(hit.HitPos) or 4096
		if enclosed and length < 1024 then walls = walls + 1 end
		distance = distance + math.min(length, 1024)
		if enclosed and length > 80 then
			local absorption = ({[MAT_DIRT] = 0.35, [MAT_GRASS] = 0.2, [MAT_SAND] = 0.25,
				[MAT_WOOD] = 0.6, [MAT_FOLIAGE] = 0.2})[hit.MatType] or 1
			reflections[#reflections + 1] = {pos = hit.HitPos + hit.HitNormal * 8,
				gain = absorption / (1 + length / 3200), direction = direction}
		end
	end
	for _, direction in ipairs(roofDirections) do
		trace.endpos = pos + direction * 1536
		local hit = util.TraceLine(trace)
		if hit.Hit and not hit.HitSky and not hit.StartSolid then
			roof = roof + 1
			height = height + hit.HitPos.z - pos.z
		end
	end
	local environment = "outdoor"
	if roof >= 3 and walls >= 5 then
		environment = distance / #directions < 420 and height / roof < 320 and "indoor" or "large"
	end
	table.sort(reflections, function(a, b) return a.gain > b.gain end)
	self.hr_acoustics = {owner = owner, pos = pos, expires = CurTime() + 0.2,
		environment = environment, reflections = reflections}
	return environment
end

function SWEP:GetShotSound(localSound)
	if self.HR.shot_sounds then
		local sounds = self.HR.shot_sounds
		local room = self:GetShotEnvironment()
		return localSound and sounds[room .. "_local"] or sounds[room] or self.HR.fire_snd
	end
	if not string.StartWith(self.HR.fire_snd or "", "HR.") then return self.HR.fire_snd end
	local suffix = ({outdoor = "", indoor = ".Indoor", large = ".Large"})[self:GetShotEnvironment()]
	return self.HR.fire_snd .. suffix .. (localSound and (suffix == "" and ".Local" or "Local") or "")
end

if not CLIENT then return end

local generation = 0
local listenerPosition
hook.Add("RenderScene", "hr_acoustics", function(origin) listenerPosition = origin end)
hook.Add("PostCleanupMap", "hr_acoustics", function() generation = generation + 1 end)

function SWEP:PlayShotReflections()
	if self.HR.kind ~= "gun" or CurTime() < (self.hr_next_reflection or 0) then return end
	self.hr_next_reflection = CurTime() + 0.09
	self:GetShotEnvironment()
	local room = self.hr_acoustics
	if not room then return end
	local key = self.HR.reflection_key or self:GetClass():sub(4)
	if not file.Exists("sound/hellraiser/reflections/" .. key .. "_1.wav", "GAME") then return end
	local listener, source = listenerPosition or LocalPlayer():EyePos(), room.pos
	local selected, first = 0
	for _, bounce in ipairs(room.reflections) do
		if not first or first:Dot(bounce.direction) < 0.5 then
			local trace = util.TraceLine({start = bounce.pos, endpos = listener, mask = MASK_SOLID_BRUSHONLY})
			if not trace.Hit and not trace.StartSolid then
				local path = source:Distance(bounce.pos) + bounce.pos:Distance(listener)
				if path < 8500 then
					local soundPath = "hellraiser/reflections/" .. key .. "_" .. math.random(1, 2) .. ".wav"
					local volume = bounce.gain * (room.environment == "outdoor" and 0.45 or 0.25)
					local epoch, point = generation, bounce.pos
					timer.Simple(math.max(0.04, path / 13504), function()
						if epoch == generation then sound.Play(soundPath, point, 110, 100, volume) end
					end)
					selected = selected + 1
					first = first or bounce.direction
					if selected == 2 then break end
				end
			end
		end
	end
end
