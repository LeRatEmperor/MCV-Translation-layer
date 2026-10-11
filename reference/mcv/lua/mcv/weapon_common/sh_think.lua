function SWEP:Think()
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    // In singleplayer this hook also runs on the client, but the client is NOT predicting
    // there: anything it writes to a NetworkVar is overwritten by the next server update.
    // Advancing the sight/speed blends here would fight the server's state on each packet.
    // Everything the client needs in singleplayer is driven from the server's values via
    // GetViewModelPosition / CalcView, so the client has nothing to do in Think.
    if CLIENT and game.SinglePlayer() then return end

    self:SyncViewModel()
    self:Think_Speed()
    self:Think_HoldType()
    self:Think_Bayonet()

    // Keep the networked viewmodel state in step with what the client draws (see sh_vm.lua).
    self:DoBodygroups(nil, false)

    self:ProcessDeferred()

    if self:GetNextIdle() <= CurTime() then
        self:Idle()
    end

    self:ThinkWeapon()
end

local function wantsMove(owner)
    return owner:KeyDown(IN_FORWARD) or owner:KeyDown(IN_MOVERIGHT) or owner:KeyDown(IN_MOVELEFT) or owner:KeyDown(IN_BACK)
end

function SWEP:GetIsSprinting()
    local owner = self:GetOwner()

    return wantsMove(owner) and owner:KeyDown(IN_SPEED)
end

// Movement blend targets (drive the "player_movement" pose parameter and hold types).
SWEP.SpeedSprint = 273
SWEP.SpeedRun = 100
SWEP.SpeedWalk = 25
SWEP.SpeedSprintThreshold = 150
SWEP.SpeedAcceleration = 750 // units per second the blend moves at

// The game's walk / run layers blend on "player_movement" in the game's own speed units, and
// the run layer (the sprint carry, gun swung across the body) starts at a per-class speed:
// 148 on rifles, 106 on the M60, 99 on the PK, 80 on the LPO-50 (MovementPoseWalk, read off the
// model's runlayer blend by port_weapon.anim_timing) and is full at MovementPoseSprint. The
// hand port drove it with a flat 100 when walking, which every rifle is happy with but which
// put the PK and the flamethrowers a way into their sprint pose (the gun points left). Walking
// stays at 100 and is capped just under the model's run layer start; sprinting goes to the
// model's top; nothing in between blends into the run layer while merely walking.
SWEP.MovementPoseWalk = 148
SWEP.MovementPoseSprint = 245
SWEP.MovementPoseWalkMax = 0.95 // fraction of MovementPoseWalk the walk may reach
// Sighted: the models' walklayerironsight (walkIdle -> walk over 0..MovementPoseSighted, the
// game's aimed walk) fades in on the "ironsight" pose while walklayer / runlayer fade to their
// idle row (port_qc.py step_sighted_walk), so aiming while walking shows that layer at this
// fraction of its full swing on every gun.
SWEP.MovementPoseSighted = 130
SWEP.SightedSwayFraction = 0.2

function SWEP:GetMovementPose(speed, sa)
    local lo, hi = self.MovementPoseWalk, self.MovementPoseSprint
    local walk = math.min(self.SpeedRun, lo * self.MovementPoseWalkMax)
    local pose

    if speed <= self.SpeedRun then
        pose = speed / self.SpeedRun * walk
    else
        pose = Lerp((speed - self.SpeedRun) / math.max(self.SpeedSprint - self.SpeedRun, 1), walk, hi)
    end

    // on the sights the movement layers are the sighted walk layer's: a set fraction of its swing
    local sighted = math.min(speed / self.SpeedRun, 1) * self.MovementPoseSighted * self.SightedSwayFraction

    // Only models with grip-corrected nearwall locomotion can use the full movement range.
    // Check the active model too: dual wield swaps ViewModel on the same weapon instance.
    local safeMovement = self.SafeMovementAnimations or (MCV.SafeMovementModels and
        MCV.SafeMovementModels[string.lower(self.ViewModel or "")])
    if self:GetSafe() and !safeMovement then
        pose = math.Clamp(pose, 0, 86)
    end

    return Lerp(sa, pose, sighted)
end

function SWEP:GetTargetSpeed()
    local owner = self:GetOwner()
    local _, grounded = self:GetWeaponMovement()

    if !grounded then return 0 end
    if !wantsMove(owner) then return 0 end

    if owner:KeyDown(IN_SPEED) then
        return self.SpeedSprint
    elseif owner:KeyDown(IN_WALK) then
        return self.SpeedWalk
    end

    return self.SpeedRun
end

// The movement blend is the predicted state itself, integrated a tick at a time by
// Think_Speed and held in the NetworkVar; GetSpeed / SetSpeed come from there. It used to be a
// start time and a start value with the blend derived from CurTime(), which is the shape that
// turns a disagreement about *when* into a step in the value and then holds the two realms
// apart until the next transition. Integrating heals instead: an error costs one tick of
// travel. Ground state comes from the completed command's movement sample, so the client
// and server do not choose different targets around a jump or landing.

if CLIENT then
    // What is drawn chases the predicted value at a bounded rate and never snaps: at least as
    // fast as the blend itself, so it tracks exactly once the two agree, and fast enough to
    // close any gap within CatchUp seconds so a correction is absorbed over a few frames.
    SWEP.VisualSpeedCatchUp = 0.08

    function SWEP:GetSpeedVisual()
        if GetPredictionPlayer() == self:GetOwner() then
            return self.VisualSpeed or self:GetSpeed()
        end
        local frame = FrameNumber()

        if self.VisualSpeedFrame == frame then return self.VisualSpeed end

        local speed = self:GetSpeed()
        local cur = self.VisualSpeed

        if cur == nil then
            cur = speed
        else
            local rate = math.max(self.SpeedAcceleration, math.abs(speed - cur) / self.VisualSpeedCatchUp)
            cur = math.Approach(cur, speed, rate * FrameTime())
        end

        self.VisualSpeed = cur
        self.VisualSpeedFrame = frame

        return cur
    end
else
    SWEP.GetSpeedVisual = SWEP.GetSpeed
end

function SWEP:Think_Speed()
    local target = self:GetTargetSpeed()
    local cur = self:GetSpeed()

    if cur == target then return end

    self:SetSpeed(math.Approach(cur, target, engine.TickInterval() * self.SpeedAcceleration))
end

function SWEP:Think_HoldType()
    local holdtype = self.HoldType
    local akimbo = self.GetAkimbo and self:GetAkimbo()

    if self:GetSpeed() >= self.SpeedSprintThreshold then
        holdtype = self.SprintHoldType
    elseif akimbo then
        holdtype = "duel" // a pistol in each hand (the second is drawn on the left hand, cl_worldmodel.lua)
    elseif self.GetBipod and self:GetBipod() then
        holdtype = "rpg" // deployed on the bipod
    elseif self:GetSightAmount() >= 1 then
        holdtype = self.AimHoldType
    end

    if self:GetSafe() then
        holdtype = self.SprintHoldType
    end

    // SetHoldType is networked; only call it when something changed. Asking the weapon what it
    // is now rather than remembering it in a plain field keeps this right through a prediction
    // error: a field is never put back, so it would claim to have set a hold type the server
    // had since replaced.
    if self:GetHoldType() == holdtype then return end

    self:SetHoldType(holdtype)
end
