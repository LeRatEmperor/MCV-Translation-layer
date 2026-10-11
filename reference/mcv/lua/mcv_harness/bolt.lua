MCVBoltTest = MCVBoltTest or {}
local T = MCVBoltTest
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
local function vec(v) return {x = v.x, y = v.y, z = v.z} end
if CLIENT then
    function T.Model()
        local model = "models/weapons/mcv/crossbow_bolt.mdl"
        local meshes, bind = util.GetModelMeshes(model)
        local entity=ClientsideModel(model)
        entity:SetPos(vector_origin)
        entity:SetAngles(angle_zero)
        entity:SetupBones()
        local lo, hi = Vector(math.huge, math.huge, math.huge), Vector(-math.huge, -math.huge, -math.huge)
        for _, mesh in ipairs(meshes or {}) do
            for _, vertex in ipairs(mesh.triangles) do
                local p = Vector()
                for _, weight in ipairs(vertex.weights) do
                    p=p+(entity:GetBoneMatrix(weight.bone)*bind[weight.bone].matrix*vertex.pos)*weight.weight
                end
                lo.x, lo.y, lo.z = math.min(lo.x,p.x), math.min(lo.y,p.y), math.min(lo.z,p.z)
                hi.x, hi.y, hi.z = math.max(hi.x,p.x), math.max(hi.y,p.y), math.max(hi.z,p.z)
            end
        end
        entity:Remove()
        assert(math.abs(hi.x-20.03)<0.05,"bolt tip calibration changed")
        file.Write(root .. "bolt_model_posed.json", util.TableToJSON({min=vec(lo),max=vec(hi)},true))
    end
    function T.View(name)
        for _, bolt in ipairs(ents.FindByClass("mcv_proj_bolt")) do
            if bolt:GetNWString("MCVBoltTest") != name then continue end
            local centre = bolt:LocalToWorld(Vector(8,0,0))
            local origin = centre + Vector(-45,-65,40)
            hook.Add("CalcView","MCVBoltTest",function() return {origin=origin,angles=(centre-origin):Angle(),fov=35,drawviewer=true} end)
            return
        end
        error("missing visual bolt " .. name)
    end
    function T.WatchFlight()
        T.client={samples={},minimum=1,draws=0}
        hook.Add("Think","MCVBoltFlight",function()
            if IsValid(T.client.entity) then return end
            for _, e in ipairs(ents.FindByClass("mcv_proj_bolt")) do
                if e:GetNWString("MCVBoltTest")!="free" then continue end
                T.client.entity=e
                local previous
                e.RenderOverride=function(self)
                    T.client.draws=T.client.draws+1
                    local pos=self:GetPos()
                    local v=previous and (pos-previous)
                    previous=pos
                    self:Draw()
                    if v and v:LengthSqr()>0.001 then
                        local dot=(self.FlightRenderAngle or self:GetAngles()):Forward():Dot(v:GetNormalized())
                        T.client.minimum=math.min(T.client.minimum,dot)
                        T.client.samples[#T.client.samples+1]={dot=dot,vel=vec(v),move=self:GetMoveType()}
                    end
                end
                hook.Add("CalcView","MCVBoltTest",function()
                    if !IsValid(e) then return end
                    local centre=e:GetPos()
                    local origin=centre+Vector(-45,-65,40)
                    return {origin=origin,angles=(centre-origin):Angle(),fov=35,drawviewer=true}
                end)
            end
        end)
    end
    function T.CheckClient(label)
        hook.Remove("Think","MCVBoltFlight")
        local result={minimum=T.client.minimum,samples=T.client.samples,draws=T.client.draws,found=IsValid(T.client.entity)}
        result.passed=#result.samples>=10 and result.minimum>0.99
        file.Write(root .. "bolt_render_" .. label .. ".json",util.TableToJSON(result,true))
        assert(result.passed,"bolt render alignment failed")
    end
    return
end

function T.Baseline(ply)
    T.rows = {}
    for i = 1, 2 do
        local bolt = ents.Create("mcv_proj_bolt")
        bolt:SetPos(Vector(3500, i * 300, -10000))
        bolt:SetAngles(angle_zero)
        bolt:SetOwner(ply)
        bolt:Spawn()
        bolt:GetPhysicsObject():SetVelocityInstantaneous(Vector(1800,0,0))
        local row = {control=i==2, samples={}, angles={}}
        bolt.OnThink = function(self)
            local phys = self:GetPhysicsObject()
            local before = phys:GetVelocity()
            // Reproduce the original velocity-reset bug on this test bolt only.
            if i == 1 and before:LengthSqr()>100 then self:SetAngles(before:Angle()) end
            row.angles[#row.angles+1] = {time=CurTime(), before=vec(before), after=vec(phys:GetVelocity())}
        end
        row.entity = bolt
        T.rows[#T.rows+1] = row
    end
    hook.Add("Think", "MCVBoltTest", function()
        for _, row in ipairs(T.rows) do
            local e = row.entity
            if IsValid(e) then row.samples[#row.samples+1] = {time=CurTime(),pos=vec(e:GetPos()),vel=vec(e:GetVelocity())} end
        end
    end)
end

function T.FinishBaseline()
    hook.Remove("Think", "MCVBoltTest")
    for _, row in ipairs(T.rows) do row.entity:Remove() row.entity=nil end
    file.Write(root .. "bolt_baseline.json", util.TableToJSON(T.rows,true))
end

function T.Start(ply, label)
    T.rows, T.entities, T.label = {}, {}, label
    local function launch(name, position, velocity, kind)
        local bolt = ents.Create("mcv_proj_bolt")
        bolt:SetPos(position)
        bolt:SetAngles(velocity:Angle())
        bolt:SetOwner(ply)
        bolt:Spawn()
        bolt:GetPhysicsObject():SetVelocityInstantaneous(velocity)
        bolt:SetNWString("MCVBoltTest", name)
        local row = {name=name, entity=bolt, kind=kind, start=position, velocity=velocity, samples={}, turns={}, impacts={}}
        local think, impact = bolt.OnThink, bolt.Impact
        bolt.OnThink = function(self)
            local phys = self:GetPhysicsObject()
            local before = IsValid(phys) and phys:GetVelocity()
            think(self)
            if before and IsValid(phys) and !self.HitDone and !self.ImpactQueued then
                row.turns[#row.turns+1] = before:Distance(phys:GetVelocity())
            end
        end
        bolt.Impact = function(self,data,collider)
            row.impacts[#row.impacts+1] = {pos=data.HitPos,dir=data.OurOldVelocity:GetNormalized(),class=data.HitEntity:GetClass()}
            impact(self,data,collider)
        end
        T.entities[#T.entities+1], T.rows[#T.rows+1] = bolt, row
        return row
    end
    launch("free",Vector(-5000,3000,-10000),Vector(1800,0,0),"free")
    launch("ground",Vector(5000,2500,-12400),Vector(0,0,-2200),"world")
    launch("oblique",Vector(5000,3000,-12400),Vector(1555,0,-1555),"world")
    for i=1,2 do
        local prop=ents.Create("prop_physics")
        prop:SetModel("models/hunter/blocks/cube2x2x2.mdl")
        prop:SetPos(Vector(6000,i*800,-12600))
        prop:Spawn()
        prop:GetPhysicsObject():EnableMotion(false)
        T.entities[#T.entities+1]=prop
        local row=launch(i==1 and "prop" or "moving_prop",prop:WorldSpaceCenter()-Vector(600,0,0),Vector(2500,0,70),"prop")
        row.target=prop
    end
    local npc=ents.Create("npc_combine_s")
    npc:SetPos(Vector(6000,-1500,-12799))
    npc:Spawn()
    npc:SetHealth(1000)
    npc:SetSchedule(SCHED_NPC_FREEZE)
    T.entities[#T.entities+1]=npc
    local row=launch("body",npc:WorldSpaceCenter()-Vector(200,0,0),Vector(2500,0,0),"body")
    row.target=npc
    local damageCount=0
    hook.Add("EntityTakeDamage","MCVBoltTest",function(ent,dmg)
        if ent==npc then
            row.damageEvents=row.damageEvents or {}
            row.damageEvents[#row.damageEvents+1]={amount=dmg:GetDamage(),type=dmg:GetDamageType()}
            if dmg:GetDamage()>0 then damageCount=damageCount+1 row.damageCount=damageCount row.damage=dmg:GetDamage() end
        end
    end)
    // Exercise the real weapon launch as well as controlled trajectory cases.
    local w=ply:GetWeapon("mcv_crossbow")
    if !IsValid(w) then w=ply:Give("mcv_crossbow") end
    local oldRandom=w.RandomSpread
    w.RandomSpread=function() return angle_zero end
    local old={}
    for _, e in ipairs(ents.FindByClass("mcv_proj_bolt")) do old[e]=true end
    w:LaunchProjectile(false,1,Vector(-5000,4000,-10000),Vector(1,0,0))
    w.RandomSpread=oldRandom
    for _,e in ipairs(ents.FindByClass("mcv_proj_bolt")) do
        if old[e] then continue end
        T.entities[#T.entities+1]=e
        T.rows[#T.rows+1]={name="weapon_launch",entity=e,kind="free",start=e:GetPos(),velocity=e:GetVelocity(),samples={},turns={},impacts={}}
    end
    T.started=CurTime()
    hook.Add("SetupPlayerVisibility","MCVBoltTest",function()
        for _, e in ipairs(T.entities) do if IsValid(e) then AddOriginToPVS(e:GetPos()) end end
    end)
    hook.Add("Think","MCVBoltTest",function()
        for _, row in ipairs(T.rows) do
            local e=row.entity
            if !IsValid(e) then continue end
            if row.kind=="free" and CurTime()-T.started>0.35 then continue end
            local velocity=e:GetVelocity()
            row.samples[#row.samples+1]={t=CurTime()-T.started,pos=vec(e:GetPos()),vel=vec(velocity),alignment=(-e:GetRight()):Dot(velocity:GetNormalized())}
        end
    end)
end

function T.Check()
    hook.Remove("Think","MCVBoltTest")
    hook.Remove("EntityTakeDamage","MCVBoltTest")
    local result={passed=true,cases={}}
    for _,row in ipairs(T.rows) do
        local e=row.entity
        local report={name=row.name, samples=row.samples, turns=row.turns, impacts=#row.impacts}
        local ok=true
        if row.kind=="free" then
            local s=row.samples[#row.samples]
            ok=s and s.vel.x>row.velocity.x*0.90 and s.pos.x-row.start.x>row.velocity.x*0.2
            for _,delta in ipairs(row.turns) do ok=ok and delta<0.001 end
        elseif row.kind=="body" then
            ok=!IsValid(e) and row.damageCount==1 and row.damage>0
            report.damage,report.damageCount,report.damageEvents=row.damage,row.damageCount,row.damageEvents
        else
            ok=IsValid(e) and #row.impacts==1 and e:GetMoveType()==MOVETYPE_NONE and !IsValid(e:GetPhysicsObject())
            if ok then
                local hit=row.impacts[1]
                report.alignment=e:GetForward():Dot(hit.dir)
                report.tip_error=e:LocalToWorld(Vector(20.03,0,0)):Distance(hit.pos+hit.dir*2)
                ok=report.alignment>0.999 and report.tip_error<0.02
                row.fixedPos=e:GetPos()
                if row.kind=="prop" then
                    ok=ok and e:GetParent()==row.target
                    local localPos=e:GetLocalPos()
                    row.target:SetPos(row.target:GetPos()+Vector(40,30,15))
                    row.target:SetAngles(Angle(10,30,0))
                    report.parent_error=e:GetPos():Distance(row.target:LocalToWorld(localPos))
                    ok=ok and report.parent_error<0.02
                end
            end
        end
        report.passed=ok
        result.passed=result.passed and ok
        result.cases[#result.cases+1]=report
    end
    T.result=result
    file.Write(root .. "bolt_" .. T.label .. ".json",util.TableToJSON(result,true))
    assert(result.passed,"bolt checks failed; see result JSON")
end

function T.Cleanup(ply)
    hook.Remove("SetupPlayerVisibility","MCVBoltTest")
    // The stationary world bolt must remain still and retain pickup behavior.
    for _,row in ipairs(T.rows) do
        if row.name!="ground" then continue end
        local e=row.entity
        assert(e:GetPos():Distance(row.fixedPos)<0.01,"stuck world bolt moved")
        local ammo=ply:GetAmmoCount("XBowBolt")
        e:Use(ply)
        assert(ply:GetAmmoCount("XBowBolt")==ammo+1,"bolt pickup lost ammo")
    end
    for _,e in ipairs(T.entities) do if IsValid(e) then e:Remove() end end
    file.Write(root .. "bolt_pickup_" .. T.label .. ".json",'{"stationary":true,"ammo_returned":true}')
end
