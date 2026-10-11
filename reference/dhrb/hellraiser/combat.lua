if SERVER then AddCSLuaFile() end
HRCombat = HRCombat or {}
local C = HRCombat
local infinite = CreateConVar("hr_infinite_durability", "0", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), "Melee weapons do not lose durability")
local reloadSpeed = CreateConVar("hr_reload_speed", "1", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY), "Hellraiser gun reload speed multiplier", 1, 2)
function C.ReloadSpeed() return reloadSpeed:GetFloat() end
function C.Remaining(w)
	return w:GetNW2Float("hr_durability_remaining", w:GetNW2Int("hr_durability", w.HR.durability or -1))
end
function C.Infinite() return infinite:GetBool() end
local duration, immunity, cooldown = 0.9, 0.8, 0.7
local force = 480 / 325

local function weapon(p)
	local w = IsValid(p) and p:GetActiveWeapon()
	if IsValid(w) and w.HR and w.HR.seq.evade_back and p:Alive()
		and not p:InVehicle() and not w:GetNW2Bool("hr_executing") then return w end
end

function C.Dodging(p)
	return IsValid(p) and p:GetNW2Float("hr_evade_end") > CurTime()
end

function C.TargetPoint(e)
	local bone = e:LookupBone("ValveBiped.Bip01_Spine2")
	return bone and e:GetBonePosition(bone) or e:WorldSpaceCenter()
end

function C.Targetable(p, e, range)
	if not IsValid(e) or not (e:IsNPC() or e:IsNextBot()) or e:Health() <= 0 then return false end
	if SERVER and e:IsNPC() and e:Disposition(p) == D_LI then return false end
	local pos = C.TargetPoint(e)
	if p:EyePos():DistToSqr(pos) > range * range then return false end
	local tr = util.TraceLine({start = p:EyePos(), endpos = pos, filter = p, mask = MASK_SHOT})
	return tr.Entity == e or not tr.Hit
end

