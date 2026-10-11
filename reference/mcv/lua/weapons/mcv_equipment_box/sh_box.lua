SWEP.DeferredActions = {"BoxUse", "BoxDrop", "BoxEnd"}

function SWEP:GetFiremodeName()
    return self.BoxKind == "medic" and "Medic Box" or "Ammo Box"
end

function SWEP:GetHUDAmmo()
    return self:GetRoundsLeft(), nil
end

// One shared magazine-equivalent budget, not a full magazine for every carried gun.
// Ammo pools are sorted and merged so duplicate guns cannot multiply the grant.
function MCV_AmmoSupplyPlan(target, magazines, cursor)
    local pools = {}
    local function addPool(ammo, clip, definition)
        if ammo < 0 then return end
        local name = string.lower(game.GetAmmoName(ammo) or "")
        if name == "mcv_ammobox" or name == "mcv_medicbox" then return end
        clip = math.max(clip, 0)
        local per = math.max(clip, 1) // a loose grenade or rocket costs a whole share
        local starting = tonumber((definition or {}).DefaultClip)
        local cap = starting and math.max(starting - clip, per) or per
        local maximum = game.GetAmmoMax(ammo)
        if maximum and maximum > 0 then cap = math.min(cap, maximum) end
        local pool = pools[ammo] or {ammo=ammo, per=0, cap=0}
        pool.per = math.max(pool.per, per)
        pool.cap = math.max(pool.cap, cap)
        pools[ammo] = pool
    end
    for _, wep in ipairs(target:GetWeapons()) do
        if wep.BoxKind then continue end // supplies never replenish supplies
        addPool(wep:GetPrimaryAmmoType(), wep:GetMaxClip1(), wep.Primary)
        addPool(wep:GetSecondaryAmmoType(), wep:GetMaxClip2(), wep.Secondary)
    end

    local candidates = {}
    for ammo, pool in pairs(pools) do
        pool.have = target:GetAmmoCount(ammo)
        pool.amount = 0
        if pool.have < pool.cap then table.insert(candidates, pool) end
    end
    table.sort(candidates, function(a,b) return a.ammo < b.ammo end)
    local count = #candidates
    cursor = cursor or 0
    if count == 0 then return {}, cursor end
    local ordered = {}
    for i=1,count do ordered[i] = candidates[(cursor+i-1)%count+1] end
    local budget = math.max(magazines or 1, 0)

    for i, pool in ipairs(ordered) do
        local share = budget / (count-i+1)
        local amount = math.floor(pool.per * share + 1e-9)
        // Indivisible ammo gets its turn when enough of the shared budget remains.
        // Rotating the first pool lets rockets receive a full share on later uses.
        if amount == 0 and budget+1e-9 >= 1/pool.per then amount = 1 end
        pool.amount = math.min(amount, pool.cap-pool.have)
        budget = budget-pool.amount/pool.per
    end
    // Distribute affordable rounding leftovers without exceeding the total budget.
    local spent = true
    while spent do
        spent = false
        for _, pool in ipairs(ordered) do
            if pool.have+pool.amount < pool.cap and budget+1e-9 >= 1/pool.per then
                pool.amount = pool.amount+1
                budget = budget-1/pool.per
                spent = true
            end
        end
    end
    return ordered, cursor+1
end

// Returns true only when something was supplied, plus the next ammo rotation cursor.
function MCV_ApplySupply(kind, target, amount_heal, magazines, cursor)
    if !IsValid(target) or !target:IsPlayer() or !target:Alive() then return false end

    if kind == "medic" then
        if target:Health() >= target:GetMaxHealth() then return false end
        if SERVER or target == LocalPlayer() then
            target:SetHealth(math.min(target:Health() + amount_heal, target:GetMaxHealth()))
        end
        if SERVER then target:Extinguish() end
        return true
    end

    local plan, nextCursor = MCV_AmmoSupplyPlan(target, magazines, cursor)
    local gave = false
    for _, pool in ipairs(plan) do
        if pool.amount <= 0 then continue end
        if SERVER or target == LocalPlayer() then
            target:SetAmmo(pool.have+pool.amount, pool.ammo)
        end
        gave = true
    end
    return gave, gave and nextCursor or cursor
end

function SWEP:GetGiveTarget()
    local owner = self:GetOwner()
    local tr = util.TraceLine({start = owner:GetShootPos(), endpos = owner:GetShootPos() + self:GetAimVector() * self.GiveRange, filter = owner})
    if IsValid(tr.Entity) and tr.Entity:IsPlayer() and tr.Entity:Alive() then
        return tr.Entity
    end
    return nil
end

