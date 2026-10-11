if not SERVER then return end
assert(game.GetMap()=="mcv_penetration_test","load the compiled BSP fixture")
local ply=player.GetHumans()[1]
local w=ply:GetActiveWeapon()
local rows,failures={},{}
local oldSpread,oldAim=w.GetSpread,w.GetAimVector
w.GetSpread=function() return 0 end
w.GetAimVector=function() return Vector(1,0,0) end
for _,case in ipairs({{name="world_metal4",y=-250,expected=true,thickness=4},
    {name="world_metal20",y=0,expected=false},
    {name="world_two_metal3",y=250,expected=true,thickness=3}}) do
    local origin=Vector(-128,case.y,64)
    ply:SetPos(origin-ply:GetViewOffset())
    local target=ents.Create("base_anim")
    target:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    target:SetPos(Vector(100,case.y,64)) target:Spawn()
    target:PhysicsInitBox(Vector(-2,-24,-24),Vector(2,24,24))
    target:SetSolid(SOLID_VPHYSICS) target:SetMoveType(MOVETYPE_VPHYSICS)
    target:EnableCustomCollisions(true) target:GetPhysicsObject():EnableMotion(false)
    local hits,damage=0,0
    hook.Add("EntityTakeDamage","MCV_WorldPenTest",function(e,dmg)
        if e==target then hits=hits+1 damage=damage+dmg:GetDamage() return true end
    end)
    local tr=util.TraceLine({start=origin,endpos=Vector(200,case.y,64),mask=MASK_SHOT,filter=ply})
    local exit,thickness=w:FindPenetrationExit(tr,Vector(1,0,0),w:GetPenetrationStats(tr.MatType))
    w:BulletAttack()
    rows[#rows+1]={name=case.name,world=tr.HitWorld,material=tr.MatType,thickness=thickness,hits=hits,damage=damage}
    if not tr.HitWorld or (hits==1)!=case.expected then failures[#failures+1]=case.name end
    -- BSP traces report a padded impact at each face (about 1/32 unit each).
    if case.thickness and (not thickness or math.abs(thickness-case.thickness)>.1) then failures[#failures+1]=case.name.." exit thickness" end
    target:Remove()
    hook.Remove("EntityTakeDamage","MCV_WorldPenTest")
end
w.GetSpread,w.GetAimVector=oldSpread,oldAim
file.Write("mcv_harness/p27016/results/penetration_world.json",util.TableToJSON({results=rows,failures=failures},true))
print("[world penetration]",#rows,#failures)
