--[[---------------------------------------------------------------------------
    MCVPort — MCV.Define: the port declaration entry point.

    Mirrors DHR.Define (reference/dhrb/dhr/core.lua:70-119): deep-merge over
    defaults, eager structural validation with precise messages, marker flags.
    A port weapon file ends with:

        MCV.Define(SWEP, {
            anims   = { fire = { "shoot01", ACT_VM_PRIMARYATTACK }, ... },
            events  = { reload = { { t = 0.9, sound = "PORT_X.MagIn" } }, ... },
            hooks   = { OnShotFired = function(self) ... end, ... },
            required = { "idle", "draw", "fire" },
        })

    The two-homes rule (docs/translation-layer-spec.md): anything the MCV base
    consumes natively stays a flat SWEP field (DamageGeneric, FireRate,
    MagInTime, SoundSingleShot, ...). Only translational data (animation roles
    for models that don't speak MCV's activities) and custom mechanics live in
    the Define table. Provenance does NOT belong here — ports are severed from
    their source; a comment header in the port file carries the notes.
-----------------------------------------------------------------------------]]

if MCVP and MCVP.LoadedDefine then return end

MCVP = MCVP or {}
MCVP.Version = "0.1.0"
MCVP.LoadedDefine = true

--------------------------------------------------------------------------------
-- Activity -> role bindings.
--
-- MCV's base code addresses animations by engine activity at well-known call
-- sites (docs/animation-system.md section 5.1, the complete inventory). Each
-- binding names the *intent* of that call site; a port may rebind the intent to
-- a sequence name or a candidate list that the foreign model actually has.
--------------------------------------------------------------------------------

MCVP.ActRoles = {
    -- lifecycle
    [ACT_VM_DRAW]               = "draw",
    [ACT_VM_HOLSTER]            = "holster",
    [ACT_VM_IDLE]               = "idle",
    [ACT_VM_IDLE_LOWERED]       = "idle_safety",
    [ACT_VM_IDLE_TO_LOWERED]    = "safety_in",
    [ACT_VM_LOWERED_TO_IDLE]    = "safety_out",
    [ACT_VM_FIDGET]             = "fidget",

    -- firing
    [ACT_VM_PRIMARYATTACK]          = "fire",
    [ACT_VM_PRIMARYATTACK_EMPTY]    = "fire_empty",
    [ACT_VM_SHOOTLAST]              = "fire_last",
    [ACT_VM_SECONDARYATTACK]        = "fire_left",      -- akimbo left-hand shot
    [ACT_VM_PRIMARYATTACK_1]        = "fire_fan",       -- revolver fan fire
    [ACT_VM_RECOIL1]                = "fire_volley",    -- volley fire
    [ACT_VM_PRIMARYATTACK_DEPLOYED] = "fire_bipod",

    -- bolt / pump cycle (sh_think.lua:119, sh_think.lua:112-132)
    [ACT_VM_RELOAD_INSERT_PULL] = "cycle",
    [ACT_SHOTGUN_PUMP]          = "pump",

    -- reload
    [ACT_VM_RELOAD]               = "reload",
    [ACT_VM_RELOADEMPTY]          = "reload_empty",
    [ACT_VM_RELOAD_INSERT]        = "reload_insert",
    [ACT_VM_RELOAD_INSERT_EMPTY]  = "reload_insert_empty",
    [ACT_SHOTGUN_RELOAD_START]    = "reload_start",
    [ACT_SHOTGUN_RELOAD_FINISH]   = "reload_finish",
    [ACT_VM_RELOAD_DEPLOYED]      = "reload_bipod",

    -- melee-ish / bayonet
    [ACT_VM_HITCENTER]       = "bash",
    [ACT_VM_HITLEFT]         = "bayonet_swing",
    [ACT_VM_ATTACH_SILENCER] = "bayonet_on",
    [ACT_VM_DETACH_SILENCER] = "bayonet_off",

    -- bipod
    [ACT_VM_DEPLOYED_IN]  = "bipod_in",
    [ACT_VM_DEPLOYED_OUT] = "bipod_out",
    [ACT_VM_DEPLOY]       = "bipod_idle",

    -- firemode selector
    [ACT_VM_FIREMODE] = "firemode",

    -- underbarrel grenade launcher
    [ACT_VM_DRAW_M203]  = "ubgl_draw",
    [ACT_VM_IDLE_M203]  = "ubgl_idle",
    [ACT_VM_ISHOOT_M203] = "ubgl_fire",
    [ACT_VM_RELOAD_M203] = "ubgl_reload",
    [ACT_VM_IIN_M203]   = "ubgl_in",
    [ACT_VM_IOUT_M203]  = "ubgl_out",
}

