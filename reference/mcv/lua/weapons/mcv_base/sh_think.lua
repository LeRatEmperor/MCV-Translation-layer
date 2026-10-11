// Gun-specific per-tick work; the shared part (movement, hold type, timers, idle) runs in
// mcv/weapon_common/sh_think.lua before this.

// Third person: the world model's "bipod" bodygroup (option 1 is the deployed one on every
// game model) follows the bipod, and its "belt" bodygroup (the long belt, blank second) goes
// away with the last round. The drawn copies take the weapon entity's bodygroups
// (cl_worldmodel.lua). Bodygroups are engine predicted fields, so update both realms.
function SWEP:Think_WorldBodygroups()
    local model = self:GetModel()
    local groups = self.MCVWorldBodygroups
    if !groups or self.MCVWorldBodygroupModel != model then
        groups = {
            bayonet = self:FindBodygroupByName("bayonet"),
            grenade = self:FindBodygroupByName("grenade"),
            bipod = self:FindBodygroupByName("bipod"),
            belt = self:FindBodygroupByName("belt"),
        }
        self.MCVWorldBodygroups, self.MCVWorldBodygroupModel = groups, model
    end

    // the two the player changes with the weapon in hand; the rest are set once at Initialize
    if self.HasBayonet then
        local b = groups.bayonet
        if b >= 0 then
            local want = self:GetBayonet() and 1 or 0
            if self:GetBodygroup(b) != want then self:SetBodygroup(b, want) end
        end
    end

    if self.HasRifleGrenade then
        local g = groups.grenade
        if g >= 0 then
            local want = self:GetGrenadeLauncher() and 1 or 0
            if self:GetBodygroup(g) != want then self:SetBodygroup(g, want) end
        end
    end

    local bipod = groups.bipod
    if bipod >= 0 then
        local want = self:GetBipod() and 1 or 0
        if self:GetBodygroup(bipod) != want then self:SetBodygroup(bipod, want) end
    end
    local belt = groups.belt
    if belt >= 0 then
        local want = self:Clip1() > 0 and 0 or 1
        if self:GetBodygroup(belt) != want then self:SetBodygroup(belt, want) end
    end
end
function SWEP:ThinkWeapon()
    local owner = self:GetOwner()

    self:Think_HammerRelease()
    self:Think_Sights()
    self:Think_Reload()
    self:Think_Bipod()
    self:Think_BayonetCharge()
    self:Think_WorldBodygroups()

    // runaway burst: the remaining rounds go out on their own, trigger or not
    local bursting = self:IsBursting()
    if bursting and !self:StillWaiting() then
        if self:Clip1() > 0 and !self:GetReloading() then
            self:PrimaryAttack()
        else
            self:SetBurstCount(0)
        end
    end

    if owner:KeyReleased(IN_ATTACK) then
        // the trigger-press flag clears; the round count only when no burst is in progress
        self:SetNeedTriggerPress(false)
        if !bursting then
            self:SetBurstCount(0)
        end

        if self:GetPrimedAttack() then
            self:PlayAnimation(self:IdleActivity())
            self:SetPrimedAttack(false)
        end
    // LastClip is the predicted clip count captured when this reload began.
    // Existing shells must not let a top-up skip its first insert.
    elseif self:GetReloading() and self.ShotgunReload and owner:KeyPressed(IN_ATTACK) and self:Clip1() > self:GetLastClip() then
        self:SetEndReload(true)
    end

    if owner:KeyPressed(IN_USE) and owner:KeyDown(IN_WALK) then
        self:ToggleUBGL()
    end

    if owner:KeyDown(IN_ATTACK) and self:GetPrimedAttack() and self:GetLastTriggerTime() + self.TriggerDelayTime < CurTime() then
        if SERVER or !game.SinglePlayer() then
            self:AttackEffects()
            if self:GetProjectileClass() then
                self:RocketAttack()
            else
                self:BulletAttack()
            end
            self:SetPrimedAttack(false)
            if self:GetAkimbo() and self:Clip1() % 2 == 0 then
                self:PlayAnimation(ACT_VM_PRIMARYATTACK_3, 0.5)
            else
                self:PlayAnimation(ACT_VM_PRIMARYATTACK_2, 0.5)
            end
        end
    end

    // the cycle waits for the trigger to be released, except on slam-firing shotguns (M1897,
    // M37): they pump with the trigger held and fire the moment the action closes
    // No IsFirstTimePredicted gate here: everything below is state, and state left out of the
    // commands the client re-simulates is state the client and the server stop agreeing on.
    // PlayAnimation and the sounds under it handle prediction themselves.
    if !self:StillWaiting() and (!owner:KeyDown(IN_ATTACK) or self.SlamFire) and self:GetNeedCycle() then
        // A dual model can have no separate bolt pull even though the single does: the dual
        // Type 67 works its bolts inside its own shot animations, since a hand holding a gun
        // cannot also pull the other gun's bolt. The cycle still happens, because the state is
        // what makes a bolt action one (it blocks the next shot until the trigger is released,
        // see CanPrimaryAttack); there is just no animation of its own to play or wait for.
        // Cycle sequences retain their source duration; each action runs at normal speed.
        local t = self:PlayAnimation(ACT_VM_RELOAD_INSERT_PULL, 1, false)
        self:EmitThirdPersonSound(self.SoundCycleThirdPerson)

        if t then
            self:SetNextPrimaryFire(CurTime() + t * self.CyclePostDelay)
            // networked so both realms show the same rounds through the cycle
            // (CycleClipPoseTime); guns have no other use for ActionStart
            self:SetActionStart(CurTime())
        end

        if t == nil or !self.AnimationHandlesHammer then
            self:SetNeedCycle(false)
        end
    end

    // Safety mechanism

    if owner:KeyDown(IN_USE) and owner:KeyPressed(IN_WALK) then
        self:ToggleSafe()
    end
    self:Think_AutoReload()
end
