util.AddNetworkString("MCV_PhysicalBullet")
util.AddNetworkString("MCV_PhysicalImpact")
local bullets = {}
local serial = 0
local maxDistance = 56756

local function waterSplash(from, to, damage)
    // A separate water trace does not stop the bullet's MASK_SHOT flight.
    local tr = util.TraceLine({start = from, endpos = to, mask = MASK_WATER})
    if tr.StartSolid then
        // Leaving water: trace backwards to locate the surface rather than the origin.
        tr = util.TraceLine({start = to, endpos = from, mask = MASK_WATER})
    end
    if !tr.Hit or tr.StartSolid or tr.AllSolid then return end
    local fx = EffectData()
    fx:SetOrigin(tr.HitPos)
    fx:SetNormal(tr.HitNormal)
    fx:SetScale(math.Clamp(math.sqrt(math.max(damage, 0) / 40), 0.5, 2) * 10)
    fx:SetFlags(bit.band(util.PointContents(tr.HitPos - tr.HitNormal), CONTENTS_SLIME) != 0 and 1 or 0)
    util.Effect("watersplash", fx, true, true)
end

local function writeFlightVector(v)
    // net.WriteVector truncates components above 16384; rifle velocities exceed it.
    net.WriteFloat(v.x)
    net.WriteFloat(v.y)
    net.WriteFloat(v.z)
end

local function send(b, event)
    net.Start("MCV_PhysicalBullet")
    net.WriteUInt(event, 2) // spawn, penetration correction, end
    net.WriteUInt(b.id, 32)
    writeFlightVector(b.src)
    if event != 2 then
        writeFlightVector(b.vel)
        net.WriteFloat(b.age)
        net.WriteUInt(b.layers, 8)
        if event == 1 then
            net.WriteFloat(b.distance)
            net.WriteFloat(b.damage)
            net.WriteFloat(b.budget)
        end
    end
    if event == 0 then
        net.WriteEntity(b.owner)
        net.WriteEntity(b.wep)
        net.WriteBool(b.left)
        net.WriteString(b.key)
        net.WriteUInt(b.pellet, 16)
        net.WriteString(b.tracer)
        net.WriteBool(b.glow)
        net.WriteFloat(b.gravity)
        net.WriteFloat(b.drag)
        net.WriteFloat(b.lifetime)
        net.WriteBool(b.boost != nil)
        if b.boost then
            writeFlightVector(b.boost)
            net.WriteFloat(b.boostTime)
        end
    end
    // A fast bullet can enter another client's PVS after leaving its shooter.
    // Broadcast compact spawn/transition messages, never a per-tick position stream.
    net.Broadcast()
end

local function impact(b, tr, damage, exit, penetrated)
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    net.Start("MCV_PhysicalImpact")
    net.WriteString(MCV.PhysicalImpactKey(b.owner, b.key, b.pellet, b.id))
    // Separate contact IDs keep a thin wall's exit from deduplicating its entry.
    net.WriteUInt(b.layers * 2 + (exit and 1 or 0), 8)
    writeFlightVector(tr.HitPos)
    writeFlightVector(tr.StartPos)
    writeFlightVector(tr.HitNormal)
    net.WriteEntity(tr.Entity)
    net.WriteUInt(tr.SurfaceProps or 0, 16)
    net.WriteUInt(tr.MatType or 0, 8)
    net.WriteUInt(math.max(tr.HitBox or 0, 0), 16)
    net.WriteFloat(damage)
    local ricochet = !exit and !penetrated and b.glow and MCV.HasTracerStreak(b.tracer)
    net.WriteBool(ricochet)
    if ricochet then net.WriteColor(b.color, false) end
    net.Broadcast()
end

