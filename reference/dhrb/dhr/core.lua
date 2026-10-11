if SERVER then AddCSLuaFile() end
if DHR and DHR.API then return DHR end

DHR = DHR or {}
DHR.Version = "0.1.0"
DHR.API = 1
DHR.ExecutionProfiles = {}
include("dhr/integrations.lua")

function DHR.LoadData(path, fallback)
    if not file.Exists(path, "LUA") then return fallback end
    if SERVER then AddCSLuaFile(path) end
    return include(path)
end

local defaults = {
    kind = "gun",
    damage = 10,
    rate = 4,
    spread = 0.02,
    kick = 1,
    force = 10,
    crosshair = "colt",
    flash = 1,
    tracer = 1,
    durability = -1,
    len = {},
    upgrades = {},
    features = {},
    world_events = {},
    wheel_icon_size = {256, 128},
}

local function finite(value)
    return isnumber(value) and value == value and math.abs(value) < math.huge
end

local function positive(value, name, allowZero)
    local valid = finite(value) and (allowZero and value >= 0 or value > 0)
    local requirement = allowZero and "nonnegative" or "positive"
    assert(valid, "DHR: " .. name .. " must be a finite " .. requirement .. " number")
end

local function validateAttacks(attacks)
    for _, attack in ipairs(attacks) do
        assert(isstring(attack.seq) or isnumber(attack.seq), "DHR: an attack needs a sequence name or activity")
        positive(attack.hit, "attack.hit", true)
        positive(attack.recover, "attack.recover")
        assert(attack.recover >= attack.hit, "DHR: attack recovery cannot precede its hit")
    end
end

local function validateUpgrades(upgrades)
    local ids = {}
    for _, upgrade in ipairs(upgrades) do
        local validID = isstring(upgrade.id) and upgrade.id:match("^[%w_%-]+$")
        assert(validID and not ids[upgrade.id], "DHR: upgrades need unique alphanumeric IDs")
        assert(isstring(upgrade.name) and upgrade.name ~= "", "DHR: an upgrade needs a name")
        ids[upgrade.id] = true
        upgrade.desc = upgrade.desc or ""
        upgrade.icon = upgrade.icon or "icon16/wrench.png"
        upgrade.icon_size = upgrade.icon_size or {16, 16}
        if upgrade.clip then positive(upgrade.clip, "upgrade.clip") end
        for _, key in ipairs({"damage", "rate", "spread", "recoil", "sensitivity"}) do
            if upgrade[key] then positive(upgrade[key], "upgrade." .. key) end
        end
    end
end

