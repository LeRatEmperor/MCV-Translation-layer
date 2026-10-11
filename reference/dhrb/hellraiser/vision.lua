if not CLIENT then return end
if HRVision and HRVision.Restore then HRVision.Restore() end
HRVision = HRVision or {}
local V = HRVision
local changed, props, skyModels, nextScan = {}, {}, {}, 0
local enabled = CreateClientConVar('hr_hellvision_world', '1', true, false, 'Transform the world while Hell Vision is active')
local textures = {}
for _, name in ipairs({'stone', 'metal', 'flesh'}) do textures[name] = Material('hellraiser/vision/'..name..'_world'):GetTexture('$basetexture') end

function V.Active()
	local p = LocalPlayer()
	local w = IsValid(p) and p:GetActiveWeapon()
	if not IsValid(p) or not p:Alive() then return false end
	if p:GetNW2Bool('hr_chatterer_vision') and cvars.Bool('hr_npc_hellvision', true) then return true end
	return IsValid(w) and w:GetClass() == 'hr_cube' and w:GetNW2Float('hr_vision') > CurTime()
end

local mapMaterials, placedDecals
local function lump(f, index)
	f:Seek(8 + index * 16)
	local offset, length, version, compression = f:ReadLong(), f:ReadLong(), f:ReadLong(), f:ReadLong()
	if compression ~= 0 or offset < 1036 or length <= 0 or length > 32 * 1024 * 1024 or offset + length > f:Size() then return end
	f:Seek(offset)
	return f:Read(length)
