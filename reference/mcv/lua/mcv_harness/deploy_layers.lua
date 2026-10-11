// Manual asset regression probe, loaded only by the test harness.
if !CLIENT then return end
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"
local output = {models = {}}
local model
local routine = coroutine.create(function()
    for _, name in ipairs({"v_ak47", "v_sks", "v_m203", "v_m21", "v_dual_m1911",
            "v_m635", "v_xm16super", "v_ptrd41_s", "v_lpo50"}) do
        model = ClientsideModel("models/weapons/mcv/" .. name .. ".mdl")
        assert(IsValid(model), "could not create " .. name)
        model:SetNoDraw(true)
        model:SetPos(vector_origin)
        model:SetAngles(angle_zero)
        model:SetPlaybackRate(0)
        // Source needs a frame after creation/pose writes before bone sampling.
        coroutine.yield()
        local row = {name = name, draws = {}}
        local movement = model:LookupPoseParameter("player_movement")
        assert(movement >= 0, "no movement pose on " .. name)
        local low, high = model:GetPoseParameterRange(movement)
        assert(high > low, "empty movement range on " .. name)

        local function sample(seq, pose, cycle)
            model:ResetSequence(seq)
            model:SetPlaybackRate(0)
            model:SetCycle(cycle)
            model:SetPoseParameter("player_movement", pose)
            coroutine.yield()
            model:InvalidateBoneCache()
            model:SetupBones()
            local bones = {}
            for bone = 0, model:GetBoneCount() - 1 do
                local matrix = model:GetBoneMatrix(bone)
                if matrix then bones[bone] = matrix:GetTranslation() end
            end
            assert(table.Count(bones) > 1, "no animation bones on " .. name)
            return bones
        end

        local function difference(seq, cycle)
            local a, b = sample(seq, low, cycle), sample(seq, high, cycle)
            local worst = 0
            for bone, pos in pairs(a) do worst = math.max(worst, pos:Distance(b[bone])) end
            return worst
        end

        for _, label in pairs(model:GetSequenceList()) do
            local index = model:LookupSequence(label)
            assert(index >= 0, "could not resolve " .. label)
            local activity = model:GetSequenceActivityName(index) or ""
            local draw = string.find(activity, "ACT_VM_DRAW", 1, true) == 1 or
                activity == "ACT_VM_READY" or activity == "ACT_VM_READY_M203" or
                activity == "ACT_VM_EMPTY_DRAW"
            if draw then
                local worst = 0
                for _, cycle in ipairs({0.2, 0.5, 0.8}) do
                    worst = math.max(worst, difference(index, cycle))
                end
                row.draws[#row.draws + 1] = {sequence = label, movementDelta = worst}
                assert(worst < 0.001, name .. ": movement still affects " .. label .. " (" .. worst .. ")")
            end
        end
        assert(#row.draws > 0, "no draw sequences tested on " .. name)
        local idle = model:LookupSequence("idle")
        assert(idle >= 0, "no idle on " .. name)
        row.idleDelta = difference(idle, 0.5)
        // Positive control: the same sampling must still see normal idle movement.
        assert(row.idleDelta > 0.01, "movement positive control failed on " .. name)
        output.models[#output.models + 1] = row
        model:Remove()
        model = nil
    end
end)
file.Write(root .. "deploy_layers_runtime.json", util.TableToJSON({running = true}))
// Also allow the sequence's ordinary 0.2-second transition to settle; otherwise
// changing sequence between samples measures the previous animation's fade.
timer.Create("MCV_DeployLayerProbe", 0.3, 0, function()
    local ok, err = coroutine.resume(routine)
    if ok and coroutine.status(routine) != "dead" then return end
    timer.Remove("MCV_DeployLayerProbe")
    if IsValid(model) then model:Remove() end
    output.ok, output.error = ok, err
    file.Write(root .. "deploy_layers_runtime.json", util.TableToJSON(output, true))
    assert(ok, err)
end)
