// The Q menu tabs: Options > Military Conflict: Vietnam > Server and > Client.
//
// Two pages, because the two kinds of convar answer to different people. The server ones are
// replicated and shared by everyone playing, so on someone else's server they are the host's to
// set and a client changing them is ignored. The client ones are that player's own and reach
// nobody else unless marked userinfo, such as tracer colour and aim input mode.
//
// Adding a convar is one entry in SERVER_SETTINGS or CLIENT_SETTINGS and nothing else. A
// `section` entry starts a heading; an entry with `choices` is a dropdown, one with `slider` a
// number, anything else a checkbox. See CLAUDE.md.

MCV = MCV or {}

local SERVER_SETTINGS = {
    {convar = "mcv_realistic_shooting", label = "Realistic shooting",
     help = "Alternate weapon handling schema inspired by Modern Warfare 4"},

    {convar = "mcv_surface_impacts", label = "The game's bullet impacts",
     help = "Use Military Conflict: Vietnam's impact effects and decals. Disable to use standard Garry's Mod impacts and bullet holes instead."},

    {convar = "mcv_bullet_penetration", label = "Bullet penetration",
     help = "Bullets can pass through thin cover. Material, thickness and weapon stats determine whether they stop and how much damage remains."},

    {convar = "mcv_spawn_rifle_grenade_ammo", label = "Starting rifle-grenade ammo",
     help = "Give newly spawned rifles their starting rifle-grenade or underbarrel-launcher ammo. Existing ammo and resupply are unaffected."},
}

local PHYSICAL_SETTINGS = {
    {convar = "mcv_physbullets", label = "Enable physical bullets", help = "Server setting: bullets travel using weapon MuzzleVelocity instead of hitting instantly."},
    {convar = "mcv_physbullets_npcs", label = "NPC physical bullets"},
    {convar = "mcv_physbullets_pellets", label = "Physical shotgun pellets", help = "Simulate each pellet separately"},
    {convar = "mcv_physbullets_velocity", label = "Muzzle velocity multiplier", slider = {0.1, 3, 2}, help = "1 uses the gun's MuzzleVelocity in metres per second. Higher values shorten travel time."},
    {convar = "mcv_physbullets_gravity", label = "Gravity multiplier", slider = {0, 3, 2}, help = "1 applies Earth gravity; 0 disables bullet drop."},
    {convar = "mcv_physbullets_drag", label = "Air resistance (per second)", slider = {0, 2, 2}},
    {convar = "mcv_physbullets_lifetime", label = "Maximum flight time (seconds)", slider = {0.1, 10, 1}},
}

local CLIENT_SETTINGS = {
    {section = "Controls"},
    {convar = "mcv_toggle_aim", label = "Toggle aim", help = "Press aim to raise or lower sights instead of holding it."},
    {convar = "mcv_auto_reload", label = "Automatic reload", help = "Reload an empty gun automatically when reserve ammo is available. Your preference is shared with the server."},
    {section = "Viewmodel"},
    {convar = "mcv_viewmodel_fov_offset", label = "Viewmodel FOV offset", slider = {-25, 25, 0}, help = "Degrees added to the weapon's normal viewmodel FOV."},
    {convar = "mcv_viewmodel_sighted_fov_offset", label = "Sighted viewmodel FOV offset", slider = {-25, 25, 0}, help = "Degrees added to the aimed viewmodel FOV."},
    {convar = "mcv_ironsight_nozoom", label = "No iron-sight zoom", help = "Keep normal world FOV and sensitivity with iron sights; scopes are unchanged."},
    {convar = "mcv_viewmodel_offset_x", label = "Hip position X (right/left)", slider = {-10, 10, 1},
     help = "Move the hip viewmodel right (+) or left (-). Fades out when aiming; zero preserves its original position."},
    {convar = "mcv_viewmodel_offset_y", label = "Hip position Y (forward/back)", slider = {-10, 10, 1},
     help = "Move the hip viewmodel forward (+) or backward (-). Fades out when aiming."},
    {convar = "mcv_viewmodel_offset_z", label = "Hip position Z (up/down)", slider = {-10, 10, 1},
     help = "Move the hip viewmodel up (+) or down (-). Fades out when aiming."},
    {section = "Effects"},
    {convar = "mcv_tracer_color", label = "Tracer colour",
     help = "Other players see this too",
     choices = {{"Default", "0"}, {"Player colour", "1"}, {"Weapon colour", "2"}}},

    {convar = "mcv_muzzle_light", label = "Muzzle flash light",
     choices = {{"Lamp with shadows", "2"}, {"Simple light", "1"}, {"Off", "0"}}, help = "Choose how muzzle flashes light the gun and surroundings."},

    {convar = "mcv_shell_smoke", label = "Shell smoke trail", help = "Draw smoke trails behind ejected cases."},

    {convar = "mcv_shell_time", label = "Shell lifetime (seconds)", slider = {0, 60, 1}, help = "How long cases remain after coming to rest."},

    {section = "HUD",},

    {convar = "mcv_hud_enable", label = "Enable HUD", help = "Show the weapon information HUD."},

    {convar = "mcv_hud_hints", label = "Control hints", choices = {{"Never", "0"}, {"On Deploy", "1"}, {"First Deploy", "2"}, {"Always", "3"}}, help = "Choose when weapon control hints appear."},

    {convar = "mcv_hud_crosshair", label = "Enable crosshair", help = "Show the weapon crosshair."},
}

