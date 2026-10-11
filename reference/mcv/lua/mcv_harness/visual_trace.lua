// Explicitly included by the local development harness. No gameplay hooks when inactive.
if !CLIENT or !file.Exists("mcv_harness/enable.txt", "DATA") then return end
MCV.VisualHarness = MCV.VisualHarness or {}
local H = MCV.VisualHarness
local port = GetConVar("hostport"):GetInt()
local root = port == 27015 and "mcv_harness/" or "mcv_harness/p" .. port .. "/"
local function xyz(v) return {v.x, v.y, v.z} end
local function pyr(v) return {v.p, v.y, v.r} end

local function record(wep, stage, vm)
    local trace = H.VisualTrace
    if !trace then return end
    if #trace.records >= 200000 then trace.dropped=trace.dropped+1 return end
    local ply = LocalPlayer()
    vm = vm or ply:GetViewModel()
    if !IsValid(vm) then return end
    local r = {stage=stage, phase=H.VisualPhase, frame=FrameNumber(), time=SysTime(),
        ct=CurTime(), upct=UnPredictedCurTime(), ft=FrameTime(), rft=RealFrameTime(),
        predicting=GetPredictionPlayer()==ply, first=IsFirstTimePredicted(),
        weapon=wep:GetClass(), ent=wep:EntIndex(), raw=wep:GetSightAmountRaw(),
        visual=wep.VisualSightRaw, visual_frame=wep.VisualSightFrame,
        speed=wep:GetSpeed(), speed_visual=wep.VisualSpeed,
        speed_frame=wep.VisualSpeedFrame, sighted=wep:GetSighted(),
        move_command=wep.GetMoveCommand and wep:GetMoveCommand(),
        move_speed=wep.GetMoveSpeed and wep:GetMoveSpeed(),
        move_grounded=wep.GetMoveGrounded and wep:GetMoveGrounded(),
        tickbase=ply:GetInternalVariable("m_nTickBase"),
        seq=vm:GetSequence(), cycle=vm:GetCycle(), rate=vm:GetPlaybackRate(),
        seqname=vm:GetSequenceName(vm:GetSequence()), parity=vm:GetInternalVariable("m_nAnimationParity"),
        animtime=vm:GetInternalVariable("m_flAnimTime"),
        animstart=wep.GetAnimationStart and wep:GetAnimationStart(),
        animduration=wep.GetAnimationDuration and wep:GetAnimationDuration(),
        newparity=vm:GetInternalVariable("m_nNewSequenceParity"),
        eventparity=vm:GetInternalVariable("m_nResetEventsParity"),
        clip=wep:Clip1(), reserve=wep:Ammo1(), reloading=wep:GetReloading(), lock=wep:GetAnimLockTime(),
        pose_aim=vm:GetPoseParameter("ironsight"), pose_move=vm:GetPoseParameter("player_movement"),
        pos=xyz(vm:GetPos()), ang=pyr(vm:GetAngles())}
    if stage == "drawn" then
        if trace.model != vm:GetModel() then
            trace.model=vm:GetModel(); trace.bones={}; trace.names={}; trace.mechanisms={}
            for i=0,vm:GetBoneCount()-1 do
                local name=vm:GetBoneName(i)
                trace.names[i]=name
                if name:lower():find("bolt") or name:lower():find("slide") or name:lower():find("pump") then
                    table.insert(trace.mechanisms,i)
                end
                if name:lower():find("weapon") or name:lower():find("hand") or name:lower():find("cam") then
                    if #trace.bones < 8 then table.insert(trace.bones,i) end
                end
            end
        end
        r.mechanisms={}
        for _,i in ipairs(trace.mechanisms) do
            local mat=vm:GetBoneMatrix(i)
            local parent=vm:GetBoneMatrix(vm:GetBoneParent(i))
            if mat and parent then
                local pos,ang=WorldToLocal(mat:GetTranslation(),mat:GetAngles(),parent:GetTranslation(),parent:GetAngles())
                r.mechanisms[tostring(i)]={pos=xyz(pos),ang=pyr(ang)}
            end
        end
        r.bones={}
        for _,i in ipairs(trace.bones) do
            local mat=vm:GetBoneMatrix(i)
            if mat then
                local pos,ang=WorldToLocal(mat:GetTranslation(),mat:GetAngles(),vm:GetPos(),vm:GetAngles())
                r.bones[tostring(i)]={pos=xyz(pos),ang=pyr(ang)}
            end
        end
    end
    table.insert(trace.records,r)