function MCV.LaunchPhysicalBullets(wep, pos, dir)
    local owner = wep:GetOwner()
    if !IsValid(owner) then return end
    local speed, gravity, drag, lifetime, acceleration, burn = MCV.PhysicalBulletParameters(wep)
    local key = MCV.PhysicalShotKey(wep)
    pos = pos or owner:GetShootPos()
    dir = (dir or wep:GetAimVector()):GetNormalized()
    for i = 1, MCV.PhysicalBulletCount(wep) do
        local heading = MCV.PhysicalBulletHeading(wep, dir, i, key)
        serial = (serial + 1) % 4294967296
        local b = {id = serial, key = key, pellet = i, src = pos, vel = heading * speed, owner = owner, wep = wep,
            left = wep.GetAkimbo and wep:GetAkimbo() and wep:Clip1() % 2 == 1 or false,
            gravity = gravity, drag = drag, lifetime = lifetime, age = 0,
            boost = acceleration > 0 and heading * acceleration or nil, boostTime = burn,
            damage = wep.DamageGeneric * wep:StatMult("damage"), distance = 0, budget = 1, layers = 0,
            pellets = wep:GetBulletCount(), tracer = wep.TracerParticle or "",
            color = MCV.TracerColor(owner, wep.TracerParticle),
            glow = wep:Clip1() % math.max(wep.TracerFrequency or 1, 1) == 0}
        bullets[#bullets + 1] = b
        send(b, 0)
    end
end

local function advance(b, dt)
    b.age = b.age + dt
    if b.age > b.lifetime or b.distance >= maxDistance or !IsValid(b.owner) or !IsValid(b.wep) then return false end
    local target, velocity = MCV.BulletFlightStep(b.src, b.vel, dt, b.gravity, b.drag,
        b.boost, b.boostTime - (b.age - dt))
    local delta = target - b.src
    local length = delta:Length()
    if length <= 0.00001 then b.vel = velocity return true end
    if b.distance + length > maxDistance then
        length = maxDistance - b.distance
        target = b.src + delta:GetNormalized() * length
    end
    local tr = MCV.TracePhysicalBullet(b, b.src, target)
    waterSplash(b.src, tr.Hit and tr.HitPos or target, b.damage)
    if !tr.Hit and !tr.StartSolid and !tr.AllSolid then
        MCV.PhysicalBulletGlass(b, b.src, target)
        b.distance = b.distance + length
        b.src, b.vel = target, velocity
        return true
    end
    // A close target can overlap the shot origin. Source's damage trace handles
    // startsolid entity hits; discarding them here made point-blank pellets vanish.
    // Embedded world starts still stop here, with no probing/firing through cover.
    if tr.HitSky or ((tr.StartSolid or tr.AllSolid) and (tr.HitWorld or !IsValid(tr.Entity))) then
        b.src = tr.HitPos
        return false
    end

    local continuation = {}
    // The swept trace finds contact; a tracer-free engine bullet applies
    // normal hitgroups, damage hooks, physics force and stock impact fallback.
    // Retrace the whole swept segment: HitPos is tolerance-offset from the solid,
    // so stopping only 0.1 HU past it can still miss the face at a shallow angle.
    // No lag compensation: this bullet hits what occupies this position now.
    b.owner:FireBullets({Src = b.src, Dir = delta:GetNormalized(),
        Distance = length, Spread = vector_origin,
        Num = 1, Tracer = 0, Damage = b.damage, Attacker = b.owner, Inflictor = b.wep,
        IgnoreEntity = b.wep,
        Callback = function(_, hit, damage)
            b.wep:ApplyBulletDamage(hit, damage, b.distance + (hit.HitPos - b.src):Length(), b.pellets)
            b.wep:QueuePenetration(hit, b, continuation)
            impact(b, hit, damage:GetDamage(), false, continuation[1] != nil)
            // Exactly one effect owner: client flight/confirmation, never this
            // engine bullet plus the SWEP impact hook plus a networked effect.
            return {effects = false}
        end})
    local nextState = continuation[1]
    if nextState then
        if nextState.exitTrace then impact(b, nextState.exitTrace, nextState.exitDamage, true) end
        b.src, b.distance, b.damage = nextState.src, nextState.distance, nextState.damage
        b.budget, b.layers = nextState.budget, nextState.layers
        // Damage attenuation is handled by the penetration code; retain flight speed.
        b.vel = nextState.dir * velocity:Length()
        send(b, 1)
        return true
    end
    b.src = tr.HitPos
    return false
end

hook.Add("Tick", "MCV_PhysicalBullets", function()
    local dt = engine.TickInterval()
    // Short curved segments keep gravity accurate even on low-tick servers.
    local steps = math.max(1, math.ceil(dt / (1 / 120)))
    for i = #bullets, 1, -1 do
        local b = bullets[i]
        local alive = true
        for _ = 1, steps do
            if !advance(b, dt / steps) then alive = false break end
        end
        if !alive then send(b, 2) table.remove(bullets, i) end
    end
end)

hook.Add("PostCleanupMap", "MCV_PhysicalBullets", function()
    for _, b in ipairs(bullets) do send(b, 2) end
    bullets = {}
end)
