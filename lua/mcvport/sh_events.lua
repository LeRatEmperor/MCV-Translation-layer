--[[---------------------------------------------------------------------------
    MCVPort — synthetic timeline events for models without usable event tracks.

    Included by each mcvport_* weapon base. A port declares timed events per
    animation role:

        events = {
            reload = {
                { t = 0.9, sound = "PORT_AK47.MagIn" },          -- server EmitSound
                { t = 1.4, data = { kind = "eject" } },           -- custom, via OnRoleEvent
            },
        }

    Mechanics, grounded in the audited prediction model
    (docs/animation-system.md section 3):

    - t is WALL-CLOCK seconds after the animation starts, matching how the
      client rebuilds the cycle (AnimationStart + AnimationDuration), so event
      timing survives prediction and re-simulation without extra networking.
    - The generation key is GetAnimationStart(): a new value means a new
      animation, which resets the fired set. The server and the local client
      each keep their own per-instance state.
    - realm gates where the event body runs:
        "server" (default) -> only on the server. Sounds emitted server-side
                              replicate to everyone; use for anything audible.
        "client"           -> only on the local player's predicted weapon.
                              One-shot first-person visuals.
        "shared"           -> both; guard one-shots yourself.
    - Non-local players' weapons never Think on their clients, so anything the
      other players must perceive (sounds, world effects) has to come from the
      server realm.

    Built-in actions:
        ev.sound = "<name>"  -> EmitSound on the weapon (server realm)
        anything else        -> forwarded to the port's OnRoleEvent hook:
                                function(self, role, ev)

    Prefer native MCV fields first (the two-homes rule): MagInTime /
    MagInTimeEmpty / ReloadInsertTime cover most reload timing, and models that
    still carry Source event tracks fire their own foley + eject natively
    (FireAnimationEvent -> DoEject, sh_shoot.lua:201-205). Synthetic events are
    only for what fields and event tracks cannot express.
-----------------------------------------------------------------------------]]

function MCVP.State(self)
    if self.MCVP_state == nil then
        self.MCVP_state = {}
    end
    return self.MCVP_state
end

local REALMS = { server = true, client = true, shared = true }

function MCVP.FireEvent(self, role, ev)
    local realm = ev.realm or "server"

    if realm == "server" then
        if CLIENT then return end
    elseif realm == "client" then
        if SERVER then return end
        local owner = self:GetOwner()
        if not (IsValid(owner) and owner == LocalPlayer()) then return end
    end

    if ev.sound then
        self:EmitSound(ev.sound)
    end

    MCVP.RunHook(self, "OnRoleEvent", role, ev)
end

-- Called from the port base Think before mcv_base's own Think, so events for
-- an action fire before the idle loop can switch animations again.
function MCVP.ThinkEvents(self)
    local cfg = self.MCVP
    if not cfg then return end
    if not self.GetAnimationStart then return end

    local st = MCVP.State(self)
    if st.role == nil then return end

    local start = self:GetAnimationStart()

    -- A new animation started outside the role bridge (idle, base logic):
    -- stop tracking events for the old role.
    if start ~= st.start then
        st.role = nil
        st.fired = {}
        return
    end

    local events = cfg.events[st.role]
    if not events then return end

    local elapsed = CurTime() - start
    for i, ev in ipairs(events) do
        if not st.fired[i] and elapsed >= ev.t then
            st.fired[i] = true
            MCVP.FireEvent(self, st.role, ev)
        end
    end
end

-- Reset the tracker (holster, drop). Plain per-instance state, no networking:
-- the frozen MCV datatable cannot grow, and event bookkeeping is realm-local.
function MCVP.ClearEvents(self)
    local st = self.MCVP_state
    if st then
        st.role = nil
        st.fired = {}
    end
end
