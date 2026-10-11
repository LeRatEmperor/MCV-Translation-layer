// GetModel's Lua-facing name can survive a viewmodel change or prediction restore.
// Gameplay metadata follows the weapon's predicted mode, not that cached name.
local function animationModel(self)
    return self:GetAkimbo() and self.ViewModelAkimbo or (self.SingleViewModel or self.ViewModel)
end

function SWEP:PrimaryAttack()
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then return self:NPC_PrimaryAttack() end
    if self:StillWaiting() then return end
    if self:GetNeedCycle() then return end

    if self:GetSafe() then self:ToggleSafe(true) return end

    local owner = self:GetOwner()
    local bursting = self:IsBursting() // a runaway burst finishing itself (ThinkWeapon)

    // bash with USE + fire; not while deployed on the bipod (the PTRD can bash undeployed
    // even though it only fires deployed)
    if owner:KeyDown(IN_USE) and !bursting then
        if !self:GetBipod() and owner:KeyPressed(IN_ATTACK) then
            self:Bash()
        end
        return
    end

    // Sprinting on the trigger with a bayonet fixed: charge, the same input the melee weapons
    // take it on. A gun will not fire at a sprint anyway, so nothing else wants this. Once the
    // charge is up the think loop owns the weapon until it lands or the player lets go.
    if self:IsBayonetCharging() then return end

    if self:GetIsSprinting() and self:GetBayonet() then
        self:StartBayonetCharge()
        return
    end

    if self.MustBipod and !self:GetBipod() then return end

    if self:GetGrenadeLauncher() then
        self:RifleGrenadeAttack()
        return
    end

    if self:Clip1() < 1 then
        self:SetBurstCount(0)
        self:Reload()
        return
    end
    if self:GetSpeed() > 150 and !bursting then return end

    if self:GetNeedTriggerPress() and !bursting then self:SetBurstCount(0) return end

    local fm = self:GetFiremodeValue()
    local fmmult = 1

    // three-round burst: a fresh pull starts counting from this round; ThinkWeapon fires the
    // rest off BurstCount whether the trigger is held or not
    if fm == MCV.FIREMODE_BURST and !bursting then
        self:SetBurstCount(0)
    end

    if self:GetAkimbo() then
        fmmult = 0.5
    end

    local t = 0
    local rate = self.ShootAnimRate

    if self:GetAkimbo() then
        if fm == MCV.FIREMODE_VOLLEY and self:Clip1() >= self.VolleyCount then
            t = self:PlayAnimation(ACT_VM_RECOIL1, rate)
        elseif fm == MCV.FIREMODE_DA then
            // pulling the trigger cocks the hammer of the hand that is up next (right on an even
            // count: prepare_delayed_right is ACT_VM_HAULBACK, _left is ACT_VM_PULLPIN); the shot
            // itself (shoot_delayed_*, ACT_VM_PRIMARYATTACK_2 / _3) plays on release in ThinkWeapon
            if self:Clip1() % 2 == 0 then
                t = self:PlayAnimation(ACT_VM_HAULBACK, rate, true)
            else
                t = self:PlayAnimation(ACT_VM_PULLPIN, rate, true)
            end
        else
            local right = self:Clip1() % 2 == 0

            if self.LastShotAnimation and self:Clip1() == 1 then
                t = self:PlayAnimation(ACT_VM_SHOOTLAST, rate)
            elseif self.LastShotAnimation and self:Clip1() == 2 then
                t = self:PlayAnimation(ACT_VM_PRIMARYATTACK_EMPTY, rate)
            elseif self:HasPoseRecoil() then
                // Pose-driven recoil: no sequence change, the hand's recoil layer is scrubbed
                // from DoBodygroups. See work/PORTING.md.
                if right then
                    self:SetLastShotTimeR(CurTime())
                else
                    self:SetLastShotTimeL(CurTime())
                end
                t = self.AkimboRecoilTime
            elseif right then
                t = self:PlayAnimation(ACT_VM_PRIMARYATTACK, rate)
            else
                t = self:PlayAnimation(ACT_VM_SECONDARYATTACK, rate)
            end
        end
    else
        if fm == MCV.FIREMODE_VOLLEY and self:Clip1() >= self.VolleyCount then
            t = self:PlayAnimation(ACT_VM_RECOIL1, rate)
        elseif fm == MCV.FIREMODE_DA then
            t = self:PlayAnimation(ACT_VM_HAULBACK, rate, true)
        elseif fm == MCV.FIREMODE_FAN then
            t = self:PlayAnimation(ACT_VM_PRIMARYATTACK_1, rate, false)
        else
            if self.LastShotAnimation and self:Clip1() == 1 then
                t = self:PlayAnimation(ACT_VM_SHOOTLAST, rate)
            else
                if self:GetBipod() then
                    t = self:PlayAnimation(ACT_VM_PRIMARYATTACK_DEPLOYED, rate)
                else
                    t = self:PlayAnimation(ACT_VM_PRIMARYATTACK, rate)
                end
            end
        end
    end

    if fm == MCV.FIREMODE_BURST then
        t = 60 / (self.FireRate * 1.25)
    end

    // PlayAnimation returns nothing when the model lacks the activity; never let that stall
    // or error the fire loop
    t = t or (60 / self.FireRate)

    if fm == MCV.FIREMODE_SA then
        if self:GetAkimbo() then
            self:SetNextPrimaryFire(CurTime() + t * 0.4)
        else
            self:SetNextPrimaryFire(CurTime() + t * 0.8)
        end
    else
        self:SetNextPrimaryFire(CurTime() + (60 / self:GetFiremodeRate(fm)) * fmmult)
    end

    if fm != MCV.FIREMODE_DA then
        if self:GetProjectileClass() then
            self:RocketAttack()
        else
            self:BulletAttack()
        end
        self:AttackEffects()
    else
        self:SetLastTriggerTime(CurTime())
        self:SetPrimedAttack(true)
    end

    local firemode = self:GetFiremodeValue()

    if firemode == MCV.FIREMODE_SEMI or firemode == MCV.FIREMODE_SA or firemode == MCV.FIREMODE_DA
        or firemode == MCV.FIREMODE_HE or firemode == MCV.FIREMODE_BUCKSHOT then
        self:SetNeedTriggerPress(true)
    end

    if firemode == MCV.FIREMODE_BURST and self:GetBurstCount() >= self.BurstRounds then
        // burst over: a short recovery, and a pull still held has to be let go first (a
        // trigger released mid-burst already counts as let go)
        self:SetNextPrimaryFire(self:GetNextPrimaryFire() + self.BurstRecovery)
        if owner:KeyDown(IN_ATTACK) then
            self:SetNeedTriggerPress(true)
        end
    end

    if self.PlayCycleAnimation and self:Clip1() > 0 then
        self:SetNeedCycle(true)
    end
