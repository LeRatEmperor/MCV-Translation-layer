--[[---------------------------------------------------------------------------
    MCVPort — animation role resolution and the PlayAnimation bridge.

    Included by each mcvport_* weapon base (the global SWEP is the base being
    defined when this runs), so the SWEP: methods below land on every port base
    without touching mcv_base itself.

    How it works:

    - MCV's base code addresses animations by engine activity at audited call
      sites (docs/animation-system.md section 5.1). MCVP.ActRoles names the
      intent of each call site ("fire", "reload", "cycle"...).
    - A port's anims table rebinds any intent to what the foreign model
      actually has: an activity number, a sequence name, or a candidate list
      tried in order (first entry the model has wins; unmentioned roles keep
      the default MCV activity).
    - The SWEP:PlayAnimation / SWEP:HasAnimation bridges translate on the fly;
      anything unbound falls through to mcv_base's native behaviour, which is
      the audited "check -> play -> tolerate nil" pattern (a missing animation
      must never stall or error the fire loop).
    - MCVP.Resolve walks every role against the real viewmodel at deploy and
      caches per model path, DHRB style (reference/dhrb/core.lua:174-246): one
      warning listing ALL missing roles at once, instead of a drip of
      "INVALID ACT" spam. Missing roles degrade gracefully — the weapon still
      deploys and fires.
-----------------------------------------------------------------------------]]

--------------------------------------------------------------------------------
-- Host parent resolution
--
-- self.BaseClass on an INSTANCE points at the class the weapon derives from —
-- which is THIS base (mcvport_gun), not mcv_base. Calling self.BaseClass.X
-- from a method defined on this base would re-enter our own bridge and loop
-- forever. Instead, capture the host base's own parent while the module is
-- included (SWEP.Base is assigned before the includes in the base file) and
-- resolve it lazily — baseclass.Get returns the fully composed parent table
-- (weapon_common merged in) and stays correct across Lua refreshes.
--------------------------------------------------------------------------------

local host_parent = SWEP.Base or "mcv_base"

local function parent()
    return baseclass.Get(host_parent)
end

--------------------------------------------------------------------------------
-- Candidate resolution against a concrete viewmodel
--------------------------------------------------------------------------------

local function vmOf(self)
    local owner = self:GetOwner()
    if IsValid(owner) and owner:IsPlayer() then
        return owner:GetViewModel()
    end
end

local function lookupSequence(vm, name)
    if MCV and MCV.CachedSequence then
        return MCV.CachedSequence(vm, name)
    end
    return vm:LookupSequence(name)
end

-- Resolve one atomic candidate (activity number or sequence name).
-- Returns { kind = "act", act = n } / { kind = "seq", name = s } or nil.
local function resolveCandidate(vm, value)
    if isnumber(value) then
        if vm:SelectWeightedSequence(value) ~= -1 then
            return { kind = "act", act = value }
        end
        return nil
    end
    if isstring(value) then
        if lookupSequence(vm, value) ~= -1 then
            return { kind = "seq", name = value }
        end
        return nil
    end
    return nil
end

-- Resolve a role value (atom or candidate list) to a single concrete form.
local function resolveValue(vm, value)
    if istable(value) then
        for _, candidate in ipairs(value) do
            local resolved = resolveCandidate(vm, candidate)
            if resolved then return resolved end
        end
        return nil
    end
    return resolveCandidate(vm, value)
end

--------------------------------------------------------------------------------
-- Per-model resolution pass (deploy time)
--------------------------------------------------------------------------------

