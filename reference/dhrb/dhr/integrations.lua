if SERVER then AddCSLuaFile() end
if DHR.RegisterIntegration then return end

local policies = {
    DHRCanFire = 'check', DHRCanReload = 'check', DHRCanBash = 'check',
    DHRCanExecute = 'check', DHRCanExecuteTarget = 'check', HRCanExecutePlayer = 'check',
    DHRCanReceiveAmmo = 'check', HRCanCreatePlayerCorpse = 'check',
    DHRCanDismember = 'check', DHRCanUseFeature = 'check',
    DHRModifyBullet = 'event', DHRShotFired = 'event', DHRReloadStarted = 'event',
    DHRMeleeHit = 'event', DHRBashHit = 'event', DHRWeaponBroken = 'event',
    DHRAmmoThrown = 'event', DHRAmmoReceived = 'event', DHRPlayerCorpseReady = 'event',
    DHRReceiveAmmo = 'provider', HRExecutionVoice = 'provider', DHRBodyState = 'provider',
}
local integrations, handlers, errors = {}, {}, {}
DHR.IntegrationVersion = 1

local function report(id, event, message)
    local key = id .. ':' .. event
    if errors[key] == message then return end
    errors[key] = message
    ErrorNoHalt('DHRB integration ' .. id .. ' (' .. event .. '): ' .. message .. '\n')
end

function DHR.RegisterIntegration(id, callbacks, priority)
    assert(isstring(id) and id:match('^[%w_.%-]+$'), 'DHR: integration needs a unique namespaced ID')
    assert(istable(callbacks), 'DHR: integration callbacks must be a table')
    priority = priority or 0
    assert(isnumber(priority) and priority == priority and math.abs(priority) < math.huge,
        'DHR: integration priority must be finite')
    local entry = {id = id, priority = priority, callbacks = {}}
    for event, callback in pairs(callbacks) do
        assert(policies[event] and isfunction(callback), 'DHR: unsupported integration callback ' .. tostring(event))
        entry.callbacks[event] = callback
    end
    integrations[id] = entry
    handlers = {}
end

function DHR.RemoveIntegration(id)
    integrations[id] = nil
    handlers = {}
end

local function registered(event)
    if handlers[event] then return handlers[event] end
    local list = {}
    for _, entry in pairs(integrations) do
        if entry.callbacks[event] then list[#list + 1] = entry end
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.id < b.id
    end)
    handlers[event] = list
    return list
end

function DHR.RunHook(event, ...)
    local policy = assert(policies[event], 'DHR: unsupported integration event ' .. tostring(event))
    local args, count = {...}, select('#', ...)
    local result
    local function invoke(id, callback, object)
        local ok, value = xpcall(function()
            if object then return callback(object, unpack(args, 1, count)) end
            return callback(unpack(args, 1, count))
        end, debug.traceback)
        if not ok then
            report(id, event, value)
            value = false
        end
        if policy == 'check' then
            if value == false then result = false
            elseif value == true and result == nil then result = true end
        elseif policy == 'provider' and value ~= nil then
            result = value
            return true
        end
    end
    -- Snapshot lists so registering/removing an integration during dispatch affects the next call.
    for _, entry in ipairs(registered(event)) do
        if invoke(entry.id, entry.callbacks[event]) then return result end
    end
    local legacy = {}
    for id, callback in pairs(hook.GetTable()[event] or {}) do
        if isstring(id) or IsValid(id) then
            legacy[#legacy + 1] = {id = id, callback = callback}
        else
            hook.Remove(event, id)
        end
    end
    table.sort(legacy, function(a, b) return tostring(a.id) < tostring(b.id) end)
    for _, entry in ipairs(legacy) do
        local object = not isstring(entry.id) and entry.id or nil
        if not object or IsValid(object) then
            if invoke('hook:' .. tostring(entry.id), entry.callback, object) then return result end
        end
    end
    local mode = gmod.GetGamemode()
    if mode and isfunction(mode[event]) then invoke('gamemode', mode[event], mode) end
    return result
end

function DHR.CanUseFeature(player, name, weapon)
    return DHR.RunHook('DHRCanUseFeature', player, name, weapon) ~= false
end

function DHR.GetBodyState(entity)
    local state = DHR.RunHook('DHRBodyState', entity)
    if state ~= nil then
        if istable(state) and isbool(state.alive) and (state.owner == nil or IsValid(state.owner)) then
            return state
        end
        if state ~= false then report('body', 'DHRBodyState', 'expected {alive = boolean, owner = entity or nil}') end
        return {alive = true} -- An unresolved custom body must not be treated as a corpse.
    end
    if not IsValid(entity) then return {alive = false} end
    if entity:IsPlayer() then return {owner = entity, alive = entity:Alive()} end
    return {alive = not entity.hr_execution_proxy and (entity:IsNPC() or entity:IsNextBot()) and entity:Health() > 0}
end
