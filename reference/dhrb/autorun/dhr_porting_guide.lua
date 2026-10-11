if SERVER then
    AddCSLuaFile()
    AddCSLuaFile("dhr/porting_guide.lua")
    return
end

DHR = DHR or {}
local window

function DHR.OpenPortingGuide()
    if IsValid(window) then window:MakePopup() return window end

    window = vgui.Create("DFrame")
    window:SetTitle("DHRB — Porting weapons")
    window:SetSize(math.min(940, ScrW() - 32), math.min(760, ScrH() - 32))
    window:Center()
    window:MakePopup()

    local page = vgui.Create("DHTML", window)
    page:Dock(FILL)
    page:SetAllowLua(false)
    page:AddFunction("dhrguide", "openLink", function(url)
        if isstring(url) and url:StartWith("https://") then gui.OpenURL(url) end
    end)
    page:SetHTML(include("dhr/porting_guide.lua"))
    return window
end

concommand.Add("dhr_porting_guide", DHR.OpenPortingGuide)

hook.Add("PopulateToolMenu", "dhr_porting_guide", function()
    spawnmenu.AddToolMenuOption("Options", "Hellraiser", "DHRPortingGuide", "Porting guide", "", "", function(panel)
        panel:Help("Bring a weapon's mesh, rig and original animations into Source, then connect them to DHRB.")
        panel:Button("Read the porting guide", "dhr_porting_guide")
        panel:Help("The guide is included with the addon and works offline. Reference links open in your browser.")
    end)
end)
