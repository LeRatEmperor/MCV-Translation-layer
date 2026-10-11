spawnmenu.AddContentType("mcv_random_weapon", function(container, obj)
    local group = MCV.RandomWeaponDefinitions[obj.spawnname]
    if !group then return end
    local npcCount = obj.npcCount or #MCV.GetRandomWeaponChoices(group.key, LocalPlayer(), true)
    local icon = vgui.Create("ContentIcon", container)
    icon:SetContentType("mcv_random_weapon")
    icon:SetSpawnName(group.key)
    icon:SetName(group.name)
    icon:SetMaterial("mcv/random/" .. (group.flag or "question") .. ".png")
    icon:SetColor(Color(135, 206, 250))
    icon:SetIsNPCWeapon(npcCount > 0)
    icon:SetTooltip(group.name .. "\nLeft click: give yourself a random weapon.\nMiddle click: spawn a random pickup.\nRight click: use this group for newly spawned NPCs.")
    icon.DoClick = function()
        RunConsoleCommand("mcv_random_weapon", group.key, "give")
        surface.PlaySound("ui/buttonclickrelease.wav")
    end
    icon.DoMiddleClick = function()
        RunConsoleCommand("mcv_random_weapon", group.key, "spawn")
        surface.PlaySound("ui/buttonclickrelease.wav")
    end
    icon.OpenMenuExtra = function(self, menu)
        menu:AddOption("Give to me", self.DoClick):SetIcon("icon16/gun.png")
        menu:AddOption("Spawn a pickup", self.DoMiddleClick):SetIcon("icon16/brick_add.png")
        local option = menu:AddOption("Use for NPCs", function()
            RunConsoleCommand("gmod_npcweapon", MCV.RandomWeaponNPCSelection(group.key))
        end)
        option:SetIcon("icon16/monkey.png")
        if npcCount == 0 then
            option:SetEnabled(false)
            option:SetTooltip("This group has no weapons supported by NPCs.")
        end
    end
    icon.OpenMenu = icon.OpenGenericSpawnmenuRightClickMenu
    // Match sandbox's selected-NPC badge while using a selector rather than a SWEP class.
    local drawSelections = icon.DrawSelections
    icon.DrawSelections = function(self)
        local original = self.m_SpawnName
        self.m_SpawnName = MCV.RandomWeaponNPCSelection(original)
        drawSelections(self)
        self.m_SpawnName = original
    end
    if IsValid(container) then container:Add(icon) end
    return icon
end)

function MCV.CreateRandomWeaponIcon(container, group)
    return spawnmenu.CreateContentIcon("mcv_random_weapon", container, {
        spawnname = group.key, nicename = group.name, npcCount = group.npcCount,
        material = "mcv/random/" .. (group.flag or "question") .. ".png",
    })
end

function MCV.PopulateRandomWeaponMisc(container)
    local groups = MCV.GetRandomWeaponGroups(LocalPlayer())
    for _, section in ipairs({{"other", "Mixed groups"}, {"country", "Countries"}, {"ww2", "World War II"}}) do
        local heading = vgui.Create("ContentHeader", container)
        heading:SetText(section[2])
        container:Add(heading)
        for _, group in ipairs(groups) do
            if group.kind == section[1] then MCV.CreateRandomWeaponIcon(container, group) end
        end
    end
end
