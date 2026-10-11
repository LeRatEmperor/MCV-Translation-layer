if SERVER then
    AddCSLuaFile()
    util.AddNetworkString('hr_npc_detection')
    local actors, sent = {}, setmetatable({}, {__mode='k'})
    local nextUpdate = 0
    local function track(e)
        if IsValid(e) and e:IsNPC() then actors[e] = true end
    end
    hook.Add('OnEntityCreated', 'hr_detection', function(e) timer.Simple(0, function() track(e) end) end)
    hook.Add('InitPostEntity', 'hr_detection', function() for _,e in ipairs(ents.GetAll()) do track(e) end end)
    hook.Add('EntityRemoved', 'hr_detection', function(e) actors[e] = nil end)
    hook.Add('Think', 'hr_detection', function()
        local now = CurTime()
        if now < nextUpdate then return end
        nextUpdate = now + .1
        local enabled = not GetConVar('ai_disabled'):GetBool() and not GetConVar('ai_ignoreplayers'):GetBool()
        for _,p in ipairs(player.GetHumans()) do
            local amount, state, threat = 0, 0, NULL
            if enabled and p:Alive() and not p:IsFlagSet(FL_NOTARGET) and p:GetObserverMode() == OBS_MODE_NONE then
                for e in pairs(actors) do
                    if IsValid(e) and not e.Dead and not e.Dormant and not e.hr_execution and not e.hr_execution_proxy
                        and e:Health() > 0 and e:Disposition(p) == D_HT then
                        local value, status = 0, 0
                        if e.HellraiserNPC then
                            local sense = e.Senses and e.Senses[p]
                            if sense and sense.amount > 0 then
                                value = sense.amount
                                if e.Focus == p and (now - sense.seen < 1.5 or now < (sense.attentionUntil or 0)) then status = 2
                                elseif now - sense.seen < .3 then status = 1
                                else status = 3 end
                            end
                        elseif e:GetEnemy() == p then
                            value, status = 1, e:Visible(p) and 2 or 3
                        end
                        local priority = status == 2 and 3 or status == 1 and 2 or status == 3 and 1 or 0
                        local previous = state == 2 and 3 or state == 1 and 2 or state == 3 and 1 or 0
                        if priority > previous or priority == previous and value > amount then
                            amount, state, threat = value, status, e
                        end
                    end
                end
            end
            local quantized = math.Clamp(math.Round(amount * 255), 0, 255)
            local last = sent[p]
            if not last or last.amount ~= quantized or last.state ~= state or last.threat ~= threat then
                net.Start('hr_npc_detection')
                net.WriteUInt(quantized, 8); net.WriteUInt(state, 2); net.WriteEntity(threat)
                net.Send(p)
                sent[p] = {amount=quantized, state=state, threat=threat}
            end
        end
    end)
    return
end

local enabled = CreateClientConVar('hr_hud_stealth', '1', true, false, 'Show stealth and enemy awareness')
local soundEnabled = CreateClientConVar('hr_detection_sound', '1', true, false, 'Play the enemy detection cue')
local icon = Material('hellraiser/ui/stealth_icon')
local vignette = Material('hellraiser/ui/stealth_vignette')
local amount, state, threat, displayed, opacity, nextSound = 0, 0, NULL, 0, 0, 0
local changed = 0
net.Receive('hr_npc_detection', function()
    local value, status, entity = net.ReadUInt(8) / 255, net.ReadUInt(2), net.ReadEntity()
    if status ~= state then changed = CurTime() end
    if status == 2 and state ~= 2 and soundEnabled:GetBool() and CurTime() >= nextSound then
        surface.PlaySound('hellraiser/ui_enemy_alerted/ui_enemy_alerted_0' .. math.random(4) .. '.wav')
        nextSound = CurTime() + 2
    end
    amount, state, threat = value, status, entity
end)

local function arc(x, y, radius, width, centre, sweep, color)
    draw.NoTexture(); surface.SetDrawColor(color)
    local count = math.max(2, math.ceil(sweep / 4))
    for i=1,count do
        local a, b = math.rad(centre - sweep*.5 + sweep*(i-1)/count), math.rad(centre - sweep*.5 + sweep*i/count)
        surface.DrawPoly({
            {x=x+math.sin(a)*(radius-width), y=y-math.cos(a)*(radius-width)},
            {x=x+math.sin(a)*radius, y=y-math.cos(a)*radius},
            {x=x+math.sin(b)*radius, y=y-math.cos(b)*radius},
            {x=x+math.sin(b)*(radius-width), y=y-math.cos(b)*(radius-width)},
        })
    end
end

local fontHeight
hook.Add('HUDPaint', 'hr_detection', function()
    local p, master = LocalPlayer(), GetConVar('hr_hud')
    if not enabled:GetBool() or master and not master:GetBool() or not GetConVar('cl_drawhud'):GetBool()
        or not IsValid(p) or not p:Alive() or p:GetObserverMode() ~= OBS_MODE_NONE
        or DHR and DHR.CanUseFeature and not DHR.CanUseFeature(p, 'hud', p:GetActiveWeapon())
        or hook.Run('HUDShouldDraw', 'HRStealth') == false then return end
    local weapon = p:GetActiveWeapon()
    if IsValid(weapon) and weapon:GetNW2Bool('hr_executing') then return end
    local scale = math.min(ScrW()/1920, ScrH()/1080)
    local size = math.max(18, math.Round(26*scale))
    if size ~= fontHeight then
        surface.CreateFont('HRStealth', {font=system.IsLinux() and 'sarala-regular.ttf' or 'Sarala', size=size, weight=400, antialias=true})
        fontHeight = size
    end
    local hidden = state == 0 and p:Crouching()
    displayed = Lerp(1-math.exp(-FrameTime()*10), displayed, amount)
    opacity = math.Approach(opacity, (state ~= 0 or hidden) and 1 or 0, FrameTime()*5)
    if opacity <= 0 then return end
    local x, y = ScrW()*.5, ScrH()*.5
    if hidden then
        surface.SetMaterial(vignette); surface.SetDrawColor(255,255,255,55*opacity)
        surface.DrawTexturedRect(0,0,ScrW(),ScrH())
        surface.SetMaterial(icon); surface.SetDrawColor(255,255,255,220*opacity)
        surface.DrawTexturedRect(x-20*scale,y+82*scale,40*scale,40*92/61*scale)
        return
    end
    if state == 0 then return end
    local bearing = IsValid(threat) and -math.AngleDifference((threat:WorldSpaceCenter()-p:EyePos()):Angle().y,p:EyeAngles().y) or 0
    local alpha = opacity * (state == 3 and 155 or 230)
    local color = state == 2 and Color(235,56,69,alpha) or state == 3 and Color(187,193,216,alpha) or Color(230,237,250,alpha)
    local radius = 74*scale
    arc(x,y,radius+scale,4*scale,bearing,64,Color(0,0,0,95*opacity))
    arc(x,y,radius,2*scale,bearing,math.max(4,64*displayed),color)
    if state == 2 then
        local pulse = math.max(0, 1-(CurTime()-changed)/.6)
        if pulse > 0 then arc(x,y,radius+(1-pulse)*12*scale,scale,bearing,64,Color(235,56,69,pulse*110)) end
    end
    if state == 3 or CurTime()-changed < 1.8 then
        draw.SimpleTextOutlined(state == 2 and 'Spotted' or state == 3 and 'Searching' or 'Suspicious', 'HRStealth', x,y+95*scale,color,TEXT_ALIGN_CENTER,TEXT_ALIGN_TOP,1,Color(0,0,0,140*opacity))
    end
end)
