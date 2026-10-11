MCVModelTest = MCVModelTest or {}
local T = MCVModelTest
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
if SERVER then
    function T.Spawn(class)
        if IsValid(T.npc) then T.npc:Remove() end
        local npc = ents.Create("npc_combine_s")
        npc:SetPos(Vector(4000, 0, -12799))
        npc:SetAngles(angle_zero)
        npc:SetKeyValue("additionalequipment", class)
        npc:Spawn()
        npc:Activate()
        npc:SetSchedule(SCHED_NPC_FREEZE)
        T.npc = npc
        SetGlobalEntity("MCVModelTestNPC", npc)
    end
    return
end
function T.View(npc)
    T.npc = npc
    hook.Add("ShouldDrawLocalPlayer", "MCV_ModelTest", function() return !T.npc end)
    hook.Add("CalcView", "MCV_ModelTest", function(ply)
        local owner = T.npc and GetGlobalEntity("MCVModelTestNPC") or ply
        if !IsValid(owner) then return end
        owner:SetupBones()
        local bone = owner:LookupBone("ValveBiped.Bip01_R_Hand")
        local matrix = bone and owner:GetBoneMatrix(bone)
        if !matrix then return end
        local hand = matrix:GetTranslation()
        local forward = Angle(0, owner:GetAngles().y, 0):Forward()
        local right = Angle(0, owner:GetAngles().y, 0):Right()
        local origin = hand + forward * 8 + right * 75 + Vector(0, 0, 12)
        return {origin = origin, angles = (hand + forward * 7 - origin):Angle(), fov = 46, drawviewer = !T.npc}
    end)
end
function T.Report(label)
    local owner = T.npc and GetGlobalEntity("MCVModelTestNPC") or LocalPlayer()
    local w = owner:GetActiveWeapon()
    local mdl = w:GetWorldModelEntity()
    mdl:SetupBones()
    local hand = owner:GetBoneMatrix(owner:LookupBone("ValveBiped.Bip01_R_Hand"))
    local gun = mdl:GetBoneMatrix(mdl:LookupBone("MCV.weapon_bone") or mdl:LookupBone("ValveBiped.weapon_bone"))
    local localGun = hand:GetInverse() * gun
    local att = mdl:GetAttachment(mdl:LookupAttachment("muzzle"))
    file.Write(root .. label .. ".json", util.TableToJSON({weapon = w:GetClass(), model = mdl:GetModel(),
        owner = owner:GetModel(), npc = owner:IsNPC(), gunPos = localGun:GetTranslation(), gunAng = localGun:GetAngles(),
        muzzle = hand:GetInverse() * att.Pos, bodygroups = mdl:GetBodyGroups()}, true))
end
function T.Stop()
    hook.Remove("CalcView", "MCV_ModelTest")
    hook.Remove("ShouldDrawLocalPlayer", "MCV_ModelTest")
end
