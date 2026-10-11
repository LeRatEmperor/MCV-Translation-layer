-- Development-only closeups and hand-relative index-finger measurements.
if not CLIENT then return end
MCVContact = MCVContact or {results = {}}
local C = MCVContact
local root = "mcv_harness/p27016/results/"
hook.Add("CalcView", "MCV_ContactView", function(p)
    local hand = p:LookupBone("ValveBiped.Bip01_R_Hand")
    local matrix = hand and p:GetBoneMatrix(hand)
    local focus = matrix and matrix:GetTranslation() or p:GetPos()+Vector(0,0,48)
    return {origin=focus+Vector(3,-38,3),angles=Angle(3,90,0),fov=48,drawviewer=true}
end)
hook.Add("ShouldDrawLocalPlayer", "MCV_ContactView", function() return true end)
function C.Record(label)
    local p = LocalPlayer()
    local w = p:GetActiveWeapon()
    local rh = p:GetBoneMatrix(p:LookupBone("ValveBiped.Bip01_R_Hand"))
    local inverse = rh:GetInverse()
    local row = {class=w:GetClass(),holdtype=w:GetHoldType(),bones={}}
    for _, name in ipairs({"ValveBiped.Bip01_R_Finger1", "ValveBiped.Bip01_R_Finger11", "ValveBiped.Bip01_R_Finger12"}) do
        local id = p:LookupBone(name)
        local matrix = id and p:GetBoneMatrix(id)
        if matrix then
            local v = (inverse * matrix):GetTranslation()
            row.bones[name] = {v.x,v.y,v.z}
        end
    end
    C.results[w:GetClass()] = row
    file.Write(root .. "worldmodel_contact_" .. label .. ".json", util.TableToJSON(C.results,true))
end
function C.Stop()
    hook.Remove("CalcView", "MCV_ContactView")
    hook.Remove("ShouldDrawLocalPlayer", "MCV_ContactView")
end
