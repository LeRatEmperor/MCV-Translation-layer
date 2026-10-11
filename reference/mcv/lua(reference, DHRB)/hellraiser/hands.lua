HRHands = HRHands or {}
local H = HRHands
local enabled = CreateClientConVar("hr_player_hands", "1", true, false, "Use your player model's hands on Hellraiser weapons")

local compatible = {}
local function playerHands(owner)
	local hands = IsValid(owner) and owner:GetHands()
	if not IsValid(hands) then return end
	local model = hands:GetModel()
	if not model or not util.IsValidModel(model) then return end
	if compatible[model] == nil then
		local reference = ClientsideModel(model, RENDERGROUP_OTHER)
		if not IsValid(reference) then return end
		reference:SetNoDraw(true)
		compatible[model] = reference:LookupBone("ValveBiped.Bip01_R_Hand") ~= nil
			and reference:LookupBone("ValveBiped.Bip01_L_Hand") ~= nil
		reference:Remove()
	end
	if compatible[model] then return hands end
end

function H.Prepare(model, owner, useHands)
	local path = model:GetModel()
	if model.hr_hands_model ~= path then
		model.hr_hands_model, model.hr_hand_groups, model.hr_hand_mode = path, {}, nil
		for _, group in ipairs(model:GetBodyGroups()) do
			if string.StartWith(group.name, "aidan_") then model.hr_hand_groups[#model.hr_hand_groups+1] = group.id end
		end
	end
	if #model.hr_hand_groups == 0 then return useHands ~= false and enabled:GetBool() and playerHands(owner) ~= nil end
	local use = enabled:GetBool() and playerHands(owner) ~= nil
	local value = use and 1 or 0
	for _, group in ipairs(model.hr_hand_groups) do
		if model:GetBodygroup(group) ~= value then model:SetBodygroup(group, value) end
	end
	model.hr_hand_mode = use
	return use
end

function H.Remove(model)
	if not IsValid(model) then return end
	if IsValid(model.hr_player_hands) then model.hr_player_hands:Remove() end
	model.hr_player_hands = nil
end

function H.DrawExecution(model, owner, hideSupport)
	if not H.Prepare(model, owner) then H.Remove(model) return end
	local source = playerHands(owner)
	local hands = model.hr_player_hands
	if not IsValid(hands) or hands:GetModel() ~= source:GetModel() then
		H.Remove(model)
		hands = ClientsideModel(source:GetModel(), RENDERGROUP_OPAQUE)
		if not IsValid(hands) then return end
		model.hr_player_hands = hands
		hands:SetNoDraw(true)
		hands:DrawShadow(false)
		hands:SetParent(model)
		hands:SetLocalPos(vector_origin)
		hands:SetLocalAngles(angle_zero)
		hands:AddEffects(EF_BONEMERGE)
		hands:SetOwner(owner)
		hands.GetPlayerColor = function(self)
			local player = self:GetOwner()
			return IsValid(player) and player:GetPlayerColor() or Vector(1, 1, 1)
		end
	end
	hands:SetSkin(source:GetSkin())
	hands:SetColor(source:GetColor())
	hands:SetMaterial(source:GetMaterial())
	for _, group in ipairs(source:GetBodyGroups()) do hands:SetBodygroup(group.id, source:GetBodygroup(group.id)) end
	for i = 0, #source:GetMaterials()-1 do hands:SetSubMaterial(i, source:GetSubMaterial(i)) end
    H.SupportArm(hands, hideSupport == true)
	hands:InvalidateBoneCache()
	hands:SetupBones()
	if model.ViewModelIndex and model:ViewModelIndex() == 1 then render.CullMode(MATERIAL_CULLMODE_CW) end
	hands:DrawModel()
    render.CullMode(MATERIAL_CULLMODE_CCW)
end

hook.Add("PreDrawPlayerHands", "hr_execution_hands", function(_, _, _, weapon)
	if IsValid(weapon) and weapon.HR
		and (weapon:GetNW2Bool("hr_executing") or (not weapon:HasScopeLens() and weapon:ScopeFraction() > 0.95)) then return true end
end)

local function collapseSupport(model)
    if not model.dhr_support_hidden and (model.dhr_support_lower or 0) <= 0 then return end
    local path = model:GetModel()
    if model.dhr_support_model ~= path or not model.dhr_support_bones or #model.dhr_support_bones == 0 then
        model.dhr_support_model, model.dhr_support_bones = path, {}
        for i = 0, model:GetBoneCount() - 1 do
            local name = model:GetBoneName(i)
            if name:find("ValveBiped.Bip01_L_", 1, true) or name:match("_l$") then
                model.dhr_support_bones[#model.dhr_support_bones + 1] = i
            end
        end
    end
    if not model.dhr_support_hidden then
        local offset = EyeAngles():Up() * (-38 * model.dhr_support_lower)
        for _, bone in ipairs(model.dhr_support_bones) do
            local matrix = model:GetBoneMatrix(bone)
            if matrix then matrix:SetTranslation(matrix:GetTranslation() + offset); model:SetBoneMatrix(bone, matrix) end
        end
        return
    end
    -- Collapse every joint together so the skinned mesh cannot stretch between them.
    local matrix = Matrix()
    matrix:SetTranslation(EyePos() - EyeAngles():Up() * 100)
    matrix:SetScale(vector_origin)
    for _, bone in ipairs(model.dhr_support_bones) do
        if model:GetBoneMatrix(bone) then model:SetBoneMatrix(bone, matrix) end
    end
end

function H.SupportArm(model, hidden, lower)
    if not IsValid(model) then return end
    if not hidden and not model.dhr_support_hidden and not lower and not model.dhr_support_lower then return end
    model.dhr_support_hidden = hidden
    model.dhr_support_lower = lower
    if not model.dhr_support_callback then
        model.dhr_support_callback = model:AddCallback("BuildBonePositions", collapseSupport)
    end
    model:InvalidateBoneCache()
end

hook.Add("PreDrawPlayerHands", "dhr_pistol_grip", function(hands, vm, owner, weapon)
    H.SupportArm(hands, DHR.OneHanded(weapon), DHR.SupportWithdrawal(weapon))
end)
