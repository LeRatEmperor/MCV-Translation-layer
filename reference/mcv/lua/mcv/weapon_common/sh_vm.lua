// Drives viewmodel bodygroups and pose parameters.
//
// Called from two places on purpose:
//  * Think (server, and the predicting client in multiplayer) with the deterministic
//    gameplay values. Viewmodel bodygroups and pose parameters are networked from the
//    server, so if the server never wrote them the client would keep receiving zeros
//    that fight what it draws (visible as a flickering "ghost" viewmodel, worst in
//    singleplayer where the client does not predict).
//  * The non-predicted GetViewModelPosition call, before bones are built for drawing,
//    with `visual = true`. Pose changes in PreDrawViewModel can arrive after bone setup.
function SWEP:DoBodygroups(vm, visual)
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end

    vm = vm or owner:GetViewModel()

    if !IsValid(vm) then return end

    local sa, speed

    if visual then
        sa = self:GetSightAmountVisual()
        speed = self:GetSpeedVisual()
    else
        sa = self:GetSightAmount()
        speed = self:GetSpeed()
    end

    vm:SetBodyGroups(self.BodyGroups)

    // walk / run layers of every game viewmodel blend on this (sh_think.lua GetMovementPose)
    vm:SetPoseParameter("player_movement", self:GetMovementPose(speed, sa))

    self:DoBodygroupsWeapon(vm, visual, sa, speed)
end

// Class-level defaults only; SWEP:Initialize creates per-instance tables.
SWEP.ActiveEffects = {}
SWEP.PCFs = {}

// Screen-depth consumers (such as gShader) need the same viewmodel silhouette as the colour
// pass: FOV, near plane and depth range must agree. Only the colour composites/effects should
// be skipped. Shadow maps have a light-space projection and must keep the engine's camera.
function SWEP:IsDepthPass(flags)
    flags = flags or 0
    return bit.band(flags, STUDIO_SSAODEPTHTEXTURE) != 0 or bit.band(flags, STUDIO_SHADOWDEPTHTEXTURE) != 0
end

// the pre draw takes (vm, weapon, ply, flags) and the post draw (vm, ply, weapon, flags); the
// render flags are the fourth argument either way
function SWEP:PreDrawViewModel(vm, weapon, ply, flags)
    vm = vm or self:GetOwner():GetViewModel()
    if self:ViewModelHidden() then return true end
    if bit.band(flags or 0, STUDIO_SHADOWDEPTHTEXTURE) != 0 then return end
    local depthpass = self:IsDepthPass(flags)


    if !depthpass then
        self:PreDrawViewModelWeapon(vm)
        self:UpdateLitParticle(vm)
    end

    local sa = self:GetSightAmountVisual() ^ 3

    local fov = MCV.ViewmodelFOV(self, sa)
    if self.ViewModelZNear then
        // a closer near plane keeps an eyepiece the aimed pose puts right at the camera from
        // being cut open (scoped rifles)
        cam.Start3D(nil, nil, fov, 0, 0, ScrW(), ScrH(), self.ViewModelZNear, 32768)
    else
        cam.Start3D(nil, nil, fov)
    end
    self.VMCamOpen = true // PostDrawViewModel closes it; nothing to close if this never ran
    cam.IgnoreZ(true)

    if !depthpass then self:PreDrawViewModelBlend(vm, sa) end
end

// Runs inside the viewmodel's own render pass (the camera PreDrawViewModel set up: the weapon's
// viewmodel FOV and near plane, the engine's viewmodel depth range), so the in-flight shells
// share the gun's projection and sort against it. TacRP's system: a shell lives here until it
// hits something, then draws itself in the world. Nothing is drawn into the depth passes.
function SWEP:ViewModelDrawn(vm, flags)
    if self:IsDepthPass(flags) then return end
    if MCV.CapturePhysicalMuzzles then MCV.CapturePhysicalMuzzles(self, vm) end

    local effects = self.ActiveEffects
    local count, kept = #effects, 0
    for _, effect in ipairs(effects) do
        if !IsValid(effect) then continue end
        if !effect.VMContext then continue end

        effect:DrawModel()

        kept = kept + 1
        effects[kept] = effect
    end

    for i = kept + 1, count do effects[i] = nil end
