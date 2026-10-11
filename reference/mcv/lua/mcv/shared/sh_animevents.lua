MCV = MCV or {}

// Third person gestures with the first person's timing (TacRP's scheme): the weapon fires the
// player animation events with the animation time in milliseconds as the data, and this hook
// restarts the gesture of the hold type in use and stretches it to that time. The per-round
// loops (shotguns, stripper clips, single-action revolvers) start the gesture part-way in, at
// the point where the shell goes in, so every insert shows the hands loading.

// cycle pointers per gesture: for PLAYERANIMEVENT_RELOAD the point the start reaches, for the
// loop and end events the point they start from
MCV.ReloadAnimOffsets = {
    [PLAYERANIMEVENT_RELOAD] = {
        [ACT_HL2MP_GESTURE_RELOAD_REVOLVER] = 0.6,
        [ACT_HL2MP_GESTURE_RELOAD_SHOTGUN] = 0.25,
    },
    [PLAYERANIMEVENT_RELOAD_LOOP] = {
        [ACT_HL2MP_GESTURE_RELOAD_REVOLVER] = 0.6,
        [ACT_HL2MP_GESTURE_RELOAD_SHOTGUN] = 0.31,
    },
    [PLAYERANIMEVENT_RELOAD_END] = {
        [ACT_HL2MP_GESTURE_RELOAD_REVOLVER] = 0.7,
        [ACT_HL2MP_GESTURE_RELOAD_SHOTGUN] = 0.5,
    },
}

local TIMED = {[PLAYERANIMEVENT_RELOAD] = true, [PLAYERANIMEVENT_RELOAD_LOOP] = true, [PLAYERANIMEVENT_RELOAD_END] = true}

hook.Add("DoAnimationEvent", "MCV_AnimEvents", function(ply, event, data)
    if !TIMED[event] then return end
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam then return end
    // the time comes with the event (milliseconds); when it does not arrive, the weapon's
    // networked animation lock is the same clock (the reload animation just started)
    local t = (data or 0) * 0.001
    if t <= 0 and wep.GetAnimLockTime then t = wep:GetAnimLockTime() - CurTime() end
    if t <= 0.05 then return end
    local slot = GESTURE_SLOT_ATTACK_AND_RELOAD

    if event == PLAYERANIMEVENT_RELOAD then
        local gest = wep:GetReloadGesture()
        ply:AnimRestartGesture(slot, gest, true)
        if wep.ShotgunReload then
            local offset = MCV.ReloadAnimOffsets[event][gest] or 0.5
            ply:SetLayerDuration(slot, t / offset)
        else
            ply:SetLayerDuration(slot, t)
        end
        return ACT_INVALID
    elseif event == PLAYERANIMEVENT_RELOAD_LOOP then
        local gest = wep:GetReloadGesture()
        local offset = MCV.ReloadAnimOffsets[event][gest] or 0.5
        ply:AnimRestartGesture(slot, gest, true)
        ply:SetLayerDuration(slot, t / offset)
        ply:SetLayerCycle(slot, offset)
        return ACT_INVALID
    elseif event == PLAYERANIMEVENT_RELOAD_END then
        local gest = wep:GetReloadGesture()
        local offset = MCV.ReloadAnimOffsets[event][gest] or 0.6
        ply:AnimRestartGesture(slot, gest, true)
        ply:SetLayerDuration(slot, t / (1 - offset))
        ply:SetLayerCycle(slot, offset)
        return ACT_INVALID
    end
end)
