// Explicitly included by work/tests/type67_timing.txt; never loaded by the addon.
MCVType67Timing = MCVType67Timing or {}
local T = MCVType67Timing
local root = "mcv_harness/p" .. GetConVar("hostport"):GetInt() .. "/results/"

function T.Start(ply, tag)
    local w = ply:GetActiveWeapon()
    assert(IsValid(w) and w:GetClass() == "mcv_type67")
    local vm = ply:GetViewModel()
    T.w, T.tag, T.rows = w, tag, {}
    local function record(kind, name)
        local now = CLIENT and w:GetViewModelTime() or CurTime()
        T.rows[#T.rows + 1] = {kind=kind, event=name, time=now,
            sequence=vm:GetSequenceName(vm:GetSequence()), start=w:GetAnimationStart(),
            duration=w:GetAnimationDuration(), elapsed=now-w:GetAnimationStart(),
            cycle=vm:GetCycle(), needCycle=w:GetNeedCycle(), emptyReload=w:GetEmptyReload(),
            hammer=vm:GetPoseParameter("hammerpos"), release=w:GetHammerReleaseTime(),
            clip=w:Clip1(), akimbo=w:GetAkimbo()}
    end
    T.think, T.event, T.body = w.ThinkWeapon, w.FireAnimationEvent, w.DoBodygroupsWeapon
    w.ThinkWeapon = function(self, ...)
        T.think(self, ...)
        if IsFirstTimePredicted() then record("think") end
    end
    w.FireAnimationEvent = function(self, pos, ang, event, name, ...)
        if name == "eject" or name == "eject2" then record("eject", name) end
        return T.event(self, pos, ang, event, name, ...)
    end
    w.DoBodygroupsWeapon = function(self, model, visual, ...)
        T.body(self, model, visual, ...)
        if visual then record("render") end
    end
end

function T.Finish()
    local w = T.w
    w.ThinkWeapon, w.FireAnimationEvent, w.DoBodygroupsWeapon = T.think, T.event, T.body
    file.Write(root .. "type67_" .. T.tag .. (CLIENT and "_client.json" or "_server.json"),
        util.TableToJSON({rows=T.rows, handlesHammer=w.AnimationHandlesHammer,
            cycleSpeed=w.CycleSpeed}, true))
end
