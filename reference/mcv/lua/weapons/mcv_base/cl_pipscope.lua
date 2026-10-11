// Scope picture: screen reprojection, done by the lens material's own shader.
//
// While aiming, the lens submaterial is swapped for materials/mcv/scope_lens.vmt. Its pixel
// shader (work/shaders/mcv_scope_ps3x.hlsl) samples the frame captured just before the
// viewmodel was drawn - the world without the gun - and magnifies it around the point where
// the scope axis meets the screen. The world is never rendered a second time; the per-frame
// cost is one frame copy (into our own texture before viewmodel/shader effects,
// lua/mcv/client/cl_rendertarget.lua) and two floats for that axis point, projected from the
// muzzle attachment so the picture follows the gun's sway. The exit pupil slides against the
// axis point's offset from the screen centre (the eye off the scope axis), the reticle is the
// material's second texture, the tube rim, edge blur, chromatic aberration and barrel
// distortion sit on top. The look constants are static per weapon.

local LENS_MATERIAL = "mcv/scope_lens"
local lensmat = Material(LENS_MATERIAL)
local HAVE_SHADER = !lensmat:IsError()
local scopeScene
// per-weapon override of the lens material (debug variants)
SWEP.ScopeLensMaterial = nil

// Look of the lens; all static, sent to the shader when the weapon is deployed and aimed.
SWEP.ScopePupilSlide = 0       // unused since the shadow is drawn on the reticle plane; kept for the VMT constant
SWEP.ScopeLensSize = 0.75      // lens diameter on screen as a fraction of its height (the eyepiece offsets are tuned to this)
SWEP.ScopeShadowStrength = 1   // 0 disables the exit pupil and tube rim
SWEP.ScopeShadowSize = 0.84    // clear picture diameter, fraction of the reticle plane (the plane is ScopeLensSize of the screen height, centred on the aim point)
SWEP.ScopeShadowSoftness = 0.1
SWEP.ScopeDistortion = -0.12   // barrel distortion (negative pulls the edge in)
SWEP.ScopeAberration = 0.006   // chromatic aberration, lens widths
SWEP.ScopeEdgeBlur = 0.005      // softening towards the edge, lens widths
SWEP.ScopeBrightness = 1
SWEP.ReticleStrength = 1

function SWEP:GetScopeFOV()
    if self:GetScopeLevel() == 2 and self.ScopeFOV2 then
        return self.ScopeFOV2
    end
    return self.ScopeFOV
end

// The occluded eye gunsight (OEGScope) is a scope too: the game's lens_singlepoint is a
// scope-lens Refract showing the scope picture, and its dot is an additive glow mesh lit up
// while aimed. Here the lens shader draws the picture and adds the glow texture's dot on the
// reticle plane (additive mode, $c2_x), so the dot sits where the shot goes; the model's own
// glow mesh stays dark. The see-through comes from the viewmodel composite (mcv_base/sh_vm.lua).
function SWEP:ShouldDoScope()
    return self:GetIronsight() and self.HasScope
end

// the model's glow mesh (lens_singlepoint_glow, additive): drawn with a material that adds
// nothing, since the dot comes from the lens shader on the reticle plane instead
local NODRAW = CreateMaterial("mcv_nodraw", "UnlitGeneric", {["$basetexture"] = "vgui/white", ["$additive"] = "1", ["$color"] = "[0 0 0]", ["$color2"] = "[0 0 0]"})

function SWEP:HideOEGGlow(vm)
    if !self.OEGScope or !IsValid(vm) then return end
    if self.OEGGlowIndex == nil then
        self.OEGGlowIndex = false
        for i, name in ipairs(vm:GetMaterials()) do
            if name:lower():find("singlepoint_glow", 1, true) then self.OEGGlowIndex = i - 1 break end
        end
    end
    if self.OEGGlowIndex then vm:SetSubMaterial(self.OEGGlowIndex, "!mcv_nodraw") end
end

// The reticle texture behind a ScopeMaterial. The game's crosshair_* VMTs are model materials
// (some of them Refract lens shaders), so the texture is read off the material rather than
// the material being drawn.
local function reticleTexture(mat)
    if !mat or !mat.GetString then return nil end
    local tex = mat:GetString("$refracttinttexture")
    if !tex or tex == "" or tex:find("_rt_") then tex = mat:GetString("$basetexture") end
    return tex
end

