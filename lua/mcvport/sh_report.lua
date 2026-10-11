--[[---------------------------------------------------------------------------
    MCVPort — the mcvport_report console command.

    Lists every registered port with its translation health: which roles the
    current viewmodel resolved, which are missing, how many timeline events
    and hooks are declared. Roles only resolve once the weapon has been
    deployed (a viewmodel must exist to resolve against); before that the
    report shows the declared candidates only.

    Run on either realm:  mcvport_report
-----------------------------------------------------------------------------]]

if MCVP and MCVP.LoadedReport then return end
MCVP.LoadedReport = true

local function count(t)
    local n = 0
    if t then for _ in pairs(t) do n = n + 1 end end
    return n
end

concommand.Add("mcvport_report", function(ply)
    if IsValid(ply) then return end -- console only

    local ports = 0
    print("\n=== MCVPort translation report ===")

    for _, wep in ipairs(weapons.GetList()) do
        if wep.MCVPort then
            ports = ports + 1
            local cfg = wep.MCVP
            print(string.format("\n%s  (%s)", wep.ClassName or "?", tostring(wep.PrintName)))
            print("  base   : " .. tostring(wep.Base))
            print("  model  : " .. tostring(wep.ViewModel))
            print("  roles  : " .. count(cfg.anims) .. " declared"
                .. ", " .. #cfg.required .. " required: " .. table.concat(cfg.required, ", "))

            local hooks_n = count(cfg.hooks)
            local events_n = 0
            for _, list in pairs(cfg.events) do events_n = events_n + #list end
            print("  events : " .. events_n .. " synthetic")
            print("  hooks  : " .. hooks_n .. (hooks_n > 0 and (" (" .. table.concat((function()
                local names = {}
                for name in pairs(cfg.hooks) do names[#names + 1] = name end
                table.sort(names)
                return names
            end)(), ", ") .. ")") or ""))
        end
    end

    -- live resolution state from weapons currently deployed in the world
    for _, ply in ipairs(player.GetAll()) do
        for _, wep in ipairs(ply:GetWeapons()) do
            if IsValid(wep) and wep.MCVPort and wep.MCVP_resolved then
                local vm = ply:GetViewModel()
                local model = IsValid(vm) and vm:GetModel()
                local cache = model and wep.MCVP_resolved[model]
                if cache then
                    local line = string.format("  [%s held by %s] ", wep:GetClass(), ply:Nick())
                    if cache.ok and #cache.missing == 0 then
                        print(line .. "all roles resolved")
                    else
                        local missing = #cache.required_missing > 0 and cache.required_missing or cache.missing
                        print(line .. "missing: " .. (#missing > 0 and table.concat(missing, ", ") or "none (optional only)"))
                    end
                end
            end
        end
    end

    if ports == 0 then
        print("no ports registered — weapons must call MCV.Define to register")
    end
    print("\n" .. ports .. " port(s) registered. "
        .. "Deploy a weapon to populate live resolution state.\n")
end)