end

function H.StartVisualTrace(name, capture)
    local wep=LocalPlayer():GetActiveWeapon()
    assert(IsValid(wep) and wep.MilitaryConflictVietnam,"visual trace requires an MCV weapon")
    assert(!H.VisualTrace,"visual trace already running")
    H.VisualTrace={name=name, records={}, images={}, image_times={}, capture=capture,
        wrapped={}, bones={}, movement_first=0, movement_replay=0, dropped=0,
        prediction_checks=0, prediction_cache_writes={}}
    H.VisualPhase="idle"
    for _,method in ipairs({"GetViewModelPosition","PreDrawViewModel","ViewModelDrawn"}) do
        local old=wep[method]
        H.VisualTrace.wrapped[method]=old
        if method=="GetViewModelPosition" then
            wep[method]=function(self,...)
                if GetPredictionPlayer()==self:GetOwner() then
                    // Count every replay without allocating two large records per
                    // command, keeping combined traces smaller in 32-bit GMod.
                    local sight,speed,stance,steady=self.VisualSightFrame,self.VisualSpeedFrame,self.VisualStanceFrame,self.VisualSteadyFrame
                    local pos,ang=old(self,...)
                    local trace=H.VisualTrace
                    trace.prediction_checks=trace.prediction_checks+1
                    local function changed(key,before,after)
                        if before != after then trace.prediction_cache_writes[key]=(trace.prediction_cache_writes[key] or 0)+1 end
                    end
                    changed("visual_frame",sight,self.VisualSightFrame)
                    changed("speed_frame",speed,self.VisualSpeedFrame)
                    changed("stance_frame",stance,self.VisualStanceFrame)
                    changed("steady_frame",steady,self.VisualSteadyFrame)
                    return pos,ang
                end
                record(self,"position_before")
                local pos,ang=old(self,...)
                record(self,"position_after")
                return pos,ang
            end
        elseif method=="PreDrawViewModel" then
            wep[method]=function(self,vm,...)
                record(self,"predraw_before",vm)
                local ret=old(self,vm,...)
                record(self,"predraw_after",vm)
                return ret
            end
        else
            wep[method]=function(self,vm,...)
                local ret=old(self,vm,...)
                record(self,"drawn",vm)
                return ret
            end
        end
    end
    local old=wep.CaptureMovement
    if old then
        H.VisualTrace.wrapped.CaptureMovement=old
        wep.CaptureMovement=function(self,...)
            local trace=H.VisualTrace
            local key=IsFirstTimePredicted() and "movement_first" or "movement_replay"
            trace[key]=trace[key]+1
            return old(self,...)
        end
    end
    H.VisualTrace.wep=wep
end

function H.StopVisualTrace()
    local trace=assert(H.VisualTrace,"no visual trace")
    H.VisualTrace=nil
    if IsValid(trace.wep) then
        for method,old in pairs(trace.wrapped) do trace.wep[method]=old end
    end
    local images=trace.images
    trace.wep=nil; trace.wrapped=nil; trace.images=nil
    file.Write(root .. "results/" .. trace.name .. ".visual.json",util.TableToJSON(trace))
    if #images > 0 then
        local dir=root .. "shots/" .. trace.name
        file.CreateDir(dir)
        for i,data in ipairs(images) do file.Write(dir .. "/" .. string.format("%05d.jpg",i),data) end
    end
    print("[visual trace saved]",trace.name,#trace.records,#images)
end

hook.Add("PostRender","MCV_HarnessVisualCapture",function()
    local trace=H.VisualTrace
    if !trace or !trace.capture or #trace.images>=600 then return end
    local now=SysTime()
    if now < (trace.nextCapture or 0) then return end
    trace.nextCapture=now+1/20
    local data=render.Capture({format="jpeg",quality=75,x=0,y=0,w=ScrW(),h=ScrH(),alpha=false})
    if data then
        table.insert(trace.images,data)
        table.insert(trace.image_times,{time=now,frame=FrameNumber(),phase=H.VisualPhase})
    end
end)
