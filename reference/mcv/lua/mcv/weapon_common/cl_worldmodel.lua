// Third person. The game's world models are rigged to ValveBiped.weapon_bone, the bone GMod's
// players carry in the right hand, and the engine places a held weapon by merging its bones onto
// the player's (EF_BONEMERGE). That merge is kept: the weapon draws a clientside copy of its
// world model merged onto the owner, and the difference between the game's player rig and
// GMod's is taken out on the player's weapon_bone itself (one adjustment for every gun, since
// every world model shares the rig convention), plus a per-weapon WorldModelOffset on top.
// Effects attach to the drawn copy, so the muzzle and the shell port are where the gun is.
// A dual draws a second copy on the left hand bone with WorldModelOffsetLeft ("duel" hold type).

// the player's weapon_bone adjustment, shared by every gun (degrees, units, in the bone's frame)
SWEP.WorldModelBoneAng = Angle(0, 0, 0)
SWEP.WorldModelBonePos = Vector(0, 0, 0)
// on top of that, per weapon (the bone's frame as well)
SWEP.WorldModelOffset = {pos = Vector(0, 0, 0), ang = Angle(0, 0, 0)}
// the left-hand copy of a dual: relative to ValveBiped.Bip01_L_Hand
SWEP.WorldModelOffsetLeft = {pos = Vector(0, 0, 0), ang = Angle(0, 0, 0)}

// live tuning: "p y r" / "x y z"; empty means the lua values
local cv_ang = CreateClientConVar("mcv_wm_ang", "", false, false, "Overrides the weapon_bone angle adjustment for every gun: 'p y r'")
local cv_pos = CreateClientConVar("mcv_wm_pos", "", false, false, "Overrides the weapon_bone position adjustment for every gun: 'x y z'")
local cv_left_ang = CreateClientConVar("mcv_wm_left_ang", "", false, false, "Overrides WorldModelOffsetLeft.ang: 'p y r'")
local cv_left_pos = CreateClientConVar("mcv_wm_left_pos", "", false, false, "Overrides WorldModelOffsetLeft.pos: 'x y z'")

local tuningValues = {}
local function readTriple(cv, ctor)
    local s = cv:GetString()
    if s == "" then return nil end
    local cached = tuningValues[cv]
    if cached and cached.text == s then return cached.value end
    local a, b, c = s:match("^%s*([-%d.]+)%s+([-%d.]+)%s+([-%d.]+)")
    local value = a and ctor(tonumber(a), tonumber(b), tonumber(c)) or nil
    tuningValues[cv] = {text = s, value = value}
    return value
end

function SWEP:GetWorldModelBoneAdjust()
    local ang = readTriple(cv_ang, Angle) or self.WorldModelBoneAng or angle_zero
    local pos = readTriple(cv_pos, Vector) or self.WorldModelBonePos or vector_origin
    local off = self.WorldModelOffset
    if off then
        pos = pos + (off.pos or vector_origin)
        ang = ang + (off.ang or angle_zero)
    end
    return pos, ang
end

// The player's weapon_bone carries the adjustment while an MCV weapon is out; put back when
// something else is (the engine's own weapon models would inherit it otherwise)
local BONE = "ValveBiped.weapon_bone"
local adjustedOwners = setmetatable({}, {__mode = "k"})

local function adjustOwnerBone(owner, pos, ang)
    local id = MCV.CachedBone(owner, BONE)
    if !id then return false end
    adjustedOwners[owner] = true
    local model = owner:GetModel()
    if owner.MCVBoneAdjusted != true or owner.MCVBoneModel != model
            or owner.MCVBonePos != pos or owner.MCVBoneAng != ang then
        owner:ManipulateBonePosition(id, pos)
        owner:ManipulateBoneAngles(id, ang)
        owner.MCVBoneAdjusted, owner.MCVBonePos, owner.MCVBoneAng = true, pos, ang
        owner.MCVBoneModel = model
        owner:InvalidateBoneCache()
        return true
    end
    return false
end

local function restoreOwnerBone(owner)
    if !owner.MCVBoneAdjusted then return end
    local id = MCV.CachedBone(owner, BONE)
    if id then
        owner:ManipulateBonePosition(id, vector_origin)
        owner:ManipulateBoneAngles(id, angle_zero)
    end
    owner.MCVBoneAdjusted = false
end

hook.Add("Think", "MCV_WorldModelBoneRestore", function()
    for ply in pairs(adjustedOwners) do
        if !IsValid(ply) then
            adjustedOwners[ply] = nil
        elseif ply.MCVBoneAdjusted then
            local wep = ply:GetActiveWeapon()
            if !IsValid(wep) or !wep.MilitaryConflictVietnam then
                restoreOwnerBone(ply)
                adjustedOwners[ply] = nil
            end
        else
            adjustedOwners[ply] = nil
        end
    end
end)

