local beam = Material("effects/laser1")

function EFFECT:Init(data)
	local source = data:GetEntity()
	local weapon = IsValid(source) and (source:IsWeapon() and source or (source.GetActiveWeapon and source:GetActiveWeapon()))
	self.Start = data:GetStart()
	self.End = data:GetOrigin()
	self.Width = 0.9
	if IsValid(weapon) and weapon.HR then
		local owner = weapon:GetOwner()
		local first = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()
		local model = first and owner:GetViewModel() or weapon
		local attachment = first and model:GetAttachment(model:LookupAttachment("muzzle")) or weapon:GetWorldAttachment("muzzle")
        local config = weapon.HR
        if weapon.DualWield then
            local side = (self.Start - owner:GetShootPos()):Dot(owner:EyeAngles():Right()) < 0 and 1 or 2
            attachment = weapon:GetEffectAttachment("muzzle", side)
            config = weapon:Gun(side).config
        end
		if attachment then self.Start = first and weapon:ViewModelEffectPosition(attachment.Pos) or attachment.Pos end
		self.Width = config.crosshair == "shotgun" and 0.5 or config.crosshair == "smg" and 0.7 or 0.9
	end
	local delta = self.End - self.Start
	self.Distance = delta:Length()
	self.Direction = delta:GetNormalized()
	self.Speed = math.max(14000, self.Distance / 0.22)
	self.Born = CurTime()
	self.Arrival = self.Distance / self.Speed
	self.Die = self.Born + self.Arrival + 0.05
	self:SetPos(self.Start)
	local a, b = self.Start, self.End
	self:SetRenderBoundsWS(Vector(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)),
		Vector(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z)), Vector(16, 16, 16))
end

function EFFECT:Think()
	return CurTime() < self.Die
end

function EFFECT:Render()
	local age = CurTime() - self.Born
	local head = math.min(self.Distance, math.max(16, age * self.Speed))
	local tail = math.max(0, head - 180)
	local front = self.Start + self.Direction * head
	local back = self.Start + self.Direction * tail
	local fade = 1 - math.Clamp((age - self.Arrival) / 0.05, 0, 1)
	local width = self.Width * math.Clamp(EyePos():Distance(front) / 450, 1, 3)
	render.SetMaterial(beam)
	render.DrawBeam(back, front, width * 2, 0, 1, Color(255, 192, 104, 180 * fade))
	render.DrawBeam(back, front, width * 0.65, 0, 1, Color(255, 248, 219, 255 * fade))
end
