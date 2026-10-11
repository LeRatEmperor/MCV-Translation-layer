// How long a full hip <-> sight transition takes, in seconds.
function SWEP:GetSightTime()
    return 0.2 / self.IronsightSpeedScale
end

// Easing applied to the sight transition. Any function mapping [0, 1] -> [0, 1] with
// f(0) = 0 and f(1) = 1 works; names from GMod's math.ease library are accepted too.
SWEP.SightEase = "InOutSine"

local function smoothstep(p)
    return p * p * (3 - 2 * p)
end

function SWEP:GetSightEase()
    local ease = self.SightEase

    if isfunction(ease) then return ease end
    if isstring(ease) and math.ease and math.ease[ease] then return math.ease[ease] end

    return smoothstep
end

// Linear sight progress: 0 = hip, 1 = fully aimed. A networked float, integrated one tick at
// a time by Think_Sights on both realms; GetSightAmountRaw / SetSightAmountRaw come from the
// NetworkVar itself (mcv/weapon_common/shared.lua, which says why it is stored this way).

local function applyEase(self, raw)
    if raw <= 0 then return 0 end
    if raw >= 1 then return 1 end

    return self:GetSightEase()(raw)
end

// Eased sight blend for GAMEPLAY (spread, recoil, hold type). Deterministic on both
// realms so predicted results match the server. Still exactly 0 at hip and 1 when aimed.
function SWEP:GetSightAmount()
    return applyEase(self, self:GetSightAmountRaw())
end

if CLIENT then
    // Visual copy of the sight progress, advanced once per rendered frame.
    //
    // Shots read the predicted NetworkVar. Rendering follows its resulting value at a
    // bounded rate, absorbing corrections over subsequent frames. This ordinary Lua cache
    // is not rolled back: only calls outside command prediction may advance it.
    SWEP.VisualSightCatchUp = 0.08

    function SWEP:GetSightAmountRawVisual()
        // GetViewModelPosition also runs while simulating commands. Never let an
        // earlier command consume this rendered frame's visual update.
        if GetPredictionPlayer() == self:GetOwner() then
            return self.VisualSightRaw or self:GetSightAmountRaw()
        end
        local frame = FrameNumber()

        if self.VisualSightFrame == frame then return self.VisualSightRaw end

        local raw = self:GetSightAmountRaw()
        local cur = self.VisualSightRaw

        if cur == nil then
            cur = raw
        else
            local rate = math.max(1 / self:GetSightTime(), math.abs(raw - cur) / self.VisualSightCatchUp)
            cur = math.Approach(cur, raw, rate * FrameTime())
        end

        self.VisualSightRaw = cur
        self.VisualSightFrame = frame

        return cur
    end

    // Eased sight blend for VISUALS (viewmodel offset, FOV, pose parameters, HUD).
    function SWEP:GetSightAmountVisual()
        return applyEase(self, self:GetSightAmountRawVisual())
    end
else
    SWEP.GetSightAmountRawVisual = SWEP.GetSightAmountRaw
    SWEP.GetSightAmountVisual = SWEP.GetSightAmount
end

// Sets the aim *intent*. Whether the sights actually come up is resolved in Think_Sights
// (sprinting keeps them down).
function SWEP:ScopeToggle(on)
    if on == nil then on = !self:GetIronsight() end

    if on and !self.Ironsight then return end
    if on and self:GetReloading() then return end
    // the PTRD only fires deployed; it does not aim off the bipod either
    if on and self.MustBipod and !self:GetBipod() then return end

    self:SetIronsight(on)
end

function SWEP:UsesToggleAim()
    local owner = self:GetOwner()
    return IsValid(owner) and owner:IsPlayer() and owner:GetInfoNum("mcv_toggle_aim", 0) != 0
end

function SWEP:Think_Sights()
    local owner = self:GetOwner()

    // Shot cooldowns must not swallow aim input during automatic fire. Only locked
    // actions block entry here; ScopeToggle also checks reload and bipod requirements.
    local aimUnlocked = self:GetAnimLockTime() <= CurTime()

    // Ironsight is already a predicted NetworkVar: replay the press against its restored
    // value, never a plain Lua latch or an IsFirstTimePredicted-only state change.
    if self:GetSafe() then
        if self:GetIronsight() then self:ScopeToggle(false) end
    elseif self:UsesToggleAim() then
        if owner:KeyPressed(IN_ATTACK2) and !owner:KeyDown(IN_USE) then
            if self:GetIronsight() then
                self:ScopeToggle(false)
            elseif aimUnlocked then
                self:ScopeToggle(true)
            end
        end
    elseif owner:KeyDown(IN_ATTACK2) then
        if !self:GetIronsight() and !owner:KeyDown(IN_USE) and aimUnlocked then
            self:ScopeToggle(true)
        end
    elseif self:GetIronsight() then
        self:ScopeToggle(false)
    end

    local sighted = self:GetIronsight() and !self:GetIsSprinting() and (!self.MustBipod or self:GetBipod())

    if sighted != self:GetSighted() then
        self:SetSighted(sighted)

        self:EmitSound(sighted and "MCV_Weapon_Foley_Ironsights.In" or "MCV_Weapon_Foley_Ironsights.Out")
    end

    // Advance the blend by exactly one tick toward the target, the same step on both realms.
    // Integrating the value the shot reads is what makes this predict: on an error the engine
    // puts the amount back to the server's and the next tick carries on from there, and the
    // client's re-simulation of the commands it has not had acknowledged reproduces the same
    // path a tick at a time.
    local target = sighted and 1 or 0
    local cur = self:GetSightAmountRaw()

    if cur != target then
        self:SetSightAmountRaw(math.Approach(cur, target, engine.TickInterval() / self:GetSightTime()))
    end
end
