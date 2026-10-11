function SWEP:MagazinePart()
	local installed = self:GetNW2Float("hr_mag_swap", 0) > 0
		and HRUpgrades.Parse(self:GetNW2String("hr_mag_from", "")) or HRUpgrades.Installed(self)
	for index, part in ipairs(self.HR.magazines or {}) do
		local negative = part.rule:sub(1, 1) == "!"
		if (negative and not installed[part.rule:sub(2)]) or (not negative and installed[part.rule]) then return index, part end
	end
end

if CLIENT then
	net.Receive("hr_weapon_cue", function()
		local weapon, path, pitch = net.ReadEntity(), net.ReadString(), net.ReadUInt(8)
		local sequence = net.ReadString()
		if not IsValid(weapon) or not weapon.HR then return end
		local owner = weapon:GetOwner()
		if owner ~= LocalPlayer() or not owner:Alive() or owner:GetActiveWeapon() ~= weapon
			or not owner:ShouldDrawLocalPlayer() or weapon:GetNW2Bool("hr_executing")
			or weapon:GetPoseSequence() ~= sequence then return end
		weapon:EmitSound(path, 0, pitch, 1, CHAN_AUTO)
	end)
	net.Receive("hr_reload_magazine", function()
		local weapon, index = net.ReadEntity(), net.ReadUInt(2)
		local sequence, rounds = net.ReadString(), net.ReadUInt(8)
		if not IsValid(weapon) or not weapon.EjectMagazine then return end
		local owner = weapon:GetOwner()
		if not IsValid(owner) or (owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()) then return end
		if HRThirdPerson and HRThirdPerson.Active(weapon) then return end
		weapon:EjectMagazine(index, sequence, rounds)
	end)
	net.Receive("hr_reload_cases", function()
		local weapon, mask = net.ReadEntity(), net.ReadUInt(6)
		if not IsValid(weapon) or not weapon.EjectCase then return end
		local owner = weapon:GetOwner()
		if not IsValid(owner) or (owner == LocalPlayer() and not owner:ShouldDrawLocalPlayer()) then return end
		for i = 1, 6 do
			if bit.band(mask, bit.lshift(1, i - 1)) ~= 0 then weapon:EjectCase(string.format("w_bullet_%02d_jnt", i)) end
		end
	end)
	return
end

util.AddNetworkString("hr_weapon_cue")
util.AddNetworkString("hr_reload_cases")
util.AddNetworkString("hr_reload_magazine")

function SWEP:QueueWorldEvents(sequence, rate)
	self.hr_world_action = (self.hr_world_action or 0) + 1
	local action, owner = self.hr_world_action, self:GetOwner()
	local rounds = self.hr_magazine_rounds or 0
	if not IsValid(owner) or not owner:IsPlayer() then return end
	for _, cue in ipairs((self.HR.world_events or {})[sequence] or {}) do
		timer.Simple(cue.time / rate, function()
			if not IsValid(self) or self.hr_world_action ~= action or not IsValid(owner) or not owner:Alive()
				or self:GetOwner() ~= owner or owner:GetActiveWeapon() ~= self or self:GetNW2Bool("hr_executing") then return end
			local listeners = RecipientFilter()
			listeners:AddPAS(owner:GetShootPos())
			if cue.event == 6003 then
				local index = self:MagazinePart()
				if index then
					net.Start("hr_reload_magazine")
					net.WriteEntity(self)
					net.WriteUInt(index, 2)
					net.WriteString(sequence)
					net.WriteUInt(math.Clamp(rounds, 0, 255), 8)
					net.Send(listeners:GetPlayers())
				end
				return
			end
			if cue.event == 6002 then
				net.Start("hr_reload_cases")
				net.WriteEntity(self)
				net.WriteUInt(bit.band(tonumber(cue.sound) or 0, bit.bnot(self:CasingMask())), 6)
				net.Send(listeners:GetPlayers())
				return
			end
			if sequence ~= self.HR.seq.draw then listeners:RemovePlayer(owner) end
			local soundData = sound.GetProperties(cue.sound)
			if not soundData then return end
			local path = istable(soundData.sound) and table.Random(soundData.sound) or soundData.sound
			local pitch = istable(soundData.pitch) and math.random(soundData.pitch[1], soundData.pitch[2]) or soundData.pitch or 100
			path = path:gsub("^[%)%^]", "")
			if sequence ~= self.HR.seq.draw then
				net.Start("hr_weapon_cue")
				net.WriteEntity(self)
				net.WriteString(path)
				net.WriteUInt(pitch, 8)
				net.WriteString(sequence)
				net.Send(owner)
			end
			if #listeners:GetPlayers() > 0 then self:EmitSound(")" .. path, 70, pitch, 0.8, CHAN_AUTO, 0, 0, listeners) end
		end)
	end
end
