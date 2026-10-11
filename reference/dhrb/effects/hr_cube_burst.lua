local flare = Material("hellraiser/effects/cube_flare")
local glow = Material("hellraiser/effects/cube_glow")
local bolt = Material("hellraiser/effects/cube_bolt")
local ring = Material("hellraiser/effects/shockwave")
local SLOTS = 16
local LINK = "models/weapons/hellraiser/hr_chain_link.mdl"

local function lightning(a, b, width, slot, color, jitter)
	render.StartBeam(7)
	for i = 0, 6 do
		local f = i / 6
		local p = LerpVector(f, a, b)
		if i > 0 and i < 6 then p = p + VectorRand() * jitter end
		render.AddBeam(p, width, (slot + f) / SLOTS, color)
	end
	render.EndBeam()
end

function EFFECT:Init(data)
	self.Origin = data:GetOrigin()
	self.Normal = data:GetNormal()
	self.Scale = math.max(data:GetScale(), 0.3)
	self.Start = CurTime()
	self.Cast = data:GetFlags() == 2
	self.Push = data:GetFlags() == 1
	self.Impact = not self.Cast and not self.Push
	self.Life = self.Cast and 0.45 or 1.1
	self.Arcs = {}
	for i = 1, self.Cast and 5 or self.Push and 12 or 9 do
		self.Arcs[i] = {dir = (VectorRand():GetNormalized() + self.Normal * 0.6):GetNormalized(), length = math.Rand(60, 150), slot = math.random(0, SLOTS - 1)}
	end
	self.NextFlicker = 0
	self:SetPos(self.Origin)
	local bounds = Vector(360, 360, 360) * self.Scale
	self:SetRenderBounds(-bounds, bounds)

	self.FlareSize = self.Cast and 34 or self.Push and 70 or 110 * math.min(self.Scale, 1.6)
	self.GlowSize = self.Cast and 26 or self.Push and 55 or 60 * math.min(self.Scale, 1.6)
	local dl = DynamicLight(self:EntIndex())
	if dl then
		dl.pos = self.Origin + self.Normal * 8
		dl.r, dl.g, dl.b = 70, 140, 255
		dl.brightness = self.Cast and 1 or self.Push and 0.8 or 2
		dl.decay = 1100
		dl.size = self.Cast and 140 or 300 * math.min(self.Scale, 1.6)
		dl.dietime = CurTime() + 0.45
	end

	local emitter = ParticleEmitter(self.Origin)
	if emitter then
		for i = 1, self.Cast and 18 or self.Push and 60 or 55 do
			local p = emitter:Add("effects/spark", self.Origin)
			if p then
				p:SetVelocity((VectorRand() + self.Normal * 0.8) * math.Rand(150, 420) * math.min(self.Scale, 1.4))
				p:SetDieTime(math.Rand(0.35, 0.9))
				p:SetStartAlpha(255)
				p:SetEndAlpha(0)
				p:SetStartSize(math.Rand(1.5, 3))
				p:SetEndSize(0)
				p:SetStartLength(math.Rand(10, 22))
				p:SetEndLength(2)
				p:SetColor(120, 190, 255)
				p:SetGravity(Vector(0, 0, -380))
				p:SetCollide(true)
				p:SetBounce(0.35)
			end
		end
		for i = 1, self.Cast and 0 or self.Push and 4 or 7 do
			local p = emitter:Add("hellraiser/effects/cube_smoke" .. math.random(1, 4), self.Origin + VectorRand() * 6)
			if p then
				p:SetVelocity(VectorRand() * 30 + self.Normal * (self.Push and math.Rand(220, 300) or math.Rand(20, 60)))
				p:SetAirResistance(self.Push and 120 or 60)
				p:SetDieTime(math.Rand(0.8, 1.3))
				p:SetStartAlpha(self.Push and 70 or 120)
				p:SetEndAlpha(0)
				p:SetStartSize(10 * math.min(self.Scale, 1.6))
				p:SetEndSize(math.Rand(45, 65) * math.min(self.Scale, 1.6))
				p:SetColor(120, 128, 140)
				p:SetRoll(math.Rand(0, 6.28))
				p:SetRollDelta(math.Rand(-0.6, 0.6))
			end
		end
		emitter:Finish()
	end

	self.Links = {}
	if self.Impact then
		for i = 1, 6 do
			local link = ClientsideModel(LINK, RENDERGROUP_OPAQUE)
			if IsValid(link) then
				link:SetNoDraw(true)
				link:DrawShadow(false)
				link:SetModelScale(1.25, 0)
				self.Links[#self.Links + 1] = {model = link, pos = self.Origin + VectorRand() * 4, ang = AngleRand(),
					vel = (VectorRand() + self.Normal * 1.2) * math.Rand(90, 230), spin = AngleRand() * 2}
			end
		end
	end
