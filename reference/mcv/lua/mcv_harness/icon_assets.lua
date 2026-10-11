-- Development-only studio renders of the addon's actual compiled models.
if not CLIENT then return end
local entries = {
    {name = "chinalake", model = "models/weapons/mcv/w_chinalake.mdl"},
    {name = "gyrojet_pistol", model = "models/weapons/mcv/w_gyrojet_pistol.mdl"},
    {name = "gyrojet_carbine", model = "models/weapons/mcv/w_gyrojet_carbine.mdl"},
    {name = "m202", model = "models/weapons/mcv/w_m202.mdl", view = Vector(0.65, -1, 0.24)},
    {name = "dp28", model = "models/weapons/mcv/w_dp28.mdl", view = Vector(0.2, -1, 0.48)},
    {name = "owen", model = "models/weapons/mcv/w_owen.mdl"},
    {name = "ppsh41dd", model = "models/weapons/mcv/w_ppsh41_doubledrum.mdl", view = Vector(0.35, -1, 0.24)},
    {name = "mat49_sog", model = "models/weapons/mcv/w_mat49_sog.mdl"},
    {name = "welrod", model = "models/weapons/mcv/w_welrod.mdl"},
    {name = "qspr", model = "models/weapons/mcv/w_qspr.mdl"},
    {name = "lpo50", model = "models/weapons/mcv/w_lpo50.mdl"},
}
local width, height = 2048, 1024
local rt = GetRenderTarget("mcv_icon_asset_studio", width, height)
local cursor = 1
hook.Add("PostRender", "MCV_IconAssets", function()
    local entry = entries[cursor]
    if not entry then hook.Remove("PostRender", "MCV_IconAssets") return end
    local model = ClientsideModel(entry.model, RENDERGROUP_OPAQUE)
    if not IsValid(model) then error("Cannot render " .. entry.model) end
    model:SetNoDraw(true)
    model:SetAngles(angle_zero)
    model:SetupBones()
    local lo, hi = model:GetRenderBounds()
    model:SetPos(-(lo + hi) * 0.5)
    local distance = math.max(hi.x-lo.x, hi.y-lo.y, (hi.z-lo.z)*2) * 1.3
    render.PushRenderTarget(rt)
    render.Clear(0, 0, 0, 0, true, true)
    render.SetWriteDepthToDestAlpha(false)
    render.OverrideAlphaWriteEnable(true, true)
    local eye = (entry.view or Vector(0.18, -1, 0.20)) * distance
    cam.Start3D(eye, (-eye):Angle(), 48, 0, 0, width, height, 1, 1000)
    render.SuppressEngineLighting(true)
    render.ResetModelLighting(0.75, 0.78, 0.72)
    render.SetModelLighting(BOX_TOP, 2.2, 1.75, 0.95)
    render.SetModelLighting(BOX_FRONT, 1.5, 1.7, 1.9)
    render.SetModelLighting(BOX_LEFT, 1.2, 1.3, 1.45)
    model:SetupBones()
    model:DrawModel()
    render.SuppressEngineLighting(false)
    cam.End3D()
    local data = render.Capture({format="png",x=0,y=0,w=width,h=height,alpha=true})
    render.OverrideAlphaWriteEnable(false)
    render.SetWriteDepthToDestAlpha(true)
    render.PopRenderTarget()
    file.Write("mcv_harness/p27016/shots/icon_asset_" .. entry.name .. "_alpha.png", data)
    model:Remove()
    print("[icon asset]", entry.name, #data)
    cursor = cursor + 1
end)