-- Default role -> activity candidates (the inverse of ActRoles). A role that
-- the porter does not mention keeps the native MCV activity as its candidate,
-- so a model that already speaks MCV's activities needs no anims table at all.
MCVP.DefaultAnims = {}
for act, role in pairs(MCVP.ActRoles) do
    if MCVP.DefaultAnims[role] == nil then
        MCVP.DefaultAnims[role] = act
    end
end

-- Roles whose successful play counts as "a shot happened" for OnShotFired.
MCVP.FireRoles = {
    fire = true, fire_empty = true, fire_last = true, fire_left = true,
    fire_fan = true, fire_volley = true, fire_bipod = true,
}

-- Hook catalog with dispatch policies (the runner lives in sh_hooks.lua).
--   check    -> any false return vetoes the action
--   event    -> notification, return values ignored
--   provider -> first non-nil return wins, dispatch stops
MCVP.HookPolicies = {
    CanFire      = "check",
    CanReload    = "check",
    CanDeploy    = "check",
    OnInitialize = "event",
    OnDeploy     = "event",
    OnHolster    = "event",
    OnThink      = "event",
    OnShotFired  = "event",
    OnRolePlayed = "event",
    OnRoleEvent  = "event",
}

MCVP.DefaultConfig = {
    events   = {},
    hooks    = {},
    required = { "idle", "draw", "fire" },
    act_roles = {},
    attachments = {},          -- this model's attachment names (muzzle/eject)
    movement = false,          -- discrete walk/sprint bridge (sh_movement.lua)
    foley    = "qc",           -- "qc": trust the model's 5004 events (default)
                               -- "synthetic": block them; the events table owns audio
    base     = "mcvport_gun",
}

--------------------------------------------------------------------------------
-- Merge and validation
--------------------------------------------------------------------------------

local function isList(t)
    if not istable(t) then return false end
    local n = #t
    if n == 0 then return false end
    return next(t, n) == nil
end

