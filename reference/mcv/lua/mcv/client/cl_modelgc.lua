// Keep strong references: Lua GC does not remove engine clientside entities.
// Independent of SWEP:OnRemove, which can be missed during transmission/owner changes.
if MCV.CleanupClientModels then MCV.CleanupClientModels() end
local models = {}

local function release(model, entry)
    models[model] = nil
    local weapon, slot = entry.weapon, entry.slot
    if IsValid(weapon) and weapon[slot] == model then
        weapon[slot] = nil
        if slot == "WMLeft" then weapon.WMLeftBind = nil end
    end
    if IsValid(model) then model:Remove() end
end

function MCV.RemoveClientModel(weapon, slot)
    local model = weapon[slot]
    if model then release(model, models[model] or {weapon = weapon, slot = slot}) end
    weapon[slot] = nil
end

function MCV.TrackClientModel(weapon, slot, model)
    MCV.RemoveClientModel(weapon, slot)
    if !IsValid(model) then return end
    models[model] = {weapon = weapon, slot = slot, owner = weapon:GetOwner()}
    model.MCVClientModel = true
    weapon[slot] = model
    return model
end

function MCV.CleanupClientModels()
    for model, entry in pairs(models) do release(model, entry) end
end

local function releaseEntity(ent)
    if ent.MCVClientModel then return end // Removed copies are retired by release/the sweep.
    for model, entry in pairs(models) do
        if entry.weapon == ent or entry.owner == ent then release(model, entry) end
    end
end

// Only visit our registered models, once a second, not every entity every frame.
timer.Create("MCV_ClientModels", 1, 0, function()
    for model, entry in pairs(models) do
        local weapon, owner = entry.weapon, entry.owner
        if !IsValid(model) or !IsValid(weapon) or weapon[entry.slot] != model
                or !IsValid(owner) or weapon:GetOwner() != owner
                or weapon:IsDormant() or owner:IsDormant()
                or (owner.GetActiveWeapon and owner:GetActiveWeapon() != weapon) then
            release(model, entry)
        end
    end
end)

hook.Add("EntityRemoved", "MCV_ClientModels", releaseEntity)
hook.Add("NotifyShouldTransmit", "MCV_ClientModels", function(ent, transmitting)
    if !transmitting then releaseEntity(ent) end
end)
hook.Add("PostCleanupMap", "MCV_ClientModels", MCV.CleanupClientModels)
hook.Add("ShutDown", "MCV_ClientModels", MCV.CleanupClientModels)
