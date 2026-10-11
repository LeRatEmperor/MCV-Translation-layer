CreateClientConVar("hr_muzzle_lights", "1", true, false, "Light nearby surfaces and characters when Hellraiser guns fire")
local enabled = CreateClientConVar("hr_weapon_motion_blur", cookie.GetString("hr_weapon_motion_blur", "1"), true, false, "Motion blur on Hellraiser first-person weapons")
local previous

local function reset()
	previous = nil
end
cvars.AddChangeCallback("hr_weapon_motion_blur", function(_, _, value)
	reset()
	cookie.Set("hr_weapon_motion_blur", value)
end, "hr_weapon_motion_blur")
hook.Add("OnScreenSizeChanged", "hr_weapon_motion_blur", reset)

concommand.Add("hr_weapon_motion_blur_toggle", function()
	RunConsoleCommand("hr_weapon_motion_blur", enabled:GetBool() and "0" or "1")
end)

hook.Add("PopulateToolMenu", "hr_weapon_options", function()
	spawnmenu.AddToolMenuOption("Options", "Hellraiser", "HellraiserWeapons", "Weapons", "", "", function(panel)
		panel:CheckBox("Use player model hands", "hr_player_hands")
		panel:Help("Turn off to use Aidan's original arms.")
		panel:CheckBox("Weapon motion blur", "hr_weapon_motion_blur")
		panel:Help("Blurs your weapon when it moves.")
		panel:CheckBox("Muzzle flash lighting", "hr_muzzle_lights")
		panel:CheckBox("Scope background blur", "hr_scope_blur")
		panel:CheckBox("Smooth aiming and firing", "hr_smooth_aim")
		panel:Help("The gun rises to the sights with the zoom and blends between shots. Turn off for the raw animations.")
		panel:CheckBox("Hold to fire semi-auto weapons", "hr_pistol_hold_fire")
		panel:Help("For weapons that support this option. Hold your fire button to repeat shots at their normal rate. On by default; turn off for click-per-shot firing. Applies only to you.")
        local sharing = panel:CheckBox("Allow ammo sharing")
        sharing:SetValue(GetConVar("dhr_ammo_sharing"):GetBool())
        sharing.OnChange = function(_, on) DHR.SetAmmoSharing(on) end
        sharing.Think = function(self)
            self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
            self:SetChecked(GetConVar("dhr_ammo_sharing"):GetBool())
        end
        panel:Help("Host/admin setting. Throw spare ammunition or loaded magazines to players and friendly NPCs. Uses ammunition you carry.")
        local bash = panel:CheckBox("Allow gun bashing")
        bash:SetValue(GetConVar("dhr_gun_bash"):GetBool())
        bash.OnChange = function(_, on) DHRBash.SetEnabled(on) end
        bash.Think = function(self)
            self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
            self:SetChecked(GetConVar("dhr_gun_bash"):GetBool())
        end
        panel:Help("Host/admin setting. Strike with a gun at close range. Uses no ammo; firing and reloading wait until the strike finishes.")
		panel:CheckBox("Auto reload", "hr_auto_reload")
		panel:Help("Guns reload on their own when the magazine runs empty, like in the game.")
		local reload = panel:NumSlider("Reload speed", "", 1, 2, 2)
		reload:SetValue(HRCombat.ReloadSpeed())
		reload.OnValueChanged = function(_, value) HRCombat.SetReloadSpeed(value) end
		reload.Think = function(self) self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin()) end
		panel:Help("Host/admin setting. 1 is normal speed; 2 reloads twice as fast. Applies to all Hellraiser guns from their next reload, including animation and sound timing.")
		local stealth = panel:CheckBox("NPCs can lose sight of you")
        stealth:SetValue(GetConVar("hr_stealth"):GetBool())
        stealth.OnChange = function(_, on) HRStealth.SetEnabled(on) end
        stealth.Think = function(self) self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin()); self:SetChecked(GetConVar("hr_stealth"):GetBool()) end
        panel:Help("Host/admin setting. Native NPCs forget you after six seconds out of sight; Hellraiser NPCs use their own sight and search behaviour.")
        local wounded = panel:NumSlider("Combat finisher health (%)", "", 0, 100, 0)
        wounded:SetValue(GetConVar("hr_execution_health_percent"):GetInt())
        wounded.OnValueChanged = function(_, value) HRExecutions.SetHealthThreshold(value) end
        wounded.Think = function(self) self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin()) end
        panel:Help("Host/admin setting. Aware enemies at or below this health can be finished from the front. Default 25%; 0 keeps front finishers limited to unaware enemies. Player targets keep their existing rules.")
        local players = panel:CheckBox("Finishers against other players")
        players:SetValue(GetConVar("hr_player_executions"):GetBool())
        players.OnChange = function(_, on) HRExecutions.Players.SetEnabled(on) end
        players.Think = function(self)
            self:SetEnabled(LocalPlayer():IsAdmin())
            self:SetChecked(GetConVar("hr_player_executions"):GetBool())
        end
        panel:Help("Host/admin setting. Front attacks fail if the victim sees you or fought you in the last six seconds; rear attacks work from behind. Damage protection still applies.")
        panel:CheckBox("Third person finishers", "hr_finisher_camera")
		panel:Help("Watch finishers from outside your body instead of through your eyes.")
		panel:CheckBox("Hell Vision world transformation", "hr_hellvision_world")
		for _, option in ipairs({{"Killing hits and blunt execution gore", "hr_dismember_living", false}, {"Corpse decapitation and dismemberment", "hr_dismember_corpses", true}}) do
			local setting = GetConVar(option[2])
			local corpse = option[3]
			local toggle = panel:CheckBox(option[1])
			toggle:SetValue(setting:GetBool())
			toggle.OnChange = function(_, on) HRDismember.SetTargetEnabled(corpse, on) end
			toggle.Think = function(self)
				self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
				self:SetChecked(setting:GetBool())
			end
		end
		panel:Help("Built-in gore; no separate addon needed. Host/admin settings, both on by default. Living targets only lose heads or limbs on killing hits and blunt executions. Corpse decapitation and dismemberment controls later shots and melee hits. Changes affect new wounds; existing wounds remain.")
        local playerGore = panel:CheckBox("Player decapitation and dismemberment")
        playerGore:SetValue(GetConVar("hr_dismember_players"):GetBool())
        playerGore.OnChange = function(_, on) HRDismember.SetPlayersEnabled(on) end
        playerGore.Think = function(self)
            self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
            self:SetChecked(GetConVar("hr_dismember_players"):GetBool())
        end
        panel:Help("Host/admin setting, on by default. Includes player corpses. Uses the killing-hit, corpse and chance settings above. Damage protection and respawning are unchanged.")
		local dismember = panel:NumSlider("Dismemberment chance (%)", "", 0, 100, 0)
		dismember:SetValue(GetConVar('hr_dismember_chance'):GetFloat()*100)
		dismember.OnValueChanged = function(_, value) HRDismember.SetChance(value) end
		dismember.Think = function(self) self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin()) end
		panel:Help("Host/admin setting. Chance for normal killing hits and blunt executions. Shotguns and upgraded rounds always sever on killing hits, and corpses take part damage. 0 disables all dismemberment.")
		local every = panel:CheckBox("Every weapon can dismember")
		every:SetValue(GetConVar("hr_dismember_any_weapon"):GetBool())
		every.OnChange = function(_, value) HRDismember.SetAnyWeapon(value) end
		every.Think = function(self)
			self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
			self:SetChecked(GetConVar("hr_dismember_any_weapon"):GetBool())
		end
		panel:Help("Host/admin setting. Half-Life 2 weapons, other addons' weapons and NPCs sever limbs and heads too. Buckshot always does.")
		local unlimited = panel:CheckBox("Infinite melee durability")
		unlimited:SetValue(HRCombat.Infinite())
		unlimited.OnChange = function(_, value) HRCombat.SetInfinite(value) end
		unlimited.Think = function(self)
			self:SetEnabled(game.SinglePlayer() or LocalPlayer():IsAdmin())
			self:SetChecked(HRCombat.Infinite())
		end
		panel:Help("Host/admin setting. Applies to everyone. Turning it off resumes existing wear.")
	end)
	spawnmenu.AddToolMenuOption("Options", "Hellraiser", "HellraiserControls", "Controls", "", "", function(panel)
		panel:Help("Click a box, then press the key or mouse button you want. Escape cancels, and right click clears it or puts the default back.")
		panel:KeyBinder("Weapon wheel", "hr_wheel_key", "Second key", "hr_wheel_backup_key")
		panel:KeyBinder("Lock on", "hr_lock_key", "Dodge", "hr_dodge_key")
		panel:Help("Dodge goes the way you're moving, or back if you're standing still. While locked on, jump dodges too.")
		panel:KeyBinder("Upgrades", "hr_upgrades_key", "Drop weapon", "hr_drop_key")
		panel:Help("Leave Upgrades empty to hold your context menu key instead.")
        panel:KeyBinder("Gun bash", "dhr_bash_key")
        panel:Help("Press once per strike. Clear the key to turn it off for yourself.")
        panel:KeyBinder("Throw spare ammo", "dhr_share_key")
        panel:Help("Default H. The wheel also offers X for spare ammo and Z for loaded ammo. Aim at a teammate to choose matching ammunition from a mixed pair.")
		panel:CheckBox("Toggle aiming", "hr_ads_toggle")
		panel:Help("Right click switches aiming on and off instead of holding it.")
		panel:Help("Fire, aim, reload and use follow your normal Garry's Mod keys.")
	end)
	spawnmenu.AddToolMenuOption("Options", "Hellraiser", "HellraiserHUD", "HUD", "", "", function(panel)
		panel:CheckBox("Enable Hellraiser HUD", "hr_hud")
		panel:CheckBox("Stealth and enemy awareness", "hr_hud_stealth")
		panel:CheckBox("Enemy detection sound", "hr_detection_sound")
		panel:Help("Master switch. Turn off to restore the standard GMod HUD, crosshair and weapon selection. Your individual settings are kept.")
		panel:CheckBox("Use it with every weapon", "hr_hud_any_weapon")
		panel:Help("Keeps the health bar, ammo counter and crosshair on screen whatever you're holding, other addons' weapons too. Turn off to only show it with these weapons.")
		panel:CheckBox("Hide the standard GMod HUD", "hr_hud_hide_default")
		panel:Help("Also hides the usual health, suit and ammo boxes while this HUD is showing.")
		panel:CheckBox("Ammo and weapon", "hr_hud_weapon")
		panel:CheckBox("Matching stock weapon icons", "hr_hud_stock_icons")
		panel:Help("Off removes stock weapon outlines beside the ammo count and uses their usual icons in the wheel.")
		local health = panel:ComboBox("Health bar", "hr_hud_health")
		health:AddChoice("When hurt", 1)
		health:AddChoice("Always", 2)
		health:AddChoice("Off", 0)
		panel:Help("Always is the default. When hurt fades at full health; Off uses GMod health unless Hide the standard GMod HUD is checked.")
		local crosshair = panel:ComboBox("Crosshair", "hr_hud_crosshair")
		crosshair:AddChoice("On", 1)
		crosshair:AddChoice("Dynamic", 2)
		crosshair:AddChoice("Minimal", 3)
		crosshair:AddChoice("Off", 0)
		crosshair:AddChoice("GMod / weapon default", -1)
		panel:Help("Dynamic only shows the full crosshair while you're shooting. GMod / weapon default leaves the crosshair to the weapon or your other addons.")
		local durability = panel:ComboBox("Melee durability", "hr_hud_durability")
		durability:AddChoice("Faint until damaged", 1)
		durability:AddChoice("Always visible", 2)
		durability:AddChoice("Off", 0)
		panel:Help("The faint ring brightens for two seconds when the weapon wears, then fades back.")
		panel:CheckBox("Control hints", "hr_hud_hints")
		panel:CheckBox("Execution and pickup prompts", "hr_hud_prompts")
		panel:CheckBox("Hit markers", "hr_hud_hitmarkers")
		panel:CheckBox("Lock-on indicator", "hr_hud_lock")
		panel:CheckBox("Weapon wheel", "hr_wheel_hud")
		panel:CheckBox("Use the wheel with every weapon", "hr_wheel_any_weapon")
        panel:CheckBox("Replace normal weapon selection", "hr_wheel_replace_selection")
        panel:Help("When fast weapon switching is off, scrolling and number keys open the wheel. Left click equips; right click cancels.")
		panel:Help("Opens with any weapon out and lists everything you carry, Half-Life 2 and other addons' weapons included.")
	end)