-- Merge an override onto defaults. List-shaped tables (animation candidate
-- chains) union with the porter's candidates first and the defaults appended
-- as final fallbacks; map-shaped tables merge key by key; scalars override.
function MCVP.Merge(default, override)
    if isList(default) and isList(override) then
        local out = table.Copy(override)
        for _, dv in ipairs(default) do
            local dup = false
            for _, ov in ipairs(out) do
                if ov == dv then dup = true break end
            end
            if not dup then out[#out + 1] = dv end
        end
        return out
    end
    if istable(default) and istable(override) then
        local out = {}
        for k, v in pairs(override) do out[k] = MCVP.Merge(default[k], v) end
        for k, v in pairs(default) do
            if out[k] == nil then out[k] = istable(v) and table.Copy(v) or v end
        end
        return out
    end
    return override
end

local function fail(msg)
    error("MCVPort: " .. msg, 0)
end

local function checkCandidate(role, value, where)
    if isnumber(value) or isstring(value) then return end
    if istable(value) and #value > 0 then
        for i, v in ipairs(value) do
            if not (isnumber(v) or isstring(v)) then
                fail(where .. "." .. role .. "[" .. i .. "] must be an activity number or a sequence name")
            end
        end
        return
    end
    fail(where .. "." .. role .. " must be an activity number, a sequence name, or a non-empty list of both")
end

local function validateAnims(anims)
    for role, value in pairs(anims) do
        if not isstring(role) then
            fail("anims keys must be role names (strings)")
        end
        checkCandidate(role, value, "anims")
    end
end

local function validateEvents(events)
    for role, list in pairs(events) do
        if not isstring(role) then fail("events keys must be role names (strings)") end
        if not istable(list) then fail("events." .. role .. " must be a list of event tables") end
        for i, ev in ipairs(list) do
            if not istable(ev) then fail("events." .. role .. "[" .. i .. "] must be a table") end
            if not isnumber(ev.t) or ev.t < 0 then
                fail("events." .. role .. "[" .. i .. "].t must be a nonnegative number of seconds after the animation starts")
            end
            if ev.sound ~= nil and not isstring(ev.sound) then
                fail("events." .. role .. "[" .. i .. "].sound must be a soundscript or sound file name")
            end
            if ev.realm ~= nil and ev.realm ~= "server" and ev.realm ~= "client" and ev.realm ~= "shared" then
                fail("events." .. role .. "[" .. i .. "].realm must be \"server\", \"client\" or \"shared\"")
            end
        end
    end
end

local function validateHooks(hooks)
    for name, fn in pairs(hooks) do
        if MCVP.HookPolicies[name] == nil then
            fail("hooks." .. tostring(name) .. " is not a known hook (see MCVP.HookPolicies)")
        end
        if not isfunction(fn) then
            fail("hooks." .. tostring(name) .. " must be a function(self, ...)")
        end
    end
end

--------------------------------------------------------------------------------
-- MCV.Define
--------------------------------------------------------------------------------

function MCVP.Define(weapon, config)
    if not istable(weapon) then fail("MCV.Define expects a SWEP table") end
    if not istable(config) then fail("MCV.Define expects a configuration table") end

    for _, key in ipairs({ "anims", "events", "hooks", "act_roles", "required", "attachments" }) do
        if config[key] ~= nil and not istable(config[key]) then
            fail(key .. " must be a table")
        end
    end

    if config.movement ~= nil and not isboolean(config.movement) then
        fail("movement must be a boolean (see sh_movement.lua)")
    end

    if config.foley ~= nil and config.foley ~= "qc" and config.foley ~= "synthetic" then
        fail('foley must be "qc" or "synthetic" (see sh_fxbridge.lua)')
    end

    if config.attachments ~= nil then
        for key, value in pairs(config.attachments) do
            if not isstring(key) or not isstring(value) then
                fail("attachments entries must be name -> attachment-name strings (e.g. muzzle = \"1\")")
            end
        end
    end

    local data = {}

    for key, value in pairs(config) do
        local def = MCVP.DefaultConfig[key]
        if istable(def) and istable(value) then
            data[key] = MCVP.Merge(def, value)
        elseif istable(value) then
            data[key] = table.Copy(value)
        else
            data[key] = value
        end
    end
    for key, def in pairs(MCVP.DefaultConfig) do
        if data[key] == nil then
            data[key] = istable(def) and table.Copy(def) or def
        end
    end

    -- anims merge over the full default role table, so a port that only
    -- rebinding "fire" still inherits defaults for every other role.
    data.anims = MCVP.Merge(MCVP.DefaultAnims, config.anims or {})

    -- required is a REPLACEMENT list (a port may drop a default requirement);
    -- the list-union merge used for candidate chains must not apply here.
    if config.required ~= nil then
        data.required = table.Copy(config.required)
    end

    validateAnims(data.anims)
    validateEvents(data.events)
    validateHooks(data.hooks)

    for act, role in pairs(data.act_roles) do
        if not isnumber(act) then fail("act_roles keys must be activity numbers") end
        if not isstring(role) then fail("act_roles values must be role names") end
    end

    for i, role in ipairs(data.required) do
        if not isstring(role) then fail("required[" .. i .. "] must be a role name") end
        if data.anims[role] == nil then
            fail("required role \"" .. role .. "\" has no candidate in anims")
        end
    end

    weapon.Base = weapon.Base or data.base
    if not string.find(weapon.Base, "^mcvport_") then
        ErrorNoHalt("MCVPort: " .. tostring(weapon.PrintName or "weapon")
            .. " uses base \"" .. weapon.Base .. "\" — the translation bridges only exist on mcvport_* bases.\n")
    end

    weapon.MCVP = data
    weapon.MCVPort = true
    return weapon
end

MCVP.Define = MCVP.Define
MCV = MCV or {}
MCV.Define = MCVP.Define
