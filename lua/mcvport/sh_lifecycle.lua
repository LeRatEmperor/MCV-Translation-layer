--[[---------------------------------------------------------------------------
    MCVPort — lifecycle wrappers for every mcvport_* base.

    Thin, non-forking overrides: each one runs the layer's bookkeeping, runs
    the port's hooks, then hands the call to mcv_base unchanged. The MCV fire /
    reload / think pipelines are never duplicated here — a port weapon gets
    upstream behaviour (and upstream fixes) byte for byte.

    Order of operations per hook is chosen against the audited base:

    - Initialize: base first (it dedupes inherited Firemodes etc.), then the
      per-instance table.Copy of the Define data. GMod merges inherited nested
      tables index by index rather than wholesale, so class-level tables must
      be copied before any instance mutates them (same lesson as
      weapon_common's Primary/Secondary copies and DHRB's self.HR copy,
      reference/dhrb/dhr_base.lua:128-134).
    - Deploy: resolve roles and warn once (complete missing list), let a
      CanDeploy hook veto, then run the base deploy.
    - Think: synthetic events and OnThink BEFORE the base think, so an
      action's events fire before the idle loop can restart the viewmodel.
    - Holster: only notify OnHolster when the base actually holsters.

    Like sh_animroles.lua, this module reaches the host base's parent through
    baseclass.Get(SWP.Base) captured at include time — self.BaseClass on an
    instance points at THIS base and would re-enter these wrappers.
-----------------------------------------------------------------------------]]

local host_parent = SWEP.Base or "mcv_base"

local function parent()
    return baseclass.Get(host_parent)
end

function SWEP:Initialize()
    local r = parent().Initialize(self)

    if self.MCVP then
        self.MCVP = table.Copy(self.MCVP)
        self.MCVP_state = {}
        self.MCVP_resolved = nil
        MCVP.RunHook(self, "OnInitialize")
    end

    return r
end

function SWEP:Deploy()
    if not self.MCVP then
        return parent().Deploy(self)
    end

    local ok = MCVP.Resolve(self)
    if not ok then
        -- warn exactly once per model, listing everything at once
        local owner = self:GetOwner()
        local vm = IsValid(owner) and owner:GetViewModel() or nil
        local model = (IsValid(vm) and vm:GetModel()) or tostring(self.ViewModel)
        local cache = self.MCVP_resolved and self.MCVP_resolved[model]
        if cache and not cache.warned then
            cache.warned = true
            local missing = #cache.required_missing > 0 and cache.required_missing or cache.missing
            ErrorNoHalt("MCVPort: " .. self:GetClass() .. " (" .. tostring(self.PrintName) .. ")"
                .. " is missing animations for: " .. table.concat(missing, ", ") .. "\n")
        end
    end

    if MCVP.RunHook(self, "CanDeploy") == false then
        return false
    end

    local r = parent().Deploy(self)
    if r ~= false then
        MCVP.RunHook(self, "OnDeploy", ok)
    end
    return r
end

function SWEP:Holster()
    local r = true
    local p = parent()
    if p.Holster then
        r = p.Holster(self)
    end

    if r ~= false then
        MCVP.ClearEvents(self)
        MCVP.RunHook(self, "OnHolster")
    end
    return r
end

function SWEP:Think()
    if self.MCVP then
        MCVP.ThinkEvents(self)
        MCVP.RunHook(self, "OnThink")
    end

    local p = parent()
    if p.Think then
        return p.Think(self)
    end
end

function SWEP:PrimaryAttack()
    if self.MCVP and MCVP.RunHook(self, "CanFire") == false then
        return
    end
    return parent().PrimaryAttack(self)
end

function SWEP:Reload()
    if self.MCVP and MCVP.RunHook(self, "CanReload") == false then
        return
    end
    return parent().Reload(self)
end