// which category the sliders below are showing, an index into MCV.Categories
local cv_category = CreateClientConVar("mcv_cat_menu", "1", true, false,
    "Q menu only: the weapon category whose stat multipliers the settings tab is showing")

// Which categories hold a weapon that launches something. The three projectile stats are
// shown for those only, so a pistol's page is not padded with dials that do nothing. Read off
// the weapons themselves rather than a list to keep, and the rifle grenades are always in.
local function launchingCategories()
    local out = {[MCV.CATEGORY_RIFLE_GRENADE] = true, [MCV.CATEGORY_ALL] = true}

    for _, wep in ipairs(weapons.GetList()) do
        if !wep.SubCategory then continue end

        for _, key in ipairs({"ShootEntity", "ThrowEntity", "ThrownEntity", "PlacedEntityClass", "RifleGrenadeEntity"}) do
            if isstring(wep[key]) and wep[key] != "" then
                out[wep.SubCategory] = true
                break
            end
        end
    end

    return out
end

local function categoryBlock(panel, rebuild)
    panel:Help("Category stats")

    local idx = math.Clamp(cv_category:GetInt(), 1, #MCV.Categories)
    local category = MCV.Categories[idx]

    local combo = panel:ComboBox("Category")
    for i, name in ipairs(MCV.Categories) do
        combo:AddChoice(name, i)
    end
    combo:SetValue(category)

    combo.OnSelect = function(_, _, _, data)
        cv_category:SetInt(data)

        // out of the callback before the controls it is running from are thrown away
        timer.Simple(0, function()
            if IsValid(panel) then rebuild(panel) end
        end)
    end

    local launches = launchingCategories()[category]

    for _, stat in ipairs(MCV.CategoryStats) do
        if stat.projectile and !launches then continue end

        panel:NumSlider(stat.label, MCV.CategoryConVarName(category, stat.key), 0, 3, 2)
        if stat.help then
            panel:ControlHelp(stat.help)
        end
    end

    local reset = panel:Button("Reset " .. category)
    reset.DoClick = function()
        for _, stat in ipairs(MCV.CategoryStats) do
            RunConsoleCommand(MCV.CategoryConVarName(category, stat.key), "1")
        end

        timer.Simple(0, function()
            if IsValid(panel) then rebuild(panel) end
        end)
    end
end

local function controls(panel, settings)
    for _, s in ipairs(settings) do
        if s.section then
            panel:Help(s.section)

            if s.help then panel:ControlHelp(s.help) end

            continue
        end

        local cv = GetConVar(s.convar)
        if !cv then continue end

        if s.choices then
            local combo = panel:ComboBox(s.label, s.convar)
            local now = cv:GetString()

            for _, c in ipairs(s.choices) do
                combo:AddChoice(c[1], c[2])

                // show what is set without firing the selection back at the convar
                if c[2] == now then combo:SetValue(c[1]) end
            end
        elseif s.slider then
            panel:NumSlider(s.label, s.convar, s.slider[1], s.slider[2], s.slider[3] or 2)
        else
            panel:CheckBox(s.label, s.convar)
        end

        if s.help then panel:ControlHelp(s.help) end
    end
end

local buildServer

// Native GMod presets: defaults come from the registered convars, not menu copies.
// The server page includes every category, even those not currently selected.
local function addPresets(panel, group, lists, categories)
    local defaults = {}
    for _, list in ipairs(lists) do
        for _, setting in ipairs(list) do
            local cv = setting.convar and GetConVar(setting.convar)
            if cv then defaults[setting.convar] = cv:GetDefault() end
        end
    end
    if categories then
        for _, category in ipairs(MCV.Categories) do
            for _, stat in ipairs(MCV.CategoryStats) do
                local name = MCV.CategoryConVarName(category, stat.key)
                local cv = GetConVar(name)
                if cv then defaults[name] = cv:GetDefault() end
            end
        end
    end
    panel:ToolPresets(group, defaults)
end

buildServer = function(panel)
    panel:ClearControls()
    addPresets(panel, "mcv_server", {SERVER_SETTINGS, PHYSICAL_SETTINGS}, true)

    controls(panel, SERVER_SETTINGS)
    controls(panel, PHYSICAL_SETTINGS)
    categoryBlock(panel, buildServer)
end

local function buildClient(panel)
    panel:ClearControls()
    addPresets(panel, "mcv_client", {CLIENT_SETTINGS})

    controls(panel, CLIENT_SETTINGS)
end

hook.Add("PopulateToolMenu", "MCV_Settings", function()
    spawnmenu.AddToolMenuOption("Options", "Military Conflict: Vietnam", "mcv_settings_physical_bullets",
        "Physical Bullets", "", "", function(panel)
            panel:ClearControls()
            addPresets(panel, "mcv_physical_bullets", {PHYSICAL_SETTINGS})
            panel:Help("Server-controlled ballistics. Particle tracers follow bullet flight; damage occurs at contact. Existing projectile weapons keep their own flight.")
            controls(panel, PHYSICAL_SETTINGS)
        end)
    spawnmenu.AddToolMenuOption("Options", "Military Conflict: Vietnam", "mcv_settings_server",
        "Server", "", "", buildServer)

    spawnmenu.AddToolMenuOption("Options", "Military Conflict: Vietnam", "mcv_settings_client",
        "Client", "", "", buildClient)
end)
