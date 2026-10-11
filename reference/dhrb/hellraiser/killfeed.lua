if SERVER then
	AddCSLuaFile()
	util.AddNetworkString('hr_kill_method')
	local function notice(victim, attacker, inflictor)
		if not IsValid(attacker) or not attacker:IsPlayer() or not IsValid(inflictor) then return end
		if inflictor == attacker then inflictor = attacker:GetActiveWeapon() end
		if not IsValid(inflictor) or not inflictor.HR then return end
		local state = victim.hr_execution
		local execution = state and state.applyingDamage and state.victim == victim and state.player == attacker
		local name = victim:IsPlayer() and victim:Nick() or GAMEMODE.GetDeathNoticeEntityName and GAMEMODE:GetDeathNoticeEntityName(victim) or '#' .. victim:GetClass()
		net.Start('hr_kill_method')
		net.WriteString(attacker:Name())
		net.WriteString(inflictor:GetClass())
		net.WriteString(name)
		net.WriteBool(execution == true)
		net.Broadcast()
	end
	hook.Add('OnNPCKilled', 'hr_kill_method', notice)
	hook.Add('PlayerDeath', 'hr_kill_method', function(victim, inflictor, attacker) notice(victim,attacker,inflictor) end)
	return
end

local function icons()
	for _, weapon in ipairs(weapons.GetList()) do
		local config = weapon.HR
		if not config then continue end
		local class = weapon.ClassName
		local path = config.kill_icon or 'hellraiser/ui/killfeed/' .. class
		if file.Exists('materials/' .. path .. '.vmt', 'GAME') or file.Exists('materials/' .. path, 'GAME') then
			killicon.Add(class, path, color_white)
		elseif config.stock_icon then
			killicon.AddAlias(class, config.stock_icon)
		end
		if config.kind == 'melee' then
			local execution = config.kill_icon_execution or path .. '_execution'
			if file.Exists('materials/' .. execution .. '.vmt', 'GAME') or file.Exists('materials/' .. execution, 'GAME') then
				killicon.Add('hr_execution_' .. class, execution, color_white)
			else
				killicon.AddAlias('hr_execution_' .. class, class)
			end
		end
	end
	if weapons.GetStored('hr_cube') then killicon.AddAlias('hr_hellshot', 'hr_cube') end
end
hook.Add('InitPostEntity', 'hr_kill_icons', icons)
hook.Add('OnReloaded', 'hr_kill_icons', icons)

local pending = {}
local function key(attacker, weapon, victim)
	return attacker .. '\0' .. weapon .. '\0' .. victim
end
net.Receive('hr_kill_method', function()
	local attacker, weapon, victim = net.ReadString(), net.ReadString(), net.ReadString()
	pending[key(attacker, weapon, victim)] = {execution = net.ReadBool(), expires = CurTime() + 2}
end)
timer.Create('hr_kill_method_expiry', 1, 0, function()
	for name, item in pairs(pending) do
		if item.expires <= CurTime() then pending[name] = nil end
	end
end)
hook.Add('AddDeathNotice', 'hr_kill_method', function(attacker, team1, weapon, victim, team2, flags)
	if not isstring(attacker) or not isstring(victim) then return end
	local name = key(attacker, weapon, victim)
	local item = pending[name]
	if not item then return end
	pending[name] = nil
	if not item.execution or item.expires <= CurTime() then return end
	GAMEMODE:AddDeathNotice(attacker, team1, 'hr_execution_' .. weapon, victim, team2, flags)
	return true
end)
