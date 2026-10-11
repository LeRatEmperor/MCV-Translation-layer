// Explicitly loaded multiplayer PVS diagnostic; never loaded by the addon.
if !file.Exists("mcv_harness/enable.txt", "DATA") then return end
MCVPVS = MCVPVS or {events = {}, samples = {}, phase = "setup"}
local T = MCVPVS
local root = "mcv_harness/pvs/"
file.CreateDir(root)
local function xyz(v) return {v.x, v.y, v.z} end
function T.Save(label)
    local id = SERVER and "server" or tostring(LocalPlayer():EntIndex())
    file.Write(root .. label .. "_" .. id .. ".json", util.TableToJSON(T, true))
end
function T.Phase(name)
    T.phase = name
    if SERVER then
        for _,p in ipairs(player.GetHumans()) do p:SendLua("MCVPVS.Phase(" .. string.format("%q",name) .. ")") end
    end
end
function T.Capture(label)
    if SERVER then
        for _,p in ipairs(player.GetHumans()) do p:SendLua("MCVPVS.Capture(" .. string.format("%q",label) .. ")") end
        return
    end
    gui.HideGameUI()
    hook.Add("PostRender","MCVPVS_capture",function()
        hook.Remove("PostRender","MCVPVS_capture")
        local bytes=render.Capture({format="png",x=0,y=0,w=ScrW(),h=ScrH(),alpha=false})
        if bytes then file.Write(root .. label .. "_" .. LocalPlayer():EntIndex() .. ".png",bytes) end
    end)
end
if SERVER then
    AddCSLuaFile()
    if !T.oldEffect then
        T.oldEffect = util.Effect
        util.Effect = function(name,data,...)
            if name == "mcv_muzzleeffect" or name == "mcv_shelleffect" then
                T.events[#T.events+1] = {phase=T.phase,name=name,origin=xyz(data:GetOrigin()),time=CurTime()}
            end
            return T.oldEffect(name,data,...)
        end
    end
    function T.Setup()
        T.events, T.samples = {}, {}
        for _,p in ipairs(player.GetHumans()) do
            p:GodEnable(); p:SetMoveType(MOVETYPE_NOCLIP)
            p:SendLua('include("mcv_harness/pvs.lua") MCVPVS.events={} MCVPVS.samples={}')
        end
    end
    function T.Flush(label)
        T.Save(label)
        for _,p in ipairs(player.GetHumans()) do p:SendLua("MCVPVS.Save(" .. string.format("%q",label) .. ")") end
    end
    return
end
if !T.wrapped then
    T.wrapped = true
    for _,name in ipairs({"mcv_muzzleeffect","mcv_shelleffect"}) do
        local effect = effects.GetList()[name]
        if effect then
            local original = effect.Init
            effect.Init = function(s,data)
                local w = data:GetEntity()
                T.events[#T.events+1] = {phase=T.phase,name=name,time=CurTime(),origin=xyz(data:GetOrigin()),
                    weapon=IsValid(w) and w:GetClass() or "NULL", dormant=IsValid(w) and w:IsDormant()}
                return original(s,data)
            end
            effects.Register(effect,name)
        end
    end
    local original = CreateParticleSystem
    CreateParticleSystem = function(parent,name,...)
        local pcf = original(parent,name,...)
        if string.find(name,"muzzle",1,true) or string.find(name,"flame",1,true) then
            local id = IsValid(parent) and parent:LookupAttachment("muzzle") or 0
            local a = id > 0 and parent:GetAttachment(id)
            T.events[#T.events+1] = {phase=T.phase,name="particle",particle=name,valid=IsValid(pcf),
                time=CurTime(),parent=IsValid(parent) and parent:GetClass() or "NULL",pos=a and xyz(a.Pos)}
        end
        return pcf
    end
end
timer.Create("MCVPVS_sample",0.2,0,function()
    local owners = player.GetAll()
    for _,n in ipairs(ents.FindByClass("npc_combine_s")) do owners[#owners+1]=n end
    for _,p in ipairs(owners) do
        if p == LocalPlayer() then continue end
        local w = p:GetActiveWeapon()
        local m = IsValid(w) and w.WM
        local id = IsValid(m) and m:LookupAttachment("muzzle") or 0
        local a = id > 0 and m:GetAttachment(id)
        local l = IsValid(w) and w.WMLeft
        local lid = IsValid(l) and l:LookupAttachment("muzzle") or 0
        local la = lid > 0 and l:GetAttachment(lid)
        T.samples[#T.samples+1] = {phase=T.phase,time=CurTime(),owner=p:EntIndex(),dormant=p:IsDormant(),
            pos=xyz(p:GetPos()),weapon=IsValid(w) and w:GetClass(),wm=IsValid(m),
            parent=IsValid(m) and m:GetParent()==p, muzzle=a and xyz(a.Pos),left=la and xyz(la.Pos),
            flame=IsValid(w) and IsValid(w.FlamePS),flame_parent=IsValid(w) and w.FlamePSEnt==m}
    end
end)
