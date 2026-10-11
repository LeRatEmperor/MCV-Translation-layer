// Functional/render asset checks, deliberately separate from prediction regression.
if not CLIENT then return end
MCVCustomAssets = {results={}, reload={}}
local T = MCVCustomAssets
local root = "mcv_harness/p27016/results/"
function T.WorldView()
    // First-person player bones can be stale; anchor this preview to player origin.
    hook.Add("CalcView", "MCV_CustomAssetsWorld", function(p)
        return {origin=p:GetPos()+Vector(5,-75,48),angles=Angle(0,90,0),fov=45,drawviewer=true}
    end)
    hook.Add("ShouldDrawLocalPlayer", "MCV_CustomAssetsWorld", function() return true end)
end
function T.StopWorldView()
    hook.Remove("CalcView", "MCV_CustomAssetsWorld")
    hook.Remove("ShouldDrawLocalPlayer", "MCV_CustomAssetsWorld")
end
function T.RecordLens()
    local ply = LocalPlayer()
    local vm = ply:GetViewModel()
    local base = vm:GetBoneMatrix(vm:LookupBone("Base"))
    local point = base * Vector(7.364,-.6525,3.0695)
    local d = point-ply:EyePos()
    local a = ply:EyeAngles()
    file.Write(root.."ptrd_lens_position.json",util.TableToJSON({right=d:Dot(a:Right()),
        forward=d:Dot(a:Forward()),up=d:Dot(a:Up()),screen=point:ToScreen(),
        base=base:GetTranslation(),angles=base:GetAngles(),eye=ply:EyePos()},true))
end
function T.Check()
    local w = LocalPlayer():GetActiveWeapon()
    local vm = LocalPlayer():GetViewModel()
    local row = {class=w:GetClass(),model=vm:GetModel(),world=w.WorldModel,materials=vm:GetMaterials(),
        clip=w:Clip1(),bodygroups=vm:GetBodyGroups(),shootRate=w.ShootAnimRate}
    for _, name in ipairs(row.materials) do assert(name!="___error" and not Material(name):IsError(),"missing material: "..name) end
    local world = ClientsideModel(w.WorldModel)
    assert(IsValid(world),"invalid worldmodel")
    world:SetNoDraw(true)
    row.worldMaterials=world:GetMaterials()
    world:Remove()
    for _, name in ipairs(row.worldMaterials) do assert(name!="___error" and not Material(name):IsError(),"missing world material: "..name) end
    if w:GetClass()=="mcv_ptrd_sniper" then
        assert(row.model=="models/weapons/mcv/v_ptrd41_s.mdl")
        assert(row.materials[w.RTScopeMaterialIndex+1]:find("crosshair_meopta256"),"wrong PTRD lens")
        assert(vm:FindBodygroupByName("bulletDisplay")>=0,"missing PTRD cartridge")
        assert(w:GetBipod() and w:ShouldDoScope(),"PTRD not deployed/aimed")
    elseif w:GetClass()=="mcv_xm16super" then
        assert(w.ShootAnimRate==.5,"wrong M16 shot playback rate")
        assert(vm:LookupSequence("gl_shoot_deployed")>=0,"lost deployed launcher shot")
    elseif w:GetClass()=="mcv_m635" then
        assert(row.materials[4]=="models/weapons/mcv/v_m601/m601","missing M601 receiver material")
        row.reloadEvents={}
        for _, name in ipairs({"reload","reload_empty"}) do
            local seq=vm:LookupSequence(name)
            local info=vm:GetSequenceInfo(seq)
            row.reloadEvents[name]=info
        end
    end
    T.results[#T.results+1]=row
    file.Write(root.."custom_weapon_assets.json",util.TableToJSON(T.results,true))
end
function T.RecordReload()
    local w = LocalPlayer():GetActiveWeapon()
    local vm = LocalPlayer():GetViewModel()
    T.reload[#T.reload+1]={time=CurTime(),clip=w:Clip1(),reload=w:GetReloading(),
        sequence=vm:GetSequenceName(vm:GetSequence()),cycle=vm:GetCycle(),
        bullet=vm:GetBodygroup(vm:FindBodygroupByName("bulletDisplay"))}
    file.Write(root.."ptrd_reload_cartridge.json",util.TableToJSON(T.reload,true))
end