-- MCVP.Resolve(self, vm) -> true when no REQUIRED role is missing.
-- Optional roles resolve to nil and simply fall through to base behaviour.
function MCVP.Resolve(self, vm)
    local cfg = self.MCVP
    if not cfg then return true end

    vm = vm or vmOf(self)
    if not IsValid(vm) then return true end -- no viewmodel yet; roles fall through

    local model = vm:GetModel()
    self.MCVP_resolved = self.MCVP_resolved or {}
    local cache = self.MCVP_resolved[model]
    if cache then return cache.ok end

    local resolved, missing = {}, {}
    for role, value in pairs(cfg.anims) do
        local r = resolveValue(vm, value)
        if r then
            resolved[role] = r
        elseif role ~= "idle" then
            -- idle falls back to IdleActivity selection, not worth listing
            missing[#missing + 1] = role
        end
    end

    local ok = true
    local required_missing = {}
    for _, role in ipairs(cfg.required) do
        if not resolved[role] then
            ok = false
            required_missing[#required_missing + 1] = role
        end
    end

    table.sort(missing)
    table.sort(required_missing)

    cache = {
        ok = ok,
        resolved = resolved,
        missing = missing,
        required_missing = required_missing,
        model = model,
        warned = false,
    }
    self.MCVP_resolved[model] = cache
    return ok
end

-- The resolved form for one role, or nil. Resolves on demand when the deploy
-- pass has not run yet (call sites can fire before Deploy on Lua refresh).
function MCVP.ResolvedRole(self, role)
    local cfg = self.MCVP
    if not cfg then return nil end

    local vm = vmOf(self)
    if not IsValid(vm) then return nil end
    local model = vm:GetModel()

    local cache = self.MCVP_resolved and self.MCVP_resolved[model]
    if cache then return cache.resolved[role] end

    -- no cache for this model yet: resolve this role directly
    return resolveValue(vm, cfg.anims[role])
end

--------------------------------------------------------------------------------
-- Playing a role
--------------------------------------------------------------------------------

-- MCVP.PlayRole(self, role, mult, lock, noidle) -> duration or nil.
-- Plays the resolved form through the base implementation and records the
-- role/generation the synthetic event scanner keys off.
function MCVP.PlayRole(self, role, mult, lock, noidle)
    local resolved = MCVP.ResolvedRole(self, role)
    if not resolved then return nil end

    -- Re-entrancy guard: an act-kind resolution plays through the parent's
    -- PlayAnimation; the guard keeps any virtual-dispatch route back into the
    -- bridge from re-translating the resolved activity.
    self.MCVP_playing = true
    local duration
    local ok, err = pcall(function()
        if resolved.kind == "seq" then
            duration = parent().PlaySequence(self, resolved.name, mult, lock, noidle)
        else
            duration = parent().PlayAnimation(self, resolved.act, mult, lock, noidle)
        end
    end)
    self.MCVP_playing = false
    if not ok then error(err, 0) end

    if duration ~= nil then
        local st = MCVP.State(self)
        st.role = role
        st.fired = {}
        st.start = (self.GetAnimationStart and self:GetAnimationStart()) or CurTime()
        MCVP.RunHook(self, "OnRolePlayed", role, duration)
        if MCVP.FireRoles[role] then
            MCVP.RunHook(self, "OnShotFired", role, duration)
        end
    end

    return duration
end

-- The act -> role lookup honouring per-weapon act_roles extensions.
function MCVP.RoleForAct(self, act)
    local cfg = self.MCVP
    if cfg and cfg.act_roles and cfg.act_roles[act] then
        return cfg.act_roles[act]
    end
    return MCVP.ActRoles[act]
end

--------------------------------------------------------------------------------
-- The bridges (defined on every mcvport_* base)
--------------------------------------------------------------------------------

-- Route parent-code activity requests through the role table when the intent
-- has a port binding; otherwise behave exactly like the parent base.
function SWEP:PlayAnimation(act, mult, lock, noidle)
    if self.MCVP and not self.MCVP_playing then
        local role = MCVP.RoleForAct(self, act)
        if role then
            local duration = MCVP.PlayRole(self, role, mult, lock, noidle)
            if duration ~= nil then return duration end
            -- no resolution for this intent: try the raw activity below
        end
    end
    return parent().PlayAnimation(self, act, mult, lock, noidle)
end

-- Keep capability probes consistent with the bridge: MCV call sites gate
-- optional animations with HasAnimation before playing them, so a role bound
-- to a sequence name must report the activity as present.
function SWEP:HasAnimation(act)
    if self.MCVP then
        local role = MCVP.RoleForAct(self, act)
        if role and MCVP.ResolvedRole(self, role) then
            return true
        end
    end
    return parent().HasAnimation(self, act)
end

-- Idle by sequence name. mcv_base's Idle() gives IdleSequence() precedence
-- over IdleActivity() and re-checks HasSequence, so returning a name the model
-- lacks is safe (it falls back to activity selection).
function SWEP:IdleSequence()
    if self.MCVP then
        local resolved = MCVP.ResolvedRole(self, "idle")
        if resolved and resolved.kind == "seq" then
            return resolved.name
        end
    end
    local p = parent()
    if p.IdleSequence then
        return p.IdleSequence(self)
    end
    return nil
end
