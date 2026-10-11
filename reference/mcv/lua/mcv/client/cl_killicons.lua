// Kill icons: the weapon's own spawn menu icon, tinted the colour the game's kill icons use.
//
// The death notice is handed the class of whatever the damage names as its inflictor. A bullet
// names the weapon, so a gun needs nothing beyond its icon; an explosion names the weapon that
// launched it while that weapon still exists (mcv_proj_base:GetInflictor), and its own entity
// otherwise, which is why each projectile, grenade and planted charge is aliased to the weapon
// that produces it. Anything with no icon of its own falls back to the game's default, as it
// did before.

local COLOR = Color(255, 80, 0, 255)  // gamemodes/base/gamemode/cl_deathnotice.lua

// the fields a weapon names its entity in
local ENTITY_KEYS = {"ShootEntity", "ThrowEntity", "ThrownEntity", "PlacedEntityClass", "StakeEntityClass"}

// after every weapon file has been read, so weapons.GetList is complete
hook.Add("Initialize", "MCV_KillIcons", function()
    local n, aliases = 0, 0

    for _, wep in ipairs(weapons.GetList()) do
        local class = wep.ClassName

        if !class or class:sub(1, 4) != "mcv_" then continue end

        local mat = "entities/" .. class .. ".png"
        if !file.Exists("materials/" .. mat, "GAME") then continue end

        killicon.Add(class, mat, COLOR)
        n = n + 1

        for _, key in ipairs(ENTITY_KEYS) do
            local ent = wep[key]

            // first weapon wins where several fire the same projectile: the alias only shows
            // when the weapon itself is gone by the time the thing goes off
            if isstring(ent) and ent != "" and !killicon.Exists(ent) then
                killicon.AddAlias(ent, class)
                aliases = aliases + 1
            end
        end
    end

    MsgN(string.format("[mcv] %d kill icons, %d aliases for their projectiles", n, aliases))
end)