end

// True when the current viewmodel was compiled with the recoil_r / recoil_l pose parameters
// (port_qc.py --pose-recoil) and the weapon opts in with AkimboPoseRecoil.
function SWEP:HasPoseRecoil()
    if !self.AkimboPoseRecoil then return false end

    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return false end

    local vm = owner:GetViewModel()
    if !IsValid(vm) then return false end

    local model = animationModel(self)

    if self.PoseRecoilModel != model then
        self.PoseRecoilModel = model
        self.PoseRecoilAvailable = false

        for i = 0, vm:GetNumPoseParameters() - 1 do
            if vm:GetPoseParameterName(i) == "recoil_r" then
                self.PoseRecoilAvailable = true
                break
            end
        end
    end

    return self.PoseRecoilAvailable
end

function SWEP:FireAnimationEvent( pos, ang, event, name )
    if (name == "eject" or name == "eject2") and IsFirstTimePredicted() then
        self:DoEject(name)
    end
end

// Animation events run on render/animation clocks and are not replayable gameplay input.
// Use the event cycles extracted from the compiled model to schedule the same transition
// from the predicted animation start instead.
function SWEP:ScheduleHammerRelease(vm, seq, duration, reverse)
    local model = MCV.HammerEvents and MCV.HammerEvents[string.lower(animationModel(self))]
    local events = model and model[string.lower(vm:GetSequenceName(seq))]
    local cycle = events and events[self.InvertAnimationHammer and 0 or 1]
    self:SetHammerReleaseTime(cycle and (CurTime() + duration * (reverse and 1 - cycle or cycle)) or 0)
