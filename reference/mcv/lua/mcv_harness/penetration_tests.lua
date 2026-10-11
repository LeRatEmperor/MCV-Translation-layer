-- Real engine collision/damage integration checks; include on the test server.
if not SERVER then return end
local ply = player.GetHumans()[1]
local w = IsValid(ply) and ply:GetActiveWeapon()
assert(IsValid(w) and w.MilitaryConflictVietnam, "equip an MCV gun first")
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
local results, entities, failures = {}, {}, {}
local cv = GetConVar("mcv_bullet_penetration")
local old = {enabled=cv:GetBool(),num=w.Num,spread=w.GetSpread,aim=w.GetAimVector}
local origin = Vector(-4000,-4000,-12190)
local direction = Vector(1,0,0)
local received, target

local function box(position, half, material)
    local e = ents.Create("base_anim")
    e:SetModel("models/hunter/blocks/cube025x025x025.mdl")
    e:SetPos(position)
    e:Spawn()
    e:PhysicsInitBox(-half, half)
    e:SetSolid(SOLID_VPHYSICS)
    e:SetMoveType(MOVETYPE_VPHYSICS)
    e:EnableCustomCollisions(true)
    e:GetPhysicsObject():EnableMotion(false)
    e:GetPhysicsObject():SetMaterial(material)
    entities[#entities+1] = e
    return e
end
local function clear()
    for _, e in ipairs(entities) do if IsValid(e) then e:Remove() end end
    entities = {}
end
local function check(name, success)
    if not success then failures[#failures+1] = name end
end
hook.Add("EntityTakeDamage", "MCV_PenetrationTest", function(ent, dmg)
    if ent != target then return end
    received[#received+1] = {damage=dmg:GetDamage(),type=dmg:GetDamageType(),
        attacker=dmg:GetAttacker()==ply,inflictor=dmg:GetInflictor()==w}
    return true
end)

local function run(name, layers, aim, pellets)
    clear()
    direction = aim or Vector(1,0,0)
    received = {}
    target = box(origin + direction*256, Vector(2,24,24), "metal")
    for i, layer in ipairs(layers) do
        box(origin+direction*(64+i*32), Vector(layer[1]*0.5,24,24), layer[2])
    end
    w.Num = pellets or 1
    w.GetSpread = function() return 0 end
    w.GetAimVector = function() return direction end
    local previous = ply:GetPos()
    ply:SetPos(origin - ply:GetViewOffset())
    local trace = util.TraceLine({start=origin,endpos=origin+direction*300,mask=MASK_SHOT,filter=ply})
    w:BulletAttack()
    ply:SetPos(previous)
    local damage = 0
    for _, r in ipairs(received) do
        damage = damage + r.damage
        check(name .. " attribution", r.attacker and r.inflictor)
    end
    local row = {name=name,damage=damage,hits=#received,mat=trace.MatType,records=received}
    results[#results+1] = row
    return row
end

local ok, err = xpcall(function()
    cv:SetBool(true)
    local control=run("unobstructed",{})
    check("unobstructed hit",control.hits==1 and control.damage>0)
    local wood=run("wood4",{{4,"wood"}})
    local metal=run("metal4",{{4,"metal"}})
    local glass=run("glass4",{{4,"glass"}})
    local concrete=run("concrete4",{{4,"concrete"}})
    local other=run("plastic4",{{4,"plastic"}})
    for _, row in ipairs({wood,metal,glass,concrete,other}) do
        check(row.name .. " penetrates once",row.hits==1 and row.damage>0 and row.damage<control.damage)
    end
    check("material costs",metal.damage<wood.damage and concrete.damage<wood.damage)
    for _, item in ipairs({{"wood17",17,"wood"},{"wood20",20,"wood"},{"metal8",8,"metal"}}) do
        check(item[1] .. " stops",run(item[1],{{item[2],item[3]}}).hits==0)
    end
    check("shallow angle penetrates",run("wood13",{{13,"wood"}}).hits==1)
    check("oblique angle stops",run("wood13_oblique",{{13,"wood"}},Vector(1,1,0):GetNormalized()).hits==0)
    local one=run("wood3",{{3,"wood"}})
    local two=run("wood3_plus3",{{3,"wood"},{3,"wood"}})
    check("stacked layers lose damage",two.hits==1 and two.damage<one.damage)
    check("mixed budget stops",run("metal4_plus_wood8",{{4,"metal"},{8,"wood"}}).hits==0)
    local pellets=run("eight_pellets",{{3,"wood"}},nil,8)
    check("pellets have independent budgets",pellets.hits==8 and math.abs(pellets.damage-one.damage*8)<0.01)
    for _, r in ipairs(pellets.records) do check("buckshot flag",bit.band(r.type,DMG_BUCKSHOT)!=0) end
    cv:SetBool(false)
    check("toggle disables penetration",run("disabled_wood3",{{3,"wood"}}).hits==0)
    cv:SetBool(true)
    local floor=util.TraceLine({start=origin,endpos=origin-Vector(0,0,2000),mask=MASK_SHOT,filter=ply})
    check("world floor hit",floor.HitWorld)
    check("thick world stops",w:FindPenetrationExit(floor,Vector(0,0,-1),50)==nil)
end,debug.traceback)
if not ok then failures[#failures+1]=err end
clear()
hook.Remove("EntityTakeDamage","MCV_PenetrationTest")
cv:SetBool(old.enabled)
w.Num,w.GetSpread,w.GetAimVector=old.num,old.spread,old.aim
file.Write(root.."penetration_engine.json",util.TableToJSON({results=results,failures=failures},true))
print("[penetration tests]",#results,"cases",#failures,"failures")
for _, failure in ipairs(failures) do print("[penetration FAIL]",failure) end
