if SERVER then AddCSLuaFile(); return end

hook.Add('SpawnmenuIconMenuOpen', 'hr_weapon_spawn_options', function(menu, icon, kind)
    if kind ~= 'weapon' then return end
    local class = icon:GetSpawnName()
    local weapon = weapons.GetStored(class)
    if not weapon or not weapon.HR or not weapon.Spawnable then return end
    menu:AddSpacer()
    menu:AddOption('Spawn weapon on ground', function() RunConsoleCommand('gm_spawnswep',class) end):SetIcon('icon16/gun.png')
    if util.IsValidModel(weapon.WorldModel) then
        menu:AddOption('Spawn as a prop', function() RunConsoleCommand('gm_spawn',weapon.WorldModel) end):SetIcon('icon16/brick.png')
    end
end)

hook.Add('PopulatePropMenu','hr_weapon_props',function()
    local props={}
    for _,weapon in ipairs(weapons.GetList()) do
        if weapon.HR and weapon.Spawnable and util.IsValidModel(weapon.WorldModel) then
            props[#props+1]={type='model',model=weapon.WorldModel}
        end
    end
    table.sort(props,function(a,b)return a.model<b.model end)
    spawnmenu.AddPropCategory('hr_weapon_props','Hellraiser: Revival Weapon Props',props,'icon16/gun.png')
end)
