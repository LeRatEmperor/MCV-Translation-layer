AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Crossbow Bolt"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/crossbow_bolt.mdl"

ENT.IsRocket = false
ENT.InstantFuse = false
ENT.TimeFuse = false
ENT.Delay = 0
ENT.Sticky = true
ENT.StickyPlace = false
ENT.ImpactDamage = 0
ENT.ImpactFuse = false

ENT.Damage = 55
ENT.HeadMultiplier = 4
ENT.ChestMultiplier = 3
ENT.PickupAmmo = "XBowBolt"
ENT.Lifetime = 60

// In the compiled idle pose the tip is 20.03 units along local +X.
local tipDistance, embedDepth = 20.03, 2

function ENT:OnInitialize()
    if SERVER then
        self:SetUseType(SIMPLE_USE)
        self.DieTime = CurTime() + self.Lifetime
        local phys = self:GetPhysicsObject()
        if IsValid(phys) then
            phys:EnableDrag(false)
            phys:SetMass(2)
            phys:AddGameFlag(FVPHYSICS_NO_IMPACT_DMG) // Impact() owns bolt damage.
        end
    else
        // Flight rendering can rotate independently of the collision sphere.
        self:SetRenderBounds(Vector(-26,-26,-26), Vector(26,26,26))
    end
end

function ENT:OnThink()
    if SERVER and CurTime() > self.DieTime then self:Remove() end
end

function ENT:Draw()
    // SetAngles on a flying VPhysics entity clears its velocity. Align only the
    // rendered mesh, every frame; the server sets the final angle when it sticks.
    if self:GetMoveType() == MOVETYPE_VPHYSICS then
        // Server-only VPhysics does not supply reliable client GetVelocity().
        // Follow the interpolated positions, retaining the angle between updates.
        local pos = self:GetPos()
        local delta = self.LastDrawPos and (pos - self.LastDrawPos)
        if delta and delta:LengthSqr() > 0.000001 then self.FlightRenderAngle = delta:Angle() end
        self.LastDrawPos = pos
        self:SetRenderAngles(self.FlightRenderAngle or self:GetAngles())
    else
        self.LastDrawPos, self.FlightRenderAngle = nil, nil
    end
    self:DrawModel()
    self:SetRenderAngles()
end

function ENT:Impact(data, collider)
    if !SERVER or self.HitDone then return end
    self.HitDone = true

    local ent = data.HitEntity
    if IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:Health() > 0) then
        local owner = IsValid(self:GetOwner()) and self:GetOwner() or self.Attacker
        // let FireBullets resolve the hitgroup for the multipliers
        local wep = self:GetWeapon()
        self:FireBullets({
            Attacker = IsValid(owner) and owner or self,
            Inflictor = IsValid(wep) and wep or self,
            Damage = self.Damage,
            Force = 4,
            Tracer = 0,
            Num = 1,
            Distance = 48,
            Src = data.HitPos - data.OurOldVelocity:GetNormalized() * 16,
            Dir = data.OurOldVelocity:GetNormalized(),
            IgnoreEntity = self,
            Callback = function(atk, tr, dmginfo)
                dmginfo:SetDamageType(DMG_SLASH + DMG_NEVERGIB)
                if tr.HitGroup == HITGROUP_HEAD then
                    dmginfo:ScaleDamage(self.HeadMultiplier)
                elseif tr.HitGroup == HITGROUP_CHEST or tr.HitGroup == HITGROUP_STOMACH then
                    dmginfo:ScaleDamage(self.ChestMultiplier)
                end
                MCV.BulletImpact(tr, dmginfo:GetDamage(), true)
                return {effects = false}
            end,
        })
        self:EmitSound("MCV_Weapon_Crossbow.BoltHitBody")
        if ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() then
            // no bolt to pick up out of a body
            timer.Simple(0.05, function() if IsValid(self) then self:Remove() end end)
        end
    else
        // Trace across the contact normal for the actual surface/sky metadata.
        // Physics collision normals point inward, unlike trace normals.
        local normal = -data.HitNormal
        local start = data.HitPos + normal * 4
        local tr = util.TraceLine({start = start, endpos = data.HitPos - normal * 4,
            mask = MASK_SHOT, filter = self})
        if !tr.Hit or tr.Entity != ent then
            // A moving prop can leave the contact before the deferred callback.
            tr = {Hit = true, HitPos = data.HitPos, HitNormal = normal, StartPos = start,
                Entity = ent, SurfaceProps = data.TheirSurfaceProps or 0}
        end
        MCV.BulletImpact(tr, self.Damage, true)
        self:EmitSound("MCV_Weapon_Crossbow.BoltHitWorld")
    end
end

function ENT:Stick(data)
    local direction = data.OurOldVelocity:GetNormalized()
    if direction:IsZero() then direction = self:GetForward() end
    // Use the incoming direction, not the bounce. The tip enters the surface
    // while the shaft stays outside. Retire flight physics before parenting.
    self:PhysicsDestroy()
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_BBOX)
    self:SetCollisionBounds(Vector(-2, -2, -2), Vector(2, 2, 2))
    self:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
    self:SetAngles(direction:Angle())
    self:SetPos(data.HitPos - direction * (tipDistance - embedDepth))
    if IsValid(data.HitEntity) and !data.HitEntity:IsWorld() then
        self:SetParent(data.HitEntity)
    end
    self:ReleaseOwner()
    self:Stuck()
end

function ENT:PhysicsCollide(data, collider)
    if self.ImpactQueued or self.HitDone then return end
    self.ImpactQueued = true
    local impact = table.Copy(data)
    // Sticking reparents the bolt and changes its collision rules. Doing that
    // inside the physics callback spews warnings and can destabilize VPhysics.
    timer.Simple(0, function()
        if !IsValid(self) then return end
        self.ImpactQueued = false
        if IsValid(impact.HitEntity) and impact.HitEntity:GetClass() == "func_breakable_surf" then
            // Keep the shared glass-shattering/continuation behavior.
            self.BaseClass.PhysicsCollide(self, impact, collider)
            return
        end
        self.ImpactNormal, self.ImpactPos = -impact.HitNormal, impact.HitPos
        self:Impact(impact, collider)
        if IsValid(self) then self:Stick(impact) end
    end)
end

function ENT:Use(ply)
    if !IsValid(ply) or !ply:IsPlayer() then return end
    ply:GiveAmmo(1, self.PickupAmmo, false)
    self:Remove()
end