function DHR.Define(weapon, config)
    assert(istable(weapon) and istable(config), "DHR.Define expects a SWEP and a configuration table")
    local data = table.Copy(defaults)
    for key, value in pairs(config) do
        data[key] = istable(value) and table.Copy(value) or value
    end
    assert(data.kind == "gun" or data.kind == "melee", "DHR: kind must be gun or melee")
    positive(data.damage, "damage", true)
    positive(data.rate, "rate")
    positive(data.spread, "spread", true)
    positive(data.kick, "kick", true)

    if data.bash ~= nil and data.bash ~= false then
        assert(istable(data.bash), "DHR: bash must be a table or false")
        if data.bash.damage then positive(data.bash.damage, "bash.damage", true) end
        if data.bash.range then positive(data.bash.range, "bash.range") end
    end

    if data.kind == "gun" then
        data.seq = data.seq or {
            idle = ACT_VM_IDLE,
            draw = ACT_VM_DRAW,
            fire = {ACT_VM_PRIMARYATTACK},
            reload = ACT_VM_RELOAD,
        }
        data.fire_snd = data.fire_snd or "Weapon_Pistol.Single"
        assert(istable(weapon.Primary), "DHR: gun SWEPs need a Primary table")
        data.clip = weapon.Primary.ClipSize
        positive(data.clip, "Primary.ClipSize")
    else
        data.seq = data.seq or {idle = ACT_VM_IDLE, draw = ACT_VM_DRAW}
        assert(istable(data.light) and #data.light > 0, "DHR: melee weapons need at least one light attack")
        validateAttacks(data.light)
        validateAttacks(data.heavy or {})
    end

    if data.pump_delay then positive(data.pump_delay, "pump_delay", true) end
    for _, curve in ipairs(data.recoil_curves or {}) do
        positive(curve.length, "recoil curve length")
        assert(istable(curve.values) and #curve.values >= 2, "DHR: recoil curves need at least two pitch/yaw samples")
        for _, sample in ipairs(curve.values) do
            assert(finite(sample[1]) and finite(sample[2]), "DHR: recoil samples must be finite numbers")
        end
    end
    validateUpgrades(data.upgrades)
    weapon.Base = weapon.Base or "dhr_base"
    weapon.HR = data
    weapon.DHRWeapon = true
    return weapon
end

function DHR.HasFeature(weapon, name)
    if name == "thirdperson" and weapon:GetNW2Bool("dhr_one_hand") then return false end
    return weapon.HR and (weapon.HR.features or {})[name] ~= false
        and DHR.CanUseFeature(weapon:GetOwner(), name, weapon)
end

function DHR.RegisterExecutions(class, profiles)
    assert(isstring(class) and class:match("^[%w_]+$"), "DHR: invalid execution weapon class")
    assert(istable(profiles) and #profiles > 0, "DHR: execution profiles need at least one entry")
    profiles = table.Copy(profiles)
    for _, profile in ipairs(profiles) do
        assert(profile.approach == "front" or profile.approach == "rear", "DHR: execution approach must be front or rear")
        for _, key in ipairs({"view_model", "driver_model", "sequence"}) do
            assert(isstring(profile[key]) and profile[key] ~= "", "DHR: execution needs " .. key)
        end
        positive(profile.length, "execution.length")
        positive(profile.damage_time, "execution.damage_time", true)
        positive(profile.distance, "execution.distance")
        positive(profile.eye_height, "execution.eye_height")
        assert(profile.damage_time <= profile.length, "DHR: execution damage must occur during the animation")
        assert(istable(profile.camera) and #profile.camera > 0, "DHR: execution needs camera samples")
        for _, sample in ipairs(profile.camera) do
            for i = 1, 6 do
                assert(finite(sample[i]), "DHR: execution camera samples need six finite numbers")
            end
        end
        assert(istable(profile.exit_offset) and #profile.exit_offset == 3, "DHR: execution needs a three-number exit_offset")
        for _, value in ipairs(profile.exit_offset) do
            assert(finite(value), "DHR: invalid execution exit_offset")
        end
        profile.target_yaw = profile.target_yaw or 0
        profile.sounds = profile.sounds or {}
        profile.blood_effects = profile.blood_effects or {}
    end
    DHR.ExecutionProfiles[class] = profiles
end

function DHR.RegisterUpgradePickup(class, weaponClass, upgradeID, options)
    assert(isstring(class) and class:match("^[%w_]+$"), "DHR: invalid pickup class")
    assert(isstring(weaponClass) and isstring(upgradeID), "DHR: pickup needs a weapon class and upgrade ID")
    options = options or {}
    scripted_ents.Register({
        Type = "anim",
        Base = "hr_upgrade_pickup",
        Spawnable = true,
        PrintName = options.name or "Weapon Upgrade",
        Category = options.category or "Dandy's Hellraiser Base",
        Model = options.model or "models/items/boxsrounds.mdl",
        WeaponClass = weaponClass,
        UpgradeID = upgradeID,
    }, class)
end

function DHR.ResolveAnimations(weapon, viewmodel, state)
    local owner = weapon:GetOwner()
    local vm = viewmodel or (IsValid(owner) and owner:IsPlayer() and owner:GetViewModel())
    if not IsValid(vm) then return end
    state = state or weapon
    if state.dhr_animation_model == vm:GetModel() then return true end

    local data = weapon.HR
    local missing = {}
    local function resolve(value)
        if istable(value) then
            local names = {}
            for _, entry in ipairs(value) do
                local name = resolve(entry)
                if name then names[#names + 1] = name end
            end
            return #names > 0 and names or nil
        end
        local id = -1
        if isnumber(value) then id = vm:SelectWeightedSequence(value)
        elseif isstring(value) then id = vm:LookupSequence(value) end
        if id < 0 then
            missing[#missing + 1] = tostring(value)
            return
        end
        local name = vm:GetSequenceName(id)
        if data.len[name] == nil then data.len[name] = vm:SequenceDuration(id) end
        return name
    end

    -- Keep the author's activities intact when a later deploy changes models.
    local source = state.dhr_animation_source
    if not source then
        source = {
            seq = table.Copy(data.seq),
            light = table.Copy(data.light or {}),
            heavy = table.Copy(data.heavy or {}),
        }
        state.dhr_animation_source = source
    end
    data.seq = {}
    for role, value in pairs(source.seq) do data.seq[role] = resolve(value) end
    for _, kind in ipairs({"light", "heavy"}) do
        if data[kind] then
            data[kind] = table.Copy(source[kind])
            for _, attack in ipairs(data[kind]) do attack.seq = resolve(attack.seq) end
        end
    end

    local required = {"idle", "draw"}
    if data.kind == "gun" then
        required[#required + 1] = "fire"
        if source.seq.reload_start then
            table.Add(required, {"reload_start", "reload_loop", "reload_end"})
        else
            required[#required + 1] = "reload"
        end
    end
    for _, role in ipairs(required) do
        if not data.seq[role] then missing[#missing + 1] = role end
    end
    if #missing > 0 then
        ErrorNoHalt("DHR: " .. weapon:GetClass() .. " cannot use " .. vm:GetModel()
            .. "; missing animations: " .. table.concat(missing, ", ") .. "\n")
        return false
    end
    state.dhr_animation_model = vm:GetModel()
    if data.aim then
        data.seq.ads_idle = data.seq.ads_idle or data.seq.idle
        data.seq.ads_fire = data.seq.ads_fire or data.seq.fire
    end
    return true
end

function DHR.GetUpgrade(weapon, stat)
    return HRUpgrades.Get(weapon, stat)
end

function DHR.GrantUpgrade(player, class, id, install)
    if not SERVER then return false end
    if not HRUpgrades.Grant(player, class, id) then return false end
    if install then HRUpgrades.Install(player, class, id) end
    return true
end

return DHR
