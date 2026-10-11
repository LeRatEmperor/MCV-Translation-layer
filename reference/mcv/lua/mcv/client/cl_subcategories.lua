-- Taken straight from MCV's implementation. It just works

hook.Add("PopulateWeapons", "zzz_MCV_SubCategories", function(pnlContent, tree, anode)

    timer.Simple(0, function()
        -- Loop through the weapons and add them to the menu
        local Weapons = list.Get("Weapon")
        local Categorised = {}
        local MCVCats = {}

        -- Build into categories + subcategories
        for k, weapon in pairs(Weapons) do
            if !weapon.Spawnable then continue end
            if !(weapons.Get(k) or {}).MilitaryConflictVietnam then continue end

            -- Get the weapon category as a string
            local Category = weapon.Category or "Other2"
            local WepTable = weapons.Get(weapon.ClassName)
            if (!isstring(Category)) then
                Category = tostring(Category)
            end

            -- Get the weapon subcategory as a string
            local SubCategory = "Other"
            if (WepTable != nil and WepTable.SubCategory != nil) then
                SubCategory = WepTable.SubCategory
                if (!isstring(SubCategory)) then
                    SubCategory = tostring(SubCategory)
                end
            end

            -- Insert it into our categorised table
            Categorised[Category] = Categorised[Category] or {}
            Categorised[Category][SubCategory] = Categorised[Category][SubCategory] or {}
            table.insert(Categorised[Category][SubCategory], weapon)
            MCVCats[Category] = true
        end

        -- Iterate through each category in the weapons table
        for _, node in pairs(tree:Root():GetChildNodes()) do

            if !MCVCats[node:GetText()] then continue end

            -- Get the subcategories registered in this category
            local catSubcats = Categorised[node:GetText()]

            if !catSubcats then continue end

            -- Overwrite the icon populate function with a custom one
            node.DoPopulate = function(self)

                -- If we've already populated it - forget it.
                if IsValid(self.PropPanel) then self.PropPanel:Remove() end

                -- Create the container panel
                self.PropPanel = vgui.Create("ContentContainer", pnlContent)
                self.PropPanel:SetVisible(false)
                self.PropPanel:SetTriggerSpawnlistChange(false)
                local randomGroups = {}
                for _, group in ipairs(MCV.GetRandomWeaponGroups(LocalPlayer())) do
                    if group.category then randomGroups[group.category] = group end
                end

                -- Iterate through the subcategories
                for subcatName, subcatWeps in SortedPairs(catSubcats) do

                    -- Create the subcategory header, if more than one exists for this category
                    if (table.Count(catSubcats) > 1) then
                        local label = vgui.Create("ContentHeader", self.PropPanel)
                        label:SetText(subcatName)
                        self.PropPanel:Add(label)
                    end

                    -- Create the clickable icon
                    if randomGroups[subcatName] then
                        MCV.CreateRandomWeaponIcon(self.PropPanel, randomGroups[subcatName])
                    end
                    for _, ent in SortedPairsByMemberValue(subcatWeps, "PrintName") do
                        -- Spawn-list entries can omit inherited SWEP fields. Resolve
                        -- the registered weapon too, so variants reuse their base icon.
                        local weapon = weapons.Get(ent.ClassName) or {}
                        spawnmenu.CreateContentIcon(ent.ScriptedEntityType or "weapon", self.PropPanel, {
                            nicename  = ent.PrintName or ent.ClassName,
                            spawnname = ent.ClassName,
                            material  = ent.IconOverride or weapon.IconOverride or "entities/" .. ent.ClassName .. ".png",
                            admin     = ent.AdminOnly
                        })
                    end
                end
            end

            -- If we click on the node populate it and switch to it.
            node.DoClick = function(self)
                self:DoPopulate()
                pnlContent:SwitchPanel(self.PropPanel)
            end
            local misc = node:AddNode("Miscellaneous", "icon16/help.png")
            misc.MCVRandomMisc = true
            misc.DoPopulate = function(self)
                if IsValid(self.PropPanel) then self.PropPanel:Remove() end
                self.PropPanel = vgui.Create("ContentContainer", pnlContent)
                self.PropPanel:SetVisible(false)
                self.PropPanel:SetTriggerSpawnlistChange(false)
                MCV.PopulateRandomWeaponMisc(self.PropPanel)
            end
            misc.DoClick = function(self)
                self:DoPopulate()
                pnlContent:SwitchPanel(self.PropPanel)
            end
            misc.OnRemove = function(self)
                if IsValid(self.PropPanel) then self.PropPanel:Remove() end
            end
        end

        -- Select the first node
        local FirstNode = tree:Root():GetChildNode(0)
        if (IsValid(FirstNode)) then
            FirstNode:InternalDoClick()
        end
    end)
end)
