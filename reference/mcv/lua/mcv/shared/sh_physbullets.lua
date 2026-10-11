// Server-authoritative flight; clients simulate the same trajectory for tracers only.
function MCV.PhysicalBulletsEnabled(wep)
    if !MCV.ConVars.mcv_physbullets:GetBool() or wep:GetProjectileClass() then return false end
    if (wep.MuzzleVelocity or 0) <= 0 then return false end
    local owner = wep:GetOwner()
    if !IsValid(owner) then return false end
    if owner:IsNPC() and !MCV.ConVars.mcv_physbullets_npcs:GetBool() then return false end
    return wep:GetBulletCount() <= 1 or MCV.ConVars.mcv_physbullets_pellets:GetBool()
end

// Analytic integration of constant gravity/thrust and linear drag, independent of tick rate.
// Velocity is HU/s, gravity is HU/s^2, drag is inverse seconds.
function MCV.BulletFlightStep(pos, vel, dt, gravity, drag, boost, burnRemaining)
    // Split exactly at motor burnout, including network catch-up steps. Thrust
    // follows the launch direction; gravity still bends the flight normally.
    if boost and burnRemaining > 0 and burnRemaining < dt then
        local p, v = MCV.BulletFlightStep(pos, vel, burnRemaining, gravity, drag, boost, burnRemaining)
        return MCV.BulletFlightStep(p, v, dt - burnRemaining, gravity, drag)
    end
    local ax, ay, az = 0, 0, -gravity
    if boost and burnRemaining > 0 then
        ax, ay, az = boost.x, boost.y, boost.z - gravity
    end
    // Scalar integration creates only the two result vectors. Operator chains
    // allocate intermediate userdata for every bullet's every substep.
    if drag <= 0 then
        local half = 0.5 * dt * dt
        return Vector(pos.x + vel.x * dt + ax * half, pos.y + vel.y * dt + ay * half,
            pos.z + vel.z * dt + az * half),
            Vector(vel.x + ax * dt, vel.y + ay * dt, vel.z + az * dt)
    end
    local decay = math.exp(-drag * dt)
    local factor = (1 - decay) / drag
    local forceFactor = (dt - factor) / drag
    return Vector(pos.x + vel.x * factor + ax * forceFactor, pos.y + vel.y * factor + ay * forceFactor,
        pos.z + vel.z * factor + az * forceFactor),
        Vector(vel.x * decay + ax * factor, vel.y * decay + ay * factor, vel.z * decay + az * factor)
end

// Both hitscan and physical bullets use the same distance response. A capped
// ramp replaces ordinary falloff for rocket bullets; cover loss still multiplies it.
function MCV.BulletRangeMultiplier(wep, distance)
    if (wep.DamageRampDistance or 0) > 0 then
        local t = math.Clamp(distance / wep.DamageRampDistance, 0, 1)
        local start = wep.DamageRampStart or 1
        return start + ((wep.DamageRampEnd or 1) - start) * t
    end
    return math.pow(wep.RangeModifier or 1, math.max(distance / 500, 0))
end

// One request/filter per bullet, reused across its swept collision substeps.
// Returned traces are still independent; only our input table is reused.
function MCV.TracePhysicalBullet(b, from, to)
    local request = b.traceRequest
    if !request then
        request = {mask = MASK_SHOT, filter = {b.owner, b.wep}}
        b.traceRequest = request
    end
    request.start, request.endpos = from, to
    request.filter[1], request.filter[2] = b.owner, b.wep
    return util.TraceLine(request)
end

function MCV.PhysicalBulletParameters(wep)
    local scale = math.Clamp(MCV.ConVars.mcv_physbullets_velocity:GetFloat(), 0.1, 3) / 0.0254
    local burn = math.max(wep.BulletBoostTime or 0, 0)
    local speed = math.max(burn > 0 and (wep.BulletLaunchVelocity or wep.MuzzleVelocity) or wep.MuzzleVelocity, 1)
    local acceleration = burn > 0 and math.max(0, wep.MuzzleVelocity - speed) * scale / burn or 0
    return speed * scale,
        9.80665 / 0.0254 * math.Clamp(MCV.ConVars.mcv_physbullets_gravity:GetFloat(), 0, 3),
        math.Clamp(MCV.ConVars.mcv_physbullets_drag:GetFloat(), 0, 2),
        math.Clamp(MCV.ConVars.mcv_physbullets_lifetime:GetFloat(), 0.1, 10), acceleration, burn
end

function MCV.PhysicalShotKey(wep)
    local owner = wep:GetOwner()
    if !owner:IsPlayer() then return "" end
    local cmd = owner:GetCurrentCommand()
    if !cmd or cmd:CommandNumber() == 0 then return "" end
    return wep:EntIndex() .. ":" .. cmd:CommandNumber() .. ":" .. wep:Clip1() .. ":" .. wep:GetBurstCount()
end

function MCV.PhysicalImpactKey(owner, key, pellet, serverID)
    if key == "" then return "server:" .. serverID end
    return owner:EntIndex() .. ":" .. key .. ":" .. pellet
end

function MCV.PhysicalBulletCount(wep)
    local count = wep:GetBulletCount()
    if wep:GetFiremodeValue() == MCV.FIREMODE_VOLLEY then
        count = count * math.min(wep:Clip1(), wep.VolleyCount)
    end
    return count
end

function MCV.PhysicalBulletHeading(wep, dir, pellet, key)
    local owner = wep:GetOwner()
    local spread = owner:IsNPC() and wep:GetNPCSpread() or wep:GetSpread()
    local draw = 0
    local function random()
        draw = draw + 1
        if key == "" then return math.Rand(-0.5, 0.5) end
        return util.SharedRandom("MCV_PhysicalSpread:" .. key, -0.5, 0.5, pellet * 256 + draw)
    end
    local x, y
    repeat x, y = random() + random(), random() + random() until x*x + y*y <= 1
    local angle = dir:Angle()
    return (dir + angle:Right() * (x * spread) + angle:Up() * (y * spread)):GetNormalized()
end
