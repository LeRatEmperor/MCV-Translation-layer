// Random spawn-menu choices are selectors, not extra SWEPs. Resolve a fresh class
// on the server, then let sandbox's ordinary give/spawn commands enforce permissions.
MCV.RandomWeaponDefinitions = {}
local definitions = MCV.RandomWeaponDefinitions
local function define(key, name, kind, data)
    data = data or {}
    data.key, data.name, data.kind = key, name, kind
    definitions[key] = data
end

define("all", "Random MCV Weapon", "other")

local function country(key, name, flag, ...)
    local aliases = {}
    for _, value in ipairs({...}) do aliases[value] = true end
    define("country:" .. key, "Random " .. name .. " Weapon", "country", {countries = aliases, flag = flag})
end
country("us", "US", "us", "United States of America")
country("ru", "Russian", "su", "Russian Empire", "Soviet Union", "Russia")
country("cn", "Chinese", "cn", "People's Republic of China", "Shanxi Province", "China")
country("fr", "French", "fr", "France")
country("de", "German", "de", "German Empire", "German Reich", "Nazi Germany", "Germany")
country("gb", "British", "gb", "United Kingdom")
country("au", "Australian", "au", "Australia")
country("be", "Belgian", "be", "Belgium")
country("nl", "Dutch", "nl", "Netherlands")
country("cz", "Czechoslovak", "cz", "Czechoslovakia")
country("kp", "North Korean", "kp", "Democratic People's Republic of Korea", "North Korea")
country("vn", "Vietnamese", "vn", "Vietnam", "North Vietnam", "Democratic Republic of Vietnam")
country("fi", "Finnish", "fi", "Finland")
country("hu", "Hungarian", "hu", "Hungary")
country("il", "Israeli", "il", "Israel")
country("it", "Italian", "it", "Italy")
country("dk", "Danish", "dk", "Kingdom of Denmark", "Denmark")
country("es", "Spanish", "es", "Kingdom of Spain", "Spain")
country("pl", "Polish", "pl", "Polish People's Republic", "Poland")
country("rh", "Rhodesian", "rh", "Republic of Rhodesia", "Rhodesia")
country("ro", "Romanian", "ro", "Romania")
country("se", "Swedish", "se", "Sweden")
country("yu", "Yugoslav", "yu", "Yugoslavia")

local function theme(key, name, flag, members, kind)
    local classes = {}
    for _, class in ipairs(string.Explode(" ", members)) do classes["mcv_" .. class] = true end
    define("theme:" .. key, "Random " .. name .. " Weapon", kind or "other", {classes = classes, flag = flag})
end
theme("homemade", "Homemade", nil, "vccarbine vcgrenade vcpistol vcpistol2 vcshotgun vcsmg")
theme("custom", "Custom", nil, "m635 xm16super ptrd_sniper m1_carbine svd_irons type56_drum")
// Explicit period configurations: modern derivatives and SOG conversions stay out.
theme("us_ww2", "US WW2", "us", "bazooka browning_auto hdm m1897 m1905_bayonet m1911a1 m1917 m1918 m1918_bar m1919 m1942_machete m1c m1g m2c m37 m3a1 m50r m55r m60r m8 mk2 mk3a2 springfield springfield_s swm10 thompson thompson_m1928", "ww2")
theme("ru_ww2", "Russian WW2", "su", "m1895 m38 m38_s m91 avt40 dp28 pps43 ppsh41 ppsh41_drum ptrd svt40 svt40_s tt33", "ww2")
theme("de_ww2", "German WW2", "de_imperial", "c96 c96_stock luger g43 kar98 kar98_s kar98_zf41 mg43 mg43d mp40 p38 panzerschreck ppk stg44 stg44_s stg44_zf41 stielhand_explosive stielhand_smoke shovel_ger", "ww2")
theme("gb_ww2", "British WW2", "gb", "bren sten sten_sog welrod", "ww2")
theme("fr_ww2", "French WW2", "fr", "fm24 lebel mas36_cr39 mas38 mle1935 fusil_robust", "ww2")
theme("jp_ww2", "Japanese WW2", "jp", "type14 type30_bayonet type97 katana", "ww2")
country("jp", "Japanese", "jp", "Empire of Japan", "Japan")

// Country pools also represent shared designs and recognizable service weapons.
// These explicit additions supplement Country without changing its display text,
// stat category, or period lists. Catalog traversal still gives each class one roll.
local function alsoCountry(key, members)
    local classes = {}
    for _, class in ipairs(string.Explode(" ", members)) do classes["mcv_" .. class] = true end
    definitions["country:" .. key].classes = classes
