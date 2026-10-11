include("dhr/dual_body.lua")
local drawFlash = include("hellraiser/flash.lua")


function SWEP:RemoveDualModels()
    for side = 1, 2 do
        local vm = self:DualViewModel(side)
        if IsValid(vm) and vm.dhr_weapon == self then
            HRHands.SupportArm(vm, false)
            HRHands.Remove(vm)
        end
    end
    if IsValid(self.dhr_left_world) then self.dhr_left_world:Remove() end
    self.dhr_left_world = nil
end

function SWEP:CalcViewModelView(vm, oldPos, oldAng, pos, ang)
    vm.dhr_weapon = self
    local side = vm:ViewModelIndex() == 1 and 1 or 2
    local reloading = self:ServiceHand()
    self.dhr_lower = self.dhr_lower or {0, 0}
    local target = reloading ~= 0 and reloading ~= side and 1 or 0
    self.dhr_lower[side] = math.Approach(self.dhr_lower[side], target, FrameTime() * 7)
    local shot = self.dhr_shots and self.dhr_shots[side] or -10
    local config = self:Gun(side).config
    local recoil = math.exp(-math.max(0, CurTime() - shot) * 12) * config.kick * 1.4
    local offset = config.dual_offset or Vector(3, 0, -1)
    pos = pos + ang:Right() * offset.x + ang:Forward() * (offset.y - recoil)
        + ang:Up() * (offset.z - self.dhr_lower[side] * 25)
    local turn = Angle(ang.p - recoil * 1.5, ang.y, ang.r)
    return pos, turn
end

function SWEP:ShowReloadHand(side)
    local other = side == 1 and 2 or 1
    return self:ServiceHand() == side and (self.dhr_lower and self.dhr_lower[other] or 0) >= 1
end

function SWEP:PreDrawViewModel(vm)
    local side = vm:ViewModelIndex() == 1 and 1 or 2
    local reload = self:ServiceHand()
    HRHands.Prepare(vm, self:GetOwner(), true)
    HRHands.SupportArm(vm, not self:ShowReloadHand(side))
    self:WithGun(side, self.ApplyAnimatedParts, vm)
    vm:InvalidateBoneCache()
    vm:SetupBones()
    if reload ~= 0 and reload ~= side and (self.dhr_lower and self.dhr_lower[side] or 0) >= 1 then return true end
end

function SWEP:PostDrawViewModel(vm)
    local side = vm:ViewModelIndex() == 1 and 1 or 2
    HRHands.DrawExecution(vm, self:GetOwner(), not self:ShowReloadHand(side))
    if HRSmoke then HRSmoke.MuzzleRendered(self, vm, side) end
    local shot = self.dhr_shots and self.dhr_shots[side] or -10
    local remaining = shot + 0.075 - CurTime()
    self.dhr_attachments = self.dhr_attachments or {}
    self.dhr_attachments[side] = {time = CurTime()}
    for _, name in ipairs({"muzzle", "shell"}) do
        self.dhr_attachments[side][name] = vm:GetAttachment(vm:LookupAttachment(name))
    end
    local attachment = self.dhr_attachments[side].muzzle
    if remaining > 0 and attachment then
        self:WithGun(side, drawFlash, self:ViewModelEffectPosition(attachment.Pos), attachment.Ang:Forward(), remaining, true)
    end
    if self.dhr_cases and self.dhr_cases[side] then
        self.dhr_cases[side] = nil
        self:EjectDualCase(side)
    end
end

function SWEP:GetEffectAttachment(name, side)
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    side = side or self.dhr_firing_side or self.dhr_effect_side or 2
    if owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer() then
        local saved = self.dhr_attachments and self.dhr_attachments[side]
        if saved and CurTime() - saved.time < 0.2 then return saved[name] end
        local vm = self:DualViewModel(side)
        if IsValid(vm) then return vm:GetAttachment(vm:LookupAttachment(name)) end
    end
    return self:GetWorldAttachment(name, nil, side)
end

function SWEP:DualShot(side)
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    self.dhr_shots = self.dhr_shots or {}
    self.dhr_shots[side] = CurTime()
    self.dhr_effect_side = side
    if owner == LocalPlayer() then
        self:WithGun(side, self.BeginRecoil)
        self:WithGun(side, self.PlayShotSound)
    end
    local fx = EffectData()
    fx:SetEntity(self)
    fx:SetAttachment(side)
    fx:SetOrigin(owner:GetShootPos())
    fx:SetScale(self:Gun(side).config.flash or 1)
    util.Effect("hr_muzzle", fx)
    self:WithGun(side, self.PlayShotReflections)
    if HRSmoke then self:WithGun(side, HRSmoke.Shot, side) end
    local kind = self:Gun(side).config.crosshair
    if kind ~= "revolver" and kind ~= "shotgun" then
        if owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer() then
            self.dhr_cases = self.dhr_cases or {}
            self.dhr_cases[side] = true
        else self:EjectDualCase(side) end
    end
end

function SWEP:EjectDualCase(side)
    local owner = self:GetOwner()
    local a = self:GetEffectAttachment("shell", side)
    if not IsValid(owner) or not a then return end
    local pos = a.Pos
    if owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer() then pos = self:ViewModelEffectPosition(pos) end
    local fx = EffectData()
    fx:SetEntity(self)
    fx:SetAttachment(side)
    fx:SetOrigin(pos)
    fx:SetAngles(a.Ang)
    util.Effect("hr_shell", fx)
end

