// Audio follows the final predicted/received state, never each command replay.
// Keep handles independently of weapon Think so holsters, death and PVS loss stop them.
local hooks = hook.GetTable()
local previous = hooks.ShutDown and hooks.ShutDown.MCV_ChainsawSounds
if previous then previous() end // also release the old handles on Lua reload
local tracked = {}

function MCV.TrackChainsaw(wep)
    tracked[wep] = tracked[wep] or {}
end

local function stop(wep)
    local state = tracked[wep]
    if !state then return end
    if state.sound then state.sound:Stop() end
    if state.transition then state.transition:Stop() end
    state.sound, state.owner, state.cutting = nil, nil, nil
    state.transition, state.transitionOwner = nil, nil
end
MCV.StopChainsawSound = stop

function MCV.UntrackChainsaw(wep)
    stop(wep)
    tracked[wep] = nil
end

local function stopAll()
    for wep in pairs(tracked) do stop(wep) end
end
hook.Add("ShutDown", "MCV_ChainsawSounds", stopAll)
hook.Add("PostCleanupMap", "MCV_ChainsawSounds", stopAll)
hook.Add("EntityRemoved", "MCV_ChainsawSounds", function(ent)
    MCV.UntrackChainsaw(ent)
end)

local function transition(state, owner, path, wep)
    if state.transition then state.transition:Stop() end
    state.transition, state.transitionOwner = nil, nil
    if !path then return end
    local sound = CreateSound(wep, path)
    if !sound then return end
    sound:SetSoundLevel(75)
    sound:PlayEx(0.7, 100)
    state.transition, state.transitionOwner = sound, owner
end

hook.Add("Think", "MCV_ChainsawSounds", function()
    // Stop old owners first: CreateSound permits one patch per file per entity.
    for wep, state in pairs(tracked) do
        if !IsValid(wep) then
            MCV.UntrackChainsaw(wep)
        else
            local owner = wep:GetOwner()
            local audible = IsValid(owner) and owner:IsPlayer() and owner:Alive()
                and !owner:IsDormant() and !wep:IsDormant()
            local active = audible and owner:GetActiveWeapon() == wep
                and wep:GetReady() and wep:GetHolsterTime() == 0
            if state.owner and (!active or state.owner != owner) then
                local windDown = audible and state.owner == owner
                    and (wep:GetHolsterTime() != 0 or owner:GetActiveWeapon() != wep)
                stop(wep)
                if windDown then transition(state, owner, wep.SoundSawStop, wep) end
            elseif state.transition and (!audible or state.transitionOwner != owner) then
                stop(wep)
            end
            state.active = active and owner or nil
        end
    end
    for wep, state in pairs(tracked) do
        if state.active then
            local cutting = wep:GetPrimedAttack()
            local volume = cutting and 0.7 or 0.35
            local changed = state.cutting != cutting
            local starting = !state.owner
            if state.sound and changed then
                state.sound:Stop()
                state.sound = nil
            end
            if starting then
                transition(state, state.active, !cutting and wep.SoundSawStart or nil, wep)
            elseif changed then
                // A rev interrupts the startup recording; it must not play under cutting.
                transition(state, state.active, nil)
            end
            if !state.sound then
                state.sound = CreateSound(state.active, cutting and wep.SoundSawCut or wep.SoundSawIdle)
                if state.sound then
                    state.sound:SetSoundLevel(75)
                    state.sound:PlayEx(volume, 100)
                    state.owner, state.cutting = state.active, cutting
                end
            end
        end
    end
end)

// Existing instances survive a Lua refresh; normal spawns register in Initialize.
for _, wep in ipairs(ents.FindByClass("mcv_chainsaw")) do MCV.TrackChainsaw(wep) end