end

function SWEP:Think_HammerRelease()
    local at = self:GetHammerReleaseTime()
    if at == 0 or CurTime() < at then return end
    self:SetHammerReleaseTime(0)
    self:SetNeedCycle(false)
    self:SetEmptyReload(false)
end

// How far the stance opens the gun up: the game's own multipliers (the weapon script's
// StandMoveSpreadMultiplier & co), blended by how fast the owner is moving. 1 is standing
// still, above 1 is moving or in the air, below 1 is crouched. Both models of inaccuracy read
// it, so a run or a jump throws the shot wider whichever one is on, and the crosshair grows
// with it because the crosshair is drawn from the same two numbers.
function SWEP:GetStanceSpreadMultiplier()
    local owner = self:GetOwner()
    if !IsValid(owner) then return 1 end

    local speed, grounded, crouched = self:GetWeaponMovement()
    local move = math.min(speed / 273, 1)

    if !grounded then
        return Lerp(move, 1, self.JumpSpreadMultiplier)
    elseif crouched then
        return Lerp(move, self.CrouchSpreadMultiplier, self.CrouchMoveSpreadMultiplier)
    end
    return Lerp(move, 1, self.StandMoveSpreadMultiplier)
end

if CLIENT then
    // Visual copy of the stance multiplier, advanced once per rendered frame toward the real
    // one, the way the sight blend is (sh_sights.lua). The gameplay value steps: leaving the
    // ground swaps a 1 for the jump multiplier inside one tick, and the drawn barrel drift
    // jumps with it. Only what is drawn is eased. The shot still leaves along the real value,
    // so the two differ for a fraction of a second after a stance changes.
    SWEP.StanceSmoothRate = 6      // multiplier a second: the default jump, 1 to 3, in a third of one
    SWEP.StanceResyncThreshold = 4 // further apart than that and it snaps instead of crawling

    function SWEP:GetStanceSpreadMultiplierVisual()
        if GetPredictionPlayer() == self:GetOwner() then
            return self.VisualStance or self:GetStanceSpreadMultiplier()
        end
        local frame = FrameNumber()
        if self.VisualStanceFrame == frame then return self.VisualStance end

        local target = self:GetStanceSpreadMultiplier()
        local cur = self.VisualStance
        if cur == nil or math.abs(cur - target) > self.StanceResyncThreshold then
            cur = target
        end

        self.VisualStance = math.Approach(cur, target, self.StanceSmoothRate * FrameTime())
        self.VisualStanceFrame = frame

        return self.VisualStance
    end
else
    SWEP.GetStanceSpreadMultiplierVisual = SWEP.GetStanceSpreadMultiplier
end

// Realistic mode (mcv_realistic_shooting 1): hip fire is barrel-accurate, so the inaccuracy is
// the barrel wandering off the screen centre. A slow two-tone drift in pitch and yaw with a peak
// of HipSwayScale times the gun's hip spread (degrees), halved on shotguns, scaled by the
// stance and damped to nothing by the sight amount. Deterministic in CurTime, so client and
// server agree; `visual` uses the frame-smoothed sight amount for drawing.
SWEP.HipSwayScale = 0.25

// How much of the sway is in play. A deployed bipod rests the gun on something and a reload is
// not aiming at anything, so the barrel does not wander in either; both are networked, so the
// shot reads the same answer on both realms.
function SWEP:GetSwaySteady()
    return (self:GetBipod() or self:GetReloading()) and 0 or 1
end

if CLIENT then
    // and what is drawn eases between the two, the way the stance multiplier and the sight
    // blend do, so the gun and the crosshair settle instead of snapping. The shot still leaves
    // along the real value, so the two differ for a fraction of a second either side.
    SWEP.SwaySteadyRate = 4   // a second: a quarter of one to go either way

    function SWEP:GetSwaySteadyVisual()
        if GetPredictionPlayer() == self:GetOwner() then
            return self.VisualSteady or self:GetSwaySteady()
        end
        local frame = FrameNumber()
        if self.VisualSteadyFrame == frame then return self.VisualSteady end

        local target = self:GetSwaySteady()
        local cur = self.VisualSteady
        if cur == nil then cur = target end

        self.VisualSteady = math.Approach(cur, target, self.SwaySteadyRate * FrameTime())
        self.VisualSteadyFrame = frame

        return self.VisualSteady
    end
