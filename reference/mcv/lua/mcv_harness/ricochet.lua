if !CLIENT then return end
MCVRicTest = MCVRicTest or {}
local T = MCVRicTest
local root = "mcv_harness/p27018/"

function T.Stop()
    timer.Remove("MCVRicTest")
    hook.Remove("HUDPaint", "MCVRicTest")
    for _, p in ipairs(T.particles or {}) do
        if IsValid(p.ps) then p.ps:StopEmission(false, true) end
    end
    T.particles = {}
end

function T.Start()
    T.Stop()
    T.rows = {}
    T.samples = {}
    local eye, ang = LocalPlayer():EyePos(), LocalPlayer():EyeAngles()
    local names = {"mcv_scaled_impact_metal_flying", "mcv_ricochet", "mcv_scaled_impact_metal_sparks", "Sparks"}
    for i, name in ipairs(names) do
        if name != "Sparks" then PrecacheParticleSystem(name) end
        T.rows[i] = {name = name, pos = eye + ang:Forward() * 350 + ang:Right() * ((i - 2.5) * 105)}
    end
    hook.Add("HUDPaint", "MCVRicTest", function()
        for _, row in ipairs(T.rows) do
            local p = row.pos:ToScreen()
            draw.SimpleText(row.name, "DermaDefault", p.x, p.y + 30, color_white, TEXT_ALIGN_CENTER)
            surface.SetDrawColor(255, 0, 0)
            surface.DrawOutlinedRect(p.x - 5, p.y - 5, 10, 10)
        end
    end)
    local function pulse()
        for _, row in ipairs(T.rows) do
            if row.name == "Sparks" then
                local fx = EffectData()
                fx:SetOrigin(row.pos)
                fx:SetNormal(vector_up)
                fx:SetMagnitude(3)
                fx:SetScale(1)
                fx:SetRadius(3)
                util.Effect("Sparks", fx, true, true)
            else
                local ps = CreateParticleSystem(LocalPlayer(), row.name, PATTACH_CUSTOMORIGIN, 0)
                local item = {ps = ps, name = row.name, pos = row.pos}
                T.particles[#T.particles + 1] = item
                if IsValid(ps) then
                    for cp = 0, 1 do
                        ps:SetControlPoint(cp, row.pos)
                        ps:SetControlPointOrientation(cp, vector_up:Angle())
                    end
                    ps:SetControlPoint(2, Vector(1, 1, 1))
                    ps:SetControlPoint(3, (row.color or Vector(235, 175, 51)) / 255)
                    ps:SetSortOrigin(row.pos)
                    ps:StartEmission()
                    for _, delay in ipairs({0.01, 0.1, 0.5}) do
                        timer.Simple(delay, function()
                            local sample = {name = row.name, delay = delay, valid = IsValid(ps), pos = tostring(row.pos)}
                            if IsValid(ps) then
                                local lo, hi = ps:GetRenderBounds()
                                sample.lo, sample.hi = tostring(lo), tostring(hi)
                                sample.finished = ps:IsFinished()
                                sample.simulate = ps:GetShouldSimulate()
                                sample.owner = tostring(ps:GetOwner())
                                sample.cp = ps:GetHighestControlPoint()
                            end
                            T.samples[#T.samples + 1] = sample
                            file.Write(root .. "ricochet_samples.json", util.TableToJSON(T.samples, true))
                        end)
                    end
                end
            end
        end
    end
    T.Pulse = pulse
    pulse()
    timer.Create("MCVRicTest", 0.7, 20, pulse)
    local mat = Material("effects/vietnam/vietnam_sparktrails_1")
    file.Write(root .. "ricochet_material.json", util.TableToJSON({shader = mat:GetShader(), error = mat:IsError(),
        texture = tostring(mat:GetTexture("$basetexture")), position = tostring(eye), angles = tostring(ang)}, true))
end
