// Rebuild the engine-facing Lua alias from the restored mode. Launcher variants
// carry both rifle and launcher animations in their own combined model.
function SWEP:SyncViewModel(changeModel)
    local owner = self:GetOwner()
    if !IsValid(owner) or !owner:IsPlayer() then return end
    self.SingleViewModel = self.SingleViewModel or weapons.Get(self:GetClass()).ViewModel
    local model = self.HasAkimbo and self:GetAkimbo() and self.ViewModelAkimbo or self.SingleViewModel
    self.ViewModel = model
    local vm = self:GetOwner():GetViewModel()
    if !IsValid(vm) then return end

    // If we don't do this, it can sometimes carry the last weapon's bodygroups over.
    if changeModel or self.MCVBodygroupVM != vm or self.MCVBodygroupModel != model then
        vm:SetBodyGroups("0000000000000000000000000000000000000000000000000000000000000")
        self.MCVBodygroupVM, self.MCVBodygroupModel = vm, model
    end

    if changeModel then
        // GetModel's cached string can agree while the engine still has the old MDL.
        local mins, maxs = vm:GetCollisionBounds()
        vm:SetModel(model)
        // Client SetModel takes the MDL hull; the server retains the VM hull.
        vm:SetCollisionBounds(mins, maxs)
    elseif CLIENT then
        // Match the server's cache update before Think, not during a deferred swap.
        self:SetSaveValue("m_iViewModelIndex", vm:GetInternalVariable("m_nModelIndex"))
    end
end

function SWEP:Deploy()
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then
        if self.NPC_Deploy then self:NPC_Deploy() end
        return true
    end
    self:CancelDeferred()
    self:SetHolsterCommand(0)
    self:SetHolsterTime(0)
    self:SetHolsterEntity(NULL)
    self:SetRecoilImpulse(vector_origin)
    self:SetRecoilCommand(0)
    self:SyncViewModel(true)
    // The save-value interface is relative on the server and absolute on the client.
    // Both writes mean ready now; CurTime on the server would double the deadline.
    self:GetOwner():SetSaveValue("m_flNextAttack", SERVER and 0 or CurTime())

    if self:ViewModelHidden() then
        self:SetReady(true)
    elseif !self:GetReady() and !self:GetGrenadeLauncher() and self:HasAnimation(ACT_VM_READY) then
        self:PlayAnimation(ACT_VM_READY, 1, true)
        self:SetReady(true)
    else
        self:DeployAnimation()
        self:SetReady(true)
    end

    self:SetIronsight(false)
    self:SetActionState(0)
    self:SetActionStart(0)

    self:SetBurstCount(0)
    self:OnDeploy()

    return true
end

function SWEP:ClientHolster()
    if game.SinglePlayer() then
        self:CallOnClient("ClientHolster")
    end

    if SERVER then return end

    local vm = self:GetOwner():GetViewModel()

    vm:SetSubMaterial()
    vm:SetMaterial()
    vm:StopParticles()
    self.VMLit = false
end

function SWEP:Holster(wep)
    if IsValid(self:GetOwner()) and self:GetOwner():IsNPC() then return true end
    if game.SinglePlayer() and CLIENT then return end

    if CLIENT and self:GetOwner() != LocalPlayer() then return end
    // The engine also calls Holster clientside outside prediction when applying a
    // weapon switch. It must not start another delayed switch or mutate restored data.
    if CLIENT and GetPredictionPlayer() != self:GetOwner() then return true end

    if self:GetReloading() then
        self:SetReloading(false)
    end

    local forced = SERVER and GetPredictionPlayer() != self:GetOwner()
    if !forced and self:GetHolsterTime() > CurTime() then return false end

    if forced or (self:GetHolsterTime() != 0 and self:GetHolsterTime() <= CurTime()) or !IsValid(wep) then
        -- Do the final holster request
        -- Picking up props try to switch to NULL, by the way
        self:SetHolsterTime(0)
        self:SetHolsterCommand(0)
        self:SetHolsterEntity(NULL)
        self:CancelDeferred()

        local vm = self:GetOwner():GetViewModel()

        vm:SetBodyGroups("000000000000000000000")

        self:ClientHolster()

        return true
    else
        self:CancelDeferred()
        local t = self:PlayAnimation(ACT_VM_HOLSTER, 1, true, true)
        self:SetHolsterTime(CurTime() + (t or 0))
        local cmd = self:GetOwner():GetCurrentCommand()
        self:SetHolsterCommand(cmd and cmd:CommandNumber() + math.ceil((t or 0) / engine.TickInterval()) or 0)
        self:SetHolsterEntity(wep)

        self:SetIronsight(false)
        self:SetActionState(0)

        self:GetOwner():DoAnimationEvent(ACT_HL2MP_GESTURE_RANGE_ATTACK_SLAM)
        return false
    end
end

hook.Add("StartCommand", "MCV_Holster", function(ply, ucmd)
    local wep = ply:GetActiveWeapon()

    if IsValid(wep) and wep.MilitaryConflictVietnam then
        // StartCommand does not supply the weapon's predicted CurTime. Command
        // numbers, including the command selected here, are identical on both sides.
        local due = wep:GetHolsterCommand()
        if due > 0 and ucmd:CommandNumber() >= due then
            if IsValid(wep:GetHolsterEntity()) then
                ucmd:SelectWeapon(wep:GetHolsterEntity()) -- Call the final holster request
            end
        end
    end
end)

function SWEP:Initialize()
    // GMod merges nested lists: a derived one-mode gun can inherit a duplicate
    // second entry. Keep a private, dense list of distinct numeric modes.
    if self.Firemodes then
        local modes, seen = {}, {}
        local selected = self.Firemodes[self:GetFiremode()]
        for _, mode in ipairs(self.Firemodes) do
            if isnumber(mode) and !seen[mode] then
                modes[#modes + 1] = mode
                seen[mode] = #modes
            end
        end
        self.Firemodes = modes
        self:SetFiremode(seen[selected] or 1)
    end
    // Also builds the engine's activity translations for NPC aiming / firing / reloads.
    self:SetHoldType(self.HoldType or "ar2")
    // Only the newly created weapon's free round is affected. Never clear the
    // owner's shared ammo pool or a loaded weapon on deploy / pickup.
    if SERVER and self.Secondary.Ammo == "smg1_grenade" and !MCV.SpawnRifleGrenadeAmmo() then
        self:SetClip2(0)
    end

    // A model first precached at the mid-animation swap has no network model index
    // on the predicting client yet. Register the alternate while giving the weapon.
    if self.ViewModelAkimbo and self.ViewModelAkimbo != "" then
        util.PrecacheModel(self.ViewModelAkimbo)
    end
    // Per-instance state. The class-level defaults in sh_vm are tables shared
    // by every weapon of the class, so they must not be mutated directly.
    self.PCFs = {}
    self.ActiveEffects = {}

    for _, p in ipairs(self:GetPrecacheParticles()) do
        if p and p != "" then
            PrecacheParticleSystem(p)
        end
    end

    // the world model's own bodygroups, on the weapon entity so they network: the dropped
    // weapon and the copies drawn on a player both take them from here
    if SERVER and self.WorldModelBodyGroups then
        self:SetBodyGroups(self.WorldModelBodyGroups)
    end
end
