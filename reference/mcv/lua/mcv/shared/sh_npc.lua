// Native individual weapon selection plus TacRP-style category/random choices.
// gmod_npcweapon is already a sandbox userinfo convar, so no client net request
// or last-spawned-NPC bookkeeping is needed.
function MCV.GetNPCWeapons(category, ply)
    local result = {}
    for _, entry in ipairs(weapons.GetList()) do
        local w = weapons.Get(entry.ClassName) // Resolve inherited NPCUsable/Spawnable.
        if w and w.MilitaryConflictVietnam and w.Spawnable and w.NPCUsable and
                (!category or w.SubCategory == category) and
                (!w.AdminOnly or (IsValid(ply) and ply:IsAdmin())) then
            result[#result + 1] = {class = entry.ClassName, title = w.PrintName, category = w.SubCategory}
        end
    end
    table.sort(result, function(a, b) return a.title == b.title and a.class < b.class or a.title < b.title end)
    return result
end

local function registerWeapons()
    local existing = {}
    for _, entry in pairs(list.Get("NPCUsableWeapons")) do existing[entry.class] = true end
    for _, entry in ipairs(MCV.GetNPCWeapons()) do
        if !existing[entry.class] then
            list.Add("NPCUsableWeapons", {class = entry.class, title = "MCV: " .. entry.title})
        end
    end
end
hook.Add("InitPostEntity", "MCV_NPCWeapons", registerWeapons)
hook.Add("OnReloaded", "MCV_NPCWeapons", registerWeapons)

if CLIENT then
    hook.Add("PopulateMenuBar", "MCV_NPCWeapons", function(bar)
        local menu = bar:AddOrGetMenu("MCV NPC Weapons")
        menu:AddCVar("Default weapon", "gmod_npcweapon", "")
        menu:AddCVar("No weapon", "gmod_npcweapon", "none")
        menu:AddSpacer()
        menu:AddCVar("Random MCV weapon", "gmod_npcweapon", "!mcv|all")
        menu:AddSpacer()
        local categories = {}
        for _, entry in ipairs(MCV.GetNPCWeapons(nil, LocalPlayer())) do
            local category = entry.category
            if !categories[category] then
                local sub = menu:AddSubMenu(category)
                sub:SetDeleteSelf(false)
                sub:AddCVar("Random " .. category, "gmod_npcweapon", "!mcv|" .. category)
                sub:AddSpacer()
                categories[category] = sub
            end
            categories[category]:AddCVar(entry.title, "gmod_npcweapon", entry.class)
        end
        local misc = menu:AddSubMenu("Miscellaneous")
        misc:SetDeleteSelf(false)
        for _, group in ipairs(MCV.GetRandomWeaponGroups(LocalPlayer())) do
            if group.kind != "category" and group.key != "all" and group.npcCount > 0 then
                misc:AddCVar(group.name, "gmod_npcweapon", MCV.RandomWeaponNPCSelection(group.key))
            end
        end
    end)
else
    hook.Add("PlayerSpawnedNPC", "MCV_NPCWeapons", function(ply, npc)
        if !IsValid(npc) or !npc:IsNPC() then return end
        // An explicit weapon from the NPC's right-click menu takes precedence.
        if npc.Equipment and npc.Equipment != "" then return end
        local selection = ply:GetInfo("gmod_npcweapon")
        if string.sub(selection, 1, 5) != "!mcv|" then return end
        if bit.band(npc:CapabilitiesGet(), CAP_USE_WEAPONS) == 0 then return end
        local category = string.sub(selection, 6)
        local choices
        if string.StartWith(category, "random:") then
            choices = MCV.GetRandomWeaponChoices(string.sub(category, 8), ply, true)
        else
            choices = MCV.GetNPCWeapons(category != "all" and category or nil, ply)
        end
        if #choices == 0 then return end
        local class = choices[math.random(#choices)].class
        npc:Give(class)
        npc.Equipment = class // Preserve the resolved weapon when duplicating.
    end)
end
