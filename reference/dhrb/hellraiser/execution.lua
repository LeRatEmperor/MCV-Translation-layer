if SERVER then
	AddCSLuaFile()
	if file.Exists('hellraiser/execution_data.lua', 'LUA') then AddCSLuaFile('hellraiser/execution_data.lua') end
end

HRExecutions = HRExecutions or {}
local X = HRExecutions
local profiles = DHR.LoadData('hellraiser/execution_data.lua', {weapons = {}})
for class, entries in pairs(profiles.weapons) do
	if not DHR.ExecutionProfiles[class] then DHR.ExecutionProfiles[class] = entries end
end
X.Data = {weapons = DHR.ExecutionProfiles}
include('hellraiser/execution_players.lua')
local enabled = CreateConVar('hr_executions', '1', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), 'Enable front finishers and rear takedowns on humanoid targets')
local healthThreshold = CreateConVar('hr_execution_health_percent', '25', bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED), 'Allow frontal finishers against aware NPCs at or below this health percentage; 0 disables', 0, 100)

if SERVER then
	util.AddNetworkString('hr_execution_health_setting')
	net.Receive('hr_execution_health_setting', function(_, p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		if CurTime() < (p.hr_execution_health_setting or 0) then return end
		p.hr_execution_health_setting = CurTime() + 0.1
		healthThreshold:SetInt(math.Clamp(net.ReadUInt(7), 0, 100))
	end)
else
	function X.SetHealthThreshold(value)
		timer.Create('hr_execution_health_setting', 0.2, 1, function()
			net.Start('hr_execution_health_setting')
			net.WriteUInt(math.Clamp(math.Round(value), 0, 100), 7)
			net.SendToServer()
		end)
	end
end

function X.Profile(w, index)
	local profiles = X.Data.weapons[w:GetNW2String('hr_execution_weapon', w:GetClass())]
	if not profiles then return end
	index = index or w:GetNW2Int('hr_execution_variant', 1)
	return profiles[math.Clamp(index, 1, #profiles)]
end

local function executionPosition(p, e, D, approach, yaw)
	local ang = Angle(0, yaw or (e:GetAngles().y + ((approach or D.approach) == 'front' and 180 or 0)), 0)
	local origin = e:GetPos() - ang:Forward() * D.distance * (D.player_scale or 1)
	local hull = util.TraceHull({start = p:GetPos(), endpos = origin,
		mins = p:OBBMins(), maxs = p:OBBMaxs(), filter = {p, e}, mask = MASK_PLAYERSOLID})
	if hull.Hit then return end
	return origin, ang
end

local function selectProfile(w, e)
	local p = w:GetOwner()
	local toward = p:GetPos() - e:GetPos()
	toward.z = 0
	if toward:Length() > 72 or math.abs(p:GetPos().z - e:GetPos().z) > 18 then return end
	toward:Normalize()
	local facing = (e:IsPlayer() and Angle(0,e:EyeAngles().y,0):Forward() or e:GetForward()):Dot(toward)
	local approaches, lineup
	if SERVER then
		if e:IsPlayer() then
			if facing >= .55 then
				if X.Players.Aware(e,p) then return end
				approaches = {'front'}
			elseif facing <= -.55 then approaches = {'rear'}
			else return end
		elseif e:Disposition(p) == D_LI then
			approaches, lineup = facing >= 0 and {'front', 'rear'} or {'rear', 'front'}, true
		else
			local engaged = HRStealth and HRStealth.Aware(e, p)
			if not HRStealth then engaged = e:GetEnemy() == p or (e:Disposition(p) == D_HT and table.HasValue(e:GetKnownEnemies(), p)) end
			if facing >= 0.55 then
				local maxHealth = e:GetMaxHealth()
				local wounded = healthThreshold:GetInt() > 0 and maxHealth > 0
					and e:Health() <= maxHealth * healthThreshold:GetInt() / 100
				if engaged and not wounded then return end
				approaches = {'front'}
			else
				approaches, lineup = {'rear'}, facing > -0.55 or nil
			end
		end
	elseif w:GetNW2Entity('hr_takedown') == e and w:GetNW2Bool('hr_takedown_lineup') then
		approaches, lineup = {w:GetNW2Bool('hr_takedown_front') and 'front' or 'rear'}, true
	elseif facing >= 0.55 then
		if w:GetNW2Entity('hr_takedown') ~= e or not w:GetNW2Bool('hr_takedown_front') then return end
		approaches = {'front'}
	elseif facing <= -0.55 then
		approaches = {'rear'}
	else
		return
	end
	local yaw = lineup and (-toward):Angle().y or e:IsPlayer() and (e:EyeAngles().y + (approaches[1] == 'front' and 180 or 0)) or nil

	local source = w
	if not IsValid(source) or source:GetNW2Bool('hr_broken') then return end
	local profiles = X.Data.weapons[source:GetClass()]
	if not profiles then return end
	for _, approach in ipairs(approaches) do
		for offset = 1, #profiles do
			local index = ((w.hr_execution_variant or 0) + offset - 1) % #profiles + 1
			local profile = profiles[index]
			if profile.approach == approach and executionPosition(p, e, profile, approach, yaw) then
				return profile, index, source, approach, yaw
			end
		end
	end
end

function X.Target(w)
	if not DHR.HasFeature(w, "executions") or DHR.RunHook("DHRCanExecute", w) == false then return end
	if not enabled:GetBool() or not X.Data.weapons[w:GetClass()] or w:GetNW2Bool('hr_broken') then return end
	local p = w:GetOwner()
	if not IsValid(p) or not p:IsPlayer() or not p:Alive() or p:IsFrozen() or p.hr_execution or p:InVehicle() or not p:OnGround() then return end

	local tr = util.TraceHull({
		mins = Vector(-5, -5, -5), maxs = Vector(5, 5, 5),
		start = p:GetShootPos(),
		endpos = p:GetShootPos() + p:GetAimVector() * 96,
		filter = p,
		mask = MASK_SHOT
	})
	local e = tr.Entity
	if not IsValid(e) or not (e:IsNPC() or e:IsPlayer()) or e:Health() <= 0 or e.hr_execution or e.hr_execution_proxy or e:GetNW2Bool("hr_execution_immune") then return end
	if DHR.RunHook("DHRCanExecuteTarget", w, e) == false then return end
	if e:IsPlayer() and not X.Players.Allowed(p,e) then return end
	if not e:LookupBone('ValveBiped.Bip01_Head1') or not e:LookupBone('ValveBiped.Bip01_Pelvis') then return end
	if e:OBBMaxs().z - e:OBBMins().z > 100 or e:GetModelScale() ~= 1 then return end

	local D, index, source, approach, yaw = selectProfile(w, e)
	if not D then return end
	return e, D, index, source, approach, yaw
end

local function setVM(w, model, seq)
	local p = w:GetOwner()
	if not IsValid(p) then return end
	local vm = p:GetViewModel()
	if not IsValid(vm) then return end
	vm:SetWeaponModel(model, w)
	local id = vm:LookupSequence(seq)
	if id >= 0 then
		vm:SendViewModelMatchingSequence(id)
		vm:SetPlaybackRate(1)
	end
	return vm
end

if SERVER then
	X.Active = X.Active or {}
	local executionVoice = include("hellraiser/execution_voice.lua")

	local function copyLook(from, to)
		to:SetSkin(from:GetSkin())
		to:SetColor(from:GetColor())
		to:SetMaterial(from:GetMaterial())
		for _, b in ipairs(from:GetBodyGroups()) do
			to:SetBodygroup(b.id, from:GetBodygroup(b.id))
		end
		for i=0,#from:GetMaterials()-1 do to:SetSubMaterial(i,from:GetSubMaterial(i)) end
		for i=0,math.min(from:GetFlexNum(),to:GetFlexNum(),96)-1 do
			local weight=from:GetFlexWeight(i)
			if weight ~= 0 then to:SetFlexWeight(i,weight) end
		end
	end

	local function corpse(st)
		local D = st.profile
		if not IsValid(st.driver) or not IsValid(st.body) then return end
		local r = ents.Create('prop_ragdoll')
		if not IsValid(r) then return end
		r:SetModel(st.body:GetModel())
		r:SetPos(st.driver:GetPos())
		r:SetAngles(st.driver:GetAngles())
		r:Spawn()
		r:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
		copyLook(st.body, r)
		st.driver:SetCycle(math.Clamp((CurTime() - st.start) / D.length, 0, 1))
		for i = 0, r:GetPhysicsObjectCount() - 1 do
			local phys = r:GetPhysicsObjectNum(i)
			local bone = r:TranslatePhysBoneToBone(i)
			local src = st.driver:LookupBone(r:GetBoneName(bone))
			if IsValid(phys) and src then
				local pos, ang = st.driver:GetBonePosition(src)
				if pos then
					phys:SetPos(pos)
					phys:SetAngles(ang)
					phys:SetVelocity(Vector(0, 0, 0))
					phys:Wake()
				end
			end
		end

		if HRDismember then HRDismember.Copy(st.body,r) end

		undo.Create('Hellraiser execution ragdoll')
		undo.AddEntity(r)
		if IsValid(st.player) then undo.SetPlayer(st.player) end
		undo.Finish()
		if IsValid(st.player) then st.player:AddCleanup('ragdolls', r) end
		return r
	end

	function X.Finish(w, cancel)
		local st = X.Active[w]
		if not st then return end
		local D = st.profile
		if st.voicePath and IsValid(st.body) then st.body:StopSound(st.voicePath) end
		X.Active[w] = nil
		if st.weapon then X.Players.Finish(w,st) end
		if not st.killed and IsValid(st.victim) and not st.victim:IsPlayer() then
			st.victim:SetNoDraw(st.oldDraw)
			st.victim:SetMoveType(st.oldMove)
			st.victim:SetNPCState(st.oldState)
			st.victim:ClearSchedule()
			local gun = st.victim:GetActiveWeapon()
			if IsValid(gun) then gun:SetNoDraw(st.oldGunDraw or false) end
		end
		if IsValid(st.victim) then st.victim.hr_execution = nil end
		if IsValid(st.player) then
			if not cancel and st.player:Alive() then
				local dest = LocalToWorld(Vector(unpack(D.exit_offset)) * (D.player_scale or 1), angle_zero, st.origin, st.yaw)
				local trace = util.TraceHull({
					start = st.player:GetPos(),
					endpos = dest,
					mins = st.player:OBBMins(),
					maxs = st.player:OBBMaxs(),
					filter = { st.player, st.victim, st.driver, st.body },
					mask = MASK_PLAYERSOLID
				})
				if not trace.Hit then st.player:SetPos(dest) end
			end
			st.player.hr_execution = nil
			st.player:Freeze(false)
		end
		if IsValid(w) then
			w:SetNW2Bool('hr_executing', false)
			setVM(w, w.ViewModel, 'idle')
			w:SetBaseSeq('')
			w:SetBusyUntil(CurTime() + 0.1)
			w:SetNextPrimaryFire(CurTime() + 0.25)
			w:SetNextSecondaryFire(CurTime() + 0.25)
		end

		if st.killed then
			local ok, err = pcall(corpse, st)
			if not ok then ErrorNoHalt(err .. '\n') end
		end
		if IsValid(st.body) then st.body:Remove() end
		if IsValid(st.driver) then st.driver:Remove() end
		if IsValid(w) and w.hr_break_position then HRCombat.Break(w, w.hr_break_position) end
	end

	function X.Start(w, e)
		if X.Active[w] or not IsValid(e) or e.hr_execution then return false end
		local target, D, variant, source, approach, yaw = X.Target(w)
		if target ~= e then return false end
		local p = w:GetOwner()
		local entryEye, entryAngle = p:EyePos(), p:EyeAngles()
		local origin, ang = executionPosition(p, e, D, approach, yaw)
		if not origin then return false end

		local driver = ents.Create('prop_dynamic')
		driver:SetModel(D.driver_model)
		driver:SetPos(e:GetPos())
		driver:SetAngles(ang + Angle(0, D.target_yaw, 0))
		driver:Spawn()
		driver:SetSolid(SOLID_NONE)
		driver:SetMoveType(MOVETYPE_NONE)
		driver:ResetSequence(driver:LookupSequence('execute'))
		driver:SetPlaybackRate(1)
		driver:SetCycle(0)
		driver:SetModelScale(D.victim_scale or 1, 0)

		local body = ents.Create('cycler_actor')
		body:SetModel(e:GetModel())
		if HRDismember then body:SetNWInt('hr_blood_color', HRDismember.BloodColor(e)) end
		body:SetPos(e:GetPos())
		body:SetAngles(ang)
		body:Spawn()
		copyLook(e, body)
		body.hr_execution_proxy = true
		body:AddFlags(FL_NOTARGET)
		body:AddEFlags(EFL_NO_THINK_FUNCTION)
		if body:IsNPC() then
			body:SetNPCState(NPC_STATE_SCRIPT)
			body:SetSchedule(SCHED_NPC_FREEZE)
		end
		body:SetPlaybackRate(0)
		body:SetSolid(SOLID_NONE)
		body:SetMoveType(MOVETYPE_NONE)
		body:SetParent(driver)
		body:AddEffects(EF_BONEMERGE)
		body:SetLocalPos(vector_origin)
		body:SetLocalAngles(angle_zero)

		local st = {
			voice = executionVoice(e),
			player = p,
			profile = D,
			origin = origin,
			bloodColor = e:GetBloodColor(),
			victim = e,
			driver = driver,
			body = body,
			start = CurTime(),
			crouching = p:Crouching(),
			oldDraw = e:GetNoDraw(),
			oldMove = e:GetMoveType(),
			oldState = e:IsNPC() and e:GetNPCState() or nil,
			yaw = ang
		}
		if e:IsPlayer() then X.Players.Start(w,st) end
		X.Active[w] = st
		e.hr_execution = st
		p.hr_execution = st
		w.hr_execution_variant = variant
		w:SetNW2Int('hr_execution_variant', variant)
		w:SetNW2String('hr_execution_weapon', source:GetClass())
		w:SetNW2Entity('hr_execution_driver', driver)
		w:SetNW2Entity('hr_execution_body', body)
		local gun = e:GetActiveWeapon()
		if IsValid(gun) then
			st.oldGunDraw = gun:GetNoDraw()
			gun:SetNoDraw(true)
		end
		e:SetNoDraw(true)
		if e:IsNPC() then
			e:SetNPCState(NPC_STATE_SCRIPT)
			e:SetSchedule(SCHED_NPC_FREEZE)
		end
		e:SetMoveType(MOVETYPE_NONE)
		p:SetPos(origin)
		p:SetEyeAngles(ang)
		p:Freeze(true)
		w:SetNW2Vector('hr_execution_entry_eye', entryEye)
		w:SetNW2Angle('hr_execution_entry_angle', entryAngle)
		w:SetNW2Float('hr_execution_entry_fov', p:GetFOV())
		w:SetNW2Float('hr_execution_start', st.start)
		w:SetNW2Vector('hr_execution_origin', origin)
		w:SetNW2Angle('hr_execution_angle', ang)
		w:SetNW2Bool('hr_executing', true)
		w:SetHitTime(0)
		w:SetBaseSeq('')
		w:SetBusyUntil(st.start + D.length)
		w:SetNextPrimaryFire(st.start + D.length)
		w:SetNextSecondaryFire(st.start + D.length)
		setVM(w, D.view_model, D.sequence)
		return true
	end

	hook.Add('Think', 'hr_executions', function()
		for w, st in pairs(X.Active) do
			local D = st.profile
			if not IsValid(w) or not IsValid(st.player) or not st.player:Alive() or not IsValid(st.driver) or (not st.killed and not IsValid(st.victim))
				or w:GetOwner() ~= st.player or st.player:GetActiveWeapon() ~= w
				or st.weapon and not X.Players.Valid(st)
				or not st.killed and DHR.RunHook("DHRCanExecuteTarget", w, st.victim) == false then
				X.Finish(w, true)
			else
				local t = CurTime() - st.start
				if st.weapon then st.driver:SetPlaybackRate(0); st.driver:SetCycle(math.Clamp(t/D.length,0,1)) end
				st.soundIndex = st.soundIndex or 1
				while D.sounds and D.sounds[st.soundIndex] and t >= D.sounds[st.soundIndex].time do
					local cue = D.sounds[st.soundIndex]
					if #cue.paths > 0 then
						local paths = cue.paths
						if cue.kind == 'voice' then
							if not st.killed and t < D.damage_time and st.voice ~= false and IsValid(st.body) then
								if istable(st.voice) then paths = st.voice
								elseif st.voice == 'female' then paths = cue.female_paths or paths end
								if st.voicePath then st.body:StopSound(st.voicePath) end
								st.voicePath = paths[math.random(#paths)]
								st.body:EmitSound(st.voicePath, 78, 100, 1, CHAN_VOICE)
							end
						else
							st.player:EmitSound(paths[math.random(#paths)], 80, 100, 1, CHAN_AUTO)
						end
					end
					st.soundIndex = st.soundIndex + 1
				end
				local contact = D.blood_effects[1] and D.blood_effects[1].time or D.damage_time
				if not st.worn and t >= math.min(contact, D.damage_time) then
					st.worn = true
					HRCombat.Wear(w, IsValid(st.body) and st.body:WorldSpaceCenter() or st.origin, 1)
				end
				st.bloodIndex = st.bloodIndex or 1
				while D.blood_effects[st.bloodIndex] and t >= D.blood_effects[st.bloodIndex].time do
					if st.bloodColor == BLOOD_COLOR_RED and IsValid(st.body) then
						local cue = D.blood_effects[st.bloodIndex]
						local frame = math.Clamp(math.floor(t / D.length * (#cue.points - 1)) + 1, 1, #cue.points)
						local point = cue.points[frame]
						local normal = Vector(point[4], point[5], point[6])
						normal:Rotate(st.driver:GetAngles())
						local fx = EffectData()
						fx:SetEntity(w)
						fx:SetAttachment(st.bloodIndex)
						fx:SetOrigin(st.driver:LocalToWorld(Vector(point[1], point[2], point[3])))
						fx:SetNormal(normal)
						util.Effect('hr_execution_blood', fx, true, true)
					end
					st.bloodIndex = st.bloodIndex + 1
				end
				if not st.killAttempted and t >= D.damage_time then
					st.killAttempted = true
					local head = st.driver:LookupBone('ValveBiped.Bip01_Head1')
					local hit = head and st.driver:GetBonePosition(head) or st.victim:WorldSpaceCenter() + Vector(0, 0, 18)
					local fx = EffectData()
					fx:SetOrigin(hit)
					fx:SetNormal(-st.yaw:Forward())
					util.Effect('BloodImpact', fx, true, true)
					if st.victim:GetBloodColor() == BLOOD_COLOR_RED then
						for i = 1, 3 do
							local direction = -st.yaw:Forward() * 30 + st.yaw:Right() * math.Rand(-35, 35) - Vector(0, 0, 100)
							local tr = util.TraceLine({start = hit, endpos = hit + direction, filter = {st.player, st.victim, st.driver, st.body}})
							if tr.Hit then util.Decal('Blood', tr.HitPos + tr.HitNormal, tr.HitPos - tr.HitNormal, {st.player, st.victim, st.driver, st.body}) end
						end
					end
					st.victim:EmitSound('physics/flesh/flesh_impact_bullet1.wav', 75, 100)
					local damage = DamageInfo()
					damage:SetAttacker(st.player)
					damage:SetInflictor(w)
					damage:SetDamage(math.max(st.victim:Health() + 100, 999999))
					local health = st.victim:Health()
					if st.victim:IsNPC() and st.victim:Classify() == CLASS_PLAYER_ALLY_VITAL then st.victim:SetHealth(1) end
					damage:SetDamageType(bit.bor(DMG_SLASH, DMG_REMOVENORAGDOLL))
					if st.victim:IsNPC() then
						st.victim:SetNPCState(st.oldState)
						st.victim:ClearSchedule()
						st.victim:SetMoveType(st.oldMove)
					end
					damage:SetDamagePosition(hit)
					local protected = st.victim:IsNPC() and bit.band(st.victim:CapabilitiesGet(), CAP_FRIENDLY_DMG_IMMUNE) ~= 0
					if protected then st.victim:CapabilitiesRemove(CAP_FRIENDLY_DMG_IMMUNE) end
					st.applyingDamage = true
					st.victim:TakeDamageInfo(damage)
					st.applyingDamage = false
					if st.killed and HRDismember then HRDismember.Execution(w,st.body,-st.yaw:Forward()*130+Vector(0,0,75)) end
					if st.killed and HRBlood then HRBlood.Add(w, 0.8) end
					if protected and IsValid(st.victim) then st.victim:CapabilitiesAdd(CAP_FRIENDLY_DMG_IMMUNE) end
					if not st.killed then
						if IsValid(st.victim) and st.victim:IsNPC() then st.victim:SetHealth(health) end
						X.Finish(w, true)
					end
				end
				if t >= D.length then X.Finish(w, false) end
			end
		end
	end)

	hook.Add('EntityEmitSound', 'hr_execution_voice', function(sound)
		local e = sound.Entity
		local st = IsValid(e) and e.hr_execution
		if st and e == st.victim and (sound.Channel == CHAN_VOICE or st.applyingDamage or st.killed) then return false end
	end)

	hook.Add('OnNPCKilled', 'hr_execution_death', function(e)
		local st = e.hr_execution
		if st then
			st.killed = true
			if st.voicePath and IsValid(st.body) then st.body:StopSound(st.voicePath) st.voicePath = nil end
		end
	end)

	hook.Add('EntityTakeDamage', 'hr_execution_lock', function(e, dmg)
		if e.hr_execution_proxy then return true end
		local st = e.hr_execution
		if st and not st.killed and not (e == st.victim and st.applyingDamage) then return true end
	end)

	hook.Add('StartCommand', 'hr_execution_lock', function(p, cmd)
		if p.hr_execution then
			cmd:ClearMovement()
			cmd:ClearButtons()
			local st = p.hr_execution
			local victim = p == st.victim
			if victim and st.victimCrouching or not victim and st.crouching then cmd:SetButtons(IN_DUCK) end
			cmd:SetViewAngles(victim and st.victimAngles or st.yaw)
		end
	end)

	hook.Add('PreCleanupMap', 'hr_executions', function()
		for w in pairs(X.Active) do X.Finish(w, true) end
	end)
end

function X.Try(w)
	local e = X.Target(w)
	if not e then return false end
	if SERVER then return X.Start(w, e) end
	return true
end

if CLIENT then
	local last = {}
	hook.Add('Think', 'hr_execution_viewmodel', function()
		local p = LocalPlayer()
		if not IsValid(p) then return end
		local w = p:GetActiveWeapon()
		if not IsValid(w) then return end
		if w:GetNW2Bool('hr_executing') then
			local D = X.Profile(w)
			if not D then return end
			local start = w:GetNW2Float('hr_execution_start')
			if last.weapon ~= w or last.start ~= start then
				local vm = setVM(w, D.view_model, D.sequence)
				if IsValid(vm) then vm:SetCycle(math.Clamp((CurTime() - start) / D.length, 0, 1)) end
				last = { weapon = w, start = start, fov = w.hr_execution_fov or w.ViewModelFOV }
			end
		elseif last.weapon then
			if IsValid(last.weapon) then
				last.weapon.ViewModelFOV = last.fov
				last.weapon.hr_execution_fov = nil
				setVM(last.weapon, last.weapon.ViewModel, 'idle')
			end
			last = {}
		end
	end)

	local outside = CreateClientConVar('hr_finisher_camera', '0', true, false, 'Watch finishers from outside your body')

	local function watching(D, t)
		return outside:GetBool() and t > 0.2 and t < D.length - 0.2
	end
	local function outsideView(w, D, t)
		local scale = D.player_scale or 1
		local yaw = w:GetNW2Angle('hr_execution_angle')
		local focus = w:GetNW2Vector('hr_execution_origin') + yaw:Forward() * D.distance * scale * 0.5 + Vector(0, 0, 46 * scale)
		local look = Angle(10, yaw.y + 75 + t * 8, 0)
		local trace = util.TraceLine({start = focus, endpos = focus - look:Forward() * 120 * scale, mask = MASK_SOLID_BRUSHONLY})
		local camera = trace.HitPos + trace.HitNormal * 4
		return camera, (focus - camera):Angle()
	end

	hook.Add('ShouldDrawLocalPlayer', 'hr_finisher_camera', function(p)
		local w = p:GetActiveWeapon()
		if not IsValid(w) or not w.HR or not w:GetNW2Bool('hr_executing') then return end
		local D = X.Profile(w)
		if D and watching(D, CurTime() - w:GetNW2Float('hr_execution_start')) then return true end
	end)

	local function gameFOV()
		local aspect = ScrW() / math.max(ScrH(), 1)
		return math.deg(2 * math.atan(math.tan(math.rad(89.424164 / 2)) * (4 / 3) / aspect))
	end

	function X.View(w, pos, ang, fov)
		if not w:GetNW2Bool('hr_executing') then
			if w.hr_execution_fov then
				w.ViewModelFOV = w.hr_execution_fov
				w.hr_execution_fov = nil
			end
			return
		end
		local D = X.Profile(w)
		if not D then return end
		local t = math.Clamp(CurTime() - w:GetNW2Float('hr_execution_start'), 0, D.length)
		local frame = t / D.length * (#D.camera - 1)
		local i = math.floor(frame) + 1
		local j = math.min(i + 1, #D.camera)
		local a = frame - math.floor(frame)
		local v = D.camera[i]
		local u = D.camera[j]
		local off = LerpVector(a, Vector(v[1], v[2], v[3]), Vector(u[1], u[2], u[3]))
		local turn = LerpAngle(a, Angle(v[4], v[5], v[6]), Angle(u[4], u[5], u[6]))
		local anchor = w:GetNW2Vector('hr_execution_origin') + Vector(0, 0, D.eye_height * (D.player_scale or 1))
		off = off * (D.player_scale or 1)
		local eye, rotation = LocalToWorld(off, turn, anchor, w:GetNW2Angle('hr_execution_angle'))
		if D.camera_offset then eye = eye + Vector(unpack(D.camera_offset)) * (D.player_scale or 1) end
		w.hr_execution_fov = w.hr_execution_fov or w.ViewModelFOV
		local targetFOV = gameFOV()
		local entry = math.Clamp(t / 0.18, 0, 1)
		entry = entry * entry * (3 - 2 * entry)
		eye = LerpVector(entry, w:GetNW2Vector('hr_execution_entry_eye'), eye)
		rotation = LerpAngle(entry, w:GetNW2Angle('hr_execution_entry_angle'), rotation)
		local cameraFOV = Lerp(entry, w:GetNW2Float('hr_execution_entry_fov', 90), targetFOV)
		local exit = math.Clamp((t - D.length + 0.18) / 0.18, 0, 1)
		exit = exit * exit * (3 - 2 * exit)
		local yaw = w:GetNW2Angle('hr_execution_angle')
		local dest = LocalToWorld(Vector(unpack(D.exit_offset)) * (D.player_scale or 1), angle_zero, w:GetNW2Vector('hr_execution_origin'), yaw)
		local p = w:GetOwner()
		local trace = util.TraceHull({start = p:GetPos(), endpos = dest,
			mins = p:OBBMins(), maxs = p:OBBMaxs(),
			filter = {p, w:GetNW2Entity('hr_execution_driver'), w:GetNW2Entity('hr_execution_body')},
			mask = MASK_PLAYERSOLID})
		if trace.Hit then dest = p:GetPos() end
		local viewOffset = p:Crouching() and p:GetViewOffsetDucked() or p:GetViewOffset()
		eye = LerpVector(exit, eye, dest + viewOffset)
		rotation = LerpAngle(exit, rotation, yaw)
		cameraFOV = Lerp(exit, cameraFOV, p:GetFOV())
		if watching(D, t) then eye, rotation = outsideView(w, D, t) end
		w.ViewModelFOV = cameraFOV
		return eye, rotation, cameraFOV
	end
end

if CLIENT then
	local face = {
		lid_raiser = {1, 0, 0}, lid_tightener = {.1, .95, .1}, lid_droop = {0, 0, .15},
		lid_closer = {0, .92, .85}, half_closed = {0, 0, 0}, blink = {0, 0, 0},
		inner_raiser = {1, .85, .2}, outer_raiser = {.65, 0, 0}, lowerer = {.45, 1, .2},
		cheek_raiser = {0, .4, 0}, wrinkler = {.15, .9, .1}, dilator = {.45, .7, 0},
		upper_raiser = {.45, .9, .1}, corner_puller = {0, 0, 0}, corner_depressor = {.9, 1, .25},
		chin_raiser = {.15, .55, .05}, part = {.85, .6, .1}, puckerer = {0, 0, 0}, funneler = {0, 0, 0},
		stretcher = {.7, .8, .1}, bite = {0, .15, 0}, presser = {0, .2, 0}, tightener = {0, .5, 0},
		jaw_clencher = {0, .8, 0}, jaw_drop = {1, .55, .25}, mouth_drop = {.7, .5, .1},
		smile = {0, 0, 0}, lower_lip = {.5, .35, .1}
	}
	local function expression(body, profile, elapsed)
		if not body.hr_face then
			body.hr_face = {}
			for i = 0, body:GetFlexNum() - 1 do
				local name = string.lower(body:GetFlexName(i)):gsub('^right_', ''):gsub('^left_', '')
				if face[name] then body.hr_face[i] = face[name] end
			end
		end
		local pain = 0
		for _, cue in ipairs(profile.blood_effects) do
			local since = elapsed - cue.time
			if since >= 0 then pain = math.max(pain, math.exp(-math.max(0, since - .12) * 3)) end
		end
		local dying = math.Clamp((elapsed - profile.damage_time - .15) / .65, 0, 1)
		dying = dying * dying * (3 - 2 * dying)
		local strength = math.Clamp(elapsed / .08, 0, 1)
		local breath = elapsed < profile.damage_time and (.92 + .08 * math.sin(elapsed * 9)) or 1
		for id, weights in pairs(body.hr_face) do
			local reaction = Lerp(pain, weights[1] * breath, weights[2])
			body:SetFlexWeight(id, Lerp(dying, reaction, weights[3]) * strength)
		end
	end
	local function playerColor(body) return body:GetNWVector('hr_player_color',Vector(255,255,255))/255 end
	local function drawVictim(body)
		if body:GetNW2Entity('hr_execution_subject') == LocalPlayer() then return end
		local w = body.hr_weapon
		if IsValid(w) and w:GetNW2Bool('hr_executing') then
			local profile = X.Profile(w)
			if profile then expression(body, profile, CurTime() - w:GetNW2Float('hr_execution_start')) end
			local attachment = body:LookupAttachment('eyes')
			local eyes = attachment > 0 and body:GetAttachment(attachment)
			if eyes then body:SetEyeTarget(eyes.Pos + eyes.Ang:Forward() * 128) end
		end
		body:DrawModel()
	end
	local arms, weapon, start
	local function clear()
		if IsValid(arms) then
			if HRHands then HRHands.Remove(arms) end
			arms:Remove()
		end
		arms, weapon, start = nil, nil, nil
	end
	hook.Add('Think', 'hr_execution_world_arms', function()
		local player = LocalPlayer()
		local current = IsValid(player) and player:GetActiveWeapon()
		if not IsValid(current) or not player:Alive() or not current:GetNW2Bool('hr_executing') then clear() return end
		local profile = X.Profile(current)
		if not profile then clear() return end
		local began = current:GetNW2Float('hr_execution_start')
		if weapon ~= current or start ~= began or not IsValid(arms) then
			clear()
			arms = ClientsideModel(profile.view_model, RENDERGROUP_OPAQUE)
			if not IsValid(arms) then return end
			weapon, start = current, began
			arms.hr_weapon = current
			arms:SetNoDraw(true)
			arms:DrawShadow(false)
			arms:SetModelScale(profile.player_scale or 1, 0)
			arms:ResetSequence(arms:LookupSequence(profile.sequence))
			arms:SetPlaybackRate(0)
		end
	end)
	function X.WorldArms(w)
		return weapon == w and IsValid(arms) and arms or nil
	end
	hook.Add('PreDrawOpaqueRenderables', 'hr_execution_world_sync', function(depth, skybox)
		if depth or skybox then return end
		for _, player in ipairs(player.GetAll()) do
			local w = player:GetActiveWeapon()
			if not IsValid(w) or not w:GetNW2Bool('hr_executing') then continue end
			local profile = X.Profile(w)
			local driver = w:GetNW2Entity('hr_execution_driver')
			local body = w:GetNW2Entity('hr_execution_body')
			if not profile or not IsValid(driver) or not IsValid(body) then continue end
			local elapsed = CurTime()-w:GetNW2Float('hr_execution_start')
			driver:SetCycle(math.Clamp(elapsed/profile.length,0,1))
			driver:InvalidateBoneCache()
			body:InvalidateBoneCache()
			body:SetupBones()
			body.hr_weapon = w
			body.GetPlayerColor = playerColor
			body.RenderOverride = drawVictim
		end
	end)

	local function finisherEye(w, profile, elapsed)
		local frame = elapsed/profile.length*(#profile.camera-1)
		local index = math.floor(frame)+1
		local a,b = profile.camera[index],profile.camera[math.min(index+1,#profile.camera)]
		local offset = LerpVector(frame%1,Vector(a[1],a[2],a[3]),Vector(b[1],b[2],b[3])) * (profile.player_scale or 1)
		return LocalToWorld(offset,angle_zero,w:GetNW2Vector('hr_execution_origin')+Vector(0,0,profile.eye_height * (profile.player_scale or 1)),w:GetNW2Angle('hr_execution_angle'))
	end

	local firstPerson = false
	hook.Add('PreDrawOpaqueRenderables', 'hr_execution_view', function(depth, skybox)
		if depth or skybox then return end
		firstPerson = false
		if not IsValid(weapon) or not IsValid(arms) or not weapon:GetNW2Bool('hr_executing') or CurTime() < start then return end
		local profile = X.Profile(weapon)
		if not profile then return end
		local view = EyePos()
		local eye = finisherEye(weapon, profile, math.Clamp(CurTime()-start,0,profile.length))
		firstPerson = view:DistToSqr(eye) < 24*24 or view:DistToSqr(LocalPlayer():EyePos()) < 16*16
	end)
	hook.Add('PrePlayerDraw', 'hr_execution_view', function(p)
		if firstPerson and p == LocalPlayer() then return true end
	end)

	hook.Add('PostDrawOpaqueRenderables', 'hr_execution_world_arms', function(depth, skybox)
		if depth or skybox or not firstPerson or not GetConVar('r_drawviewmodel'):GetBool() then return end
		local profile = X.Profile(weapon)
		local elapsed = math.Clamp(CurTime()-start,0,profile.length)
		arms:SetPos(EyePos())
		arms:SetAngles(EyeAngles())
		arms:SetCycle(math.Clamp(elapsed / math.max(arms:SequenceDuration(), 0.01), 0, 1))
		HRHands.Prepare(arms, LocalPlayer())
		arms:InvalidateBoneCache()
		arms:SetupBones()
		X.FitHeadGrip(arms, weapon:GetNW2Entity('hr_execution_body'), profile, elapsed)
		arms:DrawModel()
		HRHands.DrawExecution(arms, LocalPlayer())
	end)
	hook.Add('PreCleanupMap','hr_execution_world_arms',clear)
	hook.Add('ShutDown','hr_execution_world_arms',clear)
end

if CLIENT then
	local function rotateToward(matrix, from, to, position)
		from, to = from:GetNormalized(), to:GetNormalized()
		local axis = from:Cross(to)
		local angle = matrix:GetAngles()
		if axis:LengthSqr() > 0.000001 then angle:RotateAroundAxis(axis:GetNormalized(), math.deg(math.acos(math.Clamp(from:Dot(to), -1, 1)))) end
		local result = Matrix(matrix)
		result:SetAngles(angle)
		result:SetScale(matrix:GetScale())
		result:SetTranslation(position)
		return result
	end

	function X.FitHeadGrip(arms, body, profile, elapsed)
		local window = profile.head_grab
		if not window or not IsValid(body) then return end
		local weight = math.min(math.Clamp((elapsed-window[1]+0.16)/0.16,0,1), math.Clamp((window[2]+0.16-elapsed)/0.16,0,1))
		if weight <= 0 then return end
		weight = weight*weight*(3-2*weight)
		local head = body:LookupBone('ValveBiped.Bip01_Head1')
		local palm = arms.hr_hand_mode and 'ValveBiped.Bip01_L_Finger2' or 'middle_01_l'
		local upper, fore, hand, finger = arms:LookupBone('upperarm_l'), arms:LookupBone('lowerarm_l'), arms:LookupBone('hand_l'), arms:LookupBone(palm)
		if not head or not upper or not fore or not hand or not finger then return end
		body:SetupBones()
		local hm = body:GetBoneMatrix(head)
		local pm = arms:GetBoneMatrix(finger)
		if not hm or not pm then return end
		local inverse = hm:GetInverse()
		if not inverse then return end
		local palm = pm:GetTranslation()
		local localPalm = inverse * palm
		local set = body:GetHitboxSet()
		local closest, distance
		for i = 0, (body:GetHitBoxCount(set) or 0)-1 do
			if body:GetHitBoxBone(i,set) == head then
				local low, high = body:GetHitBoxBounds(i,set)
				local point = Vector(math.Clamp(localPalm.x,low.x,high.x),math.Clamp(localPalm.y,low.y,high.y),math.Clamp(localPalm.z,low.z,high.z))
				local world = hm * point
				local d = world:DistToSqr(palm)
				if not distance or d < distance then closest, distance = world, d end
			end
		end
		if not closest or distance < 0.0001 or distance > 64 then return end
		local old, changed = {}, {}
		for i=0,arms:GetBoneCount()-1 do old[i]=arms:GetBoneMatrix(i) end
		if not old[upper] or not old[fore] or not old[hand] then return end
		local shoulder, elbow, wrist = old[upper]:GetTranslation(), old[fore]:GetTranslation(), old[hand]:GetTranslation()
		local goal = wrist + (closest-palm)*weight
		local a, b = shoulder:Distance(elbow), elbow:Distance(wrist)
		local axis = (goal-shoulder):GetNormalized()
		local length = math.Clamp(goal:Distance(shoulder),math.abs(a-b)+0.001,a+b-0.001)
		goal = shoulder + axis*length
		local bend = elbow-shoulder
		bend = (bend-axis*bend:Dot(axis)):GetNormalized()
		local reach = (a*a+length*length-b*b)/(2*length)
		local joint = shoulder+axis*reach+bend*math.sqrt(math.max(a*a-reach*reach,0))
		changed[upper] = rotateToward(old[upper],elbow-shoulder,joint-shoulder,shoulder)
		changed[fore] = rotateToward(old[fore],wrist-elbow,goal-joint,joint)
		changed[hand] = Matrix(old[hand]);changed[hand]:SetTranslation(goal)
		for i=0,arms:GetBoneCount()-1 do
			local parent=arms:GetBoneParent(i)
			if not changed[i] and changed[parent] and old[parent] and old[i] then
				local inv = old[parent]:GetInverse()
				if inv then changed[i]=changed[parent]*inv*old[i] end
			end
			if changed[i] and arms:GetBoneName(i) ~= '__INVALIDBONE__' then arms:SetBoneMatrix(i,changed[i]) end
		end
	end
end
