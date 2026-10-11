AddCSLuaFile()
include("dhr/core.lua")
if SERVER then
	AddCSLuaFile("hellraiser/execution.lua")
	AddCSLuaFile("hellraiser/acoustics.lua")
	AddCSLuaFile("hellraiser/world_events.lua")
	AddCSLuaFile("hellraiser/upgrades.lua")
	AddCSLuaFile("hellraiser/combat.lua")
	AddCSLuaFile("hellraiser/wheel.lua")
	AddCSLuaFile("hellraiser/stock_icons.lua")
end
include("hellraiser/stealth.lua")
include("hellraiser/execution.lua")
include("hellraiser/killfeed.lua")
include("hellraiser/acoustics.lua")
include("hellraiser/world_events.lua")
include("hellraiser/upgrades.lua")
include("hellraiser/combat.lua")
include("dhr/bash.lua")
include("dhr/scope.lua")
include("hellraiser/dismember.lua")
include("hellraiser/player_corpses.lua")
include("hellraiser/blood.lua")
if CLIENT then
	HRStockIcons = include("hellraiser/stock_icons.lua")
	include("hellraiser/wheel.lua")
end
if SERVER then
	AddCSLuaFile("hellraiser/view.lua")
	AddCSLuaFile("hellraiser/motion_blur.lua")
	AddCSLuaFile("hellraiser/hands.lua")
	AddCSLuaFile("hellraiser/pose.lua")
	AddCSLuaFile("hellraiser/thirdperson.lua")
	AddCSLuaFile("hellraiser/vision.lua")
	AddCSLuaFile("hellraiser/smoke.lua")
	AddCSLuaFile("hellraiser/wall.lua")
	AddCSLuaFile("hellraiser/wounds.lua")
	if file.Exists("hellraiser/thirdperson_data.lua", "LUA") then AddCSLuaFile("hellraiser/thirdperson_data.lua") end
	if file.Exists("hellraiser/thirdperson_blade_data.lua", "LUA") then AddCSLuaFile("hellraiser/thirdperson_blade_data.lua") end
	if file.Exists("hellraiser/thirdperson_blunt_data.lua", "LUA") then AddCSLuaFile("hellraiser/thirdperson_blunt_data.lua") end
	AddCSLuaFile("hellraiser/flash.lua")
	AddCSLuaFile("hellraiser/hud.lua")
	if file.Exists("hellraiser/recoil_data.lua", "LUA") then AddCSLuaFile("hellraiser/recoil_data.lua") end
elseif CLIENT then
	include("hellraiser/hands.lua")
	include("hellraiser/pose.lua")
	include("hellraiser/thirdperson.lua")
	include("hellraiser/view.lua")
	include("hellraiser/hud.lua")
	include("hellraiser/vision.lua")
	include("hellraiser/smoke.lua")
	include("hellraiser/wall.lua")
	include("hellraiser/wounds.lua")
end

SWEP.Base = "weapon_base"
SWEP.PrintName = "DHRB Weapon"
SWEP.Category = "Dandy's Hellraiser Base"
SWEP.Author = "Dandy"
SWEP.Spawnable = false
SWEP.AdminOnly = false
SWEP.UseHands = true
SWEP.ViewModelFOV = 74
SWEP.ViewModelFlip = false
SWEP.BobScale = 0
SWEP.SwayScale = 0
SWEP.DrawAmmo = true
SWEP.DrawCrosshair = true
SWEP.BounceWeaponIcon = false
SWEP.DrawWeaponInfoBox = false
SWEP.Weight = 5
SWEP.AutoSwitchTo = false
SWEP.AutoSwitchFrom = false

SWEP.Primary.ClipSize = -1
SWEP.Primary.DefaultClip = -1
SWEP.Primary.Automatic = false
SWEP.Primary.Ammo = "none"
SWEP.Secondary.ClipSize = -1
SWEP.Secondary.DefaultClip = -1
SWEP.Secondary.Automatic = true
SWEP.Secondary.Ammo = "none"

SWEP.HR = { kind = "gun", seq = {}, len = {} }

local cv_scale = CreateConVar("hr_damage_scale", "2.5", bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY),
	"Damage multiplier for the Hellraiser weapons")
local cv_ads = CreateClientConVar("hr_ads_toggle", "0", true, true, "Hellraiser weapons: 1 = right click toggles aiming")
CreateClientConVar("hr_auto_reload", "1", true, true, "Hellraiser guns reload on their own when the magazine is empty")
CreateClientConVar("hr_pistol_hold_fire", "1", true, true, "Hold primary attack to repeat pistol shots at their normal firing rate")
local cv_smooth = CLIENT and CreateClientConVar("hr_smooth_aim", "1", true, false, "Ease the gun in and out of the sights with the zoom and blend between its animations")

