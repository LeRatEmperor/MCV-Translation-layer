if CLIENT then return end
MCVNPCCadence = {}
local T = MCVNPCCadence
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
local caps = {60, 90, 120, 180, 240}
local function near(a, b) assert(math.abs(a - b) < 0.00001, tostring(a) .. " != " .. tostring(b)) end

local function makeNPC(class, proficiency, position)
    local npc = ents.Create("npc_combine_s")
    npc:SetPos(position)
    npc:SetAngles(Angle(0, 0, 0))
    npc:SetKeyValue("spawnflags", "256")
    npc:SetKeyValue("additionalequipment", class)
    npc:Spawn()
    npc:Activate()
    npc:SetCurrentWeaponProficiency(proficiency)
    npc:SetHealth(1000000)
    local weapon = npc:GetActiveWeapon()
    assert(IsValid(weapon) and weapon:GetClass() == class)
    return npc, weapon
end

function T.Audit()
    local npc, w = makeNPC("mcv_m1911a1", 0, Vector(4000, 4000, -12799))
    local rows = {}
    for proficiency = 0, 4 do
        npc:SetCurrentWeaponProficiency(proficiency)
        local expected = math.max(60 / w:GetFiremodeRate(MCV.FIREMODE_SEMI), 60 / caps[proficiency + 1])
        near(w:GetNPCShotInterval(), expected)
        local first, last, delay = w:GetNPCBurstSettings()
        assert(first == 1 and last == 1)
        near(delay, expected)
        local restMin, restMax = w:GetNPCRestTimes()
        assert(restMin >= expected and restMax >= expected)
        rows[#rows + 1] = {proficiency = proficiency, cap = caps[proficiency + 1], interval = delay}
    end
    local statMult = w.StatMult
    w.StatMult = function(self, stat) return stat == "firerate" and 10 or statMult(self, stat) end
    near(w:GetNPCShotInterval(), 0.25) // Category boosts cannot defeat the cap.
    w.StatMult = function(self, stat) return stat == "firerate" and 0.1 or statMult(self, stat) end
    near(w:GetNPCShotInterval(), 60 / (w.FireRate * 0.1)) // Slower tuning still applies.
    w.NPCShotInterval = 2
    near(w:GetNPCShotInterval(), 2)
    npc:Remove()
    npc, w = makeNPC("mcv_akm", 0, Vector(4000, 4000, -12799))
    local autoDelay = 60 / w:GetFiremodeRate(MCV.FIREMODE_AUTO)
    near(w:GetNPCShotInterval(), autoDelay)
    w:SetFiremode(2)
    near(w:GetNPCShotInterval(), math.max(1, 60 / w:GetFiremodeRate(MCV.FIREMODE_SEMI)))
    npc:SetCurrentWeaponProficiency(4)
    near(w:GetNPCShotInterval(), math.max(0.25, 60 / w:GetFiremodeRate(MCV.FIREMODE_SEMI)))
    npc:Remove()
    for _, spec in ipairs({{"mcv_m37", 0.6}, {"mcv_vz24", 0.9}}) do
        npc, w = makeNPC(spec[1], 0, Vector(4000, 4000, -12799))
        near(w:GetNPCShotInterval(), math.max(spec[2], 60 / w:GetFiremodeRate(w:GetFiremodeValue())))
        npc:Remove()
    end
    file.Write(root .. "npc_cadence_audit.json", util.TableToJSON({levels = rows, controls = true}, true))
end

function T.Start()
    T.rows, T.entities = {}, {}
    for i = 1, 8 do
        local native = i > 6
        local proficiency = native and (i == 7 and 0 or 4) or math.min(i - 1, 4)
        local class = i == 6 and "mcv_akm" or "mcv_m1911a1"
        local position = Vector(4500, (i - 1) * 850 - 3000, -12799)
        local npc, w = makeNPC(class, proficiency, position)
        local row = {npc = npc, gun = w, proficiency = proficiency, class = class, native = native, shots = {}}
        if native then
            local target = ents.Create("npc_zombie")
            target:SetPos(position + Vector(700, 0, 0))
            target:Spawn()
            target:SetHealth(1000000)
            target:SetSchedule(SCHED_NPC_FREEZE)
            npc:AddEntityRelationship(target, D_HT, 99)
            npc:SetEnemy(target)
            npc:UpdateEnemyMemory(target, target:GetPos())
            row.target, row.targetPos = target, target:GetPos()
            T.entities[#T.entities + 1] = target
        else
            npc:SetSchedule(SCHED_NPC_FREEZE)
            // Exercise the real fire entry point every Think, without reload pauses.
            w:SetClip1(200)
            local statMult = w.StatMult
            w.StatMult = function(self, stat) return stat == "firerate" and 1 or statMult(self, stat) end
        end
        row.interval = w:GetNPCShotInterval()
        local fire = w.NPC_PrimaryAttack
        w.NPC_PrimaryAttack = function(self, ...)
            local before = self:Clip1()
            fire(self, ...)
            if self:Clip1() < before then row.shots[#row.shots + 1] = CurTime() end
        end
        T.rows[#T.rows + 1] = row
        T.entities[#T.entities + 1] = npc
    end
    hook.Add("EntityTakeDamage", "MCVNPCCadence", function(entity)
        for _, row in ipairs(T.rows) do if entity == row.target then return true end end
    end)
    hook.Add("Think", "MCVNPCCadence", function()
        for _, row in ipairs(T.rows) do
            if row.native then
                row.target:SetPos(row.targetPos)
                row.target:SetSchedule(SCHED_NPC_FREEZE)
                row.npc:SetEnemy(row.target)
                row.npc:UpdateEnemyMemory(row.target, row.targetPos)
            else
                row.npc:SetSchedule(SCHED_NPC_FREEZE)
                row.gun:NPC_PrimaryAttack(row.npc:GetShootPos(), Vector(0, 0, 1))
            end
        end
    end)
end

function T.Finish()
    hook.Remove("Think", "MCVNPCCadence")
    hook.Remove("EntityTakeDamage", "MCVNPCCadence")
    local result, passed = {cases = {}}, true
    for _, row in ipairs(T.rows) do
        local minimum = math.huge
        for i = 2, #row.shots do minimum = math.min(minimum, row.shots[i] - row.shots[i - 1]) end
        local ok = #row.shots >= 3 and minimum + 0.00001 >= row.interval
        passed = passed and ok
        result.cases[#result.cases + 1] = {class = row.class, proficiency = row.proficiency,
            native_ai = row.native, required_interval = row.interval, minimum_interval = minimum,
            shots = row.shots, passed = ok}
    end
    result.passed = passed
    file.Write(root .. "npc_cadence_runtime.json", util.TableToJSON(result, true))
    for _, entity in ipairs(T.entities) do if IsValid(entity) then entity:Remove() end end
    assert(passed, "NPC cadence failed; see npc_cadence_runtime.json")
end
