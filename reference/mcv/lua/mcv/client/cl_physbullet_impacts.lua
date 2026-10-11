local contacts = {}
local expirations = {}
local head, tail = 1, 0
local lastTime = UnPredictedCurTime()

local function clearContacts()
    contacts, expirations = {}, {}
    head, tail = 1, 0
end

local function contactTime()
    local now = UnPredictedCurTime()
    if now < lastTime then clearContacts() end
    lastTime = now
    return now
end

// Flight runs outside command prediction. Deduplicate actual contacts, not Think calls.
function MCV.PhysicalBulletImpact(key, contactIndex, tr, damage, ricochet, color)
    if !tr.Hit or tr.HitSky or tr.StartSolid or tr.AllSolid then return end
    local now = contactTime()
    // Even indices are entry/terminal hits; odd indices are penetration exits.
    local id = key .. ":" .. contactIndex
    local old = contacts[id]
    if old and (old.pos - tr.HitPos):Length() <= 32 then return end
    local contact = {id = id, pos = tr.HitPos, expires = now + 15}
    contacts[id] = contact
    tail = tail + 1
    expirations[tail] = contact
    MCV.BulletImpact(tr, damage, nil, ricochet == true and contactIndex % 2 == 0, color)
end

net.Receive("MCV_PhysicalImpact", function()
    local key, contactIndex = net.ReadString(), net.ReadUInt(8)
    local function vector() return Vector(net.ReadFloat(), net.ReadFloat(), net.ReadFloat()) end
    local tr = {Hit = true, HitPos = vector(), StartPos = vector(), HitNormal = vector(),
        Entity = net.ReadEntity(), SurfaceProps = net.ReadUInt(16),
        MatType = net.ReadUInt(8), HitBox = net.ReadUInt(16)}
    local damage, ricochet = net.ReadFloat(), net.ReadBool()
    local color = ricochet and net.ReadColor(false) or nil
    MCV.PhysicalBulletImpact(key, contactIndex, tr, damage, ricochet, color)
end)

hook.Add("Think", "MCV_PhysicalImpactCleanup", function()
    local now = contactTime()
    // Expiry times are ordered. Quiet frames inspect only the oldest entry,
    // rather than every hit made during the previous fifteen seconds.
    while head <= tail do
        local hit = expirations[head]
        if now <= hit.expires then break end
        // A corrected contact can replace this id before its old entry expires.
        if contacts[hit.id] == hit then contacts[hit.id] = nil end
        expirations[head] = nil
        head = head + 1
    end
    if head > tail then
        head, tail = 1, 0
    elseif head > 1024 and head > tail / 2 then
        // Bound array indices during continuous fire. Amortized compaction is
        // proportional to expired contacts, never to rendered frames.
        local count = tail - head + 1
        for i = 1, count do
            expirations[i] = expirations[head + i - 1]
            expirations[head + i - 1] = nil
        end
        head, tail = 1, count
    end
end)
hook.Add("PostCleanupMap", "MCV_PhysicalImpactCleanup", clearContacts)