end
alsoCountry("gb", "l1a1 hipower") // Commonwealth SLR and service pistol.
alsoCountry("au", "bren hipower") // Australian service alongside the local SLRs.
alsoCountry("be", "l1a1 l1a1_sog l2a1 babybrowning browning_auto") // FN design/manufacture.
alsoCountry("cz", "cz52 vz24 vz54 vz54s vz59 bren") // Czech designs, including the Bren's ancestry.
alsoCountry("de", "g3 t223 t223_25") // H&K family, including the US-market T223.
alsoCountry("ru", "m1895") // Belgian-designed Russian service revolver.
alsoCountry("fr", "ruby mat49k") // French service pistol and the Vietnamese MAT-49 conversion.
alsoCountry("us", "m45_sog rpd_sog rpdb_sog v40") // SOG configurations and the Dutch V40 in US service.

define("feature:scope", "Random Scoped Weapon", "other", {feature = "HasScope"})
define("feature:dual", "Random Dual-Wield Weapon", "other", {feature = "HasAkimbo"})
define("feature:launcher", "Random Rifle-Grenade Weapon", "other", {feature = "HasRifleGrenade"})

local singular = {
    ["Battle Rifles"] = "Battle Rifle", ["Assault Rifles"] = "Assault Rifle",
    ["Bolt-Action Rifles"] = "Bolt-Action Rifle", ["Sniper Rifles"] = "Sniper Rifle",
    ["Pistols"] = "Pistol", ["Machine Pistols"] = "Machine Pistol", ["Revolvers"] = "Revolver",
    ["Submachine Guns"] = "Submachine Gun", ["Carbines"] = "Carbine", ["Shotguns"] = "Shotgun",
    ["Light-Machine Guns"] = "Light-Machine Gun", ["Flamethrowers"] = "Flamethrower",
    ["Bows"] = "Bow", ["Explosives"] = "Explosive", ["Grenades"] = "Grenade",
    ["Rifle Grenades"] = "Rifle Grenade", ["Melee"] = "Melee Weapon",
}
for _, category in ipairs(MCV.Categories) do
    if category == MCV.CATEGORY_ALL then continue end
    define("category:" .. MCV.CategorySlug(category), "Random " .. (singular[category] or category),
        "category", {category = category})
end

local function catalog(ply)
    local result = {}
    for _, entry in ipairs(weapons.GetList()) do
        local w = weapons.Get(entry.ClassName)
        if !w or !w.MilitaryConflictVietnam or !w.Spawnable then continue end
        if w.AdminOnly and !(IsValid(ply) and (ply:IsAdmin() or game.SinglePlayer())) then continue end
        result[#result + 1] = {class = entry.ClassName, title = w.PrintName or entry.ClassName, weapon = w}
    end
    table.sort(result, function(a, b) return a.class < b.class end)
    return result
end

local function matches(group, entry)
    local w = entry.weapon
    if group.category then return w.SubCategory == group.category end
    if group.countries then
        return group.countries[w.Country] == true or (group.classes != nil and group.classes[entry.class] == true)
    end
    if group.classes then return group.classes[entry.class] == true end
    if group.feature then return w[group.feature] == true end
    return group.key == "all"
end

function MCV.GetRandomWeaponChoices(key, ply, npcOnly)
    local result, group = {}, definitions[key]
    if !group then return result end
    for _, entry in ipairs(catalog(ply)) do
        if matches(group, entry) and (!npcOnly or entry.weapon.NPCUsable) then
            result[#result + 1] = {class = entry.class, title = entry.title, category = entry.weapon.SubCategory}
        end
    end
    return result
end

function MCV.GetRandomWeaponGroups(ply)
    local entries, groups = catalog(ply), {}
    for key, definition in pairs(definitions) do
        local group = {key = key, name = definition.name, kind = definition.kind,
            category = definition.category, flag = definition.flag, count = 0, npcCount = 0}
        for _, entry in ipairs(entries) do
            if matches(definition, entry) then
                group.count = group.count + 1
                if entry.weapon.NPCUsable then group.npcCount = group.npcCount + 1 end
            end
        end
        if group.count > 0 then groups[#groups + 1] = group end
    end
    table.sort(groups, function(a, b) return a.name < b.name end)
    return groups
end

function MCV.RandomWeaponNPCSelection(key)
    return "!mcv|random:" .. key
end

if SERVER then
    function MCV.SpawnRandomWeapon(ply, key, drop)
        if !IsValid(ply) or !ply:IsPlayer() or !ply:Alive() then return end
        local choices = MCV.GetRandomWeaponChoices(key, ply)
        if #choices == 0 then return end
        local class = choices[math.random(#choices)].class
        if drop then
            if isfunction(Spawn_Weapon) then return Spawn_Weapon(ply, class) end
        elseif isfunction(CCGiveSWEP) then
            CCGiveSWEP(ply, "gm_giveswep", {class})
        end
    end
    concommand.Add("mcv_random_weapon", function(ply, _, args)
        if args[2] != nil and args[2] != "give" and args[2] != "spawn" then return end
        MCV.SpawnRandomWeapon(ply, args[1], args[2] == "spawn")
    end)
end
