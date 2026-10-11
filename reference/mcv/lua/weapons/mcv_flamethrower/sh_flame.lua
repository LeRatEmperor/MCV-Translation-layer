function SWEP:GetPrecacheParticles()
    return {self.FlameParticle, self.PilotParticle, "Vietnam_Explosion_Flamethrower_BackPack"}
end

function SWEP:GetHUDAmmo()
    return self:Ammo1(), nil
end

function SWEP:GetFiremodeName()
    return "Fuel"
end

// fuel lives in the reserve; nothing to reload
function SWEP:Reload()
    local owner = self:GetOwner()
    if owner:KeyPressed(IN_RELOAD) and owner:KeyDown(IN_USE) then
        self:ChangeFiremode()
    end
end

function SWEP:Think_Reload() end

function SWEP:IsFlaming()
    return self:GetPrimedAttack()
end

function SWEP:StartFlame()
    self:SetPrimedAttack(true)
    self:SetLastTriggerTime(CurTime())
    self:PlayAnimation(ACT_VM_PRIMARYATTACK, 1, false, true)
    self:EmitSound(self.SoundFireStart)
    self:EmitSound(self.SoundFireLoop)
end

function SWEP:StopFlame()
    if !self:IsFlaming() then return end
    self:SetPrimedAttack(false)
    self:StopSound(self.SoundFireLoop)
    self:EmitSound(self.SoundFireStop)
    if self:HasAnimation(ACT_VM_RECOIL1) then
        self:PlayAnimation(ACT_VM_RECOIL1, 1, false)
    else
        self:SetNextIdle(CurTime())
    end
end

// One tick of fire: a hull trace along the stream, damage and ignition on what it reaches.
function SWEP:FlameTick()
    local owner = self:GetOwner()
    self:TakeRound(self.FuelPerTick)
    self:SetNextPrimaryFire(CurTime() + 60 / self.FireRate)

    if CLIENT then return end

    local src = owner:GetShootPos()
    local dir = self:GetAimVector()
    local hull = self.FlameHull
    local hit = {}

    // a few staggered hull traces so the whole stream width burns
    for i = 0, 2 do
        local off = (i - 1) * hull * 0.8
        local right = self:GetAimAngle():Right() * off
        local tr = util.TraceHull({
            start = src + right,
            endpos = src + right + dir * self.FlameRange,
            filter = owner,
            mask = MASK_SHOT_HULL,
            mins = Vector(-hull, -hull, -hull),
            maxs = Vector(hull, hull, hull),
        })
        local ent = tr.Entity
        if IsValid(ent) and !hit[ent] then
            hit[ent] = true
            local dmg = DamageInfo()
            dmg:SetDamage(self.DamageGeneric)
            dmg:SetDamageType(DMG_BURN)
            dmg:SetAttacker(owner)
            dmg:SetInflictor(self)
            dmg:SetDamagePosition(tr.HitPos)
            dmg:SetDamageForce(dir * 200)
            ent:TakeDamageInfo(dmg)
            MCV.Burn(ent, self.IgniteTime, owner, self, self.BurnDamagePerSecond)
        end
    end

    // things standing in the cloud where the stream lands also catch fire
    local tr = util.TraceLine({start = src, endpos = src + dir * self.FlameRange, filter = owner, mask = MASK_SHOT})
    for _, ent in ipairs(ents.FindInSphere(tr.HitPos, hull * 3)) do
        if !hit[ent] and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()) and ent != owner then
            hit[ent] = true
            local dmg = DamageInfo()
            dmg:SetDamage(self.DamageGeneric * 0.5)
            dmg:SetDamageType(DMG_BURN)
            dmg:SetAttacker(owner)
            dmg:SetInflictor(self)
            ent:TakeDamageInfo(dmg)
            MCV.Burn(ent, self.IgniteTime * 0.5, owner, self, self.BurnDamagePerSecond)
        end
    end
end

function SWEP:PrimaryAttack()
    // handled in ThinkWeapon so the stream starts and stops with the key
end

function SWEP:ThinkWeapon()
    local owner = self:GetOwner()

    self:Think_Sights()

    local wants = owner:KeyDown(IN_ATTACK) and !owner:KeyDown(IN_USE) and self:GetRoundsLeft() > 0
        and self:GetAnimLockTime() <= CurTime() and self:GetHolsterTime() == 0 and !self:GetIsSprinting()

    if wants and !self:IsFlaming() then
        self:StartFlame()
    elseif !wants and self:IsFlaming() then
        self:StopFlame()
    end

    if self:IsFlaming() and self:GetNextPrimaryFire() <= CurTime() then
        self:FlameTick()
        self:SetLastRecoilTime(CurTime())
    end

    if owner:KeyPressed(IN_ATTACK) and owner:KeyDown(IN_USE) and !self:StillWaiting() then
        self:Bash()
        self:SetNextPrimaryFire(CurTime() + 0.6)
    end
end

function SWEP:Holster(wep)
    if self:IsFlaming() then
        self:StopFlame()
    end
    // Not self.BaseClass: for an LPO-50 (Base = mcv_flamethrower) that is this very class, so
    // the tail call looped forever and froze the game on every weapon switch after firing.
    return baseclass.Get("mcv_base").Holster(self, wep)
end

function SWEP:OnRemove()
    if CLIENT then self:StopFlameEffect() self:RemoveWorldModels() end
    self:StopSound(self.SoundFireLoop)
end

