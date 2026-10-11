local bolt = Material("hellraiser/effects/cube_bolt")
local flare = Material("hellraiser/effects/cube_flare")
local glow = Material("hellraiser/effects/cube_glow")
local SLOTS = 16
local WAVE = 372

function EFFECT:Init(data)
	self.StartPos = data:GetStart()
	self.EndPos = data:GetOrigin()
	self.Projectile = data:GetEntity()
	self.Start = CurTime()
	self.Direction = (self.EndPos - self.StartPos):GetNormalized()
	self.Length = self.StartPos:Distance(self.EndPos)
	self.Life = self.Length / 2600 + 0.5
	self.Slots = {}
	self.NextFlicker = 0
	self.Link = ClientsideModel("models/weapons/hellraiser/hr_chain_link.mdl", RENDERGROUP_TRANSLUCENT)
	if IsValid(self.Link) then self.Link:SetNoDraw(true); self.Link:SetModelScale(1.25, 0); self.Link:DrawShadow(false) end
	self:SetPos((self.StartPos + self.EndPos) / 2)
	local a, b = self.StartPos, self.EndPos
	self:SetRenderBoundsWS(Vector(math.min(a.x,b.x), math.min(a.y,b.y), math.min(a.z,b.z)),
		Vector(math.max(a.x,b.x), math.max(a.y,b.y), math.max(a.z,b.z)), Vector(120,120,120))
end

function EFFECT:Think()
	if CurTime() < self.Start + self.Life then return true end
	if IsValid(self.Link) then self.Link:Remove() end
	return false
end

function EFFECT:Render()
	local elapsed = CurTime() - self.Start
	local reach = math.min(elapsed * 2600, self.Length)
	if IsValid(self.Projectile) then
		reach = math.Clamp((self.Projectile:GetPos() - self.StartPos):Dot(self.Direction), 0, self.Length)
	end
	local head = self.StartPos + self.Direction * reach
	local angle = self.Direction:Angle()
	local right, up = angle:Right(), angle:Up()
	local function point(distance)
		local bend = math.sin(math.Clamp((reach - distance) / WAVE, 0, 1) * math.pi)
		return self.StartPos + self.Direction * distance + (right * math.sin(distance * 0.045 + elapsed * 5) + up * math.cos(distance * 0.045 + elapsed * 5)) * (10 * bend)
	end
	local alpha = math.Clamp((self.Life - elapsed) / 0.5, 0, 1)
	if CurTime() >= self.NextFlicker then
		self.NextFlicker = CurTime() + 0.045
		for i = 1, 8 do self.Slots[i] = math.random(0, SLOTS - 1) end
	end
	local tail = math.max(0, reach - WAVE)
	render.SetMaterial(bolt)
	for i = 1, 8 do
		local from, to = tail + (reach - tail) * (i - 1) / 8, tail + (reach - tail) * i / 8
		if to - from > 4 then
			local a, b = point(from), point(to)
			local slot = self.Slots[i] or 0
			for _, pass in ipairs({{14, Color(80, 150, 255, 230 * alpha)}, {4, Color(230, 245, 255, 255 * alpha)}}) do
				render.StartBeam(2)
				render.AddBeam(a, pass[1], slot / SLOTS, pass[2])
				render.AddBeam(b, pass[1], (slot + 1) / SLOTS, pass[2])
				render.EndBeam()
			end
		end
	end
	local lit = math.Clamp(1 - (elapsed - self.Length / 2600) / 0.12, 0, 1) * math.Clamp(head:Distance(EyePos()) / 160, 0.2, 1)
	render.SetMaterial(glow)
	render.DrawSprite(head, 60 * lit, 60 * lit, Color(70, 140, 255, 200 * alpha))
	render.DrawSprite(head, 22 * lit, 22 * lit, Color(230, 245, 255, 255 * alpha))
	render.SetMaterial(flare)
	local pulse = (70 + math.sin(elapsed * 40) * 10) * lit
	render.DrawSprite(head, pulse, pulse, Color(130, 190, 255, 170 * alpha))
	if not IsValid(self.Link) then return end
	render.SetBlend(alpha)
	for i = 0, 31 do
		local distance = reach - i * 12
		if distance >= 0 then
			local angle = (point(distance + 1) - point(distance)):Angle()
			angle:RotateAroundAxis(self.Direction, i % 2 * 90)
			self.Link:SetPos(point(distance))
			self.Link:SetAngles(angle)
			self.Link:SetupBones()
			self.Link:DrawModel()
		end
	end
	render.SetBlend(1)
end

function EFFECT:OnRemove()
	if IsValid(self.Link) then self.Link:Remove() end
end