function SWEP:GetWorldModelEntity(left)
    local key = left and "WMLeft" or "WM"
    local mdl = self[key]
    local owner = self:GetOwner()
    if !IsValid(owner) then MCV.RemoveClientModel(self, key) return end
    if IsValid(mdl) and mdl:GetModel() == self.WorldModel and mdl.MCVOwner == owner then
        // Engine PVS transitions can detach a clientside child without changing
        // our cached owner. Repair the actual parent, not just the Lua cache.
        if !left and (mdl:GetParent() != owner or mdl.MCVOwnerModel != owner:GetModel()) then
            mdl:SetParent(owner)
            mdl:SetLocalPos(vector_origin)
            mdl:SetLocalAngles(angle_zero)
            mdl:AddEffects(EF_BONEMERGE)
            mdl:InvalidateBoneCache()
            mdl.MCVOwnerModel = owner:GetModel()
        end
        return mdl
    end
    MCV.RemoveClientModel(self, key)
    if left then self.WMLeftBind = nil end
    if !self.WorldModel or self.WorldModel == "" or !util.IsValidModel(self.WorldModel) then return nil end
    mdl = ClientsideModel(self.WorldModel, RENDERGROUP_OPAQUE)
    if !IsValid(mdl) then return nil end
    mdl:SetNoDraw(true)
    mdl.MCVOwner = self:GetOwner()
    mdl.MCVOwnerModel = IsValid(owner) and owner:GetModel()
    if !left then
        // the engine's own placement: bones merged onto the owner's
        mdl:SetParent(self:GetOwner())
        mdl:SetLocalPos(vector_origin)
        mdl:SetLocalAngles(angle_zero)
        mdl:AddEffects(EF_BONEMERGE)
    end
    return MCV.TrackClientModel(self, key, mdl)
end

function SWEP:RemoveWorldModels()
    if self.StopFlameEffect then self:StopFlameEffect() end
    MCV.RemoveClientModel(self, "WM")
    MCV.RemoveClientModel(self, "WMLeft")
    self.WMLeftBind = nil
end

local function copyLook(self, mdl)
    mdl:SetSkin(self:GetSkin())
    for i = 0, self:GetNumBodyGroups() - 1 do
        mdl:SetBodygroup(i, self:GetBodygroup(i))
    end
end

// The left-hand gun of a dual: the merged right gun's weapon_bone frame is taken relative to
// the player's right hand bone, that hand-relative transform is mirrored into the left hand
// bone's frame (the left hand bone is the right one's mirror image, so the mirror is a flip of
// one of the hand's local axes), and the gun's own lateral (bone x) axis is flipped back so
// the result is a proper rotation of the same, unmirrored mesh. The second copy is placed so
// that its own weapon_bone lands on that frame. WorldModelOffsetLeft (mcv_wm_left_pos / _ang)
// sits on top in the gun's frame.
local WEAPON_BONE = "ValveBiped.weapon_bone"
local R_HAND, L_HAND = "ValveBiped.Bip01_R_Hand", "ValveBiped.Bip01_L_Hand"
local cv_mirror = CreateClientConVar("mcv_wm_left_mirror", "z", false, false, "Which hand-local axis the left hand mirrors the right across: x, y or z")
local FLIP_LATERAL = Matrix()
FLIP_LATERAL:Scale(Vector(-1, 1, 1))

local mirrorAxis, mirrorMatrix
local function handMirror()
    local axis = cv_mirror:GetString():lower()
    if axis == mirrorAxis then return mirrorMatrix end
    local M = Matrix()
    M:Scale(Vector(axis == "x" and -1 or 1, axis == "y" and -1 or 1, (axis != "x" and axis != "y") and -1 or 1))
    mirrorAxis, mirrorMatrix = axis, M
    return M
end

