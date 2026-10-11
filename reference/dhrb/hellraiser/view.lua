local drawFlash = include("hellraiser/flash.lua")
local drawMotionBlur = include("hellraiser/motion_blur.lua")
local glow = Material("sprites/light_glow02_add")
local dot = Material("hellraiser/ui/dot")
local line = Material("hellraiser/ui/line")
local spikes = Material("hellraiser/ui/cube")
local takedown = Material("hellraiser/ui/takedown")
local mouseLeft = Material("hellraiser/ui/mouse_lb")
local keyCap = Material("hellraiser/ui/key")
local scopeView = Material("hellraiser/ui/scope")
local lensDirt = Material("hellraiser/ui/lens_dirt")

local function createPromptFont()
	surface.CreateFont("HRPrompt", { font = (system.IsLinux() and "sarala-regular.ttf" or "Sarala"), size = math.max(16, math.Round(34 * ScrH() / 1080)), weight = 400, antialias = true })
end
createPromptFont()
hook.Add("OnScreenSizeChanged", "hr_prompt_font", createPromptFont)

function SWEP:ApplyViewMotion(vm, pos, ang)
	local owner = self:GetOwner()
	if not IsValid(owner) then return pos, ang end
	local now = FrameNumber()
	if self.hr_motion_frame ~= now then
		local dt = math.min(FrameTime(), 0.05)
		local smooth = GetConVar("hr_smooth_aim"):GetBool()
		self.hr_aimed = smooth and (self.hr_fovfrac or 0) or (self:GetAiming() and 1 or 0)
		local look = owner:EyeAngles()
		local previous = self.hr_look or look
		local target = Angle(math.Clamp(math.AngleDifference(look.p, previous.p), -8, 8),
			math.Clamp(math.AngleDifference(look.y, previous.y), -8, 8), 0)
		self.hr_sway = LerpAngle(1 - math.exp(-dt * 12), self.hr_sway or Angle(), target * Lerp(self.hr_aimed, 1, 0.04))
		self.hr_look = Angle(look.p, look.y, look.r)
		self.hr_recoil = (self.hr_recoil or 0) * math.exp(-dt * 7.8)
		self.hr_shot_roll = (self.hr_shot_roll or 0) * math.exp(-dt * 16)
		self.hr_kick = smooth and Lerp(1 - math.exp(-dt * 35), self.hr_kick or 0, self.hr_recoil) or self.hr_recoil
		self.hr_motion_frame = now
	end
	local sway = self.hr_sway or Angle()
	local aimed = self.hr_aimed or 0
	local scoped = self:HasScopeLens()
	local kick = (self.hr_kick or 0) * Lerp(aimed, 1, scoped and 0.08 or self.HR.ads_kick or 1)
	local turn = Angle(ang.p, ang.y, ang.r)
	local right, up, forward = ang:Right(), ang:Up(), ang:Forward()
	turn:RotateAroundAxis(up, -sway.y * 0.3)
	turn:RotateAroundAxis(right, sway.p * 0.25 + kick * 0.95)
	turn:RotateAroundAxis(forward, -sway.y * 0.1 + (self.hr_shot_roll or 0) * (1 - aimed))
	local offset = self.HR.sprint_angles
	if offset then
		local target = self:IsRunning() and not self:GetAiming() and 1 or 0
		self.hr_sprint_blend = math.Approach(self.hr_sprint_blend or 0, target, FrameTime() * 8)
		turn:RotateAroundAxis(up, offset.y * self.hr_sprint_blend)
		turn:RotateAroundAxis(right, -offset.p * self.hr_sprint_blend)
	end
	pos = pos - forward * kick + right * (-sway.y * 0.025) + up * (sway.p * 0.025)
	if scoped then
		local offset = self.HR.scope.aim
		pos = pos + (right * offset.x + forward * offset.y + up * offset.z) * aimed
	end
	local aim = self.HR.aim
	if aim then
		local offset = aim.pos or vector_origin
		local rotation = aim.ang or angle_zero
		pos = pos + (right * offset.x + forward * offset.y + up * offset.z) * aimed
		turn:RotateAroundAxis(right, rotation.p * aimed)
		turn:RotateAroundAxis(up, rotation.y * aimed)
		turn:RotateAroundAxis(forward, rotation.r * aimed)
	end
	if HRWall then pos, turn = HRWall.ViewOffset(self, pos, ang, turn) end
	return DHRBash.View(self, pos, turn)
