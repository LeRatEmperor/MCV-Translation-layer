AddCSLuaFile()

ENT.Base                     = "mcv_proj_base"
ENT.PrintName                = "Grenade"
ENT.Spawnable                = false

ENT.Model                    = "models/weapons/mcv/w_m26.mdl"

// armed the moment it leaves the hand; Delay is the fuse (set by the weapon)
ENT.InstantFuse = false
ENT.TimeFuse = 0
ENT.Delay = 4
ENT.ImpactFuse = false
ENT.ExplodeOnDamage = false
ENT.ExplodeUnderwater = false

ENT.ImpactDamage = 5
ENT.ImpactDamageSpeed = 600

ENT.ExplosionDamage = 150
ENT.ExplosionRadius = 350
ENT.IgniteRadius = 0
ENT.BurnDuration = 3 // incendiaries: how long the ground burns (the M34's fire does not linger)
ENT.BurnDamagePerSecond = 30
ENT.BurnParticle = nil // the explosion effect carries its own embers
ENT.ExplosionFamily = "grenade"
ENT.ExplosionSound = "MCV_BaseGrenade.Explode"

ENT.BounceSounds = {"MCV_HEGrenade.Bounce"}

ENT.RoundCollision = true

function ENT:InitProjectilePhysics()
    if !self.RoundCollision then
        return baseclass.Get("mcv_proj_base").InitProjectilePhysics(self)
    end

    // V40's body is a 1.5-unit sphere at the model origin; exclude its lever.
    if string.lower(self:GetModel()) == "models/weapons/mcv/w_v40.mdl" then
        self.RollRadius = 1.5
        self:PhysicsInitSphere(self.RollRadius, "metal")
    else
        // All thrown canisters/bottles are authored along local Z. A regular
        // convex cylinder removes the protrusions and seams of the model .phy.
        local mins, maxs = self:GetModelBounds()
        local cx, cy = (mins.x + maxs.x) * 0.5, (mins.y + maxs.y) * 0.5
        local radius = math.max(maxs.x - mins.x, maxs.y - mins.y) * 0.5
        radius = math.max(radius, 0.5)
        local points = {}
        for i = 0, 63 do
            local a = i * math.pi * 2 / 64
            local x, y = cx + math.cos(a) * radius, cy + math.sin(a) * radius
            points[#points + 1] = Vector(x, y, mins.z)
            points[#points + 1] = Vector(x, y, maxs.z)
        end
        self.RollRadius = radius
        self:PhysicsInitConvex(points)
    end
    self:EnableCustomCollisions(true)
end

function ENT:GetAttacker()
    local a = self.Attacker
    if IsValid(a) then return a end
    if IsValid(self:GetOwner()) then return self:GetOwner() end
    return game.GetWorld()
end

function ENT:Detonate()
    local attacker = self:GetAttacker()

    util.BlastDamage(self:GetInflictor(), attacker, self:GetPos(), self.ExplosionRadius, self.ExplosionDamage)

    // incendiary (the game's IgniteRadius extends ExplosionRadius): a short patch of fire like
    // the M202's, damage ticking in sh_burn style, no Ignite()
    if self.IgniteRadius > 0 and SERVER then
        local pool = ents.Create("mcv_firepool")
        if IsValid(pool) then
            pool:SetPos(self:GetImpactPos() + self:GetImpactNormal() * 4)
            pool:SetAngles(MCV.SurfaceAngle(self:GetImpactNormal()))
            pool.Attacker = attacker
            pool.Inflictor = self:GetInflictor()
            pool.Radius = self.ExplosionRadius + self.IgniteRadius
            pool.DamagePerSecond = self.BurnDamagePerSecond
            pool.Duration = self.BurnDuration
            pool.Particle = self.BurnParticle
            pool:Spawn()
        end
    end

    // a planted charge blows normal to the surface it was placed on; anything thrown or
    // dropped blows straight up, whatever it happened to bounce off last.
    local normal = self.PlacedNormal or vector_up
    MCV.ExplosionEffect(self.ExplosionFamily, self:GetImpactPos(), normal, self:WaterLevel() > 0)

    if self.ExplosionSound then
        self:EmitSound(self.ExplosionSound)
    end

    self:Remove()
end