else
    SWEP.GetSwaySteadyVisual = SWEP.GetSwaySteady
end

// peak of the sway in degrees (each axis), 0 when the mode is off or the sights are up
function SWEP:GetAimSwayAmplitude(visual)
    if !MCV.RealisticShooting() then return 0 end

    local steady = visual and self:GetSwaySteadyVisual() or self:GetSwaySteady()
    if steady <= 0 then return 0 end

    local sa = visual and self:GetSightAmountVisual() or self:GetSightAmount()
    local amp = (self.Spread or 0) * self:StatMult("spread") * self.HipSwayScale * (1 - sa)
    if self:GetBulletCount() > 1 then amp = amp * 0.5 end // shotguns
    // the stance swings the barrel the way it opens the game's cone: a jump or a run widens
    // the drift, a crouch steadies it. This mode has no cone to grow, so the sway is what the
    // crosshair reads to show the stance. What is drawn eases between stances; the shot reads
    // the real multiplier
    local stance = visual and self:GetStanceSpreadMultiplierVisual() or self:GetStanceSpreadMultiplier()
    return amp * stance * steady
end

function SWEP:GetAimSway(visual)
    local amp = self:GetAimSwayAmplitude(visual)
    if amp <= 0.0001 then return angle_zero end
    local t = CurTime() + self:EntIndex() * 7.3
    local p = (math.sin(t * 1.1) * 0.6 + math.sin(t * 2.3 + 1.7) * 0.4) * amp
    local y = (math.sin(t * 0.8 + 0.9) * 0.6 + math.sin(t * 1.9 + 3.1) * 0.4) * amp
    return Angle(p, y, 0)
end

// The direction a shot leaves along: eye angles, twice the view punch the recoil put on the gun,
// and the hip sway. Bullets, projectiles, the crosshair, the scope reticle and the viewmodel all
// read this.
function SWEP:GetAimAngle(visual)
    local owner = self:GetOwner()
    if owner:IsNPC() then return owner:GetAimVector():Angle() end
    if !MCV.RealisticShooting() then
        // the game: the shot goes where the view points. The camera carries the whole punch
        // (cl_camera.lua takes none of it out in this mode), so this is the screen centre
        return owner:EyeAngles() + owner:GetViewPunchAngles()
    end
    return owner:EyeAngles() + owner:GetViewPunchAngles() * 2 + self:GetAimSway(visual)
end

function SWEP:GetAimVector(visual)
    return self:GetAimAngle(visual):Forward()
end

function SWEP:GetSpread()
    if self:GetOwner():IsNPC() then return self:GetNPCSpread() end
    local sa = self:GetSightAmount()
    local fm = self:GetFiremodeValue()
    local spread = self.Spread
    local sighted = self.SpreadIronsighted

    // a deployed bipod uses the game's bipod spreads (BulletSpreadDegreesBipod*)
    if self:GetBipod() and self.SpreadBipod then
        spread = self.SpreadBipod
        sighted = self.SpreadBipodIronsighted or self.SpreadBipod
    end

    spread = spread * self:StatMult("spread")
    sighted = sighted * self:StatMult("spread_sights")

    local stance = self:GetStanceSpreadMultiplier()

    if MCV.RealisticShooting() then
        // realistic (mcv_realistic_shooting 1): the bullet leaves the barrel wherever it points.
        // Hip fire misses because the gun is not lined up with the eye, not through a cone, so
        // the gun's own dispersion is all there is from the hip, and on the sights a rifle or
        // pistol reduces dispersion to a quarter. Shotguns and volley fire keep their
        // pattern whatever the sight amount or stance.
        if self:GetBulletCount() > 1 or fm == MCV.FIREMODE_VOLLEY then
            spread = sighted
        else
            spread = sighted * Lerp(sa, 1, 0.25)
        end
    else
        // the game: a hip fire cone that narrows to the sighted spread as the sights come up,
        // widened by stance and movement
        spread = Lerp(sa, spread, sighted) * stance
    end

    if fm == MCV.FIREMODE_SA then
        spread = spread * 0.5
    elseif fm == MCV.FIREMODE_DA then
        spread = spread * 0.75
    end

    return spread / 100
