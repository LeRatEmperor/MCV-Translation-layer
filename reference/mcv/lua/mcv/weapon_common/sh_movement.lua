// Weapon Think and movement are ordered differently between realms. Queue recoil for the
// following command, then apply it at the same movement phase on both sides. Both the
// impulse and its command are restored when a command is replayed.
function SWEP:QueueRecoilImpulse(amount)
    local owner = self:GetOwner()
    local cmd = owner:IsPlayer() and GetPredictionPlayer() == owner and owner:GetCurrentCommand()
    // View punch has native prediction tolerances. Feeding it into a strict Vector
    // NetworkVar turns harmless camera differences into movement prediction errors.
    local direction = cmd and cmd:GetViewAngles():Forward() or self:GetAimVector()
    local impulse = direction * -amount
    if !cmd then
        if SERVER then owner:SetVelocity(impulse) end // NPC / non-predicted caller
        return
    end
    self:SetRecoilImpulse(self:GetRecoilImpulse() + impulse)
    self:SetRecoilCommand(cmd:CommandNumber())
end

hook.Add("SetupMove", "MCV_RecoilImpulse", function(ply, mv, cmd)
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam then return end
    local impulse = wep:GetRecoilImpulse()
    if impulse:IsZero() or cmd:CommandNumber() <= wep:GetRecoilCommand() then return end
    mv:SetVelocity(mv:GetVelocity() + impulse)
    wep:SetRecoilImpulse(vector_origin)
    wep:SetRecoilCommand(0)
end)

// Keep completed movement in prediction-owned storage. Weapon Think runs before
// movement on the client and afterwards on the server; both must read command N-1.
// A plain Lua "last velocity" survives rollback and instead supplies a future value.
function SWEP:CaptureMovement(command, speed, grounded, crouched)
    if self:GetMoveCommand() != command then
        self:SetLastMoveSpeed(self:GetMoveSpeed())
        self:SetLastMoveGrounded(self:GetMoveGrounded())
        self:SetLastMoveCrouched(self:GetMoveCrouched())
    end
    self:SetMoveCommand(command)
    self:SetMoveSpeed(speed)
    self:SetMoveGrounded(grounded)
    self:SetMoveCrouched(crouched)
end

function SWEP:GetWeaponMovement()
    local owner = self:GetOwner()
    // NPCs have no player movement commands. The second check also lets an existing
    // weapon survive Lua auto-refresh until a map change installs its new datatable.
    if !owner:IsPlayer() or !self.GetMoveCommand then
        return owner:GetVelocity():Length(), owner:IsOnGround(), owner:Crouching()
    end
    local cmd = GetPredictionPlayer() == owner and owner:GetCurrentCommand()
    if cmd and cmd:CommandNumber() == self:GetMoveCommand() then
        return self:GetLastMoveSpeed(), self:GetLastMoveGrounded(), self:GetLastMoveCrouched()
    end
    return self:GetMoveSpeed(), self:GetMoveGrounded(), self:GetMoveCrouched()
end

hook.Add("FinishMove", "MCV_MovementSample", function(ply, mv)
    local wep = ply:GetActiveWeapon()
    if !IsValid(wep) or !wep.MilitaryConflictVietnam or !wep.GetMoveCommand then return end
    if GetPredictionPlayer() != ply then return end
    local cmd = ply:GetCurrentCommand()
    if !cmd or cmd:CommandNumber() == 0 then return end
    wep:CaptureMovement(cmd:CommandNumber(), mv:GetVelocity():Length(), ply:IsOnGround(), ply:Crouching())
end)
