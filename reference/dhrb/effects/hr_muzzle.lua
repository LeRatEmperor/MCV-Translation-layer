local drawFlash = include("hellraiser/flash.lua")
local lights = CreateClientConVar("hr_muzzle_lights", "1", true, false, "Light nearby surfaces and characters when Hellraiser guns fire")

function EFFECT:Init(data)
	self.Weapon = data:GetEntity()
	self.Die = CurTime() + 0.075
	if not IsValid(self.Weapon) then return end
	local owner = self.Weapon:GetOwner()
	self.FirstPerson = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()
	self.Side = data:GetAttachment()
    self.Config = self.Weapon.DualWield and self.Weapon:Gun(self.Side).config or self.Weapon.HR
	local source = self.FirstPerson and owner:GetViewModel() or self.Weapon
	local a = self.FirstPerson and IsValid(source) and source:GetAttachment(source:LookupAttachment("muzzle")) or self.Weapon:GetWorldAttachment("muzzle")
	if self.Weapon.GetEffectAttachment then a = self.Weapon:GetEffectAttachment("muzzle", self.Side) end
	self:SetPos(a and a.Pos or data:GetOrigin())
	self:SetRenderBounds(Vector(-64, -64, -64), Vector(64, 64, 64))
	if not lights:GetBool() then return end
	local position = self:GetPos()
	if self.FirstPerson then position = self.Weapon:ViewModelEffectPosition(position) end
	if IsValid(owner) then
		local origin = owner:IsPlayer() and owner:GetShootPos() or owner:WorldSpaceCenter()
		if position:DistToSqr(origin) > 100^2 then position = origin + owner:GetForward()*24 end
		local trace = util.TraceLine({start=origin, endpos=position, filter={owner,self.Weapon}, mask=MASK_SOLID_BRUSHONLY})
		if trace.Hit then position = trace.HitPos + trace.HitNormal*3 end
	end
	local dl = DynamicLight(self.Weapon:EntIndex())
	if dl then
		dl.pos = position
		dl.r, dl.g, dl.b = 255, 192, 118
		dl.brightness = 4
		local radius = math.Clamp(300 * math.sqrt(self.Config.flash or 1), 230, 420)
		dl.size = radius
		dl.decay = radius / .12
		dl.dietime = CurTime() + .12
		dl.noworld, dl.nomodel = false, false
	end
end

function EFFECT:Think()
	return CurTime() < (self.Die or 0) and IsValid(self.Weapon)
end

function EFFECT:Render()
	if self.FirstPerson or not IsValid(self.Weapon) then return end
	local a = self.Weapon:GetWorldAttachment("muzzle", nil, self.Side)
	if not a then return end
	if self.Weapon.DualWield then
        self.Weapon:WithGun(self.Side, drawFlash, a.Pos, a.Ang:Forward(), self.Die - CurTime(), false)
    else drawFlash(self.Weapon, a.Pos, a.Ang:Forward(), self.Die - CurTime(), false) end
end