if CLIENT then
    // Hold the expanded gap for the stream, independent of its damage ticks.
    // The shared HUD smoothly opens/closes it when flaming starts/stops.
    function SWEP:GetCrosshairKick()
        return self:IsFlaming() and 1 or 0
    end

    // The stream is a particle system attached to the muzzle attachment: the viewmodel for
    // the player holding it, the world model for everyone else.
    function SWEP:FlameEmitter()
        local owner = self:GetOwner()
        if owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
            return owner:GetViewModel()
        end
        return self:GetWorldModelFor(false)
    end

    function SWEP:StartFlameEffect()
        self:StopFlameEffect()
        local ent = self:FlameEmitter()
        if !IsValid(ent) then return end
        local att = MCV.CachedAttachment(ent, self.FlameAttachment or "muzzle")
        if att <= 0 then att = 1 end
        local ps = CreateParticleSystem(ent, self.FlameParticle, PATTACH_POINT_FOLLOW, att)
        local owner = self:GetOwner()
        if IsValid(ps) and owner == LocalPlayer() and !owner:ShouldDrawLocalPlayer() then
            // viewmodel particles are drawn from PostDrawViewModel; the jet reaches into the
            // world, so it keeps the world's projection rather than the viewmodel's
            ps:StartEmission()
            ps:SetShouldDraw(false)
            table.insert(self.PCFs, ps)
            self.WorldPCFs = self.WorldPCFs or {}
            self.WorldPCFs[ps] = true // a particle handle cannot carry a field of its own
        end
        self.FlamePS = ps
        self.FlamePSEnt = ent
    end

    function SWEP:StopFlameEffect()
        if IsValid(self.FlamePS) then
            self.FlamePS:StopEmission(false, false, true)
        end
        self.FlamePS = nil
        self.FlamePSEnt = nil
    end

    // The game's stream systems aim at control point 1 (where the fuel lands); keep it on the
    // surface the player is pointing at, every frame, for both the viewmodel and world streams.
    function SWEP:UpdateFlameControlPoints()
        local ps = self.FlamePS
        if !IsValid(ps) then return end
        local owner = self:GetOwner()
        if !IsValid(owner) then return end
        local src = owner:GetShootPos()
        local dir = owner:GetAimVector()
        local target = src + dir * self.FlameRange
        local request = self.FlameVisualTrace
        if !request then request = {mask = MASK_SHOT} self.FlameVisualTrace = request end
        request.start, request.endpos, request.filter = src, target, owner
        local tr = util.TraceLine(request)
        ps:SetControlPoint(1, tr.HitPos)
        // Looking straight at a surface makes dir parallel to its normal. The
        // old cross product then had zero length, an invalid particle matrix.
        local basis = (tr.Hit and tr.HitNormal or -dir):Angle()
        ps:SetControlPointOrientation(1, basis:Forward(), basis:Right(), basis:Up())
        ps:SetControlPoint(2, target)
    end

    function SWEP:PreDrawViewModelWeapon(vm)
        self.RenderingRTScope = false
        if self:GetHolsterTime() < CurTime() then
            self:DoRTScope()
        end
        self:UpdateMuzzleLight(vm)
        self:Think_ClientFlame()
        self:UpdateFlameControlPoints()
    end

    // The stream follows the networked flag: Think does not run on the client in singleplayer
    // and other players' weapons never think here, so this is the one place that starts and
    // stops the client effect for everyone.
    function SWEP:Think_ClientFlame()
        local owner = self:GetOwner()
        local flaming = !self:IsDormant() and IsValid(owner) and !owner:IsDormant()
            and self:IsFlaming() and owner:GetActiveWeapon() == self
        if flaming and IsValid(self.FlamePS) and self.FlamePSEnt != self:FlameEmitter() then
            self:StopFlameEffect()
        end
        if flaming and !IsValid(self.FlamePS) then
            self:StartFlameEffect()
        elseif !flaming and IsValid(self.FlamePS) then
            self:StopFlameEffect()
        end
    end

    function SWEP:DrawWorldModel()
        MCV.WeaponCommon.DrawWorldModel(self)
        self:Think_ClientFlame()
        if self:GetOwner() != LocalPlayer() then self:UpdateFlameControlPoints() end
    end
end

// The tank on the back: a burst hits the wearer's back and the pack goes up.
if SERVER then
    hook.Add("EntityTakeDamage", "MCV_FlamethrowerTank", function(ent, dmginfo)
        if !ent:IsPlayer() then return end
        local wep = ent:GetActiveWeapon()
        if !IsValid(wep) or !wep.TankExplodes or !wep.MilitaryConflictVietnam then return end
        if !dmginfo:IsBulletDamage() then return end
        if (wep.NextTankCheck or 0) > CurTime() then return end
        wep.NextTankCheck = CurTime() + 0.1

        // shot from behind, into the pack
        local from = dmginfo:GetDamagePosition()
        local back = -ent:GetAimVector()
        back.z = 0
        if (from - ent:GetPos()):GetNormalized():Dot(back) < 0.55 then return end
        if math.random() > 0.35 then return end

        local pos = ent:GetPos() + Vector(0, 0, 48) + back * 10
        ParticleEffect("Vietnam_Explosion_Flamethrower_BackPack", pos, angle_zero)
        util.BlastDamage(wep, dmginfo:GetAttacker(), pos, wep.TankExplosionRadius, wep.TankExplosionDamage)
        ent:EmitSound("MCV_BaseGrenade.Explode")
        MCV.Burn(ent, 10, dmginfo:GetAttacker(), wep, wep.BurnDamagePerSecond)
        ent:SetAmmo(0, wep:GetPrimaryAmmoType())
    end)
end

function SWEP:GetControlHints()
    return {
        {"hold:+attack", "Flame"},
        {"+attack2", "Aim"},
        {"+use +attack", "Bash"},
    }
end
