MCVPackSplitTest = {}
local T = MCVPackSplitTest
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/"

function T.Audit(ply)
    local specs = util.JSONToTable(file.Read(root .. "pack_weapons.json", "DATA"))
    local rows, seen = {}, {}
    for class, spec in pairs(specs) do
        local w = weapons.Get(class)
        assert(w and w.Spawnable and w.MilitaryConflictVietnam, "unregistered " .. class)
        assert(w.Country == spec.country and w.PrintName == spec.name, "metadata " .. class)
        assert(file.Exists("weapons/" .. class .. ".lua", "LUA"), class)
        for _, key in ipairs({"ViewModel", "WorldModel", "ViewModelAkimbo", "ViewModelRifleGrenade"}) do
            local model = w[key]
            if isstring(model) and model != "" and !seen[model] then
                assert(file.Exists(model, "GAME"), "missing " .. model)
                local ent = CLIENT and ClientsideModel(model) or ents.Create("prop_dynamic")
                assert(IsValid(ent), "failed model " .. model)
                ent:SetModel(model)
                ent:SetNoDraw(true)
                if SERVER then ent:Spawn() end
                assert(ent:GetBoneCount() > 0, "unloaded model " .. model)
                ent:Remove()
                seen[model] = true
            end
        end
        if CLIENT then
            local icon = w.IconOverride or ("entities/" .. class .. ".png")
            assert(!Material(icon):IsError(), "missing icon " .. class)
        end
        rows[#rows+1] = {class=class,part=spec.part}
    end
    assert(#rows == 244)
    local report = {weapons=#rows,models=table.Count(seen),passed=true}
    file.Write(root .. "results/pack_split_" .. (CLIENT and "client" or "server") .. ".json",util.TableToJSON(report,true))
end