end

function SWEP:AttackEffects()
    local owner = self:GetOwner()

    local recoilmult = 1

    local fm = self:GetFiremodeValue()

    if fm == MCV.FIREMODE_VOLLEY then
        recoilmult = math.min(self:Clip1(), self.VolleyCount)
    end

    if self:GetAkimbo() then
        recoilmult = recoilmult * 1.25
    end

    if self:GetBipod() then
        recoilmult = recoilmult * 0.25 // Bipod absorbs 75% of recoil.
    end

    recoilmult = recoilmult * self:StatMult("recoil")

    self:SetLastRecoilTime(CurTime())

    local sa = self:GetSightAmount()
    // BurstCount is the predicted number of earlier shots, incremented below.
    // Read it on every replay; never accumulate recoil in an ordinary Lua field.
    local preceding = self:GetBurstCount()
    local recoilup = (Lerp(sa, self.ViewSlideRecoilUp, self.ViewSlideRecoilIronsightUp)
        + preceding * (self.ProgressiveRecoilUp or 0)) * recoilmult
    local recoilright = (Lerp(sa, self.ViewSlideRecoilRight, self.ViewSlideRecoilIronsightRight)
        + preceding * (self.ProgressiveRecoilRight or 0)) * recoilmult

    if MCV.RealisticShooting() then
        // realistic: from the hip the gun jumps in a random direction and harder; on the sights
        // it climbs by the script's slide. CalcView takes most of the punch back out of the
        // view so the kick moves the aim more than the picture.
        owner:ViewPunch((1 - (sa * 0.5)) * Angle(((sa * recoilup) + ((1 - sa) * recoilright)) * (-sa + (util.SharedRandom("MCVRecoilUpDown", -1, 1) * (util.SharedRandom("MCVRecoilUpDown", 0.5, 1) - sa))), recoilright * util.SharedRandom("MCVRecoilLeftRight", -1, 1), 0))
    else
        // the game's fixed view slide: up by ViewSlideRecoil.Up, sideways by .Right (side at
        // random), the ironsight pair when aiming
        owner:ViewPunch(Angle(-recoilup, recoilright * util.SharedRandom("MCVRecoilLeftRight", -1, 1), 0))
    end

    if IsFirstTimePredicted() then
        if !self.NoEjectOnShoot then
            self:DoEject()
        end
        self:DoMuzzle()
    end

    owner:DoAnimationEvent(self:GetShootGesture())

    self:SetBurstCount(self:GetBurstCount() + 1)

    if fm == MCV.FIREMODE_VOLLEY then
        self:TakePrimaryAmmo(math.min(self:Clip1(), self.VolleyCount))
    else
        self:TakePrimaryAmmo(1)
    end

    if fm == MCV.FIREMODE_VOLLEY and self:Clip1() > 1 then
        self:EmitShotSound(self.SoundDoubleShot)
    else
        self:EmitShotSound(self.SoundSingleShot)
    end

    local clip_percentage = self:Clip1() / self.Primary.ClipSize

    // if clip_percentage < 0.334 then
    //     self:EmitSound(self.SoundNearlyEmpty, 100, 100, 1 - (clip_percentage * 3), CHAN_VOICE)
    // end

    self:QueueRecoilImpulse(self.RecoilPushbackValue)
end

// The game records every weapon twice: the report from where the shot is fired, and the same
// shot heard from a long way off. The second recording is named for the first with "Distant" on
// the end, and 192 of the 199 weapons have one. Worked out once per sound name rather than
// written into every weapon file, and remembered so the lookup happens once.
local distant_of = {}

local function distantShot(near)
    local found = distant_of[near]

    if found == nil then
        local name = near .. "Distant"
        // only when the soundscript is really there: seven weapons have no distant recording
        // (the Uzi family, the SOG Sterling, the Vz.23) and asking for one logs a warning
        found = sound.GetProperties and sound.GetProperties(name) != nil and name or false
        distant_of[near] = found
    end

    return found or nil
