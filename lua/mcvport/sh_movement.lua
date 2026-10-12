--[[---------------------------------------------------------------------------
    MCVPort — discrete movement animations for foreign animsets.

    MCV expresses movement with pose parameters: the idle loop keeps one idle
    sequence playing while "player_movement" blends the walk/sprint layers
    (docs/animation-system.md section 6). A model without those pose
    parameters — every NMRiH/INS2-style discrete animset — no-ops into still
    idle while the player runs around, which reads as "the animations don't
    work".

    This bridge rides the idle loop instead of fighting it. MCV's Think calls
    Idle() whenever GetNextIdle() lapses (weapon_common/sh_think.lua:21-23),
    and Idle() gives IdleSequence() precedence over IdleActivity()
    (weapon_common/sh_anim.lua:119-129). So:

    - SWEP:IdleSequence returns the sequence matching the player's movement
      state: idle / walk / sprint, each with an _empty variant when the gun
      is dry (NMRiH's slide-back idles). The loop re-triggers them naturally,
      with the model's own fadein blending the swap.
    - MCVP.ThinkMovement (called from the lifecycle Think, before the base)
      detects state changes. Entering or leaving the sprint carry plays a
      transition sequence when the model has one (Idle_to_Sprint etc.);
      otherwise the idle loop is simply re-armed so Idle() plays the new
      state immediately.
    - State changes never cut an in-flight action animation: they only act
      when the current viewmodel sequence belongs to the movement family
      (the port's own idle/walk/sprint/transition sequences). A change that
      happens mid-fire or mid-reload lands when that animation's NextIdle
      lapses and Idle() runs — exactly how the base already recovers.

    Opt-in per port, because an MCV-rigged model must keep its pose-param
    movement:

        MCV.Define(SWEP, {
            movement = true,       -- default false
            anims = {
                idle_empty  = "Idle_empty",
                walk        = "Walk",           -- sequence names; these
                walk_empty  = "Walk_Empty",     -- activities are not in
                sprint      = "Sprint_",        -- GMod's enum, so they are
                sprint_empty = "Sprint_Empty_", -- addressed by name
                sprint_in   = "Idle_to_Sprint",
                sprint_out  = "Sprint_to_Idle",
            },
        })

    Sighting defers to MCV's vector ironsights (the iron sequences are a
    separate contract the layer does not bind); while sighted the state
    reads as nil and the plain idle plays, as on any native weapon.

    Included after sh_animroles.lua; the IdleSequence override chains onto
    the role-bridge version captured at include time.
-----------------------------------------------------------------------------]]

--------------------------------------------------------------------------------
-- Movement state
--------------------------------------------------------------------------------

-- The family the state machine maintains. _empty variants fall back to their
-- base role when the model doesn't carry them.
local MOVEMENT_ROLES = {
    "idle", "idle_empty",
    "walk", "walk_empty",
    "sprint", "sprint_empty",
    "sprint_in", "sprint_in_empty",
    "sprint_out", "sprint_out_empty",
}

local WALK_SPEED = 40    -- units/s over which the player counts as moving
local SPRINT_SPEED = 100 -- and as actually sprinting, not just leaning on shift

-- "idle" | "walk" | "sprint", or nil when the bridge should stand down
-- (action animation owns the viewmodel, or the player is sighting).
function MCVP.MovementState(self)
    local cfg = self.MCVP
    if not (cfg and cfg.movement) then return nil end

    local owner = self:GetOwner()
    if not (IsValid(owner) and owner:IsPlayer()) then return nil end

    if self.GetAnimLockTime and self:GetAnimLockTime() > CurTime() then return nil end
    if self.GetSightAmount and self:GetSightAmount() > 0.3 then return nil end

    local speed
    if self.GetWeaponMovement then
        speed = self:GetWeaponMovement()
    else
        speed = owner:GetVelocity():Length2D()
    end

    if self.GetIsSprinting and self:GetIsSprinting() and speed > SPRINT_SPEED then
        return "sprint"
    end
    if speed > WALK_SPEED then
        return "walk"
    end
    return "idle"
end

-- The idle role for the current state: the _empty variant when the gun is
-- dry, falling back to the base role when the model lacks it.
function MCVP.MovementIdleRole(self, state)
    if not self.MCVP then return nil end
    if self:Clip1() <= 0 and MCVP.ResolvedRole(self, state .. "_empty") then
        return state .. "_empty"
    end
    return state
end

--------------------------------------------------------------------------------
-- The movement family (sequences safe for a state change to replace)
--------------------------------------------------------------------------------

local function vmOf(self)
    local owner = self:GetOwner()
    if IsValid(owner) and owner:IsPlayer() then
        return owner:GetViewModel()
    end
end

local function familyNames(self, vm)
    local st = MCVP.State(self)
    local model = vm:GetModel()
    if st.mv_family_model ~= model then
        local set = {}
        for _, role in ipairs(MOVEMENT_ROLES) do
            local resolved = MCVP.ResolvedRole(self, role)
            if resolved then
                if resolved.kind == "seq" then
                    set[resolved.name] = true
                else
                    local idx = vm:SelectWeightedSequence(resolved.act)
                    if idx ~= -1 then
                        set[vm:GetSequenceName(idx)] = true
                    end
                end
            end
        end
        st.mv_family = set
        st.mv_family_model = model
    end
    return st.mv_family
end

--------------------------------------------------------------------------------
-- State-change handling (transitions, re-arming the idle loop)
--------------------------------------------------------------------------------

function MCVP.ThinkMovement(self)
    local cfg = self.MCVP
    if not (cfg and cfg.movement) then return end

    local state = MCVP.MovementState(self)
    local st = MCVP.State(self)

    if state == nil then
        st.mv_state = nil
        return
    end

    local empty = self:Clip1() <= 0
    if st.mv_state == state and st.mv_empty == empty then return end

    local was = st.mv_state
    st.mv_state = state
    st.mv_empty = empty

    local vm = vmOf(self)
    if not IsValid(vm) then return end

    -- only take the viewmodel from another movement-family sequence; an
    -- in-flight action (fire, bash, a reload's tail) finishes on its own and
    -- Idle() lands the new state when its NextIdle lapses
    local current = vm:GetSequenceName(vm:GetSequence())
    if not familyNames(self, vm)[current] then return end

    -- the sprint carry gets its transition when the model carries one
    local transition
    if state == "sprint" and was ~= "sprint" then
        transition = "sprint_in"
    elseif was == "sprint" and state ~= "sprint" then
        transition = "sprint_out"
    end

    if transition then
        if empty and MCVP.ResolvedRole(self, transition .. "_empty") then
            transition = transition .. "_empty"
        end
        if MCVP.PlayRole(self, transition, 1, false, false) then
            return -- its duration arms the idle loop; Idle() takes the new state
        end
    end

    -- no transition (or none bound): re-arm the idle loop so Idle() plays
    -- the new state's sequence in this very think
    if self.SetNextIdle then
        self:SetNextIdle(0)
    end
end

--------------------------------------------------------------------------------
-- The IdleSequence chain override
--------------------------------------------------------------------------------

-- sh_animroles.lua's version, captured before this module replaces it.
local chained_idle_sequence = SWEP.IdleSequence

function SWEP:IdleSequence()
    if self.MCVP then
        local state = MCVP.MovementState(self)
        if state then
            local role = MCVP.MovementIdleRole(self, state)
            local resolved = role and MCVP.ResolvedRole(self, role)
            if resolved and resolved.kind == "seq" then
                return resolved.name
            end
            -- act-resolved or unbound: fall through to the role bridge
        end
    end
    return chained_idle_sequence(self)
end
