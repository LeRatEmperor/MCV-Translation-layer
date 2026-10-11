local function applySequence(self, vm, seq, mult, lock, noidle)
    local reverse = false

    if mult < 0 then
        reverse = true
        mult = -mult
    end

    local time = vm:SequenceDuration(seq) * mult
    // Lua refresh cannot add datatable accessors to weapons that already exist.
    if self.SetAnimationStart then
        self:SetAnimationStart(CurTime())
        self:SetAnimationDuration(reverse and -time or time)
    end

    if self.ScheduleHammerRelease then
        self:ScheduleHammerRelease(vm, seq, time, reverse)
    end

    // Reconstruct animation state on every prediction pass. The render path
    // recovers the final command's timeline after packet/sequence processing.
    vm:SendViewModelMatchingSequence(seq)
    vm:SetPlaybackRate((reverse and -1 or 1) / mult)
    vm:SetCycle(reverse and 1 or 0)

    if lock then
        self:SetAnimLockTime(CurTime() + time)
    else
        self:SetAnimLockTime(0)
    end

    if !noidle then
        self:SetNextIdle(CurTime() + time)
    else
        self:SetNextIdle(math.huge)
    end

    return time
end

// CurTime outside prediction is the interpolated world clock. The local viewmodel
// runs at the final predicted tick plus the fractional render tick instead.
function SWEP:GetViewModelTime()
    if CLIENT and !game.SinglePlayer() and self:GetOwner() == LocalPlayer() and GetPredictionPlayer() != self:GetOwner() then
        local tick = engine.TickInterval()
        return self:GetOwner():GetInternalVariable("m_nTickBase") * tick + CurTime() % tick
    end
    return CurTime()
end

function SWEP:UpdateViewModelAnimation(vm)
    if !CLIENT or game.SinglePlayer() or self:GetOwner() != LocalPlayer() or !IsValid(vm) or !self.GetAnimationDuration then return end
    if GetPredictionPlayer() == self:GetOwner() then return end
    local duration = self:GetAnimationDuration()
    if duration == 0 then return end
    local start = self:GetAnimationStart()
    local progress = math.max(self:GetViewModelTime() - start, 0) / math.abs(duration)
    local sequence = vm:GetSequence()
    local previous = self.VisualAnimation
    if previous and previous.vm == vm and previous.sequence == sequence and previous.start == start and previous.duration == duration then
        // Clock correction can move tick base back without changing the animation.
        // Hold the visual until it catches up; never replay frames already shown.
        progress = math.max(progress, previous.progress)
        previous.progress = progress
    else
        self.VisualAnimation = {vm=vm, sequence=sequence, start=start, duration=duration, progress=progress}
    end
    if MCV.SequenceLoops(vm, sequence) and self:GetNextIdle() != math.huge then
        progress = progress % 1
    else
        progress = math.min(progress, 0.999)
    end
    // The engine's sequence receive proxy can replace its timestamp after the shot,
    // skipping its first frames. Looping no-idle stages must also hold their end
    // frame until the next command starts an insert, rather than wrap early.
    // Recover from our restored timeline before building the render bones.
    vm:SetSaveValue("m_flAnimTime", start)
    vm:SetCycle(duration < 0 and 1 - progress or progress)
end

// Play the sequence registered for an activity. mult scales the duration (negative plays
// backwards), lock blocks input for the duration, noidle keeps the last frame instead of
// returning to the idle.
function SWEP:PlayAnimation(act, mult, lock, noidle)
    mult = mult or 1
    lock = lock or false
    noidle = noidle or false

    local vm = self:GetOwner():GetViewModel()

    if !IsValid(vm) then return end

    local seq = vm:SelectWeightedSequence(act)

    if seq == -1 then print("INVALID ACT " .. act) return end

    return applySequence(self, vm, seq, mult, lock, noidle)
end

// Same, by sequence name. The game's equipment models use activities GMod does not define
// (ACT_VM_SLASH, ACT_VM_PLANT, ACT_VM_GIVE...), but their sequence names are consistent
// per weapon type, so the equipment bases address them directly.
function SWEP:PlaySequence(name, mult, lock, noidle)
    mult = mult or 1
    lock = lock or false
    noidle = noidle or false

    local vm = self:GetOwner():GetViewModel()

    if !IsValid(vm) then return end

    local seq = MCV.CachedSequence(vm, name)

    if seq == -1 then print("INVALID SEQUENCE " .. name) return end

    return applySequence(self, vm, seq, mult, lock, noidle)
end

function SWEP:Idle()
    local seq = self:IdleSequence()

    if seq and self:HasSequence(seq) then
        self:PlaySequence(seq, 1, false, false)
    else
        self:PlayAnimation(self:IdleActivity(), 1, false, false)
    end

    self:SetReady(true)
end

function SWEP:HasAnimation(act)
    if !act then return false end // an activity GMod does not define is simply not there
    local vm = self:GetOwner():GetViewModel()
    return IsValid(vm) and vm:SelectWeightedSequence(act) != -1
end

function SWEP:HasSequence(name)
    local vm = self:GetOwner():GetViewModel()
    return IsValid(vm) and MCV.CachedSequence(vm, name) != -1
end

// Duration of a named sequence at playback rate 1 (0 if missing)
function SWEP:SequenceLength(name)
    local vm = self:GetOwner():GetViewModel()
    if !IsValid(vm) then return 0 end

    local seq = MCV.CachedSequence(vm, name)
    if seq == -1 then return 0 end

    return vm:SequenceDuration(seq)
end
