AddCSLuaFile()

if CLIENT and MCV and MCV.CleanupClientModels then MCV.CleanupClientModels() end
MCV = {}

local searchdir = "mcv/"

// The shared files come back in name order, and several of them register convars through the
// helper in sh_convars.lua, which some of them sort ahead of. It goes first.
local first = "sh_convars.lua"

local function loadshared(v)
    include(searchdir .. "shared/" .. v)
    AddCSLuaFile(searchdir .. "shared/" .. v)
end

loadshared(first)

for _, v in pairs(file.Find(searchdir .. "shared/*", "LUA")) do
    if v != first then
        loadshared(v)
    end
end

for _, v in pairs(file.Find(searchdir .. "client/*", "LUA")) do
    AddCSLuaFile(searchdir .. "client/" .. v)
    if CLIENT then
        include(searchdir .. "client/" .. v)
    end
end

for _, v in pairs(file.Find(searchdir .. "client/vgui/*", "LUA")) do
    AddCSLuaFile(searchdir .. "client/vgui/" .. v)
    if CLIENT then
        include(searchdir .. "client/vgui/" .. v)
    end
end

if SERVER then
    for _, v in pairs(file.Find(searchdir .. "server/*", "LUA")) do
        include(searchdir .. "server/" .. v)
    end
end
