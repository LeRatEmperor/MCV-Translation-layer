// Explicitly loaded by the local scope regression harness only.
if !CLIENT or !file.Exists("mcv_harness/enable.txt", "DATA") then return end
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/"
MCV.ScopeProbe = MCV.ScopeProbe or {}
local H = MCV.ScopeProbe
function H.Capture(name)
    local rows = {}
    local start = FrameNumber() + 2
    local function record(stage)
        if FrameNumber() != start then return end
        local view = render.GetViewSetup()
        local rt = render.GetRenderTarget()
        rows[#rows + 1] = {stage=stage, id=view.id, target=rt and rt:GetName() or "backbuffer"}
    end
    for _, stage in ipairs({"PreDrawViewModels", "PreDrawEffects", "PostDrawEffects", "PreDrawHUD", "PostDrawHUD"}) do
        hook.Add(stage, "MCV_ScopeProbe", function() record(stage) end)
    end
    local original = MCV.CaptureScopeOverlay
    MCV.CaptureScopeOverlay = function(...)
        record("CaptureScopeOverlay")
        return original(...)
    end
    hook.Add("PostRender", "MCV_ScopeProbe", function()
        if FrameNumber() < start then return end
        hook.Remove("PostRender", "MCV_ScopeProbe")
        for _, stage in ipairs({"PreDrawViewModels", "PreDrawEffects", "PostDrawEffects", "PreDrawHUD", "PostDrawHUD"}) do
            hook.Remove(stage, "MCV_ScopeProbe")
        end
        MCV.CaptureScopeOverlay = original
        file.Write(root .. "shots/" .. name .. ".png", render.Capture({format="png",x=0,y=0,w=ScrW(),h=ScrH(),alpha=false}))
        for _, spec in ipairs({{"layer", "!mcv_scope_overlay_composite_v2"}, {"scene", "mcv/scope_lens"}, {"saved", "!mcv_scope_overlay_source_v2"}}) do
            local tex = Material(spec[2]):GetTexture("$basetexture")
            if tex then
                render.PushRenderTarget(tex)
                file.Write(root .. "shots/" .. name .. "_" .. spec[1] .. ".png", render.Capture({format="png",x=0,y=0,w=tex:Width(),h=tex:Height(),alpha=true}))
                render.PopRenderTarget()
            end
        end
        file.Write(root .. "results/" .. name .. "_passes.json", util.TableToJSON(rows,true))
    end)
end
