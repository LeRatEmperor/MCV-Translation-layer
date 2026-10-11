// Cache immutable model indices, never poses, attachment transforms or predicted state.
// Entity identity and model changes invalidate the cache. Failed lookups are retried
// because an entity can be networked before its model is ready.
local entities = setmetatable({}, {__mode = "k"})

local function modelCache(ent)
    local model = ent:GetModel()
    if !model or model == "" then return end
    local cache = entities[ent]
    if !cache or cache.model != model then
        cache = {model = model}
        entities[ent] = cache
    end
    return cache
end

local function lookup(ent, name, method, minimum)
    local cache = modelCache(ent)
    if !cache then return ent[method](ent, name) end
    local indices = cache[method]
    if !indices then indices = {} cache[method] = indices end
    local id = indices[name]
    if id == nil then
        id = ent[method](ent, name)
        if id and id >= minimum then indices[name] = id end
    end
    return id
end

function MCV.CachedAttachment(ent, name)
    return lookup(ent, name, "LookupAttachment", 1)
end

function MCV.CachedBone(ent, name)
    return lookup(ent, name, "LookupBone", 0)
end

function MCV.CachedSequence(ent, name)
    return lookup(ent, name, "LookupSequence", 0)
end

function MCV.SequenceLoops(ent, sequence)
    local cache = modelCache(ent)
    local loops = cache and cache.loops
    if loops and loops[sequence] != nil then return loops[sequence] end
    local info = ent:GetSequenceInfo(sequence)
    if !info then return false end
    local looping = bit.band(info.flags, 1) != 0
    if cache then
        if !loops then loops = {} cache.loops = loops end
        loops[sequence] = looping
    end
    return looping
end
