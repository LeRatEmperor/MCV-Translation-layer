function SWEP:CanBipod()
    local owner = self:GetOwner()

    local pos = owner:EyePos()
    local ang = owner:EyeAngles()

    local maxs = Vector(1, 1, 1)
    local mins = Vector(-1, -1, -48)

    local tr = util.TraceLine({
        start = pos,
        endpos = pos + (ang:Forward() * 64),
        filter = owner,
        mask = MASK_PLAYERSOLID
    })

    if tr.Hit then return end

    local tr2 = util.TraceHull({
        start = pos,
        endpos = pos + (ang:Forward() * 24),
        filter = owner,
        maxs = maxs,
        mins = mins,
        mask = MASK_PLAYERSOLID
    })

    return tr2.Hit
end

function SWEP:Think_Bipod()
    if !self.HasBipod then return end
    if self:StillWaiting() then return end

    local owner = self:GetOwner()

    if !self:GetBipod() then
        // Use + Walk belongs to safety / launcher controls, not bipod deployment.
        if owner:KeyPressed(IN_USE) and !owner:KeyDown(IN_WALK) and self:CanBipod() then
            // Replay both NetworkVars together. Do not play the safety exit
            // animation: the deployment animation takes the weapon into position.
            self:SetSafe(false)
            self:PlayAnimation(ACT_VM_DEPLOYED_IN, 1, true)
            self:SetBipod(true)
        end
    else
        // moving (or jumping) folds it, as does losing the surface
        local moving = owner:KeyDown(IN_FORWARD) or owner:KeyDown(IN_BACK) or owner:KeyDown(IN_MOVELEFT)
            or owner:KeyDown(IN_MOVERIGHT) or owner:KeyDown(IN_JUMP)
        if moving or !self:CanBipod() then
            self:PlayAnimation(ACT_VM_DEPLOYED_OUT, 1, true)
            self:SetBipod(false)
        end
    end
end