end)
hook.Add("AddToolMenuCategories", "hr_weapon_options", function()
	spawnmenu.AddToolCategory("Options", "Hellraiser", "Dandy's Hellraiser Base (DHRB)")
end)

local ghost, ghostHands
local function copies(w, vm, hands)
	if not IsValid(ghost) then
		ghost = ClientsideModel(vm:GetModel(), RENDERGROUP_OTHER)
		if not IsValid(ghost) then return end
		ghost:SetNoDraw(true)
		ghost:DrawShadow(false)
		ghost:AddCallback("BuildBonePositions", function(model)
			for i, matrix in pairs(model.hr_blur_bones or {}) do
				if model:GetBoneMatrix(i) then model:SetBoneMatrix(i, matrix) end
			end
		end)
	end
	if ghost:GetModel() ~= vm:GetModel() then ghost:SetModel(vm:GetModel()) end
	ghost.hr_weapon = w
	ghost:SetPos(vm:GetPos())
	ghost:SetAngles(vm:GetAngles())
	ghost:SetSkin(vm:GetSkin())
	for _, group in ipairs(vm:GetBodyGroups()) do ghost:SetBodygroup(group.id, vm:GetBodygroup(group.id)) end
	if not IsValid(hands) then
		if IsValid(ghostHands) then ghostHands:Remove() end
		return ghost
	end
	if not IsValid(ghostHands) or ghostHands:GetModel() ~= hands:GetModel() then
		if IsValid(ghostHands) then ghostHands:Remove() end
		ghostHands = ClientsideModel(hands:GetModel(), RENDERGROUP_OTHER)
		if not IsValid(ghostHands) then return ghost end
		ghostHands:SetNoDraw(true)
		ghostHands:DrawShadow(false)
		ghostHands:SetParent(ghost)
		ghostHands:AddEffects(EF_BONEMERGE)
	end
	ghostHands:SetOwner(w:GetOwner())
	ghostHands.GetPlayerColor = function() local p = w:GetOwner() return IsValid(p) and p:GetPlayerColor() or Vector(1, 1, 1) end
	ghostHands:SetSkin(hands:GetSkin())
	for _, group in ipairs(hands:GetBodyGroups()) do ghostHands:SetBodygroup(group.id, hands:GetBodygroup(group.id)) end
	return ghost, ghostHands