end

// the lit flame follows the viewmodel's attachment; started when the item lights, stopped
// when it leaves the hand or the weapon is put away (ClientHolster)
function SWEP:UpdateLitParticle(vm)
    if vm != self:GetOwner():GetViewModel() then return end
    local particle = self:GetLitParticle()
    local lit = particle != nil and self:IsLit()
    if lit == (self.VMLit or false) then return end
    self.VMLit = lit
    if lit then
        local att = MCV.CachedAttachment(vm, self.LitAttachment)
        ParticleEffectAttach(particle, PATTACH_POINT_FOLLOW, vm, att > 0 and att or 0)
    else
        vm:StopParticles()
    end
end

local refractionBackup
local function preserveContactShadowBuffer()
    if !shaderlib then return end
    local enabled = GetConVar("r_contact_shadows")
    if !enabled or !enabled:GetBool() then return end

    // Contact Shadows samples this texture for its weapon mask. Updating refraction
    // after drawing the gun replaces that input for as long as muzzle smoke lives.
    local source = render.GetRefractTexture()
    local width, height = source:Width(), source:Height()
    if !refractionBackup or refractionBackup:Width() != width or refractionBackup:Height() != height then
        refractionBackup = GetRenderTargetEx("mcv_refract_saved_" .. width .. "x" .. height,
            width, height, RT_SIZE_NO_CHANGE, MATERIAL_RT_DEPTH_NONE, 0, 0, IMAGE_FORMAT_RGBA8888)
    end
    render.CopyTexture(source, refractionBackup)
    return source
end

function SWEP:PostDrawViewModel(vm, ply, wep, flags)
    local depthpass = self:IsDepthPass(flags)
    // the pre-draw did not get as far as opening its camera (hidden viewmodel, or an error
    // in a weapon hook): nothing to draw into or close
    if !self.VMCamOpen then return end
    self.VMCamOpen = false

    // the viewmodel particle systems (muzzle flash and smoke, shell puffs and trails) are drawn
    // here by hand, still inside the camera PreDrawViewModel started, so they sit exactly on
    // the gun's attachments at its FOV and depth-test against it; they used to be drawn after
    // that camera was closed, in a plain 3D context at the world FOV, which put the flash off
    // the muzzle whenever the two FOVs differed and let the gun paint over it
    local worldpcfs, savedRefraction
    local refractionStarted = false
    if !depthpass then
        cam.IgnoreZ(false)
        if self.RenderingRTScope and MCV.CaptureScopeOverlay then MCV.CaptureScopeOverlay(self, vm) end
        local pcfs = self.PCFs
        local count, kept = #pcfs, 0
        local refractUpdated = false

        for _, pcf in ipairs(pcfs) do
            if pcf and IsValid(pcf) and pcf.Render then
                if self.WorldPCFs and self.WorldPCFs[pcf] then
                    worldpcfs = worldpcfs or {}
                    table.insert(worldpcfs, pcf)
                else
                    // Manual PCF draws need a current refraction source. The scope's
                    // UpdateScreenEffectTexture fills a different buffer. Capture once
                    // per batch, after the gun, before any particles can feed back into it.
                    if !refractUpdated then
                        savedRefraction = preserveContactShadowBuffer()
                        refractionStarted = true
                        render.UpdateRefractTexture()
                        refractUpdated = true
                    end
                    pcf:Render()
                end
                kept = kept + 1
                pcfs[kept] = pcf
            end
        end

        for i = kept + 1, count do pcfs[i] = nil end
    end

    cam.End3D()
    cam.IgnoreZ(false)
    render.SetBlend(1)

    if depthpass then return end

    // systems that reach out into the world (the flamethrower's jet) keep the world's
    // projection, or they would not land where they burn
    if worldpcfs then
        cam.Start3D()
            cam.IgnoreZ(false)
            if !refractionStarted then savedRefraction = preserveContactShadowBuffer() end
            render.UpdateRefractTexture()
            for _, pcf in ipairs(worldpcfs) do pcf:Render() end
        cam.End3D()
    end

    if savedRefraction then render.CopyTexture(refractionBackup, savedRefraction) end

    self:PostDrawViewModelWeapon(vm or self:GetOwner():GetViewModel())
    if self.RenderingRTScope and MCV.CaptureScopeOverlayPixels then MCV.CaptureScopeOverlayPixels(self) end