end

function SWEP:PostDrawViewModel(vm)
	DHRScope.Draw(self, vm)
	if self.hr_view_effect_frame == FrameNumber() then return end
	self.hr_view_effect_frame = FrameNumber()
	if HRSmoke and self.HR.kind == "gun" then HRSmoke.MuzzleRendered(self, vm) end
	if self.hr_pending_magazine then
		local pending = self.hr_pending_magazine
		self.hr_pending_magazine = nil
		if pending.sequence == vm:GetSequence() then self:EjectMagazine(pending.index, vm:GetSequenceName(pending.sequence), pending.rounds) end
	end
	local cases = self.hr_pending_cases or 0
	self.hr_pending_cases = 0
	for i = 1, cases do self:EjectCase() end
	local mask = self.hr_pending_revolver_cases or 0
	self.hr_pending_revolver_cases = nil
	if mask ~= 0 then
		for i = 1, 6 do
			if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then self:EjectCase(string.format("w_bullet_%02d_jnt", i)) end
		end
		self.hr_ejected_mask = mask
		self.hr_ejected_sequence = vm:GetSequenceName(vm:GetSequence())
		self.hr_ejected_until = self:GetNW2Float("hr_casing_show", 0)
	end
	local remaining = (self.hr_muzzle_until or 0) - CurTime()
	if remaining > 0 and not self:GetNW2Bool("hr_executing") then
		local a = vm:GetAttachment(vm:LookupAttachment("muzzle"))
		if a then
			local pos = self:ViewModelEffectPosition(a.Pos)
			drawFlash(self, pos, a.Ang:Forward(), remaining, true)
		end
	end
	if self.DrawCubeGlow then self:DrawCubeGlow(vm) end
	drawMotionBlur(self, vm)
end

local function drawBar(x, y, distance, length, width, angle, alpha)
	local rad = math.rad(angle)
	surface.SetMaterial(line)
	surface.SetDrawColor(245, 241, 235, alpha)
	surface.DrawTexturedRectRotated(x + math.cos(rad) * distance, y + math.sin(rad) * distance,
		width, length, 90 - angle)
end

function SWEP.DrawGameCrosshair(x, y, kind, bloom, alpha)
	if HRWheel and HRWheel.open then return end
	local k = math.min(ScrW() / 3840, ScrH() / 2160)
	if kind == "dot" then
		surface.SetMaterial(dot)
		surface.SetDrawColor(245, 241, 235, alpha)
		surface.DrawTexturedRect(x - 4 * k, y - 4 * k, 8 * k, 8 * k)
		return
	end
	if kind == "shotgun" then
		for i = 0, 3 do
			drawBar(x, y, (32 + bloom) * k, 2 * k, 24 * k, 45 + i * 90, alpha)
		end
		return
	end
	local length = kind == "smg" and 48 or 28
	local turn = kind == "smg" and 45 or 0
	for i = 0, 3 do
		drawBar(x, y, (17 + bloom + length / 2) * k, length * k, 8 * k, i * 90 + turn, alpha)
	end
end

function SWEP:DrawHRCrosshair(x, y)
	if HRWheel and HRWheel.open then return end
	local style = GetConVar("hr_hud_crosshair"):GetInt()
	if style <= 0 or self:GetAiming() or self:IsRunning() then return end
	local k = math.min(ScrW() / 3840, ScrH() / 2160)
	local kind = self.HR.crosshair
	local alpha = (self:GetReloadDone() > 0 or self:GetReloadStage() > 0) and 110 or 220
	local quiet = style == 2 and CurTime() - (self.hr_shot_time or -10) > 1.5
	if kind == "cube" and style ~= 3 then
		local pulse = math.max(0, (self:GetBusyUntil() - CurTime()) / 1.5)
		local size = (148 + math.min(pulse, 1) * 36) * k
		surface.SetMaterial(spikes)
		surface.SetDrawColor(245, 241, 235, alpha)
		surface.DrawTexturedRect(x - size / 2, y - size / 2, size, size)
		surface.SetMaterial(dot)
		surface.DrawTexturedRectRotated(x, y, 12 * k, 12 * k, 45)
		return
	end
	if self.HR.kind == "melee" or kind == "cube" or style == 3 or quiet then kind = "dot" end
	local motion = math.min(self:GetOwner():GetVelocity():Length2D() / 180, 1)
	self.DrawGameCrosshair(x, y, kind, (self.hr_recoil or 0) * 14 + motion * 12, alpha)