end
local function clearCopies()
	if IsValid(ghostHands) then ghostHands:Remove() end
	if IsValid(ghost) then ghost:Remove() end
	ghost, ghostHands = nil, nil
end
hook.Add("ShutDown", "hr_weapon_motion_blur", clearCopies)

local function draw(w, vm)
	local owner = w:GetOwner()
	if not enabled:GetBool() or owner ~= LocalPlayer() or not owner:Alive()
		or owner:ShouldDrawLocalPlayer() or w:GetNW2Bool("hr_executing") or w:ScopeFraction() > 0.01
		or not GetConVar("r_drawviewmodel"):GetBool() or render.GetRenderTarget() then reset() return end
	local frame = FrameNumber()
	if previous and previous.frame == frame then return end
	local view = render.GetViewSetup()
	local now = RealTime()
	local current = {weapon = w, model = vm:GetModel(), sequence = vm:GetSequence(),
		frame = frame, time = now, fov = view.fovviewmodel_unscaled, bones = {}}
	for i = 0, vm:GetBoneCount() - 1 do
		local matrix = vm:GetBoneMatrix(i)
		if matrix and vm:GetBoneName(i) ~= "__INVALIDBONE__" then
			local pos, ang = WorldToLocal(matrix:GetTranslation(), matrix:GetAngles(), view.origin, view.angles)
			current.bones[i] = {matrix = matrix, pos = pos, ang = ang, scale = matrix:GetScale()}
		end
	end
	local old = previous
	previous = current
	if not old or old.weapon ~= w or old.model ~= current.model or old.sequence ~= current.sequence
		or math.abs(old.fov - current.fov) > 1 then return end
	local dt = now - old.time
	if dt <= 0 or dt > 0.1 then return end
	local motion = 0
	for i, bone in pairs(current.bones) do
		local last = old.bones[i]
		if last then motion = math.max(motion, bone.pos:Distance(last.pos)) end
	end
	local exposure = math.min((1 / 120) / dt, 0.75)
	local strength = math.Clamp((motion * exposure - 0.02) / 0.5, 0, 1)
	if motion > 64 or strength == 0 then return end
	if w:GetAiming() then strength = strength * 0.35 end
	local ghost, ghostHands = copies(w, vm, w.UseHands and owner:GetHands())
	if not ghost then return end
	local blend = render.GetBlend()
	render.OverrideDepthEnable(true, false)
	for sample = 3, 1, -1 do
		local fraction = exposure * sample / 3
		local bones = {}
		for i, bone in pairs(current.bones) do
			local last = old.bones[i]
			if last then
				local pos, ang = LocalToWorld(LerpVector(fraction, bone.pos, last.pos),
					LerpAngle(fraction, bone.ang, last.ang), view.origin, view.angles)
				local matrix = Matrix()
				matrix:SetTranslation(pos)
				matrix:SetAngles(ang)
				matrix:SetScale(LerpVector(fraction, bone.scale, last.scale))
				bones[i] = matrix
			end
		end
		ghost.hr_blur_bones = bones
		ghost:InvalidateBoneCache()
		ghost:SetupBones()
		render.SetBlend(blend * strength * (0.13 - sample * 0.02))
		ghost:DrawModel()
		if IsValid(ghostHands) then
			ghostHands:InvalidateBoneCache()
			ghostHands:DrawModel()
		end
	end
	render.SetBlend(blend)
	render.OverrideDepthEnable(false)
end

return draw