// Pushes this weapon's look into the shared lens material. Called when the lens is swapped
// in and whenever the scope level changes.
function SWEP:ApplyScopeMaterial()
    if !HAVE_SHADER then return end
    local strength = self.ScopeShadowStrength
    lensmat:SetFloat("$c0_x", self:GetScopeFOV() / self:GetScopeWorldFov())
    lensmat:SetFloat("$c3_w", self.ScopeLensSize)
    lensmat:SetFloat("$c0_y", self.ScopePupilSlide)
    lensmat:SetFloat("$c0_z", strength > 0 and self.ScopeShadowSize / 2 or 4)
    lensmat:SetFloat("$c0_w", self.ScopeShadowSoftness)
    lensmat:SetFloat("$c1_x", self.ScopeDistortion)
    lensmat:SetFloat("$c1_y", self.ScopeAberration)
    lensmat:SetFloat("$c1_z", self.ScopeEdgeBlur)
    lensmat:SetFloat("$c1_w", strength > 0 and 0.49 or 4)
    lensmat:SetFloat("$c2_x", self.OEGScope and 1 or 0) // additive (glowing) reticle
    lensmat:SetFloat("$c2_y", self.ScopeBrightness)
    lensmat:SetFloat("$c2_z", ScrW() / ScrH())

    local tex = reticleTexture(self.ScopeMaterial)
    if tex and tex != "" then
        lensmat:SetTexture("$texture1", tex)
        lensmat:SetFloat("$c2_w", self.ReticleStrength)
    else
        lensmat:SetFloat("$c2_w", 0)
    end
end

// Capture after world translucency/effects, immediately before the viewmodel. Capturing
// before gShader reconstruction loses particles and translucent objects from the lens.
// A private texture keeps later shared-buffer updates from changing the scope picture.
function SWEP:CaptureScopeScreen()
    if !HAVE_SHADER or !self.HasScope then return end
    if self:GetSightAmountVisual() <= 0.5 or !self:ShouldDoScope() then return end
    scopeScene = scopeScene or GetRenderTargetEx("mcv_scope_scene", ScrW(), ScrH(),
        RT_SIZE_FULL_FRAME_BUFFER, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0,
        IMAGE_FORMAT_RGB888)
    render.CopyRenderTargetToTexture(scopeScene)
    lensmat:SetTexture("$basetexture", scopeScene)
    return true
end

// Where the scope axis meets the screen (0..1, y down): the muzzle attachment's forward, read
// while the viewmodel is set up for drawing, projected far ahead. The shader magnifies the
// screen around this point, so the picture follows the gun's sway.
SWEP.ScopeDebug = 0            // 1 lens uv, 2 solid red, 3 outline the reticle plane (magenta square, cyan circle)

function SWEP:UpdateScopeAxis(vm)
    // The reticle sits where the shot goes: the aim angle (eye angles plus the view punch the
    // recoil put on the gun), not the lens mesh and not the muzzle attachment. The camera
    // itself takes most of the punch back out (cl_camera.lua), so the point moves across the
    // lens with each kick and settles as the punch decays.
    local owner = self:GetOwner()
    local fwd = self:GetAimVector() // the gun base's: eye angles plus twice the view punch
    local scr = (owner:EyePos() + fwd * 4096):ToScreen()
    local x, y = scr.x / ScrW(), scr.y / ScrH()
    if !scr.visible or x != x or y != y then x, y = 0.5, 0.5 end
    lensmat:SetFloat("$c3_x", math.Clamp(x, -1, 2))
    lensmat:SetFloat("$c3_y", math.Clamp(y, -1, 2))
    lensmat:SetFloat("$c3_z", self.ScopeDebug)
end

// Swaps the lens submaterial while aiming; runs from PreDrawViewModel.
function SWEP:DoRTScope()
    if !self.HasScope then return end

    local active = self:GetSightAmountVisual() > 0.5
    local model = self:GetOwner():GetViewModel()
    self:HideOEGGlow(model)

    if active and self:ShouldDoScope() and HAVE_SHADER then
        if !self.RenderingRTScope or self.ScopeLevelApplied != self:GetScopeLevel() then
            self:ApplyScopeMaterial()
            self.ScopeLevelApplied = self:GetScopeLevel()
        end
        self:UpdateScopeAxis(model)
        self.RenderingRTScope = true
        model:SetSubMaterial(self.RTScopeMaterialIndex, self.ScopeLensMaterial or LENS_MATERIAL)
        // screenspace_general leaves the depth state to chance on a model: on the SVD the
        // scope body, drawn after the lens, painted over it. Force depth test and write for
        // the viewmodel pass; PostDrawViewModelWeapon (mcv_base/sh_vm.lua) resets it.
        render.OverrideDepthEnable(true, true)
    else
        // Not aiming: glass with its reflections, the model's own unless it hasn't any
        self.RenderingRTScope = false

        if (self.ScopeIdleLensMaterial or "") != "" then
            model:SetSubMaterial(self.RTScopeMaterialIndex, self.ScopeIdleLensMaterial)
        else
            model:SetSubMaterial(self.RTScopeMaterialIndex)
        end
    end
end

// Kept for callers of the old screen-copy path.
function SWEP:DoCheapScope() end
function SWEP:RenderScopeView() end
