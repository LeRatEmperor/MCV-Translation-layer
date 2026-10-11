// Preserve lens pixels across screen-space effects without removing the gun from
// their depth buffers. Build the mask in the VM camera; composite before the HUD.
local layer, scene, sceneMaterial, composite, frame, pixelFrame, weapon, sourceTarget
local hidden = CreateMaterial("mcv_scope_overlay_hidden", "UnlitGeneric", {
    ["$model"] = "1", ["$no_draw"] = "1",
})
local drawing = false

local function stencil(compare)
    render.SetStencilEnable(true)
    render.SetStencilWriteMask(255)
    render.SetStencilTestMask(255)
    render.SetStencilReferenceValue(1)
    render.SetStencilCompareFunction(compare)
    render.SetStencilPassOperation(compare == STENCIL_ALWAYS and STENCIL_REPLACE or STENCIL_KEEP)
    render.SetStencilFailOperation(STENCIL_KEEP)
    render.SetStencilZFailOperation(STENCIL_KEEP)
end

function MCV.CaptureScopeOverlay(wep, vm)
    if drawing or !wep.RenderingRTScope or !IsValid(vm) then return end
    if vm != wep:GetOwner():GetViewModel() then return end
    local index = wep.RTScopeMaterialIndex
    local materials = vm:GetMaterials()
    if !isnumber(index) or index < 0 or index >= #materials or #materials > 32 then return end
    local view = render.GetViewSetup()
    if view.id and view.id != 0 and view.id != 4 then return end
    local target = render.GetRenderTarget()
    local proxy = wep.ScopeOverlayModel
    if !IsValid(proxy) or proxy:GetModel() != vm:GetModel() then
        proxy = MCV.TrackClientModel(wep, "ScopeOverlayModel", ClientsideModel(vm:GetModel(), RENDERGROUP_OTHER))
        if !IsValid(proxy) then return end
        proxy:SetNoDraw(true)
    end
    // A viewmodel's bones are available here, not later in a HUD camera. A separate
    // model also avoids DrawModel re-entering VM hooks and drawing effects/hands.
    if proxy:GetParent() != vm then
        proxy:SetParent(vm)
        proxy:SetLocalPos(vector_origin)
        proxy:SetLocalAngles(angle_zero)
        proxy:AddEffects(EF_BONEMERGE)
    end
    proxy:SetSkin(vm:GetSkin())
    for i = 0, vm:GetNumBodyGroups() - 1 do proxy:SetBodygroup(i, vm:GetBodygroup(i)) end
    for i = 0, #materials - 1 do proxy:SetSubMaterial(i, vm:GetSubMaterial(i)) end
    proxy:InvalidateBoneCache()
    proxy:SetupBones()

    // Point sampling keeps full-resolution saved pixels sharp in the late copy.
    layer = layer or GetRenderTargetEx("mcv_scope_overlay_masked", ScrW(), ScrH(),
        RT_SIZE_FULL_FRAME_BUFFER, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(1, 8, 256, 512), 0,
        IMAGE_FORMAT_RGBA8888)
    scene = scene or GetRenderTargetEx("mcv_scope_overlay_pixels", ScrW(), ScrH(),
        RT_SIZE_FULL_FRAME_BUFFER, MATERIAL_RT_DEPTH_NONE, bit.bor(1, 8, 256, 512), 0,
        IMAGE_FORMAT_RGB888)
    sceneMaterial = sceneMaterial or CreateMaterial("mcv_scope_overlay_source_v2", "UnlitGeneric", {
        ["$basetexture"] = scene:GetName(), ["$ignorez"] = "1",
    })
    composite = composite or CreateMaterial("mcv_scope_overlay_composite_v2", "UnlitGeneric", {
        ["$basetexture"] = layer:GetName(), ["$translucent"] = "1",
        ["$vertexcolor"] = "1", ["$vertexalpha"] = "1", ["$ignorez"] = "1",
    })
    drawing = true
    render.PushRenderTarget(layer)
    render.Clear(0, 0, 0, 0, true, true)
    render.SetStencilEnable(false)
    render.OverrideDepthEnable(true, true)
    local ok, err = xpcall(function()
        render.OverrideColorWriteEnable(true, false)
        render.OverrideAlphaWriteEnable(true, false)
        // Transparent covers (notably the OEG's extra glass mesh) must not
        // become opaque occluders just because this pass forces depth writes.
        for i = 0, #materials - 1 do
            if i != index then
                local override = vm:GetSubMaterial(i)
                local mat = Material(override != "" and override or materials[i + 1])
                if bit.band(mat:GetInt("$flags") or 0, 2097280) != 0 then // translucent | additive
                    render.MaterialOverrideByIndex(i, hidden)
                end
            end
        end
        // Keep the original shaders: a generic depth material changes software
        // skinning on the lens and can cut a diamond out of the mask.
        proxy:DrawModel()
        for i = 0, #materials - 1 do
            if i != index then render.MaterialOverrideByIndex(i, hidden) end
        end
        stencil(STENCIL_ALWAYS)
        proxy:DrawModel()
    end, debug.traceback)
    render.MaterialOverrideByIndex()
    render.SetStencilEnable(false)
    render.OverrideColorWriteEnable(false, false)
    render.OverrideAlphaWriteEnable(false, false)
    render.PopRenderTarget()
    // The enclosing scope pass uses this depth-write override.
    render.OverrideDepthEnable(true, true)
    drawing = false
    if !ok then frame = nil ErrorNoHalt(err .. "\n") return end
    frame, weapon, sourceTarget = FrameNumber(), wep, target
end

function MCV.CaptureScopeOverlayPixels(wep)
    if frame == FrameNumber() and weapon == wep and sourceTarget == render.GetRenderTarget() then
        // Include the completed OEG blend and muzzle particles. Replaying that
        // blend inside the RGBA target can overwrite the lens mask's alpha.
        render.CopyRenderTargetToTexture(scene)
        pixelFrame = frame
    end
end

hook.Add("PreDrawHUD", "MCV_ScopeAbovePostprocessing", function()
    if frame != FrameNumber() or pixelFrame != frame or sourceTarget != render.GetRenderTarget() then return end
    local ply = LocalPlayer()
    if !IsValid(ply) or !IsValid(weapon) or ply:GetActiveWeapon() != weapon then return end
    if ply:ShouldDrawLocalPlayer() or weapon:ViewModelHidden() or !weapon:ShouldDoScope() then return end
    render.PushRenderTarget(layer)
    stencil(STENCIL_EQUAL)
    // Do this outside the engine viewmodel pass: alpha writes during that pass
    // left the entire lens layer transparent in the live renderer.
    render.SetWriteDepthToDestAlpha(false)
    render.OverrideColorWriteEnable(true, true)
    render.OverrideAlphaWriteEnable(true, true)
    render.OverrideBlend(true, BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD,
        BLEND_ONE, BLEND_ZERO, BLENDFUNC_ADD)
    cam.Start2D()
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawRect(0, 0, ScrW(), ScrH())
    cam.End2D()
    render.OverrideBlend(false)
    render.OverrideAlphaWriteEnable(true, false)
    cam.Start2D()
        surface.SetMaterial(sceneMaterial)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    cam.End2D()
    render.OverrideAlphaWriteEnable(false, false)
    render.OverrideColorWriteEnable(false, false)
    render.SetWriteDepthToDestAlpha(true)
    render.SetStencilEnable(false)
    render.PopRenderTarget()
    cam.Start2D()
        surface.SetMaterial(composite)
        surface.SetDrawColor(255, 255, 255, 255)
        surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    cam.End2D()
end)