function SWEP:UseBox(target, seq, delay)
    local t = self:HasSequence(seq) and self:PlaySequence(seq, 1, true) or 0.6
    self:SetNextPrimaryFire(CurTime() + t)
    self:SetNextSecondaryFire(CurTime() + t)

    self:SetActionTarget(target)
    self:SetActionVariant(seq == self.SequenceSelf and 1 or 0)
    self:SetActionEnd(CurTime() + t)
    self:Defer("BoxUse", math.min(delay, t))
end

function SWEP:Deferred_BoxUse()
    self:Defer("BoxEnd", math.max(self:GetActionEnd() - CurTime(), 0))
    local target = self:GetActionTarget()
    if !IsValid(target) then return end
    // Existing instances acquire the new accessor after a map change.
    local gave, cursor = MCV_ApplySupply(self.BoxKind, target, self.HealAmount, self.AmmoMagazines, self.GetSupplyCursor and self:GetSupplyCursor() or 0)
    if gave then
        if cursor and self.SetSupplyCursor then self:SetSupplyCursor(cursor) end
        self:TakeRound(1)
        self:EmitSound(self.BoxKind == "medic" and "items/medshot4.wav" or "items/ammocrate_close.wav", 70)
    else
        self:EmitSound("items/medshotno1.wav", 60)
    end
end

function SWEP:Deferred_BoxEnd()
    // The self animation finishes off screen; bring the next box back with a draw.
    if self:GetActionVariant() == 1 and self:HasSequence(self.SequenceDraw) and self:GetRoundsLeft() > 0 then
        self:PlaySequence(self.SequenceDraw, 1, true)
    end
    self:CheckEmpty()
end

function SWEP:DropBox()
    local owner = self:GetOwner()
    local t = self:HasSequence(self.SequenceThrow) and self:PlaySequence(self.SequenceThrow, 1, true) or 0.6
    self:SetNextPrimaryFire(CurTime() + t)
    owner:DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_GRENADE)

    self:SetActionVariant(2)
    self:SetActionEnd(CurTime() + t)
    self:Defer("BoxDrop", math.min(self.ThrowDelay, t))
end

function SWEP:Deferred_BoxDrop()
    self:Defer("BoxEnd", math.max(self:GetActionEnd() - CurTime(), 0))
    self:TakeRound(1)
    if CLIENT then return end
    local owner = self:GetOwner()
    local ang = self:GetAimAngle()
    local ent = ents.Create(self.DroppedEntity)
    if !IsValid(ent) then return end
    ent.Model = self.WorldModel
    ent.BoxKind = self.BoxKind
    ent.HealAmount = self.HealAmount
    ent.AmmoMagazines = self.AmmoMagazines
    ent:SetPos(owner:GetShootPos() + ang:Forward() * 16)
    ent:SetAngles(Angle(0, ang.y, 0))
    ent:SetOwner(owner)
    ent:Spawn()
    local phys = ent:GetPhysicsObject()
    if IsValid(phys) then
        phys:SetVelocityInstantaneous(ang:Forward() * 350 + Vector(0, 0, 80) + owner:GetVelocity())
    end
end

function SWEP:CheckEmpty()
    if self:GetRoundsLeft() > 0 or CLIENT then return end
    local owner = self:GetOwner()
    if !IsValid(owner) then return end
    local class = self:GetClass()
    timer.Simple(0, function()
        if !IsValid(owner) then return end
        owner:StripWeapon(class)
        local other = owner:GetWeapons()[1]
        if IsValid(other) then owner:SelectWeapon(other:GetClass()) end
    end)
end

function SWEP:PrimaryAttack()
    if self:StillWaiting() then return end
    if self:GetRoundsLeft() <= 0 then return end

    local owner = self:GetOwner()

    if owner:KeyDown(IN_USE) then
        self:DropBox()
        return
    end

    local target = self:GetGiveTarget()
    if !target then
        self:SetNextPrimaryFire(CurTime() + 0.3)
        return
    end

    self:UseBox(target, self.SequenceGive, self.GiveDelay)
end

function SWEP:SecondaryAttack()
    if self:StillWaiting() then return end
    if self:GetRoundsLeft() <= 0 then return end
    if !self:GetOwner():KeyPressed(IN_ATTACK2) then return end

    self:UseBox(self:GetOwner(), self.SequenceSelf, self.GiveDelay)
end

function SWEP:Reload()
end

function SWEP:GetControlHints()
    return {
        {"+attack", self.BoxKind == "medic" and "Heal the player you look at" or "Resupply the player you look at"},
        {"+attack2", self.BoxKind == "medic" and "Use on yourself" or "Resupply your other weapons"},
        {"+use +attack", "Drop the box"},
    }
end
