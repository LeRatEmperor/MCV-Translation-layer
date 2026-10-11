if CLIENT then return end
MCVNPCTest = MCVNPCTest or {}
local T = MCVNPCTest
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"

function T.Clear()
    hook.Remove("Think", "MCV_NPCTest")
    hook.Remove("EntityTakeDamage", "MCV_NPCTest")
    for _, e in ipairs(T.entities or {}) do if IsValid(e) then e:Remove() end end
    T.entities, T.cases = {}, {}
end

function T.Start()
    T.Clear()
    local specs = {
        {"npc_combine_s", "mcv_akm"},
        {"npc_citizen", "mcv_m21"},
        {"npc_combine_s", "mcv_m37"},
        {"npc_combine_s", "mcv_vz24"},
        {"npc_metropolice", "mcv_blackhawk"},
        {"npc_combine_s", "mcv_rpg7"},
        {"npc_citizen", "mcv_crossbow"},
        {"npc_combine_s", "mcv_m79"},
    }
    for i, spec in ipairs(specs) do
        local origin = Vector(4000, (i - 1) * 900 - 3000, -12799)
        local target = ents.Create("npc_zombie")
        target:SetPos(origin + Vector(700, 0, 0))
        target:SetKeyValue("health", "1000000")
        target:Spawn()
        target:SetHealth(1000000)
        target:SetSchedule(SCHED_NPC_FREEZE)
        local npc = ents.Create(spec[1])
        npc:SetPos(origin)
        npc:SetAngles(Angle(0, 0, 0))
        npc:SetKeyValue("spawnflags", "256")
        npc:SetKeyValue("additionalequipment", spec[2])
        npc:Spawn()
        npc:Activate()
        npc:SetHealth(1000000)
        npc:SetCurrentWeaponProficiency(WEAPON_PROFICIENCY_PERFECT)
        npc:AddEntityRelationship(target, D_HT, 99)
        npc:SetEnemy(target)
        npc:UpdateEnemyMemory(target, target:GetPos())
        local w = npc:GetActiveWeapon()
        assert(IsValid(w) and w:GetClass() == spec[2], "NPC missing " .. spec[2])
        local row = {npc = npc:GetClass(), weapon = w:GetClass(), owner = npc, target = target, gun = w,
            targetOrigin = target:GetPos(),
            initialClip = w:Clip1(), shots = {}, reloads = {}, damage = 0, reloadCalls = 0}
        local shoot, reload = w.NPC_PrimaryAttack, w.NPC_Reload
        w.NPC_PrimaryAttack = function(self, ...)
            local before = self:Clip1()
            shoot(self, ...)
            if IsValid(self) and self:Clip1() < before then
                row.shots[#row.shots + 1] = {time = CurTime(), before = before, after = self:Clip1()}
            end
        end
        w.NPC_Reload = function(self, ...)
            row.reloadCalls = row.reloadCalls + 1
            return reload(self, ...)
        end
        w:SetClip1(math.min(2, w.Primary.ClipSize))
        row.lastClip = w:Clip1()
        T.cases[#T.cases + 1] = row
        T.entities[#T.entities + 1] = npc
        T.entities[#T.entities + 1] = target
    end
    // Independent lanes: citizens and Combine must not start fighting each other.
    for _, row in ipairs(T.cases) do
        for _, other in ipairs(T.cases) do
            if other != row then
                row.owner:AddEntityRelationship(other.owner, D_NU, 99)
                row.owner:AddEntityRelationship(other.target, D_NU, 99)
            end
            row.target:AddEntityRelationship(other.owner, D_NU, 99)
        end
    end
    hook.Add("EntityTakeDamage", "MCV_NPCTest", function(ent, dmg)
        for _, row in ipairs(T.cases) do
            if ent == row.target then
                row.damage = row.damage + dmg:GetDamage()
                return true // Record real hits without gibbing/flinching the stationary target.
            end
        end
    end)
    hook.Add("Think", "MCV_NPCTest", function()
        for _, row in ipairs(T.cases) do
            local w, n = row.gun, row.owner
            if !IsValid(w) or !IsValid(n) then continue end
            local clip = w:Clip1()
            if clip > row.lastClip then row.reloads[#row.reloads + 1] = {time = CurTime(), clip = clip} end
            row.lastClip = clip
            if IsValid(row.target) then
                row.target:SetPos(row.targetOrigin)
                if !row.target:IsCurrentSchedule(SCHED_NPC_FREEZE) then row.target:SetSchedule(SCHED_NPC_FREEZE) end
                n:SetEnemy(row.target)
                n:UpdateEnemyMemory(row.target, row.target:GetPos())
            end
        end
    end)
end

function T.Report(name)
    local result = {map = game.GetMap(), singleplayer = game.SinglePlayer(), cases = {}, menu = #MCV.GetNPCWeapons()}
    for _, row in ipairs(T.cases) do
        local w, n = row.gun, row.owner
        result.cases[#result.cases + 1] = {npc = row.npc, weapon = row.weapon,
            initialClip = row.initialClip, shots = row.shots, reloads = row.reloads, damage = row.damage,
            reloadCalls = row.reloadCalls, clip = IsValid(w) and w:Clip1(), hold = IsValid(w) and w:GetHoldType(),
            schedule = IsValid(n) and n:GetCurrentSchedule(), activity = IsValid(n) and n:GetActivity(),
            enemy = IsValid(n) and tostring(n:GetEnemy() or NULL), alive = IsValid(n) and n:Health() > 0,
            targetPos = IsValid(row.target) and row.target:GetPos()}
    end
    file.Write(root .. name .. ".json", util.TableToJSON(result, true))
end