function SWEP:FireAnimationEvent(pos, ang, event, options, vm)
    local side = IsValid(vm) and vm:ViewModelIndex() == 1 and 1 or 2
    local gun = self:Gun(side)
    if event == 5004 then
        if HRCombat.Dodging(self:GetOwner()) then return true end
        local sequence = IsValid(vm) and vm:GetSequenceName(vm:GetSequence()) or self:DualSequence(side)
        if (gun.config.world_events or {})[sequence] then return true end
        return self:WithGun(side, baseclass.Get("dhr_base").FireAnimationEvent, pos, ang, event, options)
    end
    if event == 6001 then
        self:EjectDualCase(side)
    elseif event == 6002 then
        for _ = 1, math.max(0, gun.primary.ClipSize - self:GetNW2Int("dhr_reload_rounds", 0)) do self:EjectDualCase(side) end
    elseif event == 6003 then
        local index = self:WithGun(side, self.MagazinePart)
        if index and IsValid(vm) then
            self:WithGun(side, self.EjectMagazine, index, vm:GetSequenceName(vm:GetSequence()), self:GetNW2Int("dhr_reload_rounds", 0), vm)
        end
    end
    return true
end

function SWEP:DualWorldModel(side)
    if side == 2 then return self end
    if not IsValid(self.dhr_left_world) then
        self.dhr_left_world = ClientsideModel(self:Gun(side).world, RENDERGROUP_OTHER)
        if not IsValid(self.dhr_left_world) then return end
        self.dhr_left_world:SetNoDraw(true)
        self.dhr_left_world:DrawShadow(false)
    end
    return self.dhr_left_world
end

function SWEP:PoseDualWorld(side)
    if HRDualBody.Hidden(self, side) then return end
    local reload = HRDualBody.Model(self, side)
    if IsValid(reload) then return reload end
    local owner, model = self:GetOwner(), self:DualWorldModel(side)
    if not IsValid(owner) or not IsValid(model) then return end
    owner:SetupBones()
    local bone = owner:LookupBone(side == 1 and "ValveBiped.Bip01_L_Hand" or "ValveBiped.Bip01_R_Hand")
    local matrix = bone and owner:GetBoneMatrix(bone)
    if not matrix then return end
    local held = HRDualBody.Held(self, side, matrix)
    if IsValid(held) then return held end
    local pose = self:Gun(side).config.world
    if not pose then return end
    local offset = Matrix()
    offset:SetTranslation(pose.pos)
    offset:SetAngles(pose.ang)
    if side == 1 then
        local mirror = Matrix()
        mirror:SetScale(Vector(1, 1, -1))
        matrix = matrix * mirror * offset * mirror
        model:EnableMatrix("RenderMultiply", mirror)
        model.dhr_mirrored = true
    else matrix = matrix * offset end
    model:SetRenderOrigin(matrix:GetTranslation())
    model:SetRenderAngles(matrix:GetAngles())
    self:WithGun(side, self.ApplyUpgradeParts, model)
    model:InvalidateBoneCache()
    model:SetupBones()
    return model
end

function SWEP:DrawWorldModel(flags)
    if not IsValid(self:GetOwner()) then self:DrawModel(flags) return end
    for side = 1, 2 do
        local model = self:PoseDualWorld(side)
        if IsValid(model) then
            if model.dhr_mirrored then render.CullMode(MATERIAL_CULLMODE_CW) end
            model:DrawModel(flags)
            render.CullMode(MATERIAL_CULLMODE_CCW)
            local drop = model.hr_magazine_drop
            model.hr_magazine_drop = nil
            if drop and drop.weapon == self then
                self:WithGun(side, self.EjectMagazine, drop.index, drop.sequence, drop.rounds, model)
            end
            model:SetRenderOrigin()
            model:SetRenderAngles()
        end
    end
end

function SWEP:GetWorldAttachment(name, bone, side)
    local model = self:PoseDualWorld(side or self.dhr_effect_side or 2)
    if not IsValid(model) then return end
    local a = HRDualBody.Attachment(model, name)
    model:SetRenderOrigin()
    model:SetRenderAngles()
    return a
end

net.Receive("dhr_dual_shot", function()
    local weapon, side = net.ReadEntity(), net.ReadUInt(2)
    if not IsValid(weapon) or not weapon.DualWield then return end
    if weapon:GetOwner() ~= LocalPlayer() or game.SinglePlayer() then weapon:DualShot(side) end
end)

local previousWeapon
hook.Add("Think", "dhr_dual_viewmodel_cleanup", function()
    local owner = LocalPlayer()
    if not IsValid(owner) then return end
    local active = owner:Alive() and owner:GetActiveWeapon() or NULL
    if IsValid(previousWeapon) and previousWeapon.DualWield and active ~= previousWeapon then
        previousWeapon:Holster()
    end
    previousWeapon = active
end)

local pairIcons = {}
function SWEP:DrawDualIcon(x, y, scale, selected, alpha)
    for side, gun in ipairs(self.dhr_guns) do
        local offset = side == 1 and -50 or 50
        if gun.config.stock_icon then
            HRStockIcons.Draw(gun.config.stock_icon, x + offset * scale, y, 100 * scale, 90 * scale, selected and "selected" or "", alpha)
        else
            local path = "hellraiser/ui/wheel/" .. gun.class .. (selected and "_g" or "")
            pairIcons[path] = pairIcons[path] or Material(path)
            local dimensions = gun.config.wheel_icon_size or {210, 118}
            local factor = math.min(100 / dimensions[1], 90 / dimensions[2]) * scale
            surface.SetMaterial(pairIcons[path])
            surface.SetDrawColor(255, 255, 255, alpha)
            surface.DrawTexturedRect(x + offset * scale - dimensions[1] * factor / 2, y - dimensions[2] * factor / 2,
                dimensions[1] * factor, dimensions[2] * factor)
        end
    end
end
