if not CLIENT then return end
MCVGunsCheck = {}
local T = MCVGunsCheck
local port = GetConVar("hostport"):GetInt()
local root = "mcv_harness/p"..port.."/results/"
function T.WorldView()
    hook.Add("CalcView","MCV_GunsCheck",function(p)
        return {origin=p:GetPos()+Vector(5,-85,48),angles=Angle(0,90,0),fov=50,drawviewer=true}
    end)
    hook.Add("ShouldDrawLocalPlayer","MCV_GunsCheck",function() return true end)
end
function T.StopWorld()
    hook.Remove("CalcView","MCV_GunsCheck")
    hook.Remove("ShouldDrawLocalPlayer","MCV_GunsCheck")
end
function T.WorldReport(label)
    local ply=LocalPlayer()
    local w=ply:GetActiveWeapon()
    local mdl=w:GetWorldModelEntity()
    local hand=mdl:GetBoneMatrix(mdl:LookupBone("ValveBiped.Bip01_R_Hand"))
    local gun=mdl:GetBoneMatrix(mdl:LookupBone("ValveBiped.weapon_bone"))
    local matrix=hand:GetInverse()*gun
    local rows={class=w:GetClass(),pos=matrix:GetTranslation(),ang=matrix:GetAngles(),matrix={}}
    for r=1,4 do rows.matrix[r]={} for c=1,4 do rows.matrix[r][c]=matrix:GetField(r,c) end end
    file.Write(root..label.."_world.json",util.TableToJSON(rows,true))
end
function T.StartRender(label)
    T.trace={label=label,frames={}}
    hook.Add("PostDrawViewModel","MCV_GunsRenderCheck",function(vm,ply,w)
        if ply~=LocalPlayer() then return end
        local row={time=CurTime(),seq=vm:GetSequenceName(vm:GetSequence()),cycle=vm:GetCycle(),
            empty=vm:GetPoseParameter("empty"),clip=w:Clip1(),reload=w:GetReloading(),bones={}}
        for _,name in ipairs({"BaseRoot","Base","hand_r","hand_l","Bolt"}) do
            local id=vm:LookupBone(name)
            local matrix=id and vm:GetBoneMatrix(id)
            if matrix then
                local pos=WorldToLocal(matrix:GetTranslation(),angle_zero,vm:GetPos(),vm:GetAngles())
                row.bones[name]={pos.x,pos.y,pos.z}
            end
        end
        T.trace.frames[#T.trace.frames+1]=row
    end)
end
function T.StopRender()
    hook.Remove("PostDrawViewModel","MCV_GunsRenderCheck")
    file.Write(root..T.trace.label.."_render.json",util.TableToJSON(T.trace,true))
    T.trace=nil
end
