MCVRandomTest = {}
local T = MCVRandomTest
local port = GetConVar("hostport"):GetInt()
local root = (port == 27015 and "mcv_harness/" or "mcv_harness/p" .. port .. "/") .. "results/"
local function save(name, data) file.Write(root .. "random_" .. name .. ".json", util.TableToJSON(data, true)) end
local function contains(choices, class)
    for _, choice in ipairs(choices) do if choice.class == class then return true end end
    return false
end

if SERVER then
    function T.Audit(ply)
        local groups, result = MCV.GetRandomWeaponGroups(ply), {}
        for _, group in ipairs(groups) do
            local choices = MCV.GetRandomWeaponChoices(group.key, ply)
            local npc = MCV.GetRandomWeaponChoices(group.key, ply, true)
            assert(#choices == group.count and #npc == group.npcCount, "incorrect pool counts")
            local seen = {}
            for _, choice in ipairs(choices) do
                local w = weapons.Get(choice.class)
                assert(w.MilitaryConflictVietnam and w.Spawnable and !seen[choice.class], "invalid/duplicate choice")
                seen[choice.class] = true
            end
            for _, choice in ipairs(npc) do
                assert(seen[choice.class] and weapons.Get(choice.class).NPCUsable, "invalid NPC choice")
            end
            result[#result + 1] = group
        end
        for _, definition in pairs(MCV.RandomWeaponDefinitions) do
            for class in pairs(definition.classes or {}) do assert(weapons.Get(class), "unknown theme member " .. class) end
        end
        assert(#MCV.GetRandomWeaponChoices("invalid", ply) == 0)
        assert(#MCV.GetRandomWeaponChoices("category:flamethrowers", ply, true) == 0)
        assert(#MCV.GetRandomWeaponChoices("theme:homemade", ply) == 6)
        local ww2 = MCV.GetRandomWeaponChoices("theme:us_ww2", ply)
        assert(contains(ww2, "mcv_m1g") and !contains(ww2, "mcv_m16a1") and !contains(ww2, "mcv_m635"))
        local russian = MCV.GetRandomWeaponChoices("country:ru", ply)
        assert(contains(russian, "mcv_akm") and contains(russian, "mcv_m91"))
        for _, key in ipairs({"gb", "au", "be"}) do
            assert(contains(MCV.GetRandomWeaponChoices("country:" .. key, ply), "mcv_l1a1"), "missing shared SLR " .. key)
            assert(contains(MCV.GetRandomWeaponChoices("country:" .. key, ply, true), "mcv_l1a1"), "missing NPC SLR " .. key)
        end
        assert(weapons.Get("mcv_l1a1").Country == "Australia", "displayed origin changed")
        assert(!contains(MCV.GetRandomWeaponChoices("theme:gb_ww2", ply), "mcv_l1a1"), "modern SLR entered WW2 pool")
        for _, definition in pairs(MCV.RandomWeaponDefinitions) do
            if !definition.countries then continue end
            for class in pairs(definition.classes or {}) do
                assert(contains(MCV.GetRandomWeaponChoices(definition.key, ply), class), "missing country addition " .. class)
            end
        end
        assert(MCV.RandomWeaponDefinitions["theme:de_ww2"].flag == "de_imperial")
        assert(MCV.RandomWeaponDefinitions["country:de"].flag == "de")
        assert(MCV.RandomWeaponDefinitions["country:ru"].flag == "su")
        save("groups", result)
    end
    function T.SpawnNPC(ply, key, explicit)
        local selection = explicit or MCV.RandomWeaponNPCSelection(key)
        local npc = Spawn_NPC(ply, "npc_combine_s", selection, {HitPos = Vector(4500, 0, -12800), HitNormal = vector_up})
        assert(IsValid(npc), "NPC spawn failed")
        local weapon = npc:GetActiveWeapon()
        if explicit then
            assert(IsValid(weapon) and weapon:GetClass() == explicit, "explicit NPC override lost")
        else
            assert(IsValid(weapon) and contains(MCV.GetRandomWeaponChoices(key, ply, true), weapon:GetClass()), "NPC outside selected pool")
        end
        local result = {key = key, class = weapon:GetClass(), equipment = npc.Equipment, explicit = explicit}
        npc:Remove()
        save(explicit and "npc_explicit" or "npc", result)
    end
else
    function T.Open(misc)
        g_SpawnMenu:Open()
        g_SpawnMenu:OpenCreationMenuTab("#spawnmenu.category.weapons")
        local tab = g_SpawnMenu.CreateMenu:GetCreationTab("#spawnmenu.category.weapons")
        local tree = tab.ContentPanel.ContentNavBar.Tree
        local node = tree.Categories["Military Conflict: Vietnam"]
        assert(IsValid(node), "missing MCV node")
        node:SetExpanded(true)
        if misc then
            local found
            for _, child in pairs(node:GetChildNodes()) do if child.MCVRandomMisc then found = child end end
            assert(IsValid(found), "missing Miscellaneous tab")
            node = found
        end
        node:InternalDoClick()
        T.Panel = node.PropPanel
        T.Icons = {}
        for _, icon in ipairs(node.PropPanel.IconList:GetChildren()) do
            if icon.GetContentType and icon:GetContentType() == "mcv_random_weapon" then
                T.Icons[icon:GetSpawnName()] = icon
                assert(!Material(icon.m_MaterialName, "smooth mips"):IsError(), "missing random icon")
            end
        end
        local result = {}
        for key, icon in pairs(T.Icons) do result[#result + 1] = {key = key, material = icon.m_MaterialName} end
        assert(table.Count(T.Icons) > 10, "missing random groups")
        save(misc and "misc_ui" or "category_ui", result)
    end
    function T.SelectNPC(key)
        local icon = T.Icons[key]
        assert(IsValid(icon), "missing selector " .. key)
        local menu = DermaMenu()
        icon:OpenMenuExtra(menu)
        local found
        for _, option in ipairs(menu:GetCanvas():GetChildren()) do
            if option.GetText and option:GetText() == "Use for NPCs" then found = option end
        end
        assert(IsValid(found) and found:IsEnabled(), "NPC action missing or disabled")
        found:DoClick()
        menu:Remove()
        save("npc_menu", {key = key, clicked = true})
    end
end
