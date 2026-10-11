if SERVER then AddCSLuaFile() end
if HRDismember and HRDismember.Cleanup then HRDismember.Cleanup() end
HRDismember = HRDismember or {}
local D = HRDismember
local chance = CreateConVar('hr_dismember_chance', '0.35', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), 'Chance of dismemberment on a lethal Hellraiser head or limb hit', 0, 1)
local anyWeapon = CreateConVar('hr_dismember_any_weapon', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), 'Let every weapon dismember, not only the Hellraiser ones', 0, 1)
local livingEnabled = CreateConVar('hr_dismember_living', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), 'Dismember NPCs and players on killing hits and blunt executions', 0, 1)
local corpsesEnabled = CreateConVar('hr_dismember_corpses', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), 'Dismember corpses when shot or struck', 0, 1)
local playersEnabled = CreateConVar('hr_dismember_players', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), 'Enable dismemberment of players and their corpses', 0, 1)
local prefix = 'ValveBiped.Bip01_'
D.Parts = {
	{key='head', group=HITGROUP_HEAD, bone='Head1', from='Neck1', to='Head1', radius=2.6},
	{key='left_arm', group=HITGROUP_LEFTARM, bone='L_UpperArm', from='L_UpperArm', to='L_Forearm', radius=2.8},
	{key='right_arm', group=HITGROUP_RIGHTARM, bone='R_UpperArm', from='R_UpperArm', to='R_Forearm', radius=2.8},
	{key='left_leg', group=HITGROUP_LEFTLEG, bone='L_Thigh', from='L_Thigh', to='L_Calf', radius=4},
	{key='right_leg', group=HITGROUP_RIGHTLEG, bone='R_Thigh', from='R_Thigh', to='R_Calf', radius=4}
}
local groups = {}
for id,part in ipairs(D.Parts) do groups[part.group] = id; part.mask = bit.lshift(1,id-1) end

local aliases = {
    head = {'head1', 'head', 'headbone', 'headcontrol'},
    left_arm = {'lupperarm', 'upperarml', 'arm1l', 'arml1bone', 'upperarmlbone'},
    right_arm = {'rupperarm', 'upperarmr', 'arm1r', 'armr1bone', 'upperarmrbone'},
    left_leg = {'lthigh', 'thighl', 'legbone1l', 'legl1bone', 'leg1l', 'thighlbone'},
    right_leg = {'rthigh', 'thighr', 'legbone1r', 'legr1bone', 'leg1r', 'thighrbone'},
}
local rigs = {}
local function shortName(name)
    return name:lower():gsub('^.*%.', ''):gsub('^bip0[12]_?', ''):gsub('[^%w]', '')
end

function D.Part(e, id)
    local part = D.Parts[id]
    if not part or e:GetBoneCount() <= 0 then return end
    local model = e:GetModel()
    local rig = rigs[model]
    if not rig then
        rig = {}
        local names = {}
        for bone = 0, e:GetBoneCount() - 1 do names[shortName(e:GetBoneName(bone))] = bone end
        for index, definition in ipairs(D.Parts) do
            local root = e:LookupBone(prefix .. definition.bone)
            if not root then
                for _, name in ipairs(aliases[definition.key]) do
                    if names[name] then root = names[name]; break end
                end
            end
            if root and e:GetBoneParent(root) >= 0 then
                local from = e:LookupBone(prefix .. definition.from) or (index == 1 and e:GetBoneParent(root) or root)
                local to = e:LookupBone(prefix .. definition.to) or (index == 1 and root or e:GetChildBones(root)[1])
                local bones, safe = {}, true
                for bone = 0, e:GetBoneCount() - 1 do
                    local parent = bone
                    while parent >= 0 and parent ~= root do parent = e:GetBoneParent(parent) end
                    if parent == root then
                        bones[bone] = true
                        local name = shortName(e:GetBoneName(bone))
                        if name:find('spine', 1, true) or name:find('pelvis', 1, true)
                            or name:find('hips', 1, true) or name:find('chest', 1, true)
                            or name:find('body', 1, true) then safe = false end
                    end
                end
                if safe and from and to then rig[index] = {root = root, from = from, to = to, bones = bones} end
            end
        end
        rigs[model] = rig
    end
    return rig[id]
