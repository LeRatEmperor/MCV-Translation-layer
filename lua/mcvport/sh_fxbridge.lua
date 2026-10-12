--[[---------------------------------------------------------------------------
    MCVPort — foreign-model effect/event bridge.

    Discrete-animset models (NMRiH, INS2-style ports) carry their own engine
    animation events on the fire/reload sequences:

        { event AE_CL_EJECT_BRASS 0 "45acp Eject 140" }   -- engine brass
        { event AE_MUZZLEFLASH   0 "NMRIH_PISTOL_FLASH" } -- engine flash
        { event 5004 14 "Weapon_1911.clipout" }           -- soundscript foley

    MCV expects none of these: its own shot code ejects brass and draws the
    muzzle particle itself (sh_shoot.lua:448-453) and its models use
    attachment names ("muzzle", "eject") that foreign models don't have. Left
    alone, the engine's default handlers step in: the NMRiH brass event spawns
    an unresolvable error model, and both effect spawns land on the wrong
    attachment names.

    This module translates that contract, per port, through the Define table:

        attachments = { muzzle = "1", eject = "2" }  -- this model's names
        foley       = "qc"          -- trust the model's 5004 events (default)
                      "synthetic"   -- block 5004; use the events table instead

    - SWEP:FireAnimationEvent runs MCV's handler first (the duals' "eject2"
      path is preserved), then blocks what the engine would mishandle:
      eject-brass events are recognised by their options string ("<shell type>
      Eject <speed>" across NMRiH animsets), the engine muzzle flash
      (AE_MUZZLEFLASH = 21) is suppressed because MCV draws its own, and in
      "synthetic" foley mode the 5004 sound events are silenced so the
      port's timed events own the audio. Returning true blocks the engine's
      default effect (WEAPON:FireAnimationEvent, GMod wiki).
    - SWEP:DoEject injects the port's eject attachment name when MCV's own
      shot code calls it with the default. MCV's base takes the attachment
      name as a parameter (sh_effects.lua:92), so this is a pure wrapper —
      no behaviour change for weapons without an attachments table.
    - SWEP:DoMuzzle is a one-line fork of sh_effects.lua:47-87 (gated on the
      muzzle override; weapons without one inherit the base untouched). The
      base resolves the "muzzle" attachment internally, so unlike DoEject
      there is no parameter seam to ride. Keep the body in step with
      upstream when the layer tracks a new MCV revision.

    Like sh_animroles.lua, this module reaches the host base's parent through
    baseclass.Get(SWP.Base) captured at include time.
-----------------------------------------------------------------------------]]

local host_parent = SWEP.Base or "mcv_base"

local function parent()
    return baseclass.Get(host_parent)
end

--------------------------------------------------------------------------------
-- FireAnimationEvent
--------------------------------------------------------------------------------

function SWEP:FireAnimationEvent(pos, ang, event, options, source)
    local p = parent()

    -- MCV's own interception first: the duals' left-hand "eject2" events.
    if p.FireAnimationEvent then
        if p.FireAnimationEvent(self, pos, ang, event, options, source) then
            return true
        end
    end

    local cfg = self.MCVP
    if not cfg then return end

    -- NMRiH-style discrete brass: "<shelltype> Eject <speed>" in the options.
    -- The engine's own handler cannot resolve the shell type and spawns an
    -- error model, so block it; MCV's shot code has already run its own
    -- DoEject (sh_shoot.lua:448-453), which the wrapper below lands on the
    -- port's attachment.
    if options and string.find(options, "Eject", 1, true) then
        return true
    end

    -- Engine muzzle flash: MCV draws its own muzzle particle per shot.
    if event == 21 then -- AE_MUZZLEFLASH (Source SDK eventlist.h)
        return true
    end

    -- Synthetic foley mode: the model's 5004 soundscript events are blocked
    -- so the port's timed events table owns the audio instead.
    if cfg.foley == "synthetic" and event == 5004 then
        return true
    end
end

--------------------------------------------------------------------------------
-- DoEject: default-attachment injection
--------------------------------------------------------------------------------

function SWEP:DoEject(attachment)
    if attachment == nil then
        local cfg = self.MCVP
        if cfg and cfg.attachments and cfg.attachments.eject then
            attachment = cfg.attachments.eject
        end
    end
    return parent().DoEject(self, attachment)
end

--------------------------------------------------------------------------------
-- DoMuzzle: gated one-line fork of sh_effects.lua:7-18, 47-87
--------------------------------------------------------------------------------

-- verbatim from sh_effects.lua:7-18: effect position and recipients belong to
-- the shooter, never the default EffectData origin (0,0,0). The firing client
-- already predicts its own effects.
local function dispatchWeaponEffect(name, data, owner)
    local origin = owner:GetShootPos()
    data:SetOrigin(origin)
    if SERVER then
        local recipients = RecipientFilter()
        recipients:AddPVS(origin)
        if owner:IsPlayer() and not game.SinglePlayer() then recipients:RemovePlayer(owner) end
        util.Effect(name, data, true, recipients)
    else
        util.Effect(name, data)
    end
end

function SWEP:DoMuzzle(alt)
    local cfg = self.MCVP
    if not (cfg and cfg.attachments and cfg.attachments.muzzle) then
        return parent().DoMuzzle(self, alt)
    end

    if not IsFirstTimePredicted() then return end
    local owner = self:GetOwner()
    if not IsValid(owner) then return end
    local vm = owner:IsPlayer() and owner:GetViewModel() or self
    if not IsValid(vm) then return end

    -- the one changed line: the port's muzzle attachment name
    local muzz_qca = MCV.CachedAttachment(vm, cfg.attachments.muzzle)

    if self.GetGrenadeLauncher and self:GetGrenadeLauncher() and self.RifleGrenadeIsUBGL then
        muzz_qca = MCV.CachedAttachment(vm, "muzzle2")
    end

    local is_volley = self.GetFiremodeValue and self:GetFiremodeValue() == MCV.FIREMODE_VOLLEY
        and self:Clip1() >= self.VolleyCount

    if self.GetAkimbo and self:GetAkimbo() and self:Clip1() % 2 == 1 and not is_volley then
        local left = MCV.CachedAttachment(vm, "muzzleleft")
        muzz_qca = left > 0 and left or MCV.CachedAttachment(vm, "muzzle2")
    end

    local data = EffectData()
    data:SetEntity(self)
    data:SetAttachment(muzz_qca)
    data:SetMagnitude((self.GetAkimbo and self:GetAkimbo() and self:Clip1() % 2 == 1 and not is_volley) and 1 or 0)

    dispatchWeaponEffect("mcv_muzzleeffect", data, owner)

    if self.GetAkimbo and self:GetAkimbo() and is_volley then
        local data2 = EffectData()
        data2:SetEntity(self)
        data2:SetAttachment(4)
        data2:SetMagnitude(1)
        dispatchWeaponEffect("mcv_muzzleeffect", data2, owner)
    end

    if CLIENT and self:GetOwner() == LocalPlayer() then
        self:DoMuzzleLight()
    elseif game.SinglePlayer() and owner:IsPlayer() then
        self:CallOnClient("DoMuzzleLight")
    end
end