end

// A shot is two recordings, not two audiences: the near report and the same shot heard from a
// long way off. Both go to everyone and their soundlevels do the separating, the near one at 100
// dying off within a stone's throw and the far one at 125 still there well beyond it. Close up
// you hear the report with the far layer filling in underneath; further out only the far layer
// is left. Splitting the listeners by distance instead meant the far recording only reached
// someone already standing far away, and never the shooter.
local function pickShotValue(value, fallback, key, discrete, predicted, name)
    if !istable(value) then return value or fallback end
    local lo, hi = discrete and 1 or value[1], discrete and (#value + 1) or value[2]
    local n
    if predicted then
        n = util.SharedRandom("MCVShotSound:" .. name .. ":" .. key, lo, hi)
    else
        n = math.Rand(lo, hi)
    end
    return discrete and value[math.Clamp(math.floor(n), 1, #value)] or n
end

local function emitShotLayer(wep, name, channel)
    local props = sound.GetProperties(name)
    if !props then
        wep:EmitSound(name, nil, nil, nil, channel)
        return
    end

    // Resolve the script: Entity:EmitSound can ignore channel/volume overrides
    // on script names. Raw samples make each layer's replacement channel explicit.
    // Each layer rotates through a fixed channel pool: preserve adjacent reports,
    // but never stack all of their long tails on CHAN_STATIC.
    local predicted = false
    if istable(props.sound) or istable(props.volume) or istable(props.pitch) then
        local owner = wep:GetOwner()
        predicted = IsValid(owner) and owner:IsPlayer()
    end
    local sample = pickShotValue(props.sound, name, "sample", true, predicted, name)
    local volume = pickShotValue(props.volume, 1, "volume", false, predicted, name)
    local pitch = math.Round(pickShotValue(props.pitch, 100, "pitch", false, predicted, name))
    wep:EmitSound(sample, props.level or 75, pitch, volume, channel)
end

function SWEP:EmitShotSound(name)
    if !IsFirstTimePredicted() or (name or "") == "" then return end

    // Cosmetic only, advanced after the replay guard. Do not derive this from
    // BurstCount: release/repress resets it and would cut off two quick taps.
    local slot = self.MCVShotSoundSlot or 0
    self.MCVShotSoundSlot = (slot + 1) % MCV.SHOT_SOUND_SLOTS
    emitShotLayer(self, name, MCV.CHAN_SHOT + slot)

    local far = distantShot(name)
    if far then
        emitShotLayer(self, far, MCV.CHAN_SHOT_DISTANT + slot)
    end
end

// Rounds per minute for the firemode in hand. A revolver fans and pulls double action at
// their own rates (the game's tertiary and secondary); everything else fires at FireRate.
function SWEP:GetFiremodeRate(fm)
    local rate = self.FireRate

    if fm == MCV.FIREMODE_FAN and (self.FireRate_Fan or 0) > 0 then
        rate = self.FireRate_Fan
    elseif fm == MCV.FIREMODE_DA and (self.FireRate_DA or 0) > 0 then
        rate = self.FireRate_DA
    elseif fm == MCV.FIREMODE_FAST and (self.FireRate_Fast or 0) > 0 then
        rate = self.FireRate_Fast
    elseif fm == MCV.FIREMODE_SLOW and (self.FireRate_Slow or 0) > 0 then
        rate = self.FireRate_Slow
    end

    return math.max(rate * self:StatMult("firerate"), 1)
end

function SWEP:BulletAttack(shootPos, shootDir)
    local owner = self:GetOwner()

    if MCV.PhysicalBulletsEnabled(self) then
        if SERVER then MCV.LaunchPhysicalBullets(self, shootPos, shootDir) end
        if CLIENT and (game.SinglePlayer() or IsFirstTimePredicted()) then
            MCV.PredictPhysicalBullets(self, shootPos, shootDir)
        end
        return
    end

    // Ammo/recoil are updated by the caller on every prediction pass. These
    // client traces exist only for presentation; never replay their effects.
    if CLIENT and (game.SinglePlayer() or !IsFirstTimePredicted()) then return end

    local spread = self:GetSpread()

    if owner:IsPlayer() then owner:LagCompensation(true) end

    local num = self:GetBulletCount()

    if self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY then
        num = num * math.min(self:Clip1(), self.VolleyCount)
    end

    local queue = {}
    local function fireSegment(state, count, cone, tracer)
        if state.exitTrace then
            MCV.HitscanEffects(self, state.exitTrace, state.exitDamage, 0, true)
        end
        owner:FireBullets({
            Damage = state.damage,
            Num = count,
            Src = state.src,
            Dir = state.dir,
            Spread = cone,
            Distance = 56756 - state.distance,
            Attacker = owner,
            Inflictor = self,
            Tracer = 0,
            TracerName = "mcv_tracer",
            Callback = function(attacker, tr, dmginfo)
                local distance = state.distance + (tr.HitPos - tr.StartPos):Length()
                self:ApplyBulletDamage(tr, dmginfo, distance)
                local queued = #queue
                self:QueuePenetration(tr, state, queue)
                MCV.HitscanEffects(self, tr, dmginfo:GetDamage(), tracer, #queue > queued)
                return {effects = false}
            end
        })
    end
    fireSegment({src = shootPos or owner:GetShootPos(), dir = shootDir or self:GetAimVector(),
        damage = self.DamageGeneric * self:StatMult("damage"), distance = 0, budget = 1, layers = 0},
        num, Vector(spread, spread, spread), 1)

    // Finish each FireBullets call before firing its continuations, so nested
    // engine multi-damage accumulation cannot apply a target's damage twice.
    // Client continuations predict effects too; server traces stay inside the
    // original shot's lag-compensation window.
    do
        local index = 1
        while queue[index] do
            fireSegment(queue[index], 1, vector_origin, 0)
            index = index + 1
        end
    end

    if owner:IsPlayer() then owner:LagCompensation(false) end
end

function SWEP:RocketAttack(secondary, shootPos, shootDir)
    if CLIENT then return end

    local count = 1

    if !secondary and self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY then
        // every rocket left in the clip leaves at once, each with its own spread
        count = math.max(1, math.min(self:Clip1(), self.VolleyCount))
    end

    for i = 1, count do
        self:LaunchProjectile(secondary, i, shootPos, shootDir)
    end
end

function SWEP:LaunchProjectile(secondary, seed, shootPos, shootDir)
    local owner = self:GetOwner()
    local spread = self:RandomSpread(self:GetSpread(), seed)

    local src = shootPos or owner:GetShootPos()
    local dir = (shootDir and shootDir:Angle() or self:GetAimAngle()) + spread

    local ent = self:GetProjectileClass()
    local force = self.ShootEntityForce

    if secondary then
        ent = self.RifleGrenadeEntity
        force = self.RifleGrenadeForce
    end

    local rocket = ents.Create(ent)
    if !IsValid(rocket) then return end

    // The weapon owns the blast: its own numbers where it has them, the projectile's own as
    // the fallback, and the category multipliers over the top. A rifle grenade and an
    // underbarrel round answer to their own category rather than the rifle carrying them.
    local category = secondary and MCV.CATEGORY_RIFLE_GRENADE or nil
    local dmg = (self.ExplosionDamage or 0) > 0 and self.ExplosionDamage or rocket.ExplosionDamage
    local radius = (self.ExplosionRadius or 0) > 0 and self.ExplosionRadius or rocket.ExplosionRadius

    if dmg then rocket.ExplosionDamage = dmg * self:StatMult("explosion_damage", category) end
    if radius then rocket.ExplosionRadius = radius * self:StatMult("explosion_radius", category) end

    local speedmult = self:StatMult("projectile_speed", category)
    force = force * speedmult

    rocket:SetPos(src)
    rocket:SetOwner(owner)
    rocket.Inflictor = self
    rocket:SetAngles(dir)
    if isfunction(rocket.SetWeapon) then
        rocket:SetWeapon(self)
    end
    rocket:Spawn()

    // Opt-in launcher flight; rifle grenades and other projectiles keep their physics.
    if !secondary and self.RocketGravity and IsValid(rocket) then
        rocket:StartRocketFlight(dir:Forward(), force, self.RocketGravity,
            (self.RocketBoostSpeed or self.ShootEntityForce) * speedmult,
            self.RocketBoostDelay, self.RocketBoostDuration)
        return
    end

    local phys = rocket:GetPhysicsObject()

    if phys:IsValid() and force > 0 then
        phys:SetVelocityInstantaneous(dir:Forward() * force)
    end
end

function SWEP:GetFiremodeValue()
    return self.Firemodes[self:GetFiremode()]
end

// A three-round burst that has started and not finished: BurstCount is only reset once it has
// reached BurstRounds (or the trigger is pulled afresh), so the burst survives a released trigger
function SWEP:IsBursting()
    if self:GetFiremodeValue() != MCV.FIREMODE_BURST then return false end
    local n = self:GetBurstCount()
    return n > 0 and n < self.BurstRounds
end

// The game's dual models carry fewer firemodes than the single ones: the dual Blackhawk fires
// single action only, and neither dual revolver fans. Offering a mode the model cannot animate
// left the guns doing nothing at all, so a mode counts only where its animation exists.
function SWEP:FiremodeAvailable(mode)
    if mode == MCV.FIREMODE_FAN then
        return self:HasAnimation(ACT_VM_PRIMARYATTACK_1)
    elseif mode == MCV.FIREMODE_DA then
        if self:GetAkimbo() then
            // one hand each: the right gun's prepare and the left gun's
            return self:HasAnimation(ACT_VM_HAULBACK) and self:HasAnimation(ACT_VM_PULLPIN)
        end

        return self:HasAnimation(ACT_VM_HAULBACK)
    end

    return true
end

function SWEP:ChangeFiremode()
    // The rifle's selector and scope adjustment do not operate in launcher mode.
    // Preserve its selected mode and avoid interrupting the launcher animation.
    if self:GetGrenadeLauncher() then return end

    if self.AdjustableScopes then
        local scopelevel = self:GetScopeLevel()

        if scopelevel == 2 then
            self:PlayAnimation(ACT_VM_FIDGET, -1, true)
        else
            self:PlayAnimation(ACT_VM_FIDGET, 1, true)
        end

        scopelevel = scopelevel + 1

        if scopelevel > 2 then
            scopelevel = 1
        end

        self:SetScopeLevel(scopelevel)
        return
    end

    if #self.Firemodes <= 1 then return end

    self:SetBurstCount(0)

    // on to the next mode the viewmodel in hand can actually animate
    local fm = self:GetFiremode()

    for _ = 1, #self.Firemodes do
        fm = fm + 1

        if fm > #self.Firemodes then
            fm = 1
        end

        if self:FiremodeAvailable(self.Firemodes[fm]) then break end
    end

    self:SetFiremode(fm)

    local anim = ACT_VM_FIREMODE
    local mult = 1

    if fm == 1 then
        mult = -1
    end

    if self:GetBipod() then
        anim = ACT_VM_DFIREMODE
    end

    // revolvers: the game has one animation per target mode. changefiremode_towestern (fan)
    // is ACT_VM_FIREMODE, _todelayed (double action) ACT_VM_IFIREMODE, _tohammer (single
    // action) ACT_VM_DIFIREMODE; the dual models have no western
    local target = self.Firemodes[fm]
    if target == MCV.FIREMODE_FAN then
        anim = ACT_VM_FIREMODE
        mult = 1
    elseif target == MCV.FIREMODE_DA then
        anim = ACT_VM_IFIREMODE
        mult = 1
    elseif target == MCV.FIREMODE_SA then
        anim = ACT_VM_DIFIREMODE
        mult = 1
    end

    if self:HasAnimation(anim) then
        self:PlayAnimation(anim, mult, false)
    else
        self:SetAnimLockTime(CurTime() + 0.25)
        self:EmitSound("MCV_Weapon_Foley_AK47.DrawMetal")
    end

    self:GetOwner():PrintMessage(HUD_PRINTTALK, "Switched to " .. self:GetFiremodeName())
end