end

function D.Bones(e, id)
    local part = D.Part(e, id)
    return part and part.bones
end

function D.Cut(e, id)
    local part = D.Part(e, id)
    if not part then return end
    local a, b = e:GetBoneMatrix(part.from), e:GetBoneMatrix(part.to)
    if not a or not b then return end
    local normal = (b:GetTranslation() - a:GetTranslation()):GetNormalized()
    if normal:LengthSqr() < .5 then return end
    local point = id == 1 and LerpVector(.55, a:GetTranslation(), b:GetTranslation()) or a:GetTranslation() + normal * 1.5 * e:GetModelScale()
    return point, normal
end

function D.BloodColor(e)
    return e:GetNWInt('hr_blood_color', e:GetBloodColor() or BLOOD_COLOR_RED)
end

if SERVER then
	util.AddNetworkString('hr_dismember_setting')
	net.Receive('hr_dismember_setting',function(_,p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		if CurTime() < (p.hr_dismember_setting or 0) then return end
		p.hr_dismember_setting = CurTime()+.1
		chance:SetFloat(net.ReadUInt(7)/100)
	end)
	util.AddNetworkString('hr_dismember_any')
	net.Receive('hr_dismember_any',function(_,p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		anyWeapon:SetBool(net.ReadBool())
	end)
	util.AddNetworkString('hr_dismember_targets')
	net.Receive('hr_dismember_targets', function(_, p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		local setting = net.ReadBool() and corpsesEnabled or livingEnabled
		setting:SetBool(net.ReadBool())
	end)
	util.AddNetworkString('hr_dismember_players')
	net.Receive('hr_dismember_players', function(_, p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		playersEnabled:SetBool(net.ReadBool())
	end)
	local hits, forced = setmetatable({}, {__mode='k'}), setmetatable({}, {__mode='k'})
	local function blasts(w)
		return w:GetClass() == 'hr_shotgun' or HRUpgrades.Get(w, 'blast') == true
	end

	function D.Apply(e, id, force, time, inherited, destroyed)
		if not IsValid(e) or not D.Parts[id] then return end
		if DHR.GetBodyState(e).alive or DHR.RunHook("DHRCanDismember", e, nil, "apply") == false then return end
		local bones = D.Bones(e,id)
		if not bones then return end
		local part = D.Parts[id]
		if bit.band(e:GetNWInt('hr_severed'),part.mask) ~= 0 then return end
		e:SetNWInt('hr_blood_color', D.BloodColor(e))
		e:SetNWFloat('hr_wound_'..part.key, time or CurTime())
		e:SetNWVector('hr_wound_force_'..part.key, force or Vector(0,0,100))
		e:SetNWBool('hr_wound_debris_'..part.key, not inherited and not destroyed)
		e:SetNWInt('hr_severed',bit.bor(e:GetNWInt('hr_severed'),part.mask))
		if e:IsRagdoll() then
			for i=0,e:GetPhysicsObjectCount()-1 do
				if bones[e:TranslatePhysBoneToBone(i)] then
					local physics = e:GetPhysicsObjectNum(i)
					if IsValid(physics) then physics:EnableCollisions(false) end
				end
			end
		end
	end

	local function ours(w)
		return IsValid(w) and w.HR and (w.HR.kind == 'gun' or w.HR.kind == 'melee')
	end

	function D.CorpseHit(w, tr, amount, force, blast)
		local rag = tr.Entity
		if not corpsesEnabled:GetBool() or chance:GetFloat() <= 0 or amount <= 0 or not IsValid(rag) or not rag:IsRagdoll() then return end
		local body = DHR.GetBodyState(rag)
		if body.alive or DHR.RunHook("DHRCanDismember", rag, w, "corpse") == false then return end
		if (rag:GetNWBool('hr_player_corpse') or IsValid(body.owner) and body.owner:IsPlayer()) and not playersEnabled:GetBool() then return end
		if not ours(w) and not anyWeapon:GetBool() then return end
		if blast == nil then blast = ours(w) and blasts(w) end
		local physicsBone = tr.PhysicsBone
		if not physicsBone or physicsBone < 0 then return end
		if not rag.hr_dismember_parts then
			local mapping = {}
			for id in ipairs(D.Parts) do
				local bones = D.Bones(rag,id)
				if bones then
					for i=0,rag:GetPhysicsObjectCount()-1 do
						if bones[rag:TranslatePhysBoneToBone(i)] then mapping[i] = id end
					end
				end
			end
			rag.hr_dismember_parts = mapping
		end
		local id = rag.hr_dismember_parts[physicsBone]
		if not id or bit.band(rag:GetNWInt('hr_severed'),D.Parts[id].mask) ~= 0 then return end
		rag.hr_limb_damage = rag.hr_limb_damage or {}
		local hit = rag.hr_limb_damage[id] or {damage=0}
		hit.damage = hit.damage+amount
		hit.force = force:GetNormalized()*130+Vector(0,0,75)
		hit.destroyed = hit.destroyed or blast
		rag.hr_limb_damage[id] = hit
		if rag.hr_gore_pending then return end
		rag.hr_gore_pending = true
		timer.Simple(0,function()
			if not IsValid(rag) then return end
			rag.hr_gore_pending = nil
			if not corpsesEnabled:GetBool() or chance:GetFloat() <= 0 or DHR.GetBodyState(rag).alive
				or DHR.RunHook("DHRCanDismember", rag, w, "corpse") == false then return end
			for part, wound in pairs(rag.hr_limb_damage) do
				if wound.destroyed or wound.damage >= 30 then
					D.Apply(rag,part,wound.force,nil,false,wound.destroyed)
					rag.hr_limb_damage[part] = nil
				end
			end
		end)
	end

	function D.Copy(from, to)
		to:SetNWInt('hr_blood_color', D.BloodColor(from))
		local subject = from:GetNW2Entity('hr_execution_subject')
		if from:GetNWBool('hr_player_corpse') or IsValid(subject) and subject:IsPlayer() then
			to:SetNWBool('hr_player_corpse', true)
			to:SetNWVector('hr_player_color', from:GetNWVector('hr_player_color', Vector(255,255,255)))
		end
		for id,part in ipairs(D.Parts) do
			if bit.band(from:GetNWInt('hr_severed'),part.mask) ~= 0 then
				D.Apply(to,id,from:GetNWVector('hr_wound_force_'..part.key),from:GetNWFloat('hr_wound_'..part.key),true)
			end
		end
	end

	function D.Execution(w, body, force)
		if not livingEnabled:GetBool() or DHR.RunHook("DHRCanDismember", body, w, "execution") == false then return end
		local subject = IsValid(body) and body:GetNW2Entity('hr_execution_subject')
		if IsValid(subject) and subject:IsPlayer() and not playersEnabled:GetBool() then return end
		if IsValid(w) and w.HR and w.HR.kind == 'melee' and w.HR.sharp == false and math.Rand(0,1) < chance:GetFloat() then
			D.Apply(body,1,force)
		end
	end

	local function recordHit(npc, group, damage)
		if not livingEnabled:GetBool() then return end
		local hit = hits[npc]
		if not hit or hit.time ~= CurTime() then hit = {time=CurTime(),groups={}}; hits[npc] = hit end
		hit.groups[group] = (hit.groups[group] or 0)+damage:GetDamage()
	end
	hook.Add('ScaleNPCDamage', 'hr_dismember_hit', recordHit)
	hook.Add('ScalePlayerDamage', 'hr_dismember_hit', recordHit)
	hook.Add('PostEntityTakeDamage', 'hr_dismember_player_hit', function(p)
		if p:IsPlayer() then hits[p] = nil end
	end)
	hook.Add('PlayerSpawn', 'hr_dismember_player_hit', function(p) hits[p] = nil end)
	local function nearestPart(e, at)
		local best, closest
		for id, part in ipairs(D.Parts) do
			local rig = D.Part(e, id)
			local a, b = rig and rig.from, rig and rig.to
			local from, to = a and e:GetBonePosition(a), b and e:GetBonePosition(b)
			if from and to then
				if id == 1 then to = to + (to-from):GetNormalized()*6 end
				local distance = util.DistanceToLine(from, to, at)
				if distance < part.radius+14 and (not closest or distance < closest) then best, closest = id, distance end
			end
		end
		return best
	end

	local function bulletPart(e, damage)
		local direction = damage:GetDamageForce():GetNormalized()
		if direction:LengthSqr() < .5 then return end
		local start = damage:GetDamagePosition() - direction * 2
		local delta = direction * ((e:OBBMaxs() - e:OBBMins()):Length() + 4)
		local hitBone, closest
		local set = e:GetHitboxSet()
		for box = 0, e:GetHitBoxCount(set) - 1 do
			local bone = e:GetHitBoxBone(box, set)
			local matrix = e:GetBoneMatrix(bone)
			if matrix then
				local mins, maxs = e:GetHitBoxBounds(box, set)
				local _, _, fraction = util.IntersectRayWithOBB(start, delta, matrix:GetTranslation(), matrix:GetAngles(),
					mins * e:GetModelScale(), maxs * e:GetModelScale())
				if fraction and (not closest or fraction < closest) then hitBone, closest = bone, fraction end
			end
		end
		if not hitBone then return end
		for id in ipairs(D.Parts) do
			local bones = D.Bones(e, id)
			if bones and bones[hitBone] then return id end
		end
	end

	local function otherCorpseHit(rag, damage)
		local w = damage:GetInflictor()
		if ours(w) or not anyWeapon:GetBool() or not damage:IsDamageType(bit.bor(DMG_BULLET,DMG_BUCKSHOT,DMG_SLASH,DMG_CLUB)) then return end
		local at, along = damage:GetDamagePosition(), damage:GetDamageForce():GetNormalized()
		if along:LengthSqr() < .5 then along = (at-rag:WorldSpaceCenter()):GetNormalized() end
		local tr = util.TraceLine({start=at-along*12, endpos=at+along*12, filter=function(e) return e == rag end, ignoreworld=true, mask=MASK_SHOT})
		if tr.Entity ~= rag then return end
		D.CorpseHit(w, tr, damage:GetDamage(), damage:GetDamageForce(), damage:IsDamageType(DMG_BUCKSHOT))
	end

	function D.DeathWound(target, damage)
		if target.hr_execution or damage:IsDamageType(DMG_REMOVENORAGDOLL) then return end
		if target:IsPlayer() and not playersEnabled:GetBool() then return end
		local w = damage:GetInflictor()
		if DHR.RunHook("DHRCanDismember", target, w, "death") == false then return end
		if not ours(w) and not anyWeapon:GetBool() then return end
		if not damage:IsDamageType(bit.bor(DMG_BULLET,DMG_BUCKSHOT,DMG_SLASH,DMG_CLUB)) or damage:GetDamage() <= 0 then return end
		if chance:GetFloat() <= 0 or not (livingEnabled:GetBool() or corpsesEnabled:GetBool()) then return end
		if not livingEnabled:GetBool() then hits[target] = nil return true end
		local hit = hits[target]
		hits[target] = nil
		local struck = hit and hit.time == CurTime() and hit.groups or {}
		local limb = false
		for group in pairs(struck) do limb = limb or groups[group] ~= nil end
		if not limb and (damage:IsDamageType(bit.bor(DMG_SLASH,DMG_CLUB)) or struck[HITGROUP_GENERIC]) then
			local id
			if (damage:IsBulletDamage() or target:IsPlayer()) and target:GetHitBoxCount(target:GetHitboxSet()) > 0 then
				id = bulletPart(target, damage)
			else
				id = nearestPart(target, damage:GetDamagePosition())
			end
			if id then struck = {[D.Parts[id].group] = damage:GetDamage()} end
		end
		if not next(struck) then return true end
		local blast = ours(w) and blasts(w) and damage:IsBulletDamage() or not ours(w) and damage:IsDamageType(DMG_BUCKSHOT)
		local parts = {}
		if blast then
			for group, amount in pairs(struck) do
				local id = groups[group]
				if id and amount > 0 and D.Bones(target,id) then parts[id] = true end
			end
		else
			local group, largest = nil, 0
			for candidate, amount in pairs(struck) do
				if amount > largest then group,largest = candidate,amount end
			end
			local id = groups[group]
			if id and D.Bones(target,id) and math.Rand(0,1) < chance:GetFloat() then parts[id] = true end
		end
		if target.Decapitated then parts[1] = nil end
		if next(parts) then return true, {time=CurTime(),parts=parts,force=damage:GetDamageForce(),destroyed=blast} end
		return true
	end

	hook.Add('EntityTakeDamage','hr_dismember_hit',function(npc,damage)
		if npc:IsRagdoll() then return otherCorpseHit(npc, damage) end
		if not npc:IsNPC() or npc:Health() <= 0 then return end
		npc.hr_dismember_wound = nil
		local eligible, wound = D.DeathWound(npc, damage)
		if not eligible then return end
		npc.hr_dismember_wound = wound
		if not forced[npc] then
			forced[npc] = {previous=npc:GetShouldServerRagdoll()}
			timer.Simple(0,function()
				local state = forced[npc]
				if state and IsValid(npc) and npc:Health() > 0 then
					npc.hr_dismember_wound = nil
					npc:SetShouldServerRagdoll(state.previous)
				end
				forced[npc] = nil
			end)
		end
		npc:SetShouldServerRagdoll(true)
	end)
	hook.Add('CreateEntityRagdoll','hr_dismember_hit',function(npc,rag)
		if IsValid(rag) then
			rag:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
			rag:SetNWInt('hr_blood_color', D.BloodColor(npc))
		end
		if not livingEnabled:GetBool() then return end
		local wound = npc.hr_dismember_wound
		if not wound or CurTime()-wound.time > .1 or not IsValid(rag) then return end
		for id in pairs(wound.parts) do D.Apply(rag,id,wound.force:GetNormalized()*130+Vector(0,0,75),nil,false,wound.destroyed) end
		timer.Simple(0,function()
			if not IsValid(rag) then return end
			for i=0,rag:GetPhysicsObjectCount()-1 do
				local physics = rag:GetPhysicsObjectNum(i)
				if not IsValid(physics) then continue end
				local velocity = physics:GetVelocity()
				if velocity:LengthSqr() > 300*300 then physics:SetVelocity(velocity:GetNormalized()*300) end
				local spin = physics:GetAngleVelocity()
				if spin:LengthSqr() > 540*540 then physics:AddAngleVelocity(spin:GetNormalized()*540-spin) end
			end
		end)
	end)
	return
end

function D.SetChance(value)
	net.Start('hr_dismember_setting'); net.WriteUInt(math.Clamp(math.Round(value),0,100),7); net.SendToServer()
end

function D.SetAnyWeapon(on)
	net.Start('hr_dismember_any'); net.WriteBool(on); net.SendToServer()
end

function D.SetPlayersEnabled(on)
	net.Start('hr_dismember_players'); net.WriteBool(on); net.SendToServer()
end

function D.SetTargetEnabled(corpse, on)
	net.Start('hr_dismember_targets'); net.WriteBool(corpse); net.WriteBool(on); net.SendToServer()
end

local wounds, pending = {}, {}
local severSounds = {head = 'HR.Cultist_Dismemberment_HeadShot', left_arm = 'HR.Cultist_Dismemberment_ArmBreak',
	right_arm = 'HR.Cultist_Dismemberment_ArmBreak', left_leg = 'HR.Cultist_Dismemberment_LegBreak', right_leg = 'HR.Cultist_Dismemberment_LegBreak'}
local flesh = Material('hellraiser/gore_wound')
local bloodStyles = {
    [BLOOD_COLOR_RED] = {color = Color(145, 8, 5), decal = 'Blood', flesh = flesh},
    [BLOOD_COLOR_YELLOW] = {color = Color(185, 165, 35), decal = 'YellowBlood'},
    [BLOOD_COLOR_GREEN] = {color = Color(105, 145, 35), decal = 'YellowBlood'},
    [BLOOD_COLOR_ANTLION_WORKER] = {color = Color(125, 210, 45), decal = 'YellowBlood'},
}
bloodStyles[BLOOD_COLOR_ANTLION] = bloodStyles[BLOOD_COLOR_YELLOW]
bloodStyles[BLOOD_COLOR_ZOMBIE] = bloodStyles[BLOOD_COLOR_GREEN]
for id, style in pairs(bloodStyles) do
    if not style.flesh then
        style.flesh = CreateMaterial('hr_gore_blood_' .. id, 'UnlitGeneric', {
            ['$basetexture'] = 'models/hellraiser_npcs/mi_flesh_cultists_d',
            ['$color'] = '[' .. style.color.r / 255 .. ' ' .. style.color.g / 255 .. ' ' .. style.color.b / 255 .. ']',
            ['$nocull'] = '1',
        })
    end
end
function D.BloodStyle(e) return bloodStyles[D.BloodColor(e)] end
function D.Flesh(e)
    local style = D.BloodStyle(e)
    return style and style.flesh or flesh
end
local function position(e, part)
	local matrix = e:GetBoneMatrix(part.parent)
	if not matrix then return end
	part.position = matrix*part.localPoint
	part.normal = (matrix*(part.localPoint+part.localNormal)-part.position):GetNormalized()
end
local function attach(e)
	-- The wound mask can arrive before the blood colour.
	if e:GetNWInt('hr_blood_color', -2) == -2 then return end
	e:SetupBones()
	local state = wounds[e] or {parts={}}
	for id,part in ipairs(D.Parts) do
		if state.parts[id] or bit.band(e:GetNWInt('hr_severed'),part.mask) == 0 then continue end
		local bones, point, normal = D.Bones(e,id), D.Cut(e,id)
		if not bones or not point then continue end
		local parent = e:GetBoneParent(D.Part(e, id).root)
		local matrix = parent >= 0 and e:GetBoneMatrix(parent)
		if not matrix then continue end
		local inverse = matrix:GetInverse()
		local localPoint = inverse*point
		local localNormal = (inverse*(point+normal)-localPoint):GetNormalized()
		local time = e:GetNWFloat('hr_wound_'..part.key)
		local fresh = CurTime()-time < 2
		local blood = D.BloodStyle(e)
		local script = fresh and CurTime()-time < .5 and sound.GetProperties(severSounds[part.key])
		if script then
			local path = istable(script.sound) and table.Random(script.sound) or script.sound
			sound.Play(path:gsub('^[%)%^]', ''), point, 80, math.random(96, 104), 1)
		end
		if fresh and e:GetNWBool('hr_wound_debris_'..part.key) then
			local fx = EffectData(); fx:SetEntity(e); fx:SetOrigin(point); fx:SetNormal(normal); fx:SetAttachment(id)
			util.Effect('hr_limb_gib',fx)
		end
		local scales = {}
		for bone in pairs(bones) do
			scales[bone] = e:GetManipulateBoneScale(bone)
			e:ManipulateBoneScale(bone, Vector(.001,.001,.001))
		end
		state.parts[id] = {bones=bones, scales=scales, parent=parent, localPoint=localPoint, localNormal=localNormal, position=point, normal=normal, nextSpray=0, stop=time+3,
			blood=blood, emitter=fresh and blood and EyePos():DistToSqr(point)<2000*2000 and ParticleEmitter(point) or nil}
	end
	state.mask = 0
	for id in pairs(state.parts) do state.mask = bit.bor(state.mask,D.Parts[id].mask) end
	wounds[e] = state
	e:InvalidateBoneCache()
end

hook.Add('EntityNetworkedVarChanged','hr_severed_parts',function(e,name,old,value)
	if name == 'hr_severed' and value ~= 0 then pending[e] = true end
end)
local nextScan = 0
hook.Add('Think','hr_dismember',function()
	if CurTime() >= nextScan then
		nextScan = CurTime()+.1
		for _,class in ipairs({'prop_ragdoll','cycler_actor'}) do
			for _,e in ipairs(ents.FindByClass(class)) do
				local mask = e:GetNWInt('hr_severed')
				if mask ~= 0 and (not wounds[e] or wounds[e].mask ~= mask) then attach(e) end
			end
		end
	end
	for e,state in pairs(wounds) do
		for _,part in pairs(state.parts) do
			if IsValid(e) then position(e,part) end
			if not IsValid(e) or CurTime() >= part.stop then
				if part.emitter then part.emitter:Finish(); part.emitter=nil end
			elseif part.emitter and CurTime() >= part.nextSpray then
				part.nextSpray = CurTime()+.08
				local fade = math.Clamp((part.stop-CurTime())/3,0,1)
				for i=1,math.ceil(18*fade) do
					local drop = part.emitter:Add('effects/blood_core',part.position+VectorRand())
					if drop then
						drop:SetVelocity(part.normal*math.Rand(70,140)*fade+VectorRand()*35)
						drop:SetGravity(Vector(0,0,-400)); drop:SetDieTime(math.Rand(.5,1.1))
						drop:SetStartAlpha(235); drop:SetEndAlpha(0); drop:SetStartSize(math.Rand(1.4,3.5)); drop:SetEndSize(.2)
						drop:SetColor(part.blood.color.r, part.blood.color.g, part.blood.color.b); drop:SetCollide(true); drop:SetBounce(0)
						if i==1 then drop:SetCollideCallback(function(p,hit,direction) util.Decal(part.blood.decal,hit+direction,hit-direction,player.GetAll());p:SetDieTime(0) end) end
					end
				end
			end
		end
		if not IsValid(e) then wounds[e]=nil end
	end
end)
hook.Add('PreDrawOpaqueRenderables','hr_severed_parts',function(depth,sky)
	if depth or sky then return end
	for e in pairs(pending) do
		if IsValid(e) then
			attach(e)
		end
		pending[e] = nil
	end
	for e,state in pairs(wounds) do
		if IsValid(e) and not e:IsDormant() then
			for _,part in pairs(state.parts) do position(e,part) end
		end
	end
end)
hook.Add('PostDrawOpaqueRenderables','hr_severed_wounds',function(depth,sky)
	if depth or sky then return end
	for e,state in pairs(wounds) do
		if not IsValid(e) or e:IsDormant() then continue end
		render.SetMaterial(D.Flesh(e))
		for id,part in pairs(state.parts) do render.DrawSphere(part.position,D.Parts[id].radius*e:GetModelScale(),10,8,color_white) end
	end
end)
local function cleanup()
	for e,state in pairs(wounds) do
		for _,part in pairs(state.parts) do
			if part.emitter then part.emitter:Finish() end
			if IsValid(e) then
				for bone,scale in pairs(part.scales) do e:ManipulateBoneScale(bone,scale) end
			end
		end
	end
	wounds, pending = {}, {}
end
D.Cleanup = cleanup
hook.Add('PreCleanupMap','hr_dismember',cleanup)
hook.Add('ShutDown','hr_dismember',cleanup)
