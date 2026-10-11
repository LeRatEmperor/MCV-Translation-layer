local shells = {}
local limit, lifetime, fade = 192, 30, 4

function EFFECT:Init(data)
	local w = data:GetEntity()
	local config = IsValid(w) and w.HR
    if config and w.DualWield then config = w:Gun(data:GetAttachment()).config end
	local kind = config and config.crosshair or "shotgun"
	self.Shotgun = kind == "shotgun"
	self:SetModel("models/weapons/hellraiser/w_hr_" .. (self.Shotgun and "spent_shell" or "spent_brass") .. ".mdl")
	self.ImpactSound = self.Shotgun and "HR.Shotgun_Shell" or "HR.Brass_Impact"
	self:SetPos(data:GetOrigin())
	self:SetAngles(data:GetAngles())
	self:SetSolid(SOLID_NONE)
	self.Die = CurTime() + lifetime
	for i = #shells, 1, -1 do
		if not IsValid(shells[i]) or shells[i].Die <= CurTime() then table.remove(shells, i) end
	end
	if #shells >= limit then
		local oldest = table.remove(shells, 1)
		if IsValid(oldest) then oldest.Die = math.min(oldest.Die, CurTime() + 0.35) end
	end
	shells[#shells + 1] = self
	local a = data:GetAngles()
	self.Owner = IsValid(w) and w:GetOwner()
	self.Velocity = a:Right() * math.Rand(80, 110) + a:Up() * 45
		+ (IsValid(self.Owner) and self.Owner:GetVelocity() or vector_origin)
	if kind == "revolver" then
		self.Velocity = -a:Right() * math.Rand(18, 35) - a:Up() * math.Rand(15, 30) + a:Forward() * math.Rand(-12, 12)
	elseif not self.Shotgun then
		self.Velocity = self.Velocity + a:Up() * 18
	end
	self.Spin = AngleRand() * 3
end

function EFFECT:Think()
	if CurTime() >= self.Die then
		for i = #shells, 1, -1 do if shells[i] == self then table.remove(shells, i) break end end
		return false
	end
	if self.Resting then return true end
	local dt = math.min(FrameTime(), 0.05)
	self.Velocity = self.Velocity + Vector(0, 0, -600) * dt
	local tr = util.TraceHull({start = self:GetPos(), endpos = self:GetPos() + self.Velocity * dt,
		mins = Vector(-0.2, -0.2, -0.2), maxs = Vector(0.2, 0.2, 0.2), mask = MASK_SOLID_BRUSHONLY})
	self:SetPos(tr.HitPos + (tr.Hit and tr.HitNormal * 0.2 or vector_origin))
	self:SetAngles(self:GetAngles() + self.Spin * dt)
	if tr.Hit then
		if not self.Bounced then self:EmitSound(self.ImpactSound) self.Bounced = true end
		self.Velocity = (self.Velocity - 2 * self.Velocity:Dot(tr.HitNormal) * tr.HitNormal) * 0.3
		self.Spin = self.Spin * 0.4
		if self.Velocity:LengthSqr() < 400 or tr.StartSolid then
			self.Resting = true
			if tr.HitNormal.z > 0.5 and not tr.StartSolid then
				local angle = tr.HitNormal:Angle()
				angle:RotateAroundAxis(angle:Right(), -90)
				angle:RotateAroundAxis(tr.HitNormal, self:GetAngles().y)
				self:SetAngles(angle)
				self:SetPos(tr.HitPos + tr.HitNormal * (math.abs(self:OBBMins().z) + 0.02))
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
