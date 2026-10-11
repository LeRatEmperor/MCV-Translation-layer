local magazines = {}
local limit, lifetime, fade = 32, 30, 4

function EFFECT:Init(data)
	local weapon = data:GetEntity()
	local config = IsValid(weapon) and weapon.HR
    if config and weapon.DualWield then config = weapon:Gun(data:GetAttachment()).config end
	local part = config and (config.magazines or {})[data:GetFlags()]
	if not part then self.Die = 0 return end
	self:SetModel(part.model)
	self.Rounds = math.max(0, math.Round(data:GetMagnitude()))
	self:SetBodygroup(1, math.min(self.Rounds, 2))
	self:SetPos(data:GetOrigin())
	self:SetAngles(data:GetAngles())
	self:SetSolid(SOLID_NONE)
	self.Die = CurTime() + lifetime
	self.Velocity = data:GetStart()
	self.Spin = AngleRand() * 1.5
	for i = #magazines, 1, -1 do
		if not IsValid(magazines[i]) or magazines[i].Die <= CurTime() then table.remove(magazines, i) end
	end
	if #magazines >= limit then
		local oldest = table.remove(magazines, 1)
		if IsValid(oldest) then oldest.Die = math.min(oldest.Die, CurTime() + 0.35) end
	end
	magazines[#magazines + 1] = self
end

function EFFECT:Think()
	if CurTime() >= self.Die then
		for i = #magazines, 1, -1 do if magazines[i] == self then table.remove(magazines, i) break end end
		return false
	end
	if self.Resting then return true end
	local dt = math.min(FrameTime(), 0.05)
	self.Velocity = self.Velocity + Vector(0, 0, -600) * dt
	local tr = util.TraceHull({start = self:GetPos(), endpos = self:GetPos() + self.Velocity * dt,
		mins = Vector(-0.5, -0.5, -0.5), maxs = Vector(0.5, 0.5, 0.5), mask = MASK_SOLID_BRUSHONLY})
	self:SetPos(tr.HitPos + (tr.Hit and tr.HitNormal * 0.5 or vector_origin))
	self:SetAngles(self:GetAngles() + self.Spin * dt)
	if tr.Hit then
		if not self.Bounced then self:EmitSound("physics/metal/weapon_impact_soft1.wav", 55, math.random(95, 105), 0.45) self.Bounced = true end
		self.Velocity = (self.Velocity - 2 * self.Velocity:Dot(tr.HitNormal) * tr.HitNormal) * 0.25
		self.Spin = self.Spin * 0.35
		if self.Velocity:LengthSqr() < 400 or tr.StartSolid then
			self.Resting = true
			if tr.HitNormal.z > 0.5 and not tr.StartSolid then
				local angle = tr.HitNormal:Angle()
				angle:RotateAroundAxis(tr.HitNormal, self:GetAngles().y)
				local low, high = self:OBBMins(), self:OBBMaxs()
				local extent = high - low
				if extent.y < extent.x and extent.y < extent.z then angle:RotateAroundAxis(angle:Up(), 90)
				elseif extent.z < extent.x then angle:RotateAroundAxis(angle:Right(), -90) end
				local bottom = math.huge
				for _, x in ipairs({low.x, high.x}) do for _, y in ipairs({low.y, high.y}) do for _, z in ipairs({low.z, high.z}) do
					local corner = Vector(x, y, z); corner:Rotate(angle)
					bottom = math.min(bottom, corner:Dot(tr.HitNormal))
				end end end
				self:SetAngles(angle)
				self:SetPos(tr.HitPos + tr.HitNormal * (-bottom + 0.02))
			end
		end
	end
	return true
end

function EFFECT:Render()
	local blend = render.GetBlend()
	render.SetBlend(blend * math.Clamp((self.Die - CurTime()) / fade, 0, 1))
	self:DrawModel()
	render.SetBlend(blend)
end