local function pick(list, seed)
	if type(list) ~= "table" then return list end
	if #list == 1 then return list[1] end
	local i = math.floor(util.SharedRandom(seed, 1, #list + 0.999))
	return list[math.Clamp(i, 1, #list)]
end

function SWEP:SetupDataTables()
	self:NetworkVar("Bool", 0, "Aiming")
	self:NetworkVar("Bool", 1, "Heavy")
	self:NetworkVar("Bool", 2, "AdsPose")
	self:NetworkVar("Float", 0, "BusyUntil")
	self:NetworkVar("Float", 1, "ReloadDone")
	self:NetworkVar("Float", 2, "HitTime")
	self:NetworkVar("Float", 3, "StageEnd")
	self:NetworkVar("Float", 4, "ReloadUntil")
	self:NetworkVar("Float", 5, "DrawReady")
	self:NetworkVar("Int", 0, "ReloadStage")
	self:NetworkVar("Int", 1, "Swing")
	self:NetworkVar("String", 0, "BaseSeq")
	self:NetworkVar("String", 1, "Attack")
	self:NetworkVar("String", 2, "PoseSequence")
	self:NetworkVar("Float", 6, "PoseStart")
	self:NetworkVar("Float", 7, "PoseRate")
	self:NetworkVar("Float", 8, "ReloadRate")
	self:NetworkVar("Float", 10, "PumpAt")
	self:NetworkVar("Float", 19, "BashStart")
end

function SWEP:UpdateFireMode(owner)
	if not self.HR.hold_fire then return end
	owner = owner or self:GetOwner()
	self.Primary.Automatic = IsValid(owner) and owner:IsPlayer() and owner:GetInfoNum("hr_pistol_hold_fire", 1) ~= 0
end

function SWEP:Initialize()
	self.Primary = table.Copy(self.Primary)
	self.Secondary = table.Copy(self.Secondary)
	self.HR = table.Copy(self.HR)
	self.dhr_use_hands = self.UseHands
	self:SetHoldType(self.HoldType or "pistol")
end

function SWEP:Equip(owner)
	self:UpdateFireMode(owner)
	if IsValid(owner) and owner:IsNPC() and owner:GetClass() == "npc_citizen" and (self.HoldType == "pistol" or self.HoldType == "revolver") then
		self:SetHoldType("smg")
	elseif IsValid(owner) and owner:IsPlayer() then
		self:SetHoldType(self.HoldType or "pistol")
	end
end

function SWEP:CanBePickedUpByNPCs()
	return self.HR.kind == "gun" and self.Primary.ClipSize > 0
end

function SWEP:GetNPCRestTimes()
	return 0.4, 0.9
end

function SWEP:GetNPCBurstSettings()
	local delay = 1 / (self.HR.rate or 2)
	if self.Primary.Automatic then return 3, 8, delay end
	return 1, 1, math.max(delay, 0.4)
end

function SWEP:GetNPCBulletSpread(proficiency)
	return ({ [0] = 9, 6, 4, 3, 2 })[proficiency] or 4
end

function SWEP:NPCShoot_Primary(pos, dir)
	local owner = self:GetOwner()
	if not IsValid(owner) or not self:CanBePickedUpByNPCs() then return end
	local h = self.HR
	owner:FireBullets({ Num = h.pellets or 1, Src = pos, Dir = dir, Spread = Vector(h.spread, h.spread, 0), Tracer = 1,
		TracerName = "hr_tracer", Force = (h.force or 10) * 0.2, Damage = h.damage * GetConVar("hr_damage_scale"):GetFloat(),
		AmmoType = self.Primary.Ammo, Inflictor = self,
		Callback = function(_, tr, damage) HRDismember.CorpseHit(self, tr, damage:GetDamage(), damage:GetDamageForce()) end })
	owner:MuzzleFlash()
	if h.fire_snd then self:EmitSound(self:GetShotSound(false)) end
	net.Start("hr_weapon_shot")
	net.WriteEntity(self)
	net.SendPVS(pos)
end

if SERVER then
	concommand.Add("hr_drop", function(ply)
		local w = IsValid(ply) and ply:GetActiveWeapon()
		if IsValid(w) and w.HR and not w:GetNW2Bool("hr_executing") then ply:DropWeapon(w) end
	end)
end

function SWEP:SeqLen(name)
	if self.HR.len[name] then return self.HR.len[name] end
	local owner = self:GetOwner()
	local vm = IsValid(owner) and owner:IsPlayer() and owner:GetViewModel()
	local id = IsValid(vm) and name and vm:LookupSequence(name) or -1
	return id >= 0 and vm:SequenceDuration(id) or 0.5
end

function SWEP:PlaySeq(name, rate)
	local owner = self:GetOwner()
	if not name or not IsValid(owner) or not owner:IsPlayer() then return 0 end
	local vm = owner:GetViewModel()
	if not IsValid(vm) then return 0 end
	local seq = vm:LookupSequence(name)
	if seq < 0 then return 0 end
	vm:SendViewModelMatchingSequence(seq)
	rate = rate or (self.HR.movement_rates or {})[name] or 1
	vm:SetPlaybackRate(rate)
	self:SetPoseSequence(name)
	self:SetPoseStart(CurTime())
	self:SetPoseRate(rate)
	return self:SeqLen(name) / rate
end

function SWEP:Action(name, rate, magazineRounds)
	if self.HR.kind == "gun" and name and string.StartWith(name, "reload") then
		rate = rate or math.Clamp(self:GetReloadRate(), 1, 2)
	end
	self.hr_pending_magazine = nil
	if self.HR.magazines and name and string.StartWith(name, "reload") then
		self.hr_magazine_rounds = math.max(0, magazineRounds or self:Clip1())
		if SERVER then self:SetNW2Int("hr_magazine_rounds", self.hr_magazine_rounds) end
	end
	self:SetDrawReady(0)
	if self.HR.aim then self:SetAdsPose(self:GetAiming())
	else self:SetAdsPose(name ~= nil and string.StartWith(name, "ads_") and name ~= self.HR.seq.ads_out) end
	local d = self:PlaySeq(name, rate)
	if SERVER then self:QueueWorldEvents(name, rate or 1) end
	self:SetBaseSeq("")
	self:SetBusyUntil(CurTime() + d)
	return d
end

function SWEP:BaseSequence()
	local owner = self:GetOwner()
	local s = self.HR.seq
	local speed = owner:GetVelocity():Length2D()
	local moving = speed > 30 and owner:OnGround()
	local name
	if self:GetAiming() then
		name = (moving and s.ads_walk) or s.ads_idle or s.idle
	elseif self:IsRunning() and s.sprint then
		name = s.sprint
	elseif moving and s.walk then
		name = s.walk
	else
		name = s.idle
	end
	if name and self.Primary.ClipSize > 0 and self:Clip1() == 0 and s[name .. "_empty"] then
		name = s[name .. "_empty"]
	end
	return name
end

function SWEP:Deploy()
	DHRBash.Cancel(self)
	if self.DHRWeapon and DHR.ResolveAnimations(self) == false then return false end
	self:UpdateFireMode()
	self:SetAiming(false)
	self.hr_recoil = 0
	self.hr_shot_roll = 0
	self.hr_pending_cases = 0
	self.hr_recoil_curve = nil
	self.hr_look = nil
	self.hr_muzzle_until = 0
	self.hr_hit_until = 0
	self:SetReloadDone(0)
	self:SetReloadStage(0)
	self:SetReloadUntil(0)
	self:ClearReloadState()
	self:SetHitTime(0)
	self:SetPumpAt(0)
	local d = self:Action(self.HR.seq.draw)
	if self.HR.draw_snd and not (self.HR.world_events or {}).draw then self:EmitSound(self.HR.draw_snd) end
	local ready = CurTime() + (self.HR.draw_unblock or d * (self.HR.draw_ready or 0.75))
	self:SetNextPrimaryFire(ready)
	self:SetNextSecondaryFire(ready)
	if self.HR.draw_unblock then self:SetDrawReady(ready) end
	return true
end

function SWEP:OnDrop()
	DHRBash.Cancel(self)
	self.hr_world_action = (self.hr_world_action or 0) + 1
	if SERVER and self.HR.drop_snd then self:EmitSound(self.HR.drop_snd) end
end

function SWEP:Holster()
	if self:GetNW2Bool("hr_executing") then return false end
	DHRBash.Cancel(self)
	self.hr_world_action = (self.hr_world_action or 0) + 1
	self:SetAiming(false)
	self.hr_recoil = 0
	self.hr_shot_roll = 0
	self.hr_pending_cases = 0
	self.hr_recoil_curve = nil
	self.hr_look = nil
	self.hr_muzzle_until = 0
	self.hr_hit_until = 0
	if self.HR.seq.reload_fill5 and (self:GetReloadStage() == 4 or self:GetReloadDone() > 0) then
		self:SetNW2Int("hr_rev_loaded", self:Clip1())
	end
	self:SetReloadDone(0)
	self:SetReloadStage(0)
	self:SetReloadUntil(0)
	self:ClearReloadState()
	self:SetHitTime(0)
	return true
end

if SERVER then
	util.AddNetworkString("hr_weapon_shot")
	util.AddNetworkString("hr_weapon_hit")
	hook.Add("PostEntityTakeDamage", "hr_weapon_hit", function(target, damage, taken)
		if not taken or damage:GetDamage() <= 0 or not damage:IsBulletDamage() then return end
		if not target:IsNPC() and not target:IsNextBot() then return end
		local weapon = damage:GetInflictor()
		if not IsValid(weapon) or not weapon.HR or weapon.HR.kind ~= "gun" then return end
		local owner = weapon:GetOwner()
		if not IsValid(owner) or not owner:IsPlayer() or damage:GetAttacker() ~= owner then return end
		local tick = engine.TickCount()
		if weapon.hr_hit_tick == tick then return end
		weapon.hr_hit_tick = tick
		local distance = owner:GetShootPos():Distance(damage:GetDamagePosition())
		if distance < 110 then HRBlood.Add(weapon, (weapon.HR.crosshair == "shotgun" and 0.5 or 0.3) * (1 - distance / 110)) end
		net.Start("hr_weapon_hit")
		net.WriteEntity(weapon)
		net.Send(owner)
	end)
end

function SWEP:ClientShot()
	if not CLIENT then return end
	local owner = self:GetOwner()
	if not IsValid(owner) then return end
	local localView = owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()
	if localView then
		self.hr_muzzle_until = CurTime() + 0.075
		self.hr_flash_roll = math.Rand(-25, 25)
		self.hr_recoil = math.min((self.hr_recoil or 0) + self.HR.kick * 1.8 * HRUpgrades.Get(self, "recoil"), 6.5)
		self.hr_shot_roll = math.Rand(-0.3, 0.3) * self.HR.kick
		self.hr_shot_time = CurTime()
	end
	if owner == LocalPlayer() then self:BeginRecoil() end
	if owner == LocalPlayer() and self.HR.fire_snd then
		self:PlayShotSound()
	end
	local ed = EffectData()
	ed:SetEntity(self)
	ed:SetAttachment(1)
	ed:SetScale(self.HR.flash or 1)
	ed:SetOrigin(owner:IsPlayer() and owner:GetShootPos() or owner:WorldSpaceCenter())
	util.Effect("hr_muzzle", ed)
	if HRSmoke then HRSmoke.Shot(self) end
	self:PlayShotReflections()
	if self.HR.kind == "gun" and self.HR.crosshair ~= "revolver" then
		if localView then
			if self.HR.crosshair ~= "shotgun" then self.hr_pending_cases = (self.hr_pending_cases or 0) + 1 end
		else
			local delay = self.HR.crosshair == "shotgun" and 0.56 / HRUpgrades.Get(self, "rate") or 0
			timer.Simple(delay, function()
				if IsValid(self) and IsValid(owner) and self:GetOwner() == owner and owner:GetActiveWeapon() == self then self:EjectCase() end
			end)
		end
	end
end

if CLIENT then
	net.Receive("hr_weapon_hit", function()
		local weapon = net.ReadEntity()
		local owner = LocalPlayer()
		if not IsValid(weapon) or weapon:GetOwner() ~= owner or owner:GetActiveWeapon() ~= weapon then return end
		weapon.hr_hit_until = CurTime() + 0.22
	end)
	net.Receive("hr_weapon_shot", function()
		local w = net.ReadEntity()
		if not IsValid(w) or not w.ClientShot then return end
		if w:GetOwner() ~= LocalPlayer() or game.SinglePlayer() then w:ClientShot() end
	end)
end

function SWEP:MuzzleFx()
	if CLIENT then
		if IsFirstTimePredicted() then self:ClientShot() end
		return
	end
	local owner = self:GetOwner()
	owner:MuzzleFlash()
	net.Start("hr_weapon_shot")
	net.WriteEntity(self)
	net.SendPAS(owner:GetShootPos())
	if self.HR.fire_snd then
		local listeners = RecipientFilter()
		listeners:AddPAS(owner:GetShootPos())
		listeners:RemovePlayer(owner)
		self:EmitSound(self:GetShotSound(false), nil, nil, nil, nil, nil, nil, listeners)
	end
end

function SWEP:IsRunning()
	local owner = self:GetOwner()
	return IsValid(owner) and owner:OnGround() and owner:KeyDown(IN_SPEED)
		and owner:GetVelocity():Length2D() > owner:GetWalkSpeed() * 1.05
end

function SWEP:ShootGun()
	local owner = self:GetOwner()
	local h = self.HR
	local aim = self:GetAiming()
	local sp = (aim and (h.spread_ads or h.spread * 0.35) or h.spread) * HRUpgrades.Get(self, "spread")
	local b = {}
	b.Num = h.pellets or 1
	b.Src = owner:GetShootPos()
	b.Dir = owner:GetAimVector()
    if self.DualWield then
        local offset = owner:EyeAngles():Right() * (self.dhr_firing_side == 1 and -5 or 5)
        local origin = util.TraceHull({start = b.Src, endpos = b.Src + offset, mins = Vector(-1, -1, -1),
            maxs = Vector(1, 1, 1), filter = {owner, self}, mask = MASK_SHOT})
        local target = util.TraceLine({start = b.Src, endpos = b.Src + b.Dir * (h.range or 56756), filter = {owner, self}, mask = MASK_SHOT})
        b.Src = origin.HitPos
        b.Dir = (target.HitPos - b.Src):GetNormalized()
    end
	b.Spread = Vector(sp, sp, 0)
	b.Tracer = h.tracer or 1
	b.TracerName = h.tracer_effect or "hr_tracer"
	b.Force = (h.force or 10) * 0.2
	b.Damage = h.damage * cv_scale:GetFloat() * HRUpgrades.Get(self, "damage")
	if HRUpgrades.Get(self, "slug") then
		b.Damage = b.Damage * b.Num
		b.Num = 1
	end
	b.AmmoType = self.Primary.Ammo
	b.Inflictor = self
	b.Distance = h.range or 56756
	local ignite, pierce = HRUpgrades.Get(self, "ignite"), HRUpgrades.Get(self, "penetration")
	b.Callback = function(attacker, tr, damage)
		if SERVER then HRDismember.CorpseHit(self, tr, damage:GetDamage(), damage:GetDamageForce()) end
		if ignite or pierce then
			local e = tr.Entity
			if not IsValid(e) or not (e:IsNPC() or e:IsPlayer() or e:IsNextBot()) then return end
			if ignite and SERVER then e:Ignite(ignite) end
			if pierce and not self.hr_piercing then
				self.hr_piercing = true
				attacker:FireBullets({ Num = 1, Src = tr.HitPos + tr.Normal * 6, Dir = tr.Normal, Spread = vector_origin,
					Damage = b.Damage * 0.7, Force = b.Force, Tracer = 0, IgnoreEntity = e, Inflictor = self, AmmoType = b.AmmoType,
					Callback = function(_, hit, damage) if SERVER then HRDismember.CorpseHit(self, hit, damage:GetDamage(), damage:GetDamageForce()) end end })
				self.hr_piercing = false
			end
		end
	end
	DHR.RunHook("DHRModifyBullet", self, b)
	owner:FireBullets(b)
	self:MuzzleFx()
	owner:SetAnimation(PLAYER_ATTACK1)

end

function SWEP:PrimaryAttack()
	if DHRBash.Active(self) then return end
	if HRCombat.Dodging(self:GetOwner()) or self:GetNW2Bool("hr_broken") then return end
	if self:GetNW2Bool("hr_executing") or self:IsRunning() then return end
	if self.HR.kind == "melee" then return self:MeleeAttack(false) end
	local h = self.HR
	if self:GetReloadStage() == 4 then
		local allowed = self:GetNW2Float("hr_reload_interrupt", 0)
		if allowed > 0 and CurTime() >= allowed then self:RevolverInterrupt() end
		return
	end
	if self:GetReloadStage() > 0 then
		if self:Clip1() > 0 then self:FinishShellReload() end
		return
	end
	if self:GetReloadDone() > 0 then return end
	if self:Clip1() <= 0 then
		if self:AutoReload() then return self:Reload() end
		if h.dry_snd then self:EmitSound(h.dry_snd) end
		self:Action(self:GetAiming() and h.seq.ads_fire_dry or h.seq.fire_dry)
		self:SetNextPrimaryFire(CurTime() + 0.35)
		return
	end
	if DHR.RunHook("DHRCanFire", self) == false then return end
	self:ShootGun()
	self:TakePrimaryAmmo(1)

	local list = self:GetAiming() and h.seq.ads_fire or h.seq.fire
	local name = pick(list, "hr_fireanim" .. self:Clip1())
	if self:Clip1() <= 0 and h.seq.fire_last then name = self:GetAiming() and (h.seq.ads_fire_last or h.seq.fire_last) or h.seq.fire_last end
	local multiplier = HRUpgrades.Get(self, "rate")
	local pump = h.crosshair == "shotgun"
	local duration = self:Action(name, pump and multiplier or 1)
	local delay = 1 / (h.rate * multiplier)
	if pump then delay = math.max(delay, duration) end
	if h.seq.pump then
		local start = h.pump_delay and h.pump_delay / multiplier or duration
		self:SetPumpAt(CurTime() + start)
		delay = math.max(delay, start + self:SeqLen(h.seq.pump) / multiplier)
	end
	self:SetNextPrimaryFire(CurTime() + delay)
	if IsFirstTimePredicted() then DHR.RunHook("DHRShotFired", self) end
end

function SWEP:SecondaryAttack()
	if self.HR.kind == "melee" then return self:MeleeAttack(true) end
end

function SWEP:CanReload()
	if DHRBash.Active(self) then return false end
	local owner = self:GetOwner()
	if self.Primary.ClipSize <= 0 then return false end
	if self:GetReloadDone() > 0 or self:GetReloadStage() > 0 then return false end
	if CurTime() < self:GetNextPrimaryFire() - 0.05 then return false end
	if self:Clip1() >= self.Primary.ClipSize then return false end
	return owner:GetAmmoCount(self.Primary.Ammo) > 0
end

function SWEP:AutoReload()
	local owner = self:GetOwner()
	return self:Clip1() <= 0 and IsValid(owner) and owner:IsPlayer() and owner:GetInfoNum("hr_auto_reload", 1) ~= 0 and self:CanReload()
end

function SWEP:Reload()
	if self.HR.kind == "melee" or not self:CanReload() then return end
	if DHR.RunHook("DHRCanReload", self) == false then return end
	if IsFirstTimePredicted() then DHR.RunHook("DHRReloadStarted", self) end
	self:SetNW2Float("hr_mag_swap", 0)
	self:SetReloadRate(HRCombat.ReloadSpeed())
	local h = self.HR
	local owner = self:GetOwner()
	self:SetAiming(false)
	owner:SetAnimation(PLAYER_RELOAD)
	if h.seq.reload_start then
		local d = self:Action(h.seq.reload_start)
		self:SetReloadStage(1)
		self:SetStageEnd(CurTime() + d)
		self:SetNextPrimaryFire(CurTime() + d * 0.5)
		return
	end
	if h.seq.reload_fill5 then return self:RevolverReload() end
	local ext = HRUpgrades.Get(self, "reload") == "ext" and "_ext" or ""
	local name = h.seq["reload" .. ext] or h.seq.reload
	if self:Clip1() > 0 and h.seq["reload_half" .. ext] then name = h.seq["reload_half" .. ext] end
	local d = self:Action(name)
	local insert, input = self:ReloadTiming(name, d)
	self:SetReloadDone(CurTime() + insert)
	self:SetNextPrimaryFire(CurTime() + input)
	self:SetReloadUntil(CurTime() + input)
end

function SWEP:ReloadTiming(name, d)
	local ev = (self.HR.reload_events or {})[name] or {}
	local rate = math.max(self:GetPoseRate(), 1)
	return ev.insert and ev.insert / rate or d * (self.HR.reload_fill and self.HR.reload_fill[name] or 0.8), ev.input and ev.input / rate or d
end

function SWEP:ClearReloadState()
	self:SetNW2Int("hr_casing_hide", 0)
	self:SetNW2Float("hr_casing_show", 0)
	self:SetNW2Float("hr_reload_interrupt", 0)
	self:SetNW2Float("hr_reload_input", 0)
	self:SetNW2String("hr_reload_section", "")
	self:SetNW2Float("hr_mag_swap", 0)
	self.hr_reload_starved = nil
end

function SWEP:RevolverLoaded()
	local loaded = self:GetNW2Int("hr_rev_loaded", -1)
	return loaded >= 0 and loaded or self.Primary.ClipSize
end

function SWEP:RevolverReload()
	local h, owner = self.HR, self:GetOwner()
	local clip, size, loaded = self:Clip1(), self.Primary.ClipSize, self:RevolverLoaded()
	local rules = h.casing_hide or {}
	self:ClearReloadState()
	if clip <= 0 and owner:GetAmmoCount(self.Primary.Ammo) >= size then
		self:SetNW2Int("hr_casing_hide", (rules.full or {})[tostring(loaded)] or 0)
		if SERVER then self:SetNW2Int("hr_reload_cases", math.Clamp(loaded, 0, 6)) end
		local d = self:Action(h.seq.reload)
		local ev = (h.reload_events or {}).reload or {}
		if ev.casings then self:SetNW2Float("hr_casing_show", CurTime() + ev.casings[1] / self:GetPoseRate()) end
		local insert, input = self:ReloadTiming("reload", d)
		self:SetReloadDone(CurTime() + insert)
		self:SetNextPrimaryFire(CurTime() + input)
		self:SetReloadUntil(CurTime() + input)
		return
	end
	local start = (loaded > clip and "reload_rem" or "reload_only") .. clip
	if not h.seq[start] then start = "reload_rem" .. clip end
	self:SetNW2Int("hr_casing_hide", ((rules.partial or {})[tostring(clip)] or {})[tostring(loaded)] or 0)
	if SERVER then self:SetNW2Int("hr_reload_cases", math.Clamp(loaded - clip, 0, 6)) end
	self:SetReloadStage(4)
	self:RevolverSection(start)
end

function SWEP:RevolverSection(name)
	local h, now = self.HR, CurTime()
	local show = self:GetNW2Float("hr_casing_show", 0)
	if show > 0 and now >= show then self:SetNW2Int("hr_casing_hide", 0) end
	local d = self:Action(h.seq[name])
	local rate = self:GetPoseRate()
	local ev = (h.reload_events or {})[name] or {}
	self:SetNW2String("hr_reload_section", name)
	self:SetStageEnd(now + d)
	self:SetReloadDone(ev.insert and now + ev.insert / rate or 0)
	self:SetNW2Float("hr_reload_input", ev.input and now + ev.input / rate or 0)
	if ev.casings then self:SetNW2Float("hr_casing_show", now + ev.casings[1] / rate) end
	if ev.interrupt and self:GetNW2Float("hr_reload_interrupt", 0) == 0 then
		self:SetNW2Float("hr_reload_interrupt", now + ev.interrupt / rate)
	end
	self:SetReloadUntil(now + d)
	self:SetNextPrimaryFire(now)
	self.hr_reload_starved = nil
end

function SWEP:RevolverInterrupt()
	local section = self:GetNW2String("hr_reload_section")
	if section == "reload_fill5" or string.StartWith(section, "reload_end") then return end
	local name = "reload_end" .. self:Clip1()
	if not self.HR.seq[name] then return self:RevolverFinish() end
	self:RevolverSection(name)
end

function SWEP:RevolverFinish()
	self:SetNW2Int("hr_rev_loaded", self:Clip1())
	self:SetReloadStage(0)
	self:SetReloadUntil(0)
	self:ClearReloadState()
	self:SetNextPrimaryFire(CurTime())
end

function SWEP:ThinkRevolverReload(now)
	local owner = self:GetOwner()
	local section = self:GetNW2String("hr_reload_section")
	if self:GetReloadDone() > 0 and now >= self:GetReloadDone() then
		self:SetReloadDone(0)
		self:FillClip(1)
		if owner:GetAmmoCount(self.Primary.Ammo) <= 0 and section ~= "reload_fill5" then self.hr_reload_starved = now + 0.2 / math.max(self:GetReloadRate(), 1) end
	end
	if self.hr_reload_starved and now >= self.hr_reload_starved then
		self.hr_reload_starved = nil
		return self:RevolverInterrupt()
	end
	local input = self:GetNW2Float("hr_reload_input", 0)
	if section == "reload_fill5" and input > 0 and now >= input then return self:RevolverFinish() end
	if now < self:GetStageEnd() then return end
	if section == "reload_fill5" or string.StartWith(section, "reload_end") or self:Clip1() >= self.Primary.ClipSize then
		self:RevolverFinish()
	elseif owner:GetAmmoCount(self.Primary.Ammo) <= 0 then
		self:RevolverInterrupt()
	else
		self:RevolverSection("reload_fill" .. self:Clip1())
	end
end

function SWEP:CasingMask()
	local mask = self:GetNW2Int("hr_casing_hide", 0)
	if mask == 0 then return 0 end
	local show = self:GetNW2Float("hr_casing_show", 0)
	if show > 0 and CurTime() >= show then return 0 end
	return mask
end

function SWEP:UpgradeReload(old)
	local h, owner = self.HR, self:GetOwner()
	local outgoingRounds = self:Clip1()
	if not IsValid(owner) or not owner:IsPlayer() or owner:GetActiveWeapon() ~= self or self:GetNW2Bool("hr_executing") then return end
	local before, after = HRUpgrades.Parse(old), HRUpgrades.Installed(self)
	local changed, ammoType, magazine, fitting
	for _, u in ipairs(h.upgrades or {}) do
		if (u.swap or u.fit) and (before[u.id] or false) ~= (after[u.id] or false) then
			changed = true
			if u.group == "ammo" then ammoType = true end
			if u.reload then magazine = true end
			if u.fit then fitting = true end
		end
	end
	if not changed then return end
	self:SetReloadRate(HRCombat.ReloadSpeed())
	local ammo = self.Primary.Ammo
	self:SetAiming(false)
	self:SetReloadStage(0)
	self:SetReloadDone(0)
	self:ClearReloadState()
	if fitting and not ammoType and not magazine then
		if self:Clip1() > self.Primary.ClipSize then
			owner:GiveAmmo(self:Clip1() - self.Primary.ClipSize, ammo, true)
			self:SetClip1(self.Primary.ClipSize)
		end
		local d = self:Action(h.seq.draw)
		self:SetNW2String("hr_mag_from", old)
		self:SetNW2Float("hr_mag_swap", CurTime() + math.min(0.15, d * 0.2))
		self:SetNextPrimaryFire(CurTime() + d)
		self:SetReloadUntil(CurTime() + d)
		return true
	end
	if h.seq.reload_start then
		if ammoType and self:Clip1() > 0 then
			owner:GiveAmmo(self:Clip1(), ammo, true)
			self:SetClip1(0)
		elseif self:Clip1() > self.Primary.ClipSize then
			owner:GiveAmmo(self:Clip1() - self.Primary.ClipSize, ammo, true)
			self:SetClip1(self.Primary.ClipSize)
		end
		self:SetNextPrimaryFire(CurTime())
		self:SetReloadUntil(0)
		if self:CanReload() then self:Reload() end
		return true
	end
	if self:Clip1() > 0 then
		owner:GiveAmmo(self:Clip1(), ammo, true)
		self:SetClip1(0)
	end
	local swaps = h.mag_swap or {}
	local name = HRUpgrades.Get(self, "reload") == "ext" and "reload_ext" or "reload"
	if magazine and swaps[name] and not swaps[name].both then
		for other, swap in pairs(swaps) do if swap.both then name = other end end
	end
	name = h.seq[name] and name or "reload"
	local d = self:Action(h.seq[name], nil, outgoingRounds)
	local insert, input = self:ReloadTiming(name, d)
	self:SetNW2String("hr_mag_from", old)
	self:SetNW2Float("hr_mag_swap", CurTime() + ((swaps[name] or {}).time and swaps[name].time / self:GetPoseRate() or insert))
	self:SetReloadDone(CurTime() + insert)
	self:SetNextPrimaryFire(CurTime() + input)
	self:SetReloadUntil(CurTime() + input)
	owner:SetAnimation(PLAYER_RELOAD)
	return true
end

function SWEP:VisualUpgrades()
	if CurTime() < self:GetNW2Float("hr_mag_swap", 0) then return HRUpgrades.Parse(self:GetNW2String("hr_mag_from", "")) end
	return HRUpgrades.Installed(self)
end

function SWEP:FillClip(n)
	local owner = self:GetOwner()
	local have = owner:GetAmmoCount(self.Primary.Ammo)
	local take = math.min(n or (self.Primary.ClipSize - self:Clip1()), have, self.Primary.ClipSize - self:Clip1())
	if take <= 0 then return 0 end
	self:SetClip1(self:Clip1() + take)
	owner:RemoveAmmo(take, self.Primary.Ammo)
	return take
end

function SWEP:FinishShellReload()
	local stage = self:GetReloadStage()
	if stage ~= 1 and stage ~= 2 then return end
	local d = self:Action(self.HR.seq.reload_end)
	self:SetReloadStage(3)
	self:SetStageEnd(CurTime() + d)
	self:SetNextPrimaryFire(CurTime() + d)
end

function SWEP:ThinkReload(now)
	local h = self.HR
	if self:GetReloadStage() == 4 then return self:ThinkRevolverReload(now) end
	if self:GetReloadDone() > 0 and now >= self:GetReloadDone() then
		self:SetReloadDone(0)
		self:FillClip()
		if h.seq.reload_fill5 then self:SetNW2Int("hr_rev_loaded", self:Clip1()) end
	end
	local st = self:GetReloadStage()
	if st == 0 or now < self:GetStageEnd() then return end
	local owner = self:GetOwner()
	if st == 1 or st == 2 then
		if st == 2 then self:FillClip(1) end
		if self:Clip1() < self.Primary.ClipSize and owner:GetAmmoCount(self.Primary.Ammo) > 0 then
			local d = self:Action(h.seq.reload_loop)
			self:SetReloadStage(2)
			self:SetStageEnd(now + d)
		else
			self:FinishShellReload()
		end
	elseif st == 3 then
		self:SetReloadStage(0)
	end
end

local SURFACE = {
	[MAT_CONCRETE] = "concrete", [MAT_METAL] = "metal", [MAT_VENT] = "metal", [MAT_GRATE] = "metal", [MAT_COMPUTER] = "metal",
	[MAT_WOOD] = "wood", [MAT_GLASS] = "glass", [MAT_TILE] = "ceramic", [MAT_PLASTIC] = "ceramic", [MAT_DIRT] = "rock",
	[MAT_SAND] = "rock", [MAT_GRASS] = "rock", [MAT_SNOW] = "rock", [MAT_FOLIAGE] = "wood",
}
function SWEP:MeleeAttack(heavy)
	if HRCombat.Dodging(self:GetOwner()) or self:GetNW2Bool("hr_broken") then return end
	if self:GetNW2Bool("hr_executing") or CurTime() < self:GetNextPrimaryFire() then return end
	if not heavy and HRExecutions.Try(self) then return end
	local h = self.HR
	local list = heavy and h.heavy or h.light
	if not list or #list == 0 then return end
	local n = self:GetSwing()
	local a = list[(n % #list) + 1]
	self:SetSwing(n + 1)
	self:SetHeavy(heavy)
	self:SetAttack(a.seq)
	self:Action(a.seq)
	if h.swing_snd then self:EmitSound(h.swing_snd) end
	self:SetHitTime(CurTime() + a.hit)
	self:SetBusyUntil(CurTime() + (a.len or a.recover + 0.3))
	self:SetNextPrimaryFire(CurTime() + a.recover)
	self:SetNextSecondaryFire(CurTime() + a.recover)
	self:GetOwner():SetAnimation(PLAYER_ATTACK1)
end

local BREAKABLE = { func_breakable = true, func_breakable_surf = true, func_physbox = true, prop_physics = true,
	prop_physics_multiplayer = true, item_item_crate = true }
local function breakable(e)
	if not IsValid(e) or e:IsPlayer() or e:IsNPC() or e:IsNextBot() or e:IsRagdoll() then return false end
	return BREAKABLE[e:GetClass()] or SERVER and e:Health() > 0
end

function SWEP:MeleeHit()
	local owner = self:GetOwner()
	local h = self.HR
	local range = h.range or 72
	if owner:IsPlayer() then owner:LagCompensation(true) end
	local src = owner:GetShootPos()
	local dir = owner:GetAimVector()
	local tr = util.TraceLine({ start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT_HULL })
	if not IsValid(tr.Entity) then
		tr = util.TraceHull({ start = src, endpos = src + dir * range, filter = owner, mask = MASK_SHOT_HULL,
			mins = Vector(-10, -10, -8), maxs = Vector(10, 10, 8) })
	end
	if owner:IsPlayer() then owner:LagCompensation(false) end
	if not tr.Hit then return end
	if SERVER then
		hook.Run("HRMeleeNoise", owner, tr.HitPos)
		DHR.RunHook("DHRMeleeHit", self, tr)
	end
	local ent = tr.Entity
	local fleshy = IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:IsRagdoll())
		or tr.MatType == MAT_FLESH or tr.MatType == MAT_ALIENFLESH or tr.MatType == MAT_BLOODYFLESH
	local snd = h.hit_flesh
	if not fleshy then
		local hw = h.hit_world or {}
		snd = hw[SURFACE[tr.MatType] or "concrete"] or hw.concrete
	end
	if snd then self:EmitSound(snd) end
	if IsFirstTimePredicted() then
		local ed = EffectData()
		ed:SetOrigin(tr.HitPos)
		ed:SetStart(src)
		ed:SetSurfaceProp(tr.SurfaceProps)
		ed:SetDamageType(h.sharp and DMG_SLASH or DMG_CLUB)
		ed:SetHitBox(tr.HitBox)
		ed:SetEntity(ent)
		if fleshy then
			ed:SetNormal(tr.HitNormal)
			ed:SetColor(IsValid(ent) and HRDismember.BloodColor(ent) or BLOOD_COLOR_RED)
			util.Effect("BloodImpact", ed)
		else
			util.Effect("Impact", ed)
		end
		if h.sharp and not fleshy then util.Decal("ManhackCut", tr.HitPos + tr.HitNormal, tr.HitPos - tr.HitNormal) end
	end
	if not fleshy and not breakable(ent) and h.seq.bounce and not self:GetHeavy() then
		self:Action(h.seq.bounce)
		self:SetNextPrimaryFire(CurTime() + self:SeqLen(h.seq.bounce) * 0.8)
	end
	if SERVER and IsValid(ent) then
		local d = DamageInfo()
		d:SetAttacker(owner)
		d:SetInflictor(self)
		local character = ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot()
		local amount = (self:GetHeavy() and (h.damage_heavy or h.damage) or h.damage) * cv_scale:GetFloat()
		if breakable(ent) then
			d:SetDamage(math.max(amount, GetConVarNumber("sk_plr_dmg_crowbar")))
			d:SetDamageType(DMG_CLUB)
		else
			d:SetDamage(amount * (character and 1 or 0.1))
			d:SetDamageType(h.sharp and DMG_SLASH or DMG_CLUB)
		end
		d:SetDamageForce(dir * (h.force or 30) * 180)
		d:SetDamagePosition(tr.HitPos)
		HRDismember.CorpseHit(self, tr, amount, d:GetDamageForce())
		ent:DispatchTraceAttack(d, tr, dir)
	end
	if SERVER then
		local character = IsValid(ent) and (ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot())
		HRCombat.Wear(self, tr.HitPos, character and 1 or 0.1)
		if fleshy then HRBlood.Add(self, 0.35) end
	end
end

function SWEP:Think()
	self:UpdateFireMode()
	HRUpgrades.Sync(self)
	if CLIENT and game.SinglePlayer() then return end
	if self:GetNW2Bool("hr_executing") or HRCombat.Dodging(self:GetOwner()) then return end
	local owner = self:GetOwner()
	if not IsValid(owner) or not owner:IsPlayer() then return end
	local now = CurTime()
	local h = self.HR
	if DHRBash.Think(self) then return end
	if h.kind == "gun" then
		if self:GetPumpAt() > 0 and now >= self:GetPumpAt() then
			self:SetPumpAt(0)
			self:Action(h.seq.pump, HRUpgrades.Get(self, "rate"))
		end
		self:ThinkReload(now)
		if now >= self:GetBusyUntil() and self:AutoReload() then self:Reload() end
		if h.seq.ads_idle then
			local want
			if cv_ads:GetBool() or owner:GetInfoNum("hr_ads_toggle", 0) == 1 then
				want = self:GetAiming()
				if owner:KeyPressed(IN_ATTACK2) then want = not want end
			else
				want = owner:KeyDown(IN_ATTACK2)
			end
			local reloading = self:GetReloadDone() > 0 or self:GetReloadStage() > 0 or now < self:GetReloadUntil()
			if reloading or self:IsRunning() then want = false end
			if self.HR.aim then self:SetAdsPose(want) end
			if want ~= self:GetAiming() then
				self:SetAiming(want)
				self:SetBaseSeq("")
			end
			local free = now >= self:GetBusyUntil() or (self:GetDrawReady() > 0 and now >= self:GetDrawReady())
			local firing = string.match(self:GetPoseSequence(), "^ads_fire") or string.match(self:GetPoseSequence(), "^fire")
			if firing and not free and not reloading then self:SetAdsPose(self:GetAiming()) end
			local turning = self:GetPoseSequence() == h.seq.ads_in or self:GetPoseSequence() == h.seq.ads_out
			if (free or turning) and not reloading and self:GetAdsPose() ~= self:GetAiming() then
				self:Action(self:GetAiming() and h.seq.ads_in or h.seq.ads_out)
				local zoom = h.ads and (self:GetAiming() and h.ads.time_in or h.ads.time_out)
				if zoom then self:SetBusyUntil(math.max(self:GetBusyUntil(), now + zoom + 0.05)) end
			end
		end
	elseif self:GetHitTime() > 0 and now >= self:GetHitTime() then
		self:SetHitTime(0)
		self:MeleeHit()
		if not IsValid(self) or self:GetNW2Bool("hr_broken") then return end
	end
	if SERVER and h.kind == "melee" and now >= (self.hr_takedown_check or 0) then
		self.hr_takedown_check = now + 0.1
		local target, profile, _, _, approach, yaw = HRExecutions.Target(self)
		target = target or NULL
		self:SetNW2Bool("hr_takedown_front", profile and approach == "front" or false)
		self:SetNW2Bool("hr_takedown_lineup", yaw ~= nil)
		if self:GetNW2Entity("hr_takedown") ~= target then self:SetNW2Entity("hr_takedown", target) end
	end
	if now >= self:GetBusyUntil() then
		local want = self:BaseSequence()
		if want and want ~= self:GetBaseSeq() then
			self:SetBaseSeq(want)
			self:PlaySeq(want)
		end
		local vm = owner:GetViewModel()
		if IsValid(vm) then
			vm:SetPlaybackRate((h.movement_rates or {})[want] or 1)
		end
	end
end

local GAME_FOV = math.rad(89.424164 / 2)

function SWEP:AimTangent()
	local ads = self.HR.ads
	if not ads then return math.tan(GAME_FOV * (self.HR.ads_zoom or 0.85)) / math.tan(GAME_FOV) end
	return math.tan(GAME_FOV + math.rad(ads.fov_target / 2)) / math.tan(GAME_FOV)
end

function SWEP:AimBlend(now)
	local ads = self.HR.ads or {}
	local duration = self.hr_aim_state and (ads.time_in or 0.22) or (ads.time_out or 0.2)
	local u = math.Clamp((now - self.hr_aim_start) / math.max(duration, 0.01), 0, 1)
	u = u * u * u * (u * (u * 6 - 15) + 10)
	return Lerp(u, self.hr_aim_from, self.hr_aim_state and 1 or 0)
end

function SWEP:AimFraction()
	local now, aiming = UnPredictedCurTime(), self:GetAiming() and self:GetAdsPose()
	if self.hr_aim_state == nil then
		self.hr_aim_state, self.hr_aim_from, self.hr_aim_start = aiming, aiming and 1 or 0, now - 10
	elseif aiming ~= self.hr_aim_state then
		self.hr_aim_from = self:AimBlend(now)
		self.hr_aim_state, self.hr_aim_start = aiming, now
	end
	return self:AimBlend(now)
end

function SWEP:HasScopeLens()
	return self.HR.scope ~= nil and not self.DualWield and self:AimZoom() ~= nil
end

function SWEP:AimZoom()
	return HRUpgrades.Get(self, "zoom")
end

function SWEP:TranslateFOV(fov)
	local f = self:AimFraction()
	self.hr_fovfrac = f
	local scope = self:AimZoom()
	if scope and not self:HasScopeLens() then return fov * (1 - (1 - scope) * f) end
	return math.deg(2 * math.atan(math.tan(math.rad(fov / 2)) * Lerp(f, 1, self:AimTangent())))
end

function SWEP:AdjustMouseSensitivity()
	local f = self.hr_fovfrac or 0
	if f <= 0 then return end
	local scope = self:AimZoom()
	return Lerp(f, 1, scope and scope * HRUpgrades.Get(self, "sensitivity") or self:AimTangent())
end

function SWEP:DoDrawCrosshair()
	return GetConVar("hr_hud"):GetBool() and GetConVar("hr_hud_crosshair"):GetInt() >= 0
        and DHR.CanUseFeature(self:GetOwner(), "hud", self)
end

function SWEP:DrawHUD()
	if CLIENT then
		local x, y = ScrW() / 2, ScrH() / 2
		self:DrawHRScope()
		if not self:HRHudVisible() then return end
		self:DrawHRHealth()
		self:DrawHRAmmo()
		self:DrawHRControls()
		self:DrawHRCrosshair(x, y)
		self:DrawHRDurability()
		self:DrawHRHitMarker(x, y)
		self:DrawHRTakedownPrompt()
	end
end

if CLIENT then
	local icons = {}
	function SWEP:DrawWeaponSelection(x, y, w, h, a)
		if self.HR.stock_icon and HRStockIcons.Draw(self.HR.stock_icon, x + w / 2, y + h / 2, w, h, nil, a) then return end
		local cls = self:GetClass()
		icons[cls] = icons[cls] or Material("entities/" .. cls .. ".png", "smooth")
		if icons[cls]:IsError() then return baseclass.Get("weapon_base").DrawWeaponSelection(self, x, y, w, h, a) end
		local s = math.min(w, h) * 1.1
		surface.SetDrawColor(255, 255, 255, a)
		surface.SetMaterial(icons[cls])
		surface.DrawTexturedRect(x + (w - s) / 2, y + (h - s) / 2, s, s)
	end
end

if CLIENT then
	function SWEP:WorldModelPose()
		local owner, wm = self:GetOwner(), self.HR.world
		if IsValid(owner) and wm then
			local bone = owner:LookupBone("ValveBiped.Bip01_R_Hand")
			local matrix = bone and owner:GetBoneMatrix(bone)
			if matrix then return LocalToWorld(wm.pos, wm.ang, matrix:GetTranslation(), matrix:GetAngles()) end
		end
		return self:GetPos(), self:GetAngles()
	end

	function SWEP:GetWorldAttachment(name, bone)
		local pose = HRThirdPerson.Model(self)
		if IsValid(pose) then
			local attachment = pose:GetAttachment(pose:LookupAttachment(name))
			if attachment then return attachment end
			local id = bone and pose:LookupBone(bone)
			local matrix = id and pose:GetBoneMatrix(id)
			if matrix then return {Pos=matrix:GetTranslation(),Ang=matrix:GetAngles()} end
		end
		self:ApplyUpgradeParts(self)
		if self.HR.world then
			local pos, ang = self:WorldModelPose()
			self:SetRenderOrigin(pos)
			self:SetRenderAngles(ang)
		end
		self:InvalidateBoneCache()
		self:SetupBones()
		local attachment = self:GetAttachment(self:LookupAttachment(name))
		if not attachment and bone then
			local id = self:LookupBone(bone)
			local matrix = id and self:GetBoneMatrix(id)
			if matrix then attachment = {Pos = matrix:GetTranslation(), Ang = matrix:GetAngles()} end
		end
		self:SetRenderOrigin()
		self:SetRenderAngles()
		return attachment
	end

	function SWEP:DrawWorldModel(flags)
		if not self.HR.world then
			self:ApplyUpgradeParts(self)
			self:DrawModel(flags)
			return
		end
		if HRThirdPerson.Draw(self) then return end
		self:ApplyUpgradeParts(self)
		local pos, ang = self:WorldModelPose()
		self:SetRenderOrigin(pos)
		self:SetRenderAngles(ang)
		self:InvalidateBoneCache()
		self:SetupBones()
		self:DrawModel(flags)
		self:SetRenderOrigin()
		self:SetRenderAngles()
	end
end

if CLIENT then
	function SWEP:ApplyUpgradeParts(model)
		local installed = self:VisualUpgrades()
		for bone, rule in pairs(self.HR.parts or {}) do
			local id = model:LookupBone(bone)
			if id then
				local hidden = rule:sub(1, 1) == "!"
				local show = hidden and not installed[rule:sub(2)] or not hidden and installed[rule]
				model:ManipulateBoneScale(id, show and Vector(1, 1, 1) or Vector(0.001, 0.001, 0.001))
			end
		end
	end

	function SWEP:ApplyAnimatedParts(vm)
		local casings = self:CasingMask()
		if self.hr_ejected_sequence == vm:GetSequenceName(vm:GetSequence()) and CurTime() < (self.hr_ejected_until or 0) then
			casings = bit.bor(casings, self.hr_ejected_mask or 0)
		end
		for bone, data in pairs(self.HR.bone_scales or {}) do
			local id = vm:LookupBone(bone)
			if id then
				local frames = data.sequences[vm:GetSequenceName(vm:GetSequence())]
				local value = data.default
				if frames and #frames > 0 then
					local f = math.Clamp(vm:GetCycle(), 0, 1) * (#frames - 1)
					local i = math.floor(f) + 1
					value = Lerp(f - math.floor(f), frames[i], frames[math.min(i + 1, #frames)])
				end
				local bullet = tonumber(string.match(bone, "^w_bullet_0(%d)_jnt$"))
				if bullet and bit.band(casings, bit.lshift(1, bullet - 1)) ~= 0 then value = 0.001 end
				vm:ManipulateBoneScale(id, Vector(value, value, value))
			end
		end
		self:ApplyUpgradeParts(vm)
		local sequence = vm:GetSequenceName(vm:GetSequence())
		local release = (self.HR.magazine_release or {})[sequence]
		local owner = self:GetOwner()
		local firstPerson = IsValid(owner) and owner:IsPlayer()
			and (vm == owner:GetViewModel(0) or vm == owner:GetViewModel(1))
		local thirdPerson = not firstPerson
		if not release or not release.pickup then
			if thirdPerson then vm.hr_magazine_clock = nil end
			return
		end
		local t = math.Clamp(vm:GetCycle(), 0, 1) * vm:SequenceDuration()
		if t >= release.time and t < release.pickup then
			for _, part in ipairs(self.HR.magazines or {}) do
				local id = vm:LookupBone(part.bone)
				if id then vm:ManipulateBoneScale(id, Vector(0.001, 0.001, 0.001)) end
			end
		end
		if thirdPerson then
			local last = vm.hr_magazine_clock
			if last and last.sequence == sequence and last.weapon == self and last.t < release.time and t >= release.time then
				local index = self:MagazinePart()
				if index then
					local rounds = self:GetNW2Int(self.DualWield and "dhr_reload_rounds" or "hr_magazine_rounds", 0)
					vm.hr_magazine_drop = {weapon = self, index = index, sequence = sequence, rounds = rounds}
				end
			end
			vm.hr_magazine_clock = {sequence = sequence, weapon = self, t = t}
		end
	end

	function SWEP:AimClipCycle(vm)
		local paths = self.HR.ads_path
		if not paths or not cv_smooth:GetBool() then return end
		local name = vm:GetSequenceName(vm:GetSequence())
		local path = paths[name]
		if not path then return end
		local f = self:AimFraction()
		local progress = name == self.HR.seq.ads_in and f or 1 - f
		local cycle = 1
		for i = 2, #path do
			if progress <= path[i] then
				cycle = (i - 2 + (progress - path[i - 1]) / math.max(path[i] - path[i - 1], 0.0001)) / (#path - 1)
				break
			end
		end
		vm:SetCycle(math.Clamp(cycle, 0, 1))
	end

	local FADE = 0.08
	local function crossfade(w, vm)
		local origin = Matrix()
		origin:SetTranslation(vm:GetPos())
		origin:SetAngles(vm:GetAngles())
		local toLocal = origin:GetInverseTR()
		local fade = vm.hr_fade
		local seq, started, model = vm:GetSequence(), w:GetPoseStart(), vm:GetModel()
		if not fade or fade.weapon ~= w or fade.model ~= model then
			fade = {weapon = w, model = model, seq = seq, started = started}
			vm.hr_fade = fade
		elseif fade.seq ~= seq or fade.started ~= started then
			fade.seq, fade.started, fade.from, fade.begin = seq, started, fade.last, UnPredictedCurTime()
		end
		local weight = fade.from and math.Clamp((UnPredictedCurTime() - fade.begin) / FADE, 0, 1) or 1
		weight = weight * weight * (3 - 2 * weight)
		local last = {}
		for i = 0, vm:GetBoneCount() - 1 do
			local m = vm:GetBoneMatrix(i)
			if m then
				local here = toLocal * m
				local from = weight < 1 and fade.from[i]
				if from then
					local blended = Matrix()
					blended:SetTranslation(LerpVector(weight, from:GetTranslation(), here:GetTranslation()))
					blended:SetAngles(LerpAngle(weight, from:GetAngles(), here:GetAngles()))
					blended:SetScale(here:GetScale())
					here = blended
					vm:SetBoneMatrix(i, origin * here)
				end
				last[i] = here
			end
		end
		fade.last = last
		if weight >= 1 then fade.from = nil end
	end

	function SWEP:PreDrawViewModel(vm)
		self.UseHands = HRHands.Prepare(vm, self:GetOwner(), self.dhr_use_hands)
        HRHands.SupportArm(vm, DHR.OneHanded(self), DHR.SupportWithdrawal(self))
		self:AimClipCycle(vm)
		if not vm.hr_aim_callback then
			vm.hr_aim_callback = vm:AddCallback("BuildBonePositions", function(model)
				local owner = model:GetOwner()
				local w = IsValid(owner) and owner:GetActiveWeapon()
				if IsValid(w) and w.HR then
					if cv_smooth:GetBool() then crossfade(w, model) end
					HRPose.Aim(w, model)
					if HRWall then HRWall.Hand(w, model) end
				end
			end)
		end
		if self:GetNW2Bool("hr_executing") and HRExecutions.WorldArms(self) then return true end
		self:ApplyAnimatedParts(vm)
		if not self:HasScopeLens() and self:ScopeFraction() > 0.95 then return true end
		DHRScope.Blur(self)
		DHRScope.Prepare(self, vm)
		vm:InvalidateBoneCache()
		vm:SetupBones()
	end

	hook.Add("PreDrawViewModel", "hr_viewmodel_bones", function(vm, _, weapon)
		local model = vm:GetModel()
		if vm.hr_bones_weapon == weapon and vm.hr_bones_model == model then return end
		vm.hr_bones_weapon, vm.hr_bones_model = weapon, model
		for i = 0, vm:GetBoneCount() - 1 do vm:ManipulateBoneScale(i, Vector(1, 1, 1)) end
	end)

	function SWEP:ScopeFraction()
		return self:AimZoom() and (self.hr_fovfrac or 0) or 0
	end
end

function SWEP:CalcView(owner, pos, ang, fov)
	if CLIENT then return HRExecutions.View(self, pos, ang, fov) end
end

function SWEP:OnRemove()
	if SERVER then HRExecutions.Finish(self, true) end
end

function SWEP:CalcViewModelView(vm, oldPos, oldAng, pos, ang)
	if not CLIENT then return end
	if self:GetNW2Bool("hr_executing") then return HRExecutions.View(self, pos, ang, self.ViewModelFOV) end
	return self:ApplyViewMotion(vm, pos, ang)
end