function SWEP:GetWorldModelTransformLeft(right, left)
    local owner = self:GetOwner()
    local rb = IsValid(right) and MCV.CachedBone(right, WEAPON_BONE)
    local W = rb and right:GetBoneMatrix(rb)
    local rh, lh = MCV.CachedBone(owner, R_HAND), MCV.CachedBone(owner, L_HAND)
    local R, L = rh and owner:GetBoneMatrix(rh), lh and owner:GetBoneMatrix(lh)
    if !W or !R or !L then return nil end
    local localGun = R:GetInverse() * W
    local Wl = L * handMirror() * localGun * FLIP_LATERAL
    local offpos = readTriple(cv_left_pos, Vector) or (self.WorldModelOffsetLeft and self.WorldModelOffsetLeft.pos) or vector_origin
    local offang = readTriple(cv_left_ang, Angle) or (self.WorldModelOffsetLeft and self.WorldModelOffsetLeft.ang) or angle_zero
    if offpos != vector_origin or offang != angle_zero then
        local O = Matrix()
        O:SetTranslation(offpos)
        O:SetAngles(offang)
        Wl = Wl * O
    end
    // the copy's origin: its own weapon_bone bind transform taken back out
    if !self.WMLeftBind and IsValid(left) then
        local lb = MCV.CachedBone(left, WEAPON_BONE)
        if lb then
            left:SetPos(vector_origin)
            left:SetAngles(angle_zero)
            left:SetupBones()
            local B = left:GetBoneMatrix(lb)
            if B then self.WMLeftBind = B:GetInverse() end
        end
    end
    local E = self.WMLeftBind and (Wl * self.WMLeftBind) or Wl
    return E:GetTranslation(), E:GetAngles()
end

// Effects can arrive before DrawWorldModel (or while the gun is off screen).
// Both paths must prepare the same current pose before reading attachments.
function SWEP:UpdateWorldModels(drawing)
    local owner = self:GetOwner()
    if self:IsDormant() or (IsValid(owner) and owner:IsDormant()) then
        self:RemoveWorldModels()
        return
    end
    if !IsValid(owner) or !(owner:IsPlayer() or owner:IsNPC()) then
        self:RemoveWorldModels()
        return
    end
    // These rigs merge onto the right hand. A custom NPC without that bone
    // needs the engine's normal weapon renderer, not a copy at its root origin.
    local hand = MCV.CachedBone(owner, R_HAND)
    if !hand then self:RemoveWorldModels() return end
    local changed = adjustOwnerBone(owner, self:GetWorldModelBoneAdjust())
    // NPC weapons can draw outside the owner's pass. Rebuild before merging;
    // also rebuild immediately if this call changed a player's bone adjustment.
    if !drawing or owner:IsNPC() or changed then owner:SetupBones() end
    if !owner:GetBoneMatrix(hand) then self:RemoveWorldModels() return end
    local right = self:GetWorldModelEntity(false)
    if !right then return end
    copyLook(self, right)
    right:SetupBones()

    local drawnLeft
    if self.GetAkimbo and self:GetAkimbo() then
        local left = self:GetWorldModelEntity(true)
        local pos, ang = self:GetWorldModelTransformLeft(right, left)
        if left and pos then
            left:SetPos(pos)
            left:SetAngles(ang)
            copyLook(self, left)
            left:SetupBones()
            drawnLeft = left
        end
    elseif IsValid(self.WMLeft) then
        MCV.RemoveClientModel(self, "WMLeft")
        self.WMLeftBind = nil
    end
    // A failed left-hand transform must not draw an old/default pose.
    return right, drawnLeft
end

function SWEP:DrawWorldModel(flags)
    local right, left = self:UpdateWorldModels(true)
    if IsValid(right) then
        right:DrawModel()
        if IsValid(left) then left:DrawModel() end
    elseif !self:IsDormant() then
        self:DrawModel()
    end
end

// The model the third person effects attach to (right or left gun)
function SWEP:GetWorldModelFor(left)
    local right, other = self:UpdateWorldModels()
    local mdl = left and other or right
    if IsValid(mdl) then return mdl end
    return self
end

// Retire particles along with their attachment models on PVS loss. Re-entry
// lazily rebuilds them; never keep an orphaned model at an old world position.
hook.Add("NotifyShouldTransmit", "MCV_WorldModelPVS", function(ent, transmitting)
    if transmitting then return end
    local wep = ent
    if ent.GetActiveWeapon then wep = ent:GetActiveWeapon() end
    if IsValid(wep) and wep.MilitaryConflictVietnam and wep.RemoveWorldModels then
        wep:RemoveWorldModels()
    end
end)

// Model and attachment id for a third person effect: kind "muzzle" or "eject", left gun or
// right. The game names the muzzle "muzzle" and the port "shell_eject" (a few models "eject");
// a model without the attachment returns 0 and the effect falls back.
local ejectAttachments = {"shell_eject", "eject", "eject2", "shell_eject2"}
function SWEP:GetWorldModelAttachment(kind, left)
    local mdl = self:GetWorldModelFor(left)
    if kind == "muzzle" then
        return mdl, math.max(MCV.CachedAttachment(mdl, "muzzle"), 0)
    end
    for _, name in ipairs(ejectAttachments) do
        local id = MCV.CachedAttachment(mdl, name)
        if id > 0 then return mdl, id end
    end
    return mdl, 0
end

function SWEP:OnRemove()
    if CLIENT then self:RemoveWorldModels() end
end
