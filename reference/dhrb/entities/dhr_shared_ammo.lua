AddCSLuaFile()
ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Shared ammunition"
ENT.Spawnable = false
ENT.DisableDuplicator = true
ENT.DoNotDuplicate = true

function ENT:SetupDataTables()
    self:NetworkVar("String", 0, "AmmoName")
    self:NetworkVar("Int", 0, "Rounds")
    self:NetworkVar("Entity", 0, "Donor")
end

if CLIENT then
    function ENT:Draw() self:DrawModel() end
    return
end

function ENT:Initialize()
    if self:GetRounds() <= 0 or game.GetAmmoID(self:GetAmmoName()) < 0 then self:Remove(); return end
    self.ThrowVelocity = self.ThrowVelocity or Vector(0, 0, 0)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_BBOX)
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS_TRIGGER)
    self:SetCollisionBounds(Vector(-8,-8,-5), Vector(8,8,5))
    self:SetTrigger(true)
    self:SetUseType(SIMPLE_USE)
    self.Created = CurTime()
    self.LastStep = CurTime()
    self.Die = CurTime() + 45
    self.Spin = Angle(100, 160, 65)
    if self.Magazine and self:GetNumBodyGroups() > 1 then self:SetBodygroup(1, math.min(2, self:GetRounds())) end
end

function ENT:Collect(target)
    if self.Collecting or not IsValid(target) or CurTime() < self.Created + 0.25 then return end
    local donor = self:GetDonor()
    if target == donor and CurTime() < self.Created + 1 then return end
    if target:WorldSpaceCenter():DistToSqr(self:GetPos()) > 72^2 then return end
    local trace = util.TraceLine({start = self:GetPos(), endpos = target:WorldSpaceCenter(), mask = MASK_SOLID_BRUSHONLY})
    if trace.Hit then return end
    self.Collecting = true
    local given = DHR.GiveSharedAmmo(target, donor, self:GetAmmoName(), self:GetRounds())
    if given > 0 then
        self:SetRounds(self:GetRounds() - given)
        self:EmitSound("items/ammo_pickup.wav", 65, 100, 0.7)
        DHR.RunHook("DHRAmmoReceived", target, donor, self:GetAmmoName(), given)
    end
    if self:GetRounds() <= 0 then self:Remove() else self.Collecting = false end
end

function ENT:StartTouch(target) self:Collect(target) end
function ENT:Use(target) self:Collect(target) end

function ENT:Think()
    local now = CurTime()
    if now >= self.Die then self:Remove(); return end
    local dt = math.Clamp(now - self.LastStep, 0, 0.05)
    self.LastStep = now
    if not self.Resting then
        self.ThrowVelocity = self.ThrowVelocity - Vector(0, 0, 600) * dt
        local trace = util.TraceHull({start = self:GetPos(), endpos = self:GetPos() + self.ThrowVelocity * dt,
            mins = Vector(-2,-2,-2), maxs = Vector(2,2,2), mask = MASK_SOLID_BRUSHONLY})
        self:SetPos(trace.HitPos + (trace.Hit and trace.HitNormal * 2 or vector_origin))
        self:SetAngles(self:GetAngles() + self.Spin * dt)
        if trace.Hit then
            self.ThrowVelocity = (self.ThrowVelocity - 2 * self.ThrowVelocity:Dot(trace.HitNormal) * trace.HitNormal) * 0.25
            self.Spin = self.Spin * 0.35
            if self.ThrowVelocity:LengthSqr() < 400 or trace.StartSolid then self.Resting = true end
        end
    end
    for _, target in ipairs(ents.FindInSphere(self:GetPos(), 40)) do
        if target:IsPlayer() or target:IsNPC() or target:IsNextBot() then
            self:Collect(target)
            if not IsValid(self) then return end
        end
    end
    self:NextThink(now + 0.03)
    return true
end
