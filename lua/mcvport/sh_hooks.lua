--[[---------------------------------------------------------------------------
    MCVPort — the hook runner.

    Port of DHRB's integration system (reference/dhrb/integrations.lua) with the
    same three dispatch policies:

        check    -> any false return vetoes the action (CanFire, CanReload...)
        event    -> notification, return values ignored (OnShotFired, ...)
        provider -> first non-nil return wins (reserved for future use)

    Sources consulted per dispatch, in order:
        1. the weapon's own Define hooks  (hooks = { OnShotFired = fn, ... })
        2. registered integrations        (MCVP.RegisterIntegration)
        3. legacy global hooks, prefixed  (hook.Add("MCVP_OnShotFired", id, fn))

    Every callback is xpcall-wrapped and duplicate error messages are reported
    only once, exactly like DHRB's report() (integrations.lua:17-22) — a broken
    companion addon must not spam the console or take the weapon down.
-----------------------------------------------------------------------------]]

if MCVP and MCVP.LoadedHooks then return end
MCVP.LoadedHooks = true

local integrations = {}
local handlers = {}
local seen_errors = {}

local function report(id, name, message)
    local key = id .. ":" .. name
    if seen_errors[key] == message then return end
    seen_errors[key] = message
    ErrorNoHalt("MCVPort integration " .. id .. " (" .. name .. "): " .. message .. "\n")
end

function MCVP.RegisterIntegration(id, callbacks, priority)
    if not (isstring(id) and id:match("^[%w_.%-]+$")) then
        error("MCVPort: integration needs a unique namespaced ID", 0)
    end
    if not istable(callbacks) then
        error("MCVPort: integration callbacks must be a table", 0)
    end
    priority = priority or 0
    if not (isnumber(priority) and priority == priority and math.abs(priority) < math.huge) then
        error("MCVPort: integration priority must be a finite number", 0)
    end

    local entry = { id = id, priority = priority, callbacks = {} }
    for event, callback in pairs(callbacks) do
        if MCVP.HookPolicies[event] == nil or not isfunction(callback) then
            error("MCVPort: unsupported integration callback " .. tostring(event), 0)
        end
        entry.callbacks[event] = callback
    end
    integrations[id] = entry
    handlers = {} -- rebuild sorted dispatch lists lazily
end

function MCVP.RemoveIntegration(id)
    integrations[id] = nil
    handlers = {}
end

local function ordered(name)
    if handlers[name] then return handlers[name] end
    local list = {}
    for _, entry in pairs(integrations) do
        if entry.callbacks[name] then list[#list + 1] = entry end
    end
    table.sort(list, function(a, b)
        if a.priority ~= b.priority then return a.priority > b.priority end
        return a.id < b.id
    end)
    handlers[name] = list
    return list
end

-- Invoke one callback under the policy. Returns stop (provider
-- short-circuit) plus the callback's return value.
local function invoke(report_id, name, fn, self, args, nargs)
    local ok, a = xpcall(fn, debug.traceback, self, unpack(args, 1, nargs))

    if not ok then
        report(report_id, name, tostring(a))
        return false, nil
    end

    if MCVP.HookPolicies[name] == "provider" and a ~= nil then
        return true, a
    end
    return false, a
end

-- MCVP.RunHook(self, name, ...) -> false on check-veto, value on provider,
-- otherwise nil. Safe to call on weapons without a Define table.
function MCVP.RunHook(self, name, ...)
    local policy = MCVP.HookPolicies[name]
    if policy == nil then return end

    local args = { ... }
    local nargs = select("#", ...)
    local result

    -- 1. the weapon's own Define hooks
    local cfg = self.MCVP
    if cfg and cfg.hooks and cfg.hooks[name] then
        local stop, value = invoke("<weapon>", name, cfg.hooks[name], self, args, nargs)
        if stop then return value end
        if value == false then result = false end
    end

    -- 2. registered integrations, priority order
    for _, entry in ipairs(ordered(name)) do
        local stop, value = invoke(entry.id, name, entry.callbacks[name], self, args, nargs)
        if stop then return value end
        if value == false then result = false end
    end

    -- 3. legacy global hooks under a prefixed name
    local legacy = hook.GetTable()["MCVP_" .. name]
    if legacy then
        local entries = {}
        for id, fn in pairs(legacy) do
            if isfunction(fn) then entries[#entries + 1] = { id = id, fn = fn } end
        end
        table.sort(entries, function(a, b) return tostring(a.id) < tostring(b.id) end)
        for _, e in ipairs(entries) do
            local stop, value = invoke("hook:" .. tostring(e.id), name, e.fn, self, args, nargs)
            if stop then return value end
            if value == false then result = false end
        end
    end

    return result
end