end

function EFFECT:Think()
	local dt = FrameTime()
	for _, link in ipairs(self.Links) do
		link.vel.z = link.vel.z - 600 * dt
		local to = link.pos + link.vel * dt
		local tr = util.TraceLine({start = link.pos, endpos = to, mask = MASK_SOLID_BRUSHONLY})
		if tr.Hit then
			link.vel = (link.vel - 2 * link.vel:Dot(tr.HitNormal) * tr.HitNormal) * 0.35
			link.spin = link.spin * 0.5
			to = tr.HitPos + tr.HitNormal * 0.5
		end
		link.pos = to
		link.ang = link.ang + link.spin * dt
	end
	if CurTime() < self.Start + self.Life + (self.Impact and 0.9 or 0) then return true end
	self:RemoveLinks()
	return false
end

function EFFECT:RemoveLinks()
	for _, link in ipairs(self.Links) do
		if IsValid(link.model) then link.model:Remove() end
	end
	self.Links = {}
end

function EFFECT:OnRemove()
	self:RemoveLinks()
end

function EFFECT:Render()
	local elapsed = CurTime() - self.Start
	local t = math.Clamp(elapsed / self.Life, 0, 1)
	local origin = self.Origin + (self.Push and self.Normal * t * 260 or vector_origin)
	local scale = self.Scale
	if CurTime() >= self.NextFlicker then
		self.NextFlicker = CurTime() + 0.045
		for _, arc in ipairs(self.Arcs) do
			arc.slot = math.random(0, SLOTS - 1)
			arc.dir = (arc.dir + VectorRand() * 0.25):GetNormalized()
		end
	end
	if t < 1 then
		local flash = math.Clamp(1 - elapsed / 0.22, 0, 1)
		render.SetMaterial(flare)
		render.DrawSprite(origin, self.FlareSize * (0.8 + 0.4 * t), self.FlareSize * (0.8 + 0.4 * t), Color(120, 180, 255, 170 * flash * flash))
		render.SetMaterial(glow)
		render.DrawSprite(origin, self.GlowSize, self.GlowSize, Color(70, 140, 255, 150 * (1 - t) ^ 2))
		render.DrawSprite(origin, self.GlowSize * 0.3, self.GlowSize * 0.3, Color(225, 240, 255, 230 * (1 - t) ^ 2))
		if self.Push then
			render.SetMaterial(ring)
			local size = 60 + t * 320
			render.DrawQuadEasy(origin, self.Normal, size, size, Color(115, 195, 255, 110 * (1 - t) ^ 2), 0)
		elseif not self.Cast then
			render.SetMaterial(ring)
			local size = (20 + t * 220) * scale
			render.DrawQuadEasy(self.Origin + self.Normal, self.Normal, size, size, Color(115, 195, 255, 200 * (1 - t) ^ 2), 0)
		end
		local live = math.Clamp(1 - t / 0.65, 0, 1)
		if live > 0 then
			render.SetMaterial(bolt)
			for _, arc in ipairs(self.Arcs) do
				local reach = (self.Cast and 0.35 or 1) * arc.length * math.min(scale, 1.6)
				local tip = origin + arc.dir * reach * (0.4 + 0.6 * math.min(t / 0.25, 1))
				local width = (self.Cast and 6 or 14) * math.min(scale, 1.6)
				lightning(origin, tip, width * live, arc.slot, Color(80, 150, 255, 255 * live), width * 0.4)
				lightning(origin, tip, width * 0.3 * live, arc.slot, Color(230, 245, 255, 255 * live), width * 0.15)
			end
		end
	end
	local fade = math.Clamp(self.Start + self.Life + 0.9 - CurTime(), 0, 0.5) / 0.5
	render.SetBlend(fade)
	for _, link in ipairs(self.Links) do
		if IsValid(link.model) then
			link.model:SetPos(link.pos)
			link.model:SetAngles(link.ang)
			link.model:SetupBones()
			link.model:DrawModel()
		end
	end
	render.SetBlend(1)
end
