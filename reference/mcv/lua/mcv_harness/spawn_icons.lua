// Render the real ContentIcon panels at their normal spawn-menu size.
if !CLIENT then return end
local frame = vgui.Create("DFrame")
frame:SetSize(850, 210)
frame:Center()
frame:SetTitle("Military Conflict: Vietnam - weapon icons")
frame:MakePopup()
local content = vgui.Create("ContentContainer", frame)
content:Dock(FILL)
local result = {}
for _, class in ipairs({"mcv_rhogun", "mcv_cobra", "mcv_ptrd_sniper", "mcv_m635", "mcv_xm16super", "mcv_swm76"}) do
    local weapon = weapons.Get(class)
    local path = weapon.IconOverride or "entities/" .. class .. ".png"
    local material = Material(path, "smooth mips")
    assert(!material:IsError(), "missing icon " .. path)
    assert(material:Width() == 512 and material:Height() == 512, "wrong icon size")
    local icon = spawnmenu.CreateContentIcon("weapon", content, {
        nicename = weapon.PrintName, spawnname = class, material = path,
    })
    assert(IsValid(icon), "failed to create spawn icon " .. class)
    result[#result + 1] = {class = class, material = path, width = material:Width(), height = material:Height()}
end
local port = GetConVar("hostport"):GetInt()
local root = port == 27015 and "mcv_harness/" or "mcv_harness/p" .. port .. "/"
file.Write(root .. "results/spawn_icons.json", util.TableToJSON(result, true))
MCVSpawnIconFrame = frame