end
local function mapOverlays()
	if mapMaterials then return mapMaterials end
	mapMaterials, placedDecals = {}, {}
	local f = file.Open('maps/'..game.GetMap()..'.bsp', 'rb', 'GAME')
	if not f then return mapMaterials end
	if f:Size() >= 1036 and f:Read(4) == 'VBSP' then
		for name in (lump(f, 43) or ''):gmatch('[^%z]+') do mapMaterials[#mapMaterials + 1] = name end
		for block in (lump(f, 0) or ''):gmatch('{(.-)}') do
			if block:find('"classname" "infodecal"', 1, true) or block:find('"classname" "info_overlay"', 1, true) then
				local name = block:match('"texture" "([^"]+)"') or block:match('"material" "([^"]+)"')
				if name then
					mapMaterials[#mapMaterials + 1] = name
					placedDecals[string.lower(name)] = true
				end
			end
		end
	end
	f:Close()
	return mapMaterials
end

local function replace(name, decalsOnly)
	name = string.lower(name)
	if changed[name] or name:find('hellraiser', 1, true) or name:find('tools/', 1, true) or name:find('skybox/', 1, true) then return end
	local mat = Material(name)
	if mat:IsError() then return end
	local flags = mat:GetInt('$flags') or 0
	if bit.band(flags, 65536) ~= 0 or placedDecals and placedDecals[name] then
		changed[name] = {material=mat, flags=flags, values={}}
		mat:SetInt('$flags', bit.bor(flags, 4))
		return
	end
	if decalsOnly then return end
	local shader = mat:GetShader():lower()
	if (not shader:StartWith('lightmappedgeneric') and not shader:StartWith('worldvertextransition') and not shader:StartWith('vertexlitgeneric')) then return end
	if bit.band(flags, 2097152 + 256) ~= 0 then return end
	local old = mat:GetTexture('$basetexture')
	if not old or old:IsError() or old:GetName() == 'error' then return end
	local kind = name:find('metal') and 'metal' or (name:find('wood') or name:find('flesh')) and 'flesh' or 'stone'
	local backup = CreateMaterial('hr_vision_backup_'..util.CRC(name), 'UnlitGeneric', {})
	local entry = {material=mat, backup=backup, values={}}
	for _, key in ipairs({'$basetexture', '$basetexture2', '$bumpmap', '$bumpmap2'}) do
		local value = mat:GetTexture(key)
		if value and not value:IsError() and value:GetName() ~= 'error' then
			backup:SetTexture(key, value)
			entry.values[key] = value
			mat:SetTexture(key, key:find('bump') and 'dev/flat_normal' or textures[kind])
		end
	end
	entry.color = mat:GetVector('$color') or Vector(1, 1, 1)
	mat:SetVector('$color', kind == 'flesh' and Vector(.6, .24, .22) or kind == 'metal' and Vector(.5, .4, .3) or Vector(.42, .44, .48))
	changed[name] = entry
end

local function restoreProp(e, state)
	if IsValid(e) and e.RenderOverride == state.draw then e.RenderOverride = state.previous end
	if IsValid(state.model) then state.model:Remove() end
	props[e] = nil
end

function V.Restore()
	for _, state in pairs(changed) do
		for key, value in pairs(state.values) do state.material:SetTexture(key, value) end
		if state.color then state.material:SetVector('$color', state.color) end
		if state.flags then state.material:SetInt('$flags', state.flags) end
	end
	changed = {}
	for e, state in pairs(props) do restoreProp(e, state) end
	for _, model in pairs(skyModels) do if IsValid(model) then model:Remove() end end
	skyModels = {}
	V.Transformed = false
end

local function prop(e)
	if props[e] or table.Count(props) >= 48 then return end
	local name = (e:GetModel() or ''):lower()
	local kind = (name:find('barrel') or name:find('oildrum')) and 'pillar'
		or (name:find('crate') or name:find('box')) and 'block'
		or (name:find('lamp') or name:find('light')) and 'torch'
	if not kind then return end
	local model = ClientsideModel('models/weapons/hellraiser/vision_'..kind..'.mdl', RENDERGROUP_OPAQUE)
	if not IsValid(model) then return end
	model:SetNoDraw(true); model:DrawShadow(false)
	local lo, hi = model:GetModelBounds()
	local size, target = hi-lo, e:OBBMaxs()-e:OBBMins()
	local scale = Vector(math.Clamp(target.x/math.max(size.x,1),.1,10), math.Clamp(target.y/math.max(size.y,1),.1,10), math.Clamp(target.z/math.max(size.z,1),.1,10))
	local matrix = Matrix(); matrix:Scale(scale); model:EnableMatrix('RenderMultiply',matrix)
	local offset = e:OBBCenter()-Vector((lo.x+hi.x)*scale.x,(lo.y+hi.y)*scale.y,(lo.z+hi.z)*scale.z)*.5
	local state = {model=model, previous=e.RenderOverride}
	state.draw = function(entity)
		if IsValid(model) and V.Transformed then
			model:SetPos(entity:LocalToWorld(offset)); model:SetAngles(entity:GetAngles())
			model:SetupBones(); model:DrawModel()
		elseif state.previous then state.previous(entity) else entity:DrawModel() end
	end
	e.RenderOverride = state.draw
	props[e] = state
end

local function drawSky()
	if not V.Transformed then return end
	for _, name in ipairs({'sky', 'leviathan'}) do
		if not IsValid(skyModels[name]) then
			local model = ClientsideModel('models/weapons/hellraiser/vision_'..name..'.mdl', RENDERGROUP_OPAQUE)
			if IsValid(model) then model:SetNoDraw(true); model:DrawShadow(false); skyModels[name] = model end
		end
	end
	render.OverrideDepthEnable(true, false)
	cam.Start3D(vector_origin, render.GetViewSetup().angles)
	render.SuppressEngineLighting(true)
	local sky = skyModels.sky
	if IsValid(sky) then
		sky:SetPos(vector_origin); sky:SetAngles(Angle(0, CurTime()*.15, 0))
		sky:SetupBones(); sky:DrawModel()
	end
	local leviathan = skyModels.leviathan
	if IsValid(leviathan) then
		render.SetColorModulation(.4, .42, .5)
		leviathan:SetPos(Vector(-40,180,65)); leviathan:SetAngles(Angle(0,CurTime()*.7,0))
		leviathan:SetupBones(); leviathan:DrawModel()
		render.SetColorModulation(1,1,1)
	end
	render.SuppressEngineLighting(false)
	cam.End3D()
	render.OverrideDepthEnable(false, false)
end

hook.Add('PreDrawSkyBox', 'hr_hellvision_sky', function()
	if not V.Transformed then return end
	drawSky()
	return true
end)
hook.Add('PostDraw2DSkyBox', 'hr_hellvision_sky', drawSky)

hook.Add('Think', 'hr_hellvision_world', function()
	local on = enabled:GetBool() and V.Active()
	if not on then if V.Transformed then V.Restore() end return end
	if not V.Transformed then
		V.Transformed = true
		local overlays = mapOverlays()
		for _, name in ipairs(game.GetWorld():GetMaterials()) do
			replace(name)
			local patch = 'maps/'..game.GetMap()..'/'..name..'_wvt_patch'
			if file.Exists('materials/'..patch..'.vmt', 'GAME') then replace(patch) end
		end
		for _, name in ipairs(overlays) do replace(name, true) end
		nextScan = 0
	end
	if CurTime() < nextScan then return end
	nextScan = CurTime() + .3
	for e, state in pairs(props) do
		if not IsValid(e) or e:IsDormant() or e:GetPos():DistToSqr(EyePos()) > 3500*3500 then restoreProp(e, state) end
	end
	local playerMaterials = {}
	for _, p in ipairs(player.GetAll()) do
		for _, name in ipairs(p:GetMaterials()) do playerMaterials[name:lower()] = true end
	end
	for _, e in ipairs(ents.FindInSphere(EyePos(), 3000)) do
		local class = e:GetClass()
		if e == LocalPlayer() or e:GetNW2Bool('hr_npc_victim_body') or e:IsWeapon() or not e:GetModel() or (not e:IsNPC() and not e:IsNextBot() and not e:IsRagdoll() and not string.StartWith(class, 'prop_') and not string.StartWith(class, 'func_')) then continue end
		if string.StartWith(class, 'prop_') and not e:IsRagdoll() then prop(e) end
		for _, name in ipairs(e:GetMaterials()) do if not playerMaterials[name:lower()] then replace(name) end end
	end
end)
hook.Add('PreCleanupMap', 'hr_hellvision_world', V.Restore)
hook.Add('ShutDown', 'hr_hellvision_world', V.Restore)

hook.Add('SetupWorldFog', 'hr_hellvision_world', function()
	if not V.Transformed then return end
	render.FogMode(MATERIAL_FOG_LINEAR); render.FogColor(22, 25, 34)
	render.FogStart(400); render.FogEnd(2400); render.FogMaxDensity(.8)
	return true
end)
hook.Add('SetupSkyboxFog', 'hr_hellvision_world', function(scale)
	if not V.Transformed then return end
	render.FogMode(MATERIAL_FOG_LINEAR); render.FogColor(22, 25, 34)
	render.FogStart(0); render.FogEnd(100*scale); render.FogMaxDensity(1)
	return true
end)
