local bullets = {}
local pending = {}
local fading = {}
local muzzleCache = setmetatable({}, {__mode = "k"})
local function clock() return UnPredictedCurTime() end
local function readFlightVector()
    return Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat())
end
// Standalone versions of the game's rope smoke emit at the moving CP0, without
// depending on particles in a native tracer parent. The beam supplies the streak.
local families = {
    assaultrifle = {150, 2}, gyrojet = {200, 3}, machinegun = {170, 4},
    pistol = {125, 3}, ptrd = {200, 4}, rifle = {200, 3}, shotgun = {125, 2},
    shotgun_dots = {0, 2}, silenced = {0, 0}, smg = {125, 2}, sniperrifle = {200, 3},
}
game.AddParticles("particles/mcv_physical_smoke.pcf")
for name in pairs(families) do
    PrecacheParticleSystem("mcv_phys_vietnam_tracer_" .. name .. "_smoke")
end
local beam = CreateMaterial("mcv_physical_tracer_beam", "UnlitGeneric", {
    ["$basetexture"] = "vgui/white", ["$additive"] = "1",
    ["$vertexcolor"] = "1", ["$vertexalpha"] = "1", ["$translucent"] = "1",
})
local glow = Material("sprites/light_glow02_add")

local function fadeSmoke(b)
    if !IsValid(b.particle) then return end
    b.particle:StopEmission(false, false, false)
    fading[#fading + 1] = {particle = b.particle, started = clock()}
    b.particle = nil
end

local function remove(id)
    local b = bullets[id]
    if b then fadeSmoke(b) end
    bullets[id] = nil
end

function MCV.PhysicalMuzzleOffset(offset, angle, viewFOV, worldFOV)
    local ratio = math.tan(math.rad(worldFOV) * 0.5) / math.tan(math.rad(viewFOV) * 0.5)
    local forward = angle:Forward()
    local axial = forward * offset:Dot(forward)
    return axial + (offset - axial) * ratio
end

// Called with the bones and camera used to draw the gun, outside prediction.
local muzzleNames = {"muzzle", "muzzleleft", "muzzle2"}
function MCV.CapturePhysicalMuzzles(wep, vm)
    if !MCV.PhysicalBulletsEnabled(wep) then muzzleCache[wep] = nil return end
    local owner = wep:GetOwner()
    if !IsValid(owner) or owner != LocalPlayer() or !IsValid(vm) then return end
    local eye, angle = EyePos(), EyeAngles()
    local viewFOV = MCV.ViewmodelFOV(wep, wep:GetSightAmountVisual() ^ 3)
    local entry = muzzleCache[wep] or {}
    entry.vm, entry.model, entry.time = vm, vm:GetModel(), clock()
    entry.muzzle, entry.muzzleleft, entry.muzzle2 = nil, nil, nil
    local worldFOV = wep.ViewmodelCameraFrame == FrameNumber()
        and wep.ViewmodelCameraFOV or owner:GetFOV()
    for _, name in ipairs(muzzleNames) do
        local id = MCV.CachedAttachment(vm, name)
        local att = id > 0 and vm:GetAttachment(id)
        local offset = att and att.Pos - eye
        if offset and offset:Length() <= 256 then
            entry[name] = MCV.PhysicalMuzzleOffset(offset, angle, viewFOV, worldFOV)
        end
    end
    muzzleCache[wep] = entry
end

local function muzzle(wep, owner, left, fallback)
    if !IsValid(wep) or !IsValid(owner) then return fallback end
    local mdl, att
    if owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
        mdl = owner:GetViewModel()
        if IsValid(mdl) then
            local cached = muzzleCache[wep]
            if cached and cached.vm == mdl and cached.model == mdl:GetModel()
                    and clock() >= cached.time and clock() - cached.time <= 0.1 then
                local offset = left and (cached.muzzleleft or cached.muzzle2) or cached.muzzle
                offset = offset or cached.muzzle
                if offset then return fallback + offset end
            end
            // Do not rebuild render bones from the user-command/prediction context.
            att = left and MCV.CachedAttachment(mdl, "muzzleleft") or 0
            if left and att <= 0 then att = MCV.CachedAttachment(mdl, "muzzle2") end
            if att <= 0 then att = MCV.CachedAttachment(mdl, "muzzle") end
        end
    elseif wep.GetWorldModelAttachment then
        mdl, att = wep:GetWorldModelAttachment("muzzle", left)
        if IsValid(mdl) then mdl:SetupBones() end
    end
    local a = IsValid(mdl) and att and att > 0 and mdl:GetAttachment(att)
    // Attachments can be stale/uninitialized during deploy or a model change.
    // A muzzle cannot reasonably be hundreds of units away from its shot source.
    if a and (a.Pos - fallback):Length() <= 256 then return a.Pos end
    return fallback
end

function MCV.PhysicalBulletVisualPosition(pos, offset, distance)
    return pos + offset * (1 - math.Clamp(distance / 1000, 0, 1))
end

local function updateSmoke(b)
    if !IsValid(b.particle) then return end
    // Share the beam's projected position in every path, not only in Think.
    b.particle:SetControlPoint(0, b.visualPos)
    b.particle:SetControlPoint(1, b.visualPos)
    b.particle:SetSortOrigin(b.visualPos)
end

local function updateVisual(b, pos, vel, distance)
    b.travelled = distance
    b.visualPos = MCV.PhysicalBulletVisualPosition(pos, b.muzzleOffset, distance)
    local tailLength = math.min(b.tail, distance)
    b.tailPos = MCV.PhysicalBulletVisualPosition(pos - vel:GetNormalized() * tailLength,
        b.muzzleOffset, distance - tailLength)
    updateSmoke(b)
end

local function startSmoke(b, pos)
    if !b.smoke or !CreateParticleSystemNoEntity then return end
    local ps = CreateParticleSystemNoEntity(b.smoke, pos)
    if !IsValid(ps) then return end
    // No emission may sample a default control point, including after penetration.
    ps:SetShouldSimulate(false)
    local angle = b.vel:Angle()
    for cp = 0, 1 do
        ps:SetControlPoint(cp, pos)
        ps:SetControlPointOrientation(cp, angle:Forward(), angle:Right(), angle:Up())
    end
    ps:SetSortOrigin(pos)
    // The PCF schedules emission after a short CP-history warmup. Do not stop
    // an empty system here: Source can consider it finished before it starts.
    ps:StartEmission()
    ps:SetShouldSimulate(true)
    b.particle = ps
end

local function create(id, pos, vel, owner, tracer, visible, gravity, drag, lifetime, wep, left, boost, burn)
    local family = tracer:gsub("^vietnam_tracer_", ""):gsub("_primary$", ""):gsub("_secondary$", "")
    local smokeFamily = family:gsub("_green", "")
    local style = families[smokeFamily] or {0, 0}
    local smoke = families[smokeFamily] and ("mcv_phys_vietnam_tracer_" .. smokeFamily .. "_smoke")
    // The packet carries the family even when its weapon/owner is outside PVS.
    // Keep remote flight/impacts, but never start (or restart) a silenced trail.
    if smokeFamily == "silenced" and (!IsValid(owner) or owner != LocalPlayer()) then
        smoke = nil
    end
    local color = MCV.TracerColor(owner, tracer)
    remove(id)
    local b = {pos = pos, vel = vel, gravity = gravity, drag = drag,
        boost = boost, boostTime = burn or 0, age = 0,
        expires = clock() + lifetime, lastTime = clock(), tail = style[1], width = style[2] * 0.2,
        visible = visible, color = color, travelled = 0}
    b.layers, b.budget = 0, 1
    b.damage = IsValid(wep) and wep.DamageGeneric * wep:StatMult("damage") or 40
    local from = muzzle(wep, owner, left, pos)
    b.muzzleOffset, b.visualPos, b.wep = from - pos, from, wep
    b.smoke = smoke
    startSmoke(b, from)
    b.owner, b.tracer = owner, tracer
    bullets[id] = b
    return b
end

function MCV.PredictPhysicalBullets(wep, pos, dir)
    if wep:GetOwner() != LocalPlayer() or (!game.SinglePlayer() and !IsFirstTimePredicted()) then return end
    local key = MCV.PhysicalShotKey(wep)
    if key == "" then return end // SP/out-of-command fire uses the authoritative spawn.
    local speed, gravity, drag, lifetime, acceleration, burn = MCV.PhysicalBulletParameters(wep)
    pos = pos or wep:GetOwner():GetShootPos()
    dir = (dir or wep:GetAimVector()):GetNormalized()
    for i = 1, MCV.PhysicalBulletCount(wep) do
        local token = key .. ":" .. i
        if pending[token] then continue end
        local heading = MCV.PhysicalBulletHeading(wep, dir, i, key)
        local vel = heading * speed
        local b = create(token, pos, vel, wep:GetOwner(), wep.TracerParticle or "",
            wep:Clip1() % math.max(wep.TracerFrequency or 1, 1) == 0, gravity, drag, lifetime, wep,
            wep.GetAkimbo and wep:GetAkimbo() and wep:Clip1() % 2 == 1,
            acceleration > 0 and heading * acceleration or nil, burn)
        b.predicted, b.started, b.wep = true, clock(), wep
        b.impactKey = MCV.PhysicalImpactKey(wep:GetOwner(), key, i)
        pending[token] = {bullet = b, expires = clock() + lifetime + 2}
    end
end

net.Receive("MCV_PhysicalBullet", function()
    local event, id, pos = net.ReadUInt(2), net.ReadUInt(32), readFlightVector()
    if event == 2 then remove(id) return end
    local vel, age, layer = readFlightVector(), net.ReadFloat(), net.ReadUInt(8)
    if event == 1 then
        local distance, damage, budget = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
        local b = bullets[id]
        if b then
            if b.predicted and b.layers >= layer then return end
            b.layers = layer
            b.travelled, b.damage, b.budget = distance, damage, budget
            local ahead = b.predicted and math.max(0, clock() - b.started - age) or 0
            b.pos, b.vel = MCV.BulletFlightStep(pos, vel, ahead, b.gravity, b.drag, b.boost, b.boostTime - age)
            b.age = age + ahead
            b.lastTime, b.tailPos = clock(), nil
            b.hidden = false
            // A rope must not connect the old path to a corrected/penetrated path.
            fadeSmoke(b)
            b.visualPos = MCV.PhysicalBulletVisualPosition(b.pos, b.muzzleOffset, b.travelled)
            startSmoke(b, b.visualPos)
        end
        return
    end
    local owner = net.ReadEntity()
    local wep, left = net.ReadEntity(), net.ReadBool()
    local key, pellet = net.ReadString(), net.ReadUInt(16)
    local tracer, visible = net.ReadString(), net.ReadBool()
    local gravity, drag, lifetime = net.ReadFloat(), net.ReadFloat(), net.ReadFloat()
    local boost, burn
    if net.ReadBool() then boost, burn = readFlightVector(), net.ReadFloat() end
    local token = key .. ":" .. pellet
    local match = owner == LocalPlayer() and key != "" and pending[token]
    if match then
        // Move the existing visual to the server ID, never replay it at the muzzle.
        local b = match.bullet
        if bullets[token] then
            bullets[token], bullets[id] = nil, b
            local elapsed = math.max(0, clock() - b.started)
            local previous = b.visualPos
            b.boost, b.boostTime, b.age = boost, burn or 0, elapsed
            b.pos, b.vel = MCV.BulletFlightStep(pos, vel, elapsed, gravity, drag, boost, burn)
            b.gravity, b.drag, b.lastTime = gravity, drag, clock()
            b.visualPos = MCV.PhysicalBulletVisualPosition(b.pos, b.muzzleOffset, b.travelled)
            if !b.hidden and (b.visualPos - previous):Length() > 32 then
                fadeSmoke(b)
                startSmoke(b, b.visualPos)
            end
            updateVisual(b, b.pos, b.vel, b.travelled)
        end
        return // Tombstones also suppress echoes after a predicted bullet expires.
    end
    local b = create(id, pos, vel, owner, tracer, visible, gravity, drag, lifetime, wep, left, boost, burn)
    b.age = age
end)

local function advanceVisual(b, dt, now)
    local pos, vel = MCV.BulletFlightStep(b.pos, b.vel, dt, b.gravity, b.drag, b.boost, b.boostTime - b.age)
    b.age = b.age + dt
    if b.predicted then
        // Replicate contact and penetration cosmetically, never client damage.
        local tr = MCV.TracePhysicalBullet(b, b.pos, pos)
        if tr.Hit or tr.StartSolid then
            local hit = tr.StartSolid and b.pos or tr.HitPos
            local distance = b.travelled + (hit - b.pos):Length()
            local continuation = {}
            if IsValid(b.wep) then
                b.wep:QueuePenetration(tr, {damage = b.damage, distance = b.travelled,
                    budget = b.budget, layers = b.layers}, continuation)
            end
            local nextState = continuation[1]
            MCV.PhysicalBulletImpact(b.impactKey, b.layers * 2, tr,
                b.damage * (IsValid(b.wep) and MCV.BulletRangeMultiplier(b.wep, distance) or 1),
                !nextState and b.visible and MCV.HasTracerStreak(b.tracer), b.color)
            if nextState then
                if nextState.exitTrace then
                    MCV.PhysicalBulletImpact(b.impactKey, b.layers * 2 + 1, nextState.exitTrace, nextState.exitDamage)
                end
                b.pos, b.vel, b.lastTime = nextState.src, nextState.dir * vel:Length(), now
                b.layers, b.budget, b.damage = nextState.layers, nextState.budget, nextState.damage
                updateVisual(b, b.pos, b.vel, nextState.distance)
                return
            end
            updateVisual(b, hit, vel, b.travelled + (hit - b.pos):Length())
            b.hidden = true
            fadeSmoke(b)
            return
        end
    end
    local distance = b.travelled + (pos - b.pos):Length()
    b.pos, b.vel, b.lastTime, b.travelled = pos, vel, now, distance
end

hook.Add("Think", "MCV_PhysicalBulletVisuals", function()
    local now = clock()
    for i = #fading, 1, -1 do
        local old = fading[i]
        if !IsValid(old.particle) or now - old.started > 5 or now < old.started then
            if IsValid(old.particle) then old.particle:StopEmissionAndDestroyImmediately() end
            table.remove(fading, i)
        end
    end
    for token, entry in pairs(pending) do
        if now > entry.expires or now < entry.bullet.started then pending[token] = nil end
    end
    for id, b in pairs(bullets) do
        if now > b.expires or now < b.lastTime or b.travelled >= 56756 or (b.predicted and !IsValid(b.wep)) then remove(id) continue end
        if b.hidden then continue end
        local dt = now - b.lastTime
        if dt > 0 then
            local steps = math.max(1, math.ceil(dt / (1 / 120)))
            for _ = 1, steps do
                advanceVisual(b, dt / steps, now)
                if b.hidden then break end
            end
            // Collision retains every substep; the renderer consumes only the
            // frame's final pose. Terminal contacts update before hiding above.
            if !b.hidden then updateVisual(b, b.pos, b.vel, b.travelled) end
        end
    end
end)

hook.Add("PostDrawTranslucentRenderables", "MCV_PhysicalBulletVisuals", function(depth, sky)
    if depth or sky then return end
    for _, b in pairs(bullets) do
        if b.hidden or !b.visible or b.tail <= 0 or !b.tailPos then continue end
        render.SetMaterial(beam)
        render.DrawBeam(b.tailPos, b.visualPos, b.width, 0, 1, b.color)
        render.SetMaterial(glow)
        render.DrawSprite(b.visualPos, b.width * 3, b.width * 3, b.color)
    end
end)

local function clear()
    pending = {}
    muzzleCache = setmetatable({}, {__mode = "k"})
    for id in pairs(bullets) do remove(id) end
    for _, old in ipairs(fading) do
        if IsValid(old.particle) then old.particle:StopEmissionAndDestroyImmediately() end
    end
    fading = {}
end
hook.Add("PostCleanupMap", "MCV_PhysicalBulletVisuals", clear)
hook.Add("ShutDown", "MCV_PhysicalBulletVisuals", clear)