end

function SWEP:GetViewModelPosition(pos, ang)
    if GetPredictionPlayer() != self:GetOwner() then
        local vm = self:GetOwner():GetViewModel()
        self:UpdateViewModelAnimation(vm)
        self:DoBodygroups(vm, true)
        if IsValid(vm) then vm:InvalidateBoneCache() end
    end
    local aim_delta = self:GetSightAmountVisual()

    local ipos, iang = self.IronsightPos, self.IronsightAng
    // the dual models aim from their own script offsets where those differ
    if self.GetAkimbo and self:GetAkimbo() and self.IronsightPosAkimbo then
        ipos, iang = self.IronsightPosAkimbo, self.IronsightAngAkimbo or iang
    elseif self.GetGrenadeLauncher and self:GetGrenadeLauncher() and self.IronsightPosLauncher then
        // A scoped rifle can use a different eye position for its launcher ladder.
        ipos, iang = self.IronsightPosLauncher, self.IronsightAngLauncher or iang
    end
    local offsetpos = LerpVector(aim_delta, self.CustomPos, ipos)
    local x, y, z = MCV.ViewmodelPositionOffset(aim_delta)
    offsetpos.x = offsetpos.x + x
    offsetpos.y = offsetpos.y + y
    offsetpos.z = offsetpos.z + z
    local offsetang = LerpAngle(aim_delta, self.CustomAng, iang)

    // the gun points where it shoots: the hip sway of realistic mode turns the whole viewmodel
    if self.GetAimSway then
        local sw = self:GetAimSway(true)
        if sw != angle_zero then
            ang:RotateAroundAxis(ang:Right(), -sw.p)
            ang:RotateAroundAxis(ang:Up(), sw.y)
        end
    end

    // An angular kick projected through the narrower viewmodel FOV rises farther
    // than the same kick in the world. Reproject relative to this frame's camera
    // before applying the authored offsets. Rest alignment and hip placement stay
    // intact; animation-local recoil remains part of the model's animation.
    if aim_delta > 0 and self.ViewmodelCameraFrame == FrameNumber() then
        local camera = self.ViewmodelCameraAngle
        local _, relative = WorldToLocal(vector_origin, ang, vector_origin, camera)
        local pitch, yaw = MCV.ViewmodelRecoilProjection(relative.p, relative.y,
            MCV.ViewmodelFOV(self, aim_delta ^ 3), self.ViewmodelCameraFOV, 1.5)
        relative = LerpAngle(aim_delta, relative, Angle(pitch, yaw, relative.r))
        local _, projected = LocalToWorld(vector_origin, relative, vector_origin, camera)
        ang:Set(projected)
    end

    pos:Add(ang:Right() * offsetpos.x)
    pos:Add(ang:Forward() * offsetpos.y)
    pos:Add(ang:Up() * offsetpos.z)

    // offsetang.y = offsetang.y + (aim_punch.p * 0.5)
    // offsetang.p = offsetang.p + (aim_punch.y * 0.5)

    // the script's ironsightpitch / yaw / roll: pitch turns about the viewmodel's right axis,
    // yaw about up (they were the other way round, which left the P38's 0.9 degree sight
    // pitch applied as a yaw and its front post below the notch)
    ang:RotateAroundAxis(ang:Right(), offsetang.p)
    ang:RotateAroundAxis(ang:Up(), offsetang.y)
    ang:RotateAroundAxis(ang:Forward(), offsetang.r)

    return pos, ang
end
