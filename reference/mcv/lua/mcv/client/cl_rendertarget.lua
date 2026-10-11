// The scope lens shader samples the frame from before the viewmodel was drawn: the world
// without the colour viewmodel, but including world translucency/effects.
local function captureScope()
    // Do not replace the main view with a reflection, camera or another addon's RT view.
    local view = render.GetViewSetup()
    if view.id and view.id != 0 and view.id != 4 then return end
    local ply = LocalPlayer()
    if !IsValid(ply) then return end
    local wpn = ply:GetActiveWeapon()

    if !IsValid(wpn) or !wpn.MilitaryConflictVietnam then return end

    if wpn.CaptureScopeScreen then wpn:CaptureScopeScreen() end
end

// Migrate the obsolete wrapper on Lua refresh. PreDrawEffects is AFTER viewmodels:
// capturing there overwrites the clean world image with the gun and scope itself.
local contactHook = MCV.ContactScopeHook
if contactHook and contactHook.wrapper then
    local effects = hook.GetTable().PreDrawEffects
    if effects and effects.ContactShadows == contactHook.wrapper then
        hook.Add("PreDrawEffects", "ContactShadows", contactHook.original)
    end
end
MCV.ContactScopeHook = nil
hook.Remove("PreRender", "MCV_ContactScopeCapture")

hook.Add("PreDrawViewModels", "MCV_CaptureScopeScreen", function()
    captureScope()
end)

// Also remove the obsolete early capture when this file is hot-reloaded.
hook.Remove("PreDrawReconstruction", "MCV_CaptureScopeBeforeShaders")

// The model's own $bbox is the viewmodel's render box, and a box that ends at eye height (the
// molotov's and the dynamite's) had the whole viewmodel culled: nothing drawn, and none of
// the weapon's PreDrawViewModel hooks run for a culled viewmodel, so the bounds are set here,
// before the viewmodels are considered at all. port_qc's step_bbox widens the box at compile
// time as well.
local VM_BOUNDS_MIN, VM_BOUNDS_MAX = Vector(-96, -96, -96), Vector(96, 96, 96)
hook.Add("PreDrawViewModels", "MCV_ViewModelBounds", function()
    local ply = LocalPlayer()
    if !IsValid(ply) then return end
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam then return end
    local vm = ply:GetViewModel()
    if IsValid(vm) then vm:SetRenderBounds(VM_BOUNDS_MIN, VM_BOUNDS_MAX) end
end)
