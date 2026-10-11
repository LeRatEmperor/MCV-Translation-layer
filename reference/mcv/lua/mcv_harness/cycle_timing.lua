MCVCycleTiming = MCVCycleTiming or {}
local T = MCVCycleTiming
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/"

function T.Audit()
    local results = {}
    for _, spec in ipairs(util.JSONToTable(file.Read(root .. "cycle_manifest.json", "DATA"))) do
        local model = "models/weapons/mcv/" .. spec.model .. ".mdl"
        local ent = CLIENT and ClientsideModel(model) or ents.Create("prop_dynamic")
        ent:SetModel(model)
        ent:SetNoDraw(true)
        if SERVER then ent:Spawn() end
        local seq = ent:LookupSequence(spec.sequence)
        assert(seq >= 0, model)
        local duration = ent:SequenceDuration(seq)
        assert(math.abs(duration - spec.duration) < 0.0001, model .. ": " .. duration)
        results[#results + 1] = {model=model, duration=duration, sequence=spec.sequence}
        ent:Remove()
    end
    file.Write(root .. "results/cycle_models_" .. (CLIENT and "client" or "server") .. ".json", util.TableToJSON(results,true))
end

function T.Start(ply, tag)
    local w = ply:GetActiveWeapon()
    assert(IsValid(w) and w.PlayCycleAnimation)
    T.w, T.tag, T.rows = w, tag, {}
    T.play = w.PlayAnimation
    w.PlayAnimation = function(self, act, ...)
        local t = T.play(self, act, ...)
        if act == ACT_VM_RELOAD_INSERT_PULL then
            local vm = ply:GetViewModel()
            local cmd = ply:GetCurrentCommand()
            T.rows[#T.rows + 1] = {class=self:GetClass(), start=CurTime(), duration=t,
                command=cmd and cmd:CommandNumber(), first=IsFirstTimePredicted(),
                model=vm:GetModel(), rate=vm:GetPlaybackRate(), sequence=vm:GetSequenceName(vm:GetSequence()),
                release=self:GetHammerReleaseTime(), clip=self:Clip1()}
        end
        return t
    end
end

function T.Finish()
    T.w.PlayAnimation = T.play
    local result = {rows=T.rows, finalStart=T.w:GetActionStart(), needCycle=T.w:GetNeedCycle(), clip=T.w:Clip1()}
    file.Write(root .. "results/cycle_" .. T.tag .. "_" .. (CLIENT and "client" or "server") .. ".json", util.TableToJSON(result,true))
    assert(#T.rows > 0, "no real-input cycle recorded")
    assert(!result.needCycle, "cycle did not finish")
    for _, row in ipairs(T.rows) do
        assert(row.duration and row.rate == 1, "cycle did not play at authored speed")
    end
end