if SERVER then
	util.AddNetworkString("hr_reload_speed_setting")
	net.Receive("hr_reload_speed_setting", function(_, p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		if CurTime() < (p.hr_reload_speed_setting or 0) then return end
		p.hr_reload_speed_setting = CurTime() + 0.1
		local value = net.ReadFloat()
		if value ~= value then return end
		reloadSpeed:SetFloat(math.Clamp(value, 1, 2))
	end)
	util.AddNetworkString("hr_durability_setting")
	net.Receive("hr_durability_setting", function(_, p)
		if not game.SinglePlayer() and not p:IsAdmin() then return end
		if CurTime() < (p.hr_durability_setting or 0) then return end
		p.hr_durability_setting = CurTime() + 0.2
		infinite:SetBool(net.ReadBool())
	end)
	util.AddNetworkString("hr_lock")
	util.AddNetworkString("hr_evade")

	net.Receive("hr_lock", function(_, p)
		if CurTime() < (p.hr_lock_request or 0) then return end
		p.hr_lock_request = CurTime() + 0.2
		local old = p:GetNW2Entity("hr_lock_target")
		p:SetNW2Entity("hr_lock_target", NULL)
		if IsValid(old) or not weapon(p) then return end
		local target, best = nil, 0.75
		for _, e in ipairs(ents.FindInSphere(p:EyePos(), 400 / 2.54)) do
			if C.Targetable(p, e, 400 / 2.54) then
				local score = p:GetAimVector():Dot((C.TargetPoint(e) - p:EyePos()):GetNormalized())
				if score > best then target, best = e, score end
			end
		end
		p:SetNW2Entity("hr_lock_target", target or NULL)
	end)

	net.Receive("hr_evade", function(_, p)
		local side = net.ReadInt(2)
		local w = weapon(p)
		if not w or not p:OnGround() or p:Crouching() or p:WaterLevel() > 1
			or p:GetMoveType() ~= MOVETYPE_WALK or p:IsFrozen()
			or CurTime() < p:GetNW2Float("hr_evade_ready") or CurTime() < w:GetNextPrimaryFire()
            or w.DualWield and CurTime() < w:GetNextSecondaryFire() then return end
		local a = Angle(0, p:EyeAngles().y, 0)
		local dir = side == -1 and -a:Right() or side == 1 and a:Right() or -a:Forward()
		local name = side == -1 and "evade_left" or side == 1 and "evade_right" or "evade_back"
		w:SetAiming(false)
		if w.HR.seq.reload_fill5 and (w:GetReloadStage() == 4 or w:GetReloadDone() > 0) then w:SetNW2Int("hr_rev_loaded", w:Clip1()) end
		w:SetReloadDone(0)
		w:SetReloadStage(0)
		w:SetReloadUntil(0)
		w:ClearReloadState()
		w:SetHitTime(0)
        local length
        if w.DualWield then length = w:PlayDualDodge(name, duration)
        else w:Action(w.HR.seq[name]); length = w:SeqLen(w.HR.seq[name]) end
        local stop = CurTime() + math.max(duration, length)
		w:SetBusyUntil(stop)
		w:SetNextPrimaryFire(stop)
		w:SetNextSecondaryFire(stop)
		p:SetNW2Vector("hr_evade_direction", dir)
		p:SetNW2Float("hr_evade_end", CurTime() + duration)
		p:SetNW2Float("hr_evade_ready", CurTime() + duration + cooldown)
		local listeners = RecipientFilter()
		listeners:AddPAS(p:GetPos())
		if not w.DualWield then listeners:RemovePlayer(p) end
		w:EmitSound("HR.Evade", 75, 100, 1, CHAN_AUTO, 0, 0, listeners)
	end)

	hook.Add("Think", "hr_combat_state", function()
		for _, p in ipairs(player.GetAll()) do
			local w = weapon(p)
			local e = p:GetNW2Entity("hr_lock_target")
			if IsValid(e) and (not w or not C.Targetable(p, e, 240)) then p:SetNW2Entity("hr_lock_target", NULL) end
			if C.Dodging(p) and (not w or p:GetMoveType() ~= MOVETYPE_WALK or p:InVehicle()) then p:SetNW2Float("hr_evade_end", 0) end
		end
	end)

	hook.Add("EntityTakeDamage", "hr_evade", function(p, damage)
		if not p:IsPlayer() or not C.Dodging(p) or not weapon(p) then return end
		local elapsed = duration - (p:GetNW2Float("hr_evade_end") - CurTime())
		if elapsed < immunity and damage:IsDamageType(bit.bor(DMG_BULLET, DMG_SLASH, DMG_CLUB)) then return true end
	end)

	function C.Wear(w, pos, amount)
		local maximum = w.HR.durability or -1
		if infinite:GetBool() or maximum < 0 or w:GetNW2Bool("hr_broken") then return end
		local remaining = math.max(0, math.Round(C.Remaining(w) - (amount or 1), 3))
		w:SetNW2Float("hr_durability_remaining", remaining)
		w:SetNW2Int("hr_durability", math.ceil(remaining))
		if remaining > 0 then return end
		w:SetNW2Bool("hr_broken", true)
		w:SetHitTime(0)
		if w:GetNW2Bool("hr_executing") then w.hr_break_position = pos return end
		C.Break(w, pos)
	end

	function C.Break(w, pos)
		if not IsValid(w) or not w:GetNW2Bool("hr_broken") then return end
		w.hr_break_position = nil
		DHR.RunHook("DHRWeaponBroken", w, pos)
		if w.HR.break_sound then w:EmitSound(w.HR.break_sound) end
		local owner = w:GetOwner()
		local key = w:GetClass():gsub("^hr_", "")
		for i = 1, 2 do
			local model = (w.HR.break_models or {})[i] or "models/weapons/hellraiser/w_hr_broken_" .. key .. "_" .. i .. ".mdl"
			if util.IsValidModel(model) then
				local piece = ents.Create("prop_physics")
				piece:SetModel(model)
				piece:SetPos(pos)
				piece:SetAngles(IsValid(owner) and owner:EyeAngles() or angle_zero)
				piece:Spawn()
				piece:SetCollisionGroup(COLLISION_GROUP_DEBRIS)
				local phys = piece:GetPhysicsObject()
				if IsValid(phys) then phys:SetVelocity(VectorRand() * 70 + Vector(0, 0, 80)) end
				timer.Simple(6, function() if IsValid(piece) then piece:Remove() end end)
			end
		end
		if IsValid(owner) and owner:IsPlayer() then
			owner:PrintMessage(HUD_PRINTTALK, w.PrintName .. " broke.")
		end
		w:Remove()
	end
end

local function strength(t)
	local a, b, m0, m1, width
	if t <= 0.7 then a, b, m0, m1, width = 1, 0.8, -0.053288907, -1, 0.7; t = t / width
	else a, b, m0, m1, width = 0.8, 0, -1, -5.2197204, 0.3; t = (t - 0.7) / width end
	return (2*t^3-3*t^2+1)*a + (t^3-2*t^2+t)*m0*width + (-2*t^3+3*t^2)*b + (t^3-t^2)*m1*width
end

hook.Add("SetupMove", "hr_aim_slowdown", function(p, move)
	local w = p:GetActiveWeapon()
	if not IsValid(w) or not w.HR or not w.GetAiming or not w:GetAiming() then return end
	local slowdown = (w.HR.ads or {}).slowdown
	if not slowdown or slowdown >= 1 then return end
	move:SetMaxClientSpeed(move:GetMaxClientSpeed() * slowdown)
	move:SetMaxSpeed(move:GetMaxSpeed() * slowdown)
end)

hook.Add("SetupMove", "hr_evade", function(p, move)
	if not C.Dodging(p) then return end
	local t = math.Clamp(1 - (p:GetNW2Float("hr_evade_end") - CurTime()) / duration, 0, 1)
	local v = p:GetNW2Vector("hr_evade_direction") * force * p:GetWalkSpeed() * strength(t)
	v.z = math.min(move:GetVelocity().z, 0)
	move:SetForwardSpeed(0)
	move:SetSideSpeed(0)
	move:SetUpSpeed(0)
	move:SetButtons(bit.band(move:GetButtons(), bit.bnot(bit.bor(IN_JUMP, IN_DUCK))))
	move:SetVelocity(v)
end)

if not CLIENT then return end
local lockKey = CreateClientConVar("hr_lock_key", tostring(KEY_F), true, false, "Toggle target lock")
local dodgeKey = CreateClientConVar("hr_dodge_key", tostring(KEY_LALT), true, false, "Directional dodge")
local dropKey = CreateClientConVar("hr_drop_key", "0", true, false, "Drops the Hellraiser weapon you're holding. 0 for none")
local function held(code)
	if code >= MOUSE_FIRST and code <= MOUSE_LAST then return input.IsMouseDown(code) end
	return code > KEY_NONE and code < MOUSE_FIRST and input.IsKeyDown(code)
end
function C.SetReloadSpeed(value)
	timer.Create("hr_reload_speed_setting", 0.2, 1, function()
		net.Start("hr_reload_speed_setting")
		net.WriteFloat(math.Clamp(value, 1, 2))
		net.SendToServer()
	end)
end
function C.SetInfinite(value)
	net.Start("hr_durability_setting")
	net.WriteBool(value)
	net.SendToServer()
end
local oldLock, oldDodge, oldDrop = false, false, false
local function usable()
	return weapon(LocalPlayer()) and not gui.IsGameUIVisible() and not vgui.CursorVisible() and not (HRWheel and HRWheel.open)
end
local function lock()
	if usable() and not (HRUpgrades and HRUpgrades.PickupTarget(LocalPlayer())) then
		net.Start("hr_lock") net.SendToServer()
	end
end
local function dodge()
	if not usable() then return end
	local p = LocalPlayer()
	local side = p:KeyDown(IN_MOVELEFT) and -1 or p:KeyDown(IN_MOVERIGHT) and 1 or 0
	net.Start("hr_evade") net.WriteInt(side, 2) net.SendToServer()
end
concommand.Add("hr_lock", lock)
concommand.Add("hr_dodge", dodge)
hook.Add("Think", "hr_combat_keys", function()
	local downLock, downDodge, downDrop = held(lockKey:GetInt()), held(dodgeKey:GetInt()), held(dropKey:GetInt())
	if downLock and not oldLock then lock() end
	if downDodge and not oldDodge then dodge() end
	if downDrop and not oldDrop and usable() then RunConsoleCommand("hr_drop") end
	oldLock, oldDodge, oldDrop = downLock, downDodge, downDrop
end)
hook.Add("PlayerBindPress", "hr_combat_keys", function(p, bind, pressed, code)
	if not usable() then return end
	if bind == "+use" then return end
	if code == lockKey:GetInt() or code == dodgeKey:GetInt() or code == dropKey:GetInt() then return true end
	if bind == "+jump" and IsValid(p:GetNW2Entity("hr_lock_target")) then
		if pressed then dodge() end
		return true
	end
end)
hook.Add("CreateMove", "hr_target_lock", function(cmd)
	if not usable() then return end
	local p = LocalPlayer()
	local e = p:GetNW2Entity("hr_lock_target")
	if not C.Targetable(p, e, 240) then return end
	local wanted = (C.TargetPoint(e) - p:EyePos()):Angle()
	cmd:SetViewAngles(LerpAngle(1 - math.exp(-FrameTime() / 0.15), cmd:GetViewAngles(), wanted))
end)
hook.Add("HUDPaint", "hr_combat", function()
	local p = LocalPlayer()
	local w = weapon(p)
	if not w or not DHR.CanUseFeature(LocalPlayer(), "hud", w) or not GetConVar("cl_drawhud"):GetBool() or not cvars.Bool("hr_hud", true) or not cvars.Bool("hr_hud_lock", true) then return end
	local s = ScrH() / 1080
	local target = p:GetNW2Entity("hr_lock_target")
	if IsValid(target) then
		local pos = C.TargetPoint(target):ToScreen()
		surface.SetDrawColor(235, 70, 75, 230)
		surface.DrawOutlinedRect(pos.x - 10*s, pos.y - 10*s, 20*s, 20*s, math.max(1, 2*s))
		local jump = input.LookupBinding("+jump", true)
		draw.SimpleTextOutlined("Locked on. " .. (jump and string.upper(jump) .. " to dodge" or "Jump to dodge"), "HRUpgradeSmall", ScrW()/2, ScrH()*0.67, Color(230,237,250), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP, 1, Color(0,0,0,220))
	end
end)
