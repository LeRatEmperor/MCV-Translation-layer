// Deferred weapon actions, stored in the predicted datatable.
//
// A queued closure cannot predict. The list it sits in is a plain Lua table, so the engine
// never puts it back when the server disagrees, and it is only ever queued on the first
// prediction of a command, so a command the client re-simulates never queues it again. Between
// those two the client's pending work and the server's drift apart and stay apart.
//
// What replaces it is the shape NextPrimaryFire already has: a deadline in a networked float,
// compared against CurTime in the predicted think. Because a closure cannot travel, a class
// lists the actions it can defer in SWEP.DeferredActions in a fixed order; the index into that
// list is what is networked, so both realms read the same name out of the same number, and the
// handler is the method named Deferred_<name>.
//
// One stage is pending at a time. Multi-stage actions keep ActionEnd and their arguments in
// NetworkVars, then schedule the next stage from the handler. Every stage can be replayed.

SWEP.DeferredActions = {}

function SWEP:Defer(name, delay)
    local id = 0

    for i, n in ipairs(self.DeferredActions) do
        if n == name then
            id = i
            break
        end
    end

    if id == 0 then return end

    self:SetDeferredAction(id)
    self:SetDeferredTime(CurTime() + delay)
end

function SWEP:DeferPending(name)
    local id = self:GetDeferredAction()

    return id > 0 and (name == nil or self.DeferredActions[id] == name)
end

function SWEP:CancelDeferred()
    self:SetDeferredAction(0)
    self:SetDeferredTime(0)
end

function SWEP:ProcessDeferred()
    local id = self:GetDeferredAction()

    if id == 0 then return end
    if CurTime() < self:GetDeferredTime() then return end

    local name = self.DeferredActions[id]
    self:CancelDeferred()

    local handler = name and self["Deferred_" .. name]
    if handler then handler(self) end
end
