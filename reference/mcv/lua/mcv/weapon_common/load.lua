// Compose common weapon behavior once, without an extra registered SWEP base.
// Functions (and module hooks) are shared; mutable default tables belong to each base.
AddCSLuaFile()
if !MCV.IncludeWeaponModules then
    function MCV.IncludeWeaponModules(dir)
        local files, dirs = file.Find(dir .. "/*.lua", "LUA")
        for _, filename in ipairs(files) do
            if filename != "shared.lua" and filename != "load.lua" then
                local realm = string.sub(filename, 1, 2)
                local path = dir .. "/" .. filename
                if realm != "sv" then AddCSLuaFile(path) end
                if realm != "cl" and realm != "sv" or realm == "cl" and CLIENT or realm == "sv" and SERVER then
                    include(path)
                end
            end
        end
        for _, folder in ipairs(dirs) do MCV.IncludeWeaponModules(dir .. "/" .. folder) end
    end
end

if !MCV.WeaponCommon then
    local target = SWEP
    SWEP = {Primary = {}, Secondary = {}}
    local ok, err = pcall(include, "mcv/weapon_common/shared.lua")
    local common = SWEP
    SWEP = target
    if !ok then error(err) end
    MCV.WeaponCommon = common
end

for key, value in pairs(MCV.WeaponCommon) do
    SWEP[key] = istable(value) and table.Copy(value) or value
end