end

function SWEP:DrawHRHitMarker(x, y)
	if not GetConVar("hr_hud_hitmarkers"):GetBool() then return end
	local remaining = (self.hr_hit_until or 0) - CurTime()
	if remaining <= 0 or not self:GetOwner():Alive() or self:GetNW2Bool("hr_executing") then return end
	local scale = math.max(ScrH() / 1080, 0.65)
	local alpha = 255 * math.min(remaining / 0.14, 1)
	for i = 0, 3 do
		drawBar(x, y, 11 * scale, 10 * scale, 5 * scale, 45 + i * 90, alpha)
	end
end

local recoilCurves = DHR.LoadData("hellraiser/recoil_data.lua", {})

function SWEP:BeginRecoil()
	local key = self.HR.recoil_class or self:GetClass()
	local installed = HRUpgrades.Installed(self)
	for _, u in ipairs(self.HR.upgrades or {}) do
		if u.curves and installed[u.id] and recoilCurves[key .. ":" .. u.curves] then key = key .. ":" .. u.curves end
	end
	local curves = self.HR.recoil_curves or recoilCurves[key]
	if not curves then return end
	self.hr_recoil_curve = curves[math.random(#curves)]
	self.hr_recoil_start = CurTime()
	self.hr_recoil_previous = {0, 0}
end

hook.Add("CreateMove", "hr_weapon_recoil", function(cmd)
	local p = LocalPlayer()
	if not IsValid(p) or not p:Alive() then return end
	local w = p:GetActiveWeapon()
	if not IsValid(w) or not w.hr_recoil_curve or w:GetNW2Bool("hr_executing") then return end
	local curve = w.hr_recoil_curve
	local elapsed = CurTime() - w.hr_recoil_start
	local frame = math.Clamp(elapsed / curve.length, 0, 1) * (#curve.values - 1)
	local i = math.floor(frame) + 1
	local a, b = curve.values[i], curve.values[math.min(i + 1, #curve.values)]
	local scale = HRUpgrades.Get(w, "recoil")
	local pitch = Lerp(frame % 1, a[1], b[1]) * scale
	local yaw = Lerp(frame % 1, a[2], b[2]) * scale
	local previous = w.hr_recoil_previous
	local ang = cmd:GetViewAngles()
	ang.p = math.Clamp(ang.p - (pitch - previous[1]), -89, 89)
	ang.y = ang.y + yaw - previous[2]
	cmd:SetViewAngles(ang)
	w.hr_recoil_previous = {pitch, yaw}
	if elapsed >= curve.length then w.hr_recoil_curve = nil end
end)

function SWEP:ViewModelEffectPosition(pos)
	local view = render.GetViewSetup()
	local offset = pos - view.origin
	local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
	local ratio = math.tan(math.rad(view.fovviewmodel_unscaled) / 2)
		/ math.tan(math.rad(view.fov_unscaled) / 2)
	return view.origin + forward * offset:Dot(forward)
		+ (right * offset:Dot(right) + up * offset:Dot(up)) * ratio
end

function SWEP:DrawHRTakedownPrompt()
	if not GetConVar("hr_hud_prompts"):GetBool() then self.hr_prompt_alpha = 0 return end
	local target = self:GetNW2Entity("hr_takedown")
	local show = IsValid(target) and not self:GetNW2Bool("hr_executing")
	if show then
		self.hr_prompt_target = target
		self.hr_prompt_front = self:GetNW2Bool("hr_takedown_front")
	end
	self.hr_prompt_alpha = math.Approach(self.hr_prompt_alpha or 0, show and 1 or 0, FrameTime() * 8)
	target = self.hr_prompt_target
	if self.hr_prompt_alpha <= 0 or not IsValid(target) then return end

	local bone = target:LookupBone("ValveBiped.Bip01_Spine2")
	local pos = bone and target:GetBonePosition(bone) or target:WorldSpaceCenter()
	local screen = pos:ToScreen()
	if not screen.visible then return end

	local s = ScrH() / 1080
	local a = self.hr_prompt_alpha
	local label = self.hr_prompt_front and "Front execution" or "Rear takedown"
	surface.SetFont("HRPrompt")
	local tw = surface.GetTextSize(label)
	local key = input.LookupBinding("+attack") or "MOUSE1"
	local mouse = key == "MOUSE1"
	local keyW = mouse and 26 * s or 50 * s
	local gap = 12 * s
	local box = 65 * s
	local width = keyW + gap + tw + gap + box
	local x = math.Round(screen.x - width / 2)
	local y = math.Round(screen.y)

	surface.SetDrawColor(20, 23, 28, 38 * a)
	surface.DrawRect(x + 27 * s, y - 27 * s, width - 55 * s, 55 * s)

	if mouse then
		surface.SetMaterial(mouseLeft)
		surface.SetDrawColor(255, 255, 255, 255 * a)
		surface.DrawTexturedRect(x, y - 27 * s, keyW, 55 * s)
	else
		surface.SetMaterial(keyCap)
		surface.SetDrawColor(230, 237, 250, 255 * a)
		surface.DrawTexturedRect(x, y - 25 * s, keyW, 50 * s)
		draw.SimpleText(string.upper(key), "HRPrompt", x + keyW / 2, y, Color(20, 23, 28, 255 * a), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
	end

	draw.SimpleTextOutlined(label, "HRPrompt", x + keyW + gap, y, Color(230, 237, 250, 255 * a),
		TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER, 1, Color(0, 0, 0, 128 * a))

	local bx = x + width - box
	draw.RoundedBox(4 * s, bx, y - box / 2, box, box, Color(194, 93, 93, 179 * a))
	draw.RoundedBox(0, bx + 5 * s, y - 27.5 * s, 55 * s, 55 * s, Color(20, 23, 28, 255 * a))
	surface.SetMaterial(takedown)
	surface.SetDrawColor(255, 255, 255, 255 * a)
	surface.DrawTexturedRect(bx + box / 2 - 26 * s, y - 46.5 * s, 52 * s, 93 * s)
end

function SWEP:DrawHRScope()
	if self:HasScopeLens() then return end
	local f = self:ScopeFraction()
	if f < 0.85 then return end
	local a = math.Clamp((f - 0.85) / 0.1, 0, 1)
	local size = ScrH()
	local x = (ScrW() - size) / 2
	surface.SetDrawColor(0, 0, 0, 255 * a)
	surface.DrawRect(0, 0, math.ceil(x) + 1, ScrH())
	surface.DrawRect(math.floor(x + size) - 1, 0, ScrW() - x - size + 2, ScrH())
	surface.SetMaterial(scopeView)
	surface.SetDrawColor(255, 255, 255, 255 * a)
	surface.DrawTexturedRect(x, 0, size, size)
	surface.SetMaterial(lensDirt)
	surface.SetDrawColor(255, 255, 255, 34 * a)
	surface.DrawTexturedRect(x, 0, size, size)
end


function SWEP:PlayShotSound()
	if not IsValid(self:GetOwner()) then return end
	self:EmitSound(self:GetShotSound(true))
end

function SWEP:EjectCase(bone)
	local owner = self:GetOwner()
	if not IsValid(owner) then return end
	local first = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()
	local source = first and owner:GetViewModel() or self
	local a = first and source:GetAttachment(source:LookupAttachment("shell")) or self:GetWorldAttachment("shell", bone)
	local pos = a and a.Pos
	if bone and first then
		local id = source:LookupBone(bone)
		local matrix = id and source:GetBoneMatrix(id)
		if matrix then pos = matrix:GetTranslation() end
	end
	if not pos then pos = owner:WorldSpaceCenter() + owner:GetForward() * 12 end
	if first then pos = self:ViewModelEffectPosition(pos) end
	local fx = EffectData()
	fx:SetOrigin(pos)
	fx:SetAngles(owner:EyeAngles())
	fx:SetEntity(self)
	util.Effect("hr_shell", fx)
end

function SWEP:EjectMagazine(index, sequence, rounds, rig)
	local owner, part = self:GetOwner(), (self.HR.magazines or {})[index]
	local release = (self.HR.magazine_release or {})[sequence]
	local pose = release and release.parts[index]
	if not IsValid(owner) or not part or not pose then return end
	local first = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()
	local attachment
	local model = rig or (first and owner:GetViewModel())
	if IsValid(model) then
		local bone = model:LookupBone(release.root)
		local matrix = bone and model:GetBoneMatrix(bone)
		if matrix then attachment = {Pos = matrix:GetTranslation(), Ang = matrix:GetAngles()} end
	elseif not first then
		attachment = self:GetWorldAttachment("magazine_root", release.root)
	end
	if not attachment then return end
	local position, angle = LocalToWorld(Vector(unpack(pose.pos)), Angle(unpack(pose.ang)), attachment.Pos, attachment.Ang)
	local velocity = Vector(unpack(pose.velocity))
	velocity:Rotate(attachment.Ang)
	if velocity:LengthSqr() > 90000 then velocity = velocity:GetNormalized() * 300 end
	if first then
		local view = render.GetViewSetup()
		local offset = position - view.origin
		local forward, right, up = view.angles:Forward(), view.angles:Right(), view.angles:Up()
		local factor = math.tan(math.rad(view.fov_unscaled)/2) / math.tan(math.rad(view.fovviewmodel_unscaled)/2)
		position = view.origin + forward * offset:Dot(forward) + (right * offset:Dot(right) + up * offset:Dot(up)) * factor
	end
	local fx = EffectData()
	fx:SetEntity(self)
	fx:SetFlags(index)
    if self.DualWield then fx:SetAttachment(self.dhr_side or 2) end
	fx:SetMagnitude(math.max(0, rounds or 0))
	fx:SetOrigin(position)
	fx:SetAngles(angle)
	local carry = owner:GetVelocity()
	carry.z = math.min(carry.z, 0)
	velocity.z = math.min(velocity.z, 0)
	fx:SetStart(carry + velocity - Vector(0, 0, 30))
	util.Effect("hr_magazine", fx)
end

function SWEP:FireAnimationEvent(pos, ang, event, options)
	local owner = self:GetOwner()
	if event == 5004 and owner == LocalPlayer() and options then
		local vm = owner:GetViewModel()
		local sequence = IsValid(vm) and vm:GetSequenceName(vm:GetSequence())
		if (self.HR.world_events or {})[sequence] and (sequence == self.HR.seq.draw or owner:ShouldDrawLocalPlayer()) then return true end
		self.hr_animation_sounds = self.hr_animation_sounds or {}
		local now = RealTime()
		if now - (self.hr_animation_sounds[options] or -1) < 0.06 then return true end
		self.hr_animation_sounds[options] = now
		local script = sound.GetProperties(options)
		if script then
			local path = istable(script.sound) and table.Random(script.sound) or script.sound
			local pitch = istable(script.pitch) and math.random(script.pitch[1], script.pitch[2]) or script.pitch or 100
			self:EmitSound(path:gsub("^[%)%^]", ""), 0, pitch, 1, CHAN_AUTO)
			return true
		end
	end
	if event == 6003 then
		if IsValid(owner) and owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer() then
			local index = self:MagazinePart()
			if index then self.hr_pending_magazine = {index = index, sequence = owner:GetViewModel():GetSequence(), rounds = self:GetNW2Int("hr_magazine_rounds", self.hr_magazine_rounds or 0)} end
		end
		return true
	end
	if event ~= 6001 and event ~= 6002 then return end
	if not IsValid(owner) or owner ~= LocalPlayer() or owner:ShouldDrawLocalPlayer() then return true end
	if event == 6002 then
		self.hr_pending_revolver_cases = bit.band(tonumber(options) or 0, bit.bnot(self:CasingMask()))
	else
		self.hr_pending_cases = (self.hr_pending_cases or 0) + 1
	end
	return true
end
