if SERVER then AddCSLuaFile() return end
DHRScope = DHRScope or {}
local S = DHRScope
local target, lens, disc
local size = 1024
local rendering = false
local blur = Material("pp/blurscreen")
local blurEnabled = CreateClientConVar("hr_scope_blur", "1", true, false, "Blur the background around a 3D scope while aiming")
local hidden = CreateMaterial("dhr_scope_glass_hidden", "UnlitGeneric", {['$alpha'] = '0', ['$translucent'] = '1'})

local function resources()
    if target then return end
    target = GetRenderTarget("dhr_scope_view", size, size)
    lens = CreateMaterial("dhr_scope_lens", "UnlitGeneric", {['$basetexture'] = target:GetName(), ['$model'] = '1', ['$nocull'] = '1'})
    disc = Mesh(lens)
    local triangles = {}
    for i = 0, 63 do
        for _, angle in ipairs({false, i * math.pi / 32, (i + 1) * math.pi / 32}) do
            local x, y = angle and math.cos(angle) or 0, angle and math.sin(angle) or 0
            triangles[#triangles + 1] = {pos = Vector(x, 0, y), normal = Vector(0, 1, 0), u = .5 - x / 2, v = .5 - y / 2}
        end
    end
    disc:BuildFromTriangles(triangles)
end

local function reticle(config)
    if config.reticle then
        surface.SetMaterial(Material(config.reticle))
        surface.SetDrawColor(255, 255, 255)
        surface.DrawTexturedRect(0, 0, size, size)
        return
    end
    draw.NoTexture()
    surface.SetDrawColor(12, 12, 12, 240)
    surface.DrawLine(0, 512, 1024, 512)
    surface.DrawLine(512, 0, 512, 1024)
    for i = 0, 3 do
        local start = i == 1 and 742 or 598
        local polygon = {}
        for _, point in ipairs({{start, 512}, {start + 10, 502}, {1024, 502}, {1024, 522}, {start + 10, 522}}) do
            local x, y = point[1] - 512, point[2] - 512
            local a = i * math.pi / 2
            polygon[#polygon + 1] = {x = 512 + x * math.cos(a) - y * math.sin(a), y = 512 + x * math.sin(a) + y * math.cos(a)}
        end
        surface.DrawPoly(polygon)
    end
    surface.DrawLine(495, 569, 529, 569)
    surface.DrawCircle(512, 626, 13, 12, 12, 12, 240)
    surface.DrawCircle(512, 683, 13, 12, 12, 12, 240)
end

hook.Add("RenderScene", "dhr_scope_view", function(origin, angles)
    if rendering or render.GetRenderTarget() then return end
    local player = LocalPlayer()
    local weapon = IsValid(player) and player:GetActiveWeapon()
    if not IsValid(weapon) or not weapon.HasScopeLens or not weapon:HasScopeLens()
        or not player:Alive() or player:ShouldDrawLocalPlayer() or player:GetViewEntity() ~= player
        or not GetConVar("r_drawviewmodel"):GetBool() or weapon:ScopeFraction() <= .01 then return end
    resources()
    rendering = true
    local config = weapon.HR.scope
    render.PushRenderTarget(target)
    render.Clear(0, 0, 0, 255, true, true)
    render.RenderView({origin = origin, angles = angles, fov = config.fov or 12,
        x = 0, y = 0, w = size, h = size, aspectratio = 1,
        drawviewmodel = false, drawhud = false, dopostprocess = false})
    cam.Start2D()
    reticle(config)
    cam.End2D()
    render.PopRenderTarget()
    rendering = false
    S.weapon, S.frame = weapon, FrameNumber()
end)

function S.Blur(weapon)
    if rendering or render.GetRenderTarget() or not blurEnabled:GetBool() or not weapon:HasScopeLens() then return end
    local fraction = weapon:ScopeFraction()
    if fraction <= .01 then return end
    cam.Start2D()
    surface.SetMaterial(blur)
    surface.SetDrawColor(255, 255, 255)
    for i = 1, 2 do
        blur:SetFloat("$blur", i * 2 * fraction)
        blur:Recompute()
        render.UpdateScreenEffectTexture()
        surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    end
    cam.End2D()
end

function S.Prepare(weapon, model)
    if rendering or render.GetRenderTarget() or S.frame ~= FrameNumber() then return end
    local config = weapon:HasScopeLens() and weapon.HR.scope
    if not config or weapon:ScopeFraction() <= .01 or S.weapon ~= weapon then return end
    for index, material in ipairs(model:GetMaterials()) do
        if material == config.material then
            model.dhr_scope_material = {index = index - 1, previous = model:GetSubMaterial(index - 1)}
            model:SetSubMaterial(index - 1, '!' .. hidden:GetName())
            return
        end
    end
end

function S.Draw(weapon, model)
    local changed = model.dhr_scope_material
    if not changed then return end
    local config = weapon.HR.scope
    local bone = model:LookupBone(config.bone)
    local matrix = bone and model:GetBoneMatrix(bone)
    if matrix and S.weapon == weapon and S.frame == FrameNumber() then
        local transform = Matrix()
        transform:SetTranslation(config.pos)
        transform:SetScale(Vector(config.radius, config.radius, config.radius))
        cam.PushModelMatrix(matrix * transform)
        render.SetMaterial(lens)
        disc:Draw()
        cam.PopModelMatrix()
    end
    model:SetSubMaterial(changed.index, changed.previous)
    model.dhr_scope_material = nil
end
