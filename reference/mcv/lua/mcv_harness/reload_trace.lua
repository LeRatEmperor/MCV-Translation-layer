// Explicit, local harness instrumentation. Never included by the addon loader.
if !CLIENT or !file.Exists("mcv_harness/enable.txt","DATA") then return end
MCV.ReloadHarness=MCV.ReloadHarness or {}
local H=MCV.ReloadHarness
local port=GetConVar("hostport"):GetInt()
local root=port==27015 and "mcv_harness/" or "mcv_harness/p"..port.."/"

function H.Start(name,third)
    assert(!H.trace,"reload trace already active")
    local ply=LocalPlayer()
    local wep=ply:GetActiveWeapon()
    local vm=ply:GetViewModel()
    H.trace={name=name,weapon=wep:GetClass(),wep=wep,old=wep.PlayAnimation,
             animations={},sounds={},third=third}
    wep.PlayAnimation=function(self,act,...)
        local predicted=GetPredictionPlayer()==ply
        local cmd=predicted and ply:GetCurrentCommand()
        local r={act=act,cmd=cmd and cmd:CommandNumber(),first=IsFirstTimePredicted(),
            ct=CurTime(),frame=FrameNumber(),before_seq=vm:GetSequence(),before_cycle=vm:GetCycle(),
            before_parity=vm:GetInternalVariable("m_nAnimationParity"),
            before_animtime=vm:GetInternalVariable("m_flAnimTime")}
        local ret=H.trace.old(self,act,...)
        r.seq=vm:GetSequence(); r.seqname=vm:GetSequenceName(r.seq)
        r.cycle=vm:GetCycle(); r.parity=vm:GetInternalVariable("m_nAnimationParity")
        r.animtime=vm:GetInternalVariable("m_flAnimTime")
        r.duration=ret; r.lock=self:GetAnimLockTime(); r.clip=self:Clip1()
        table.insert(H.trace.animations,r)
        return ret
    end
    if third then
        hook.Add("ShouldDrawLocalPlayer","MCV_ReloadProbeThird",function() return true end)
        hook.Add("CalcView","MCV_ReloadProbeThird",function(ply,pos,ang,fov)
            return {origin=pos-ang:Forward()*110+ang:Right()*30,angles=ang,fov=fov,drawviewer=true}
        end)
    end
    hook.Add("EntityEmitSound","MCV_ReloadProbeSound",function(data)
        local name=(data.OriginalSoundName or "").." "..(data.SoundName or "")
        if !name:lower():find("reload") then return end
        if data.Entity!=ply and data.Entity!=wep and data.Entity!=vm then return end
        table.insert(H.trace.sounds,{name=name,first=IsFirstTimePredicted(),
            ct=CurTime(),frame=FrameNumber(),predicting=GetPredictionPlayer()==ply})
    end)
end

function H.Stop()
    local trace=assert(H.trace,"no reload trace")
    trace.wep.PlayAnimation=trace.old
    trace.wep=nil; trace.old=nil
    H.trace=nil
    hook.Remove("ShouldDrawLocalPlayer","MCV_ReloadProbeThird")
    hook.Remove("CalcView","MCV_ReloadProbeThird")
    hook.Remove("EntityEmitSound","MCV_ReloadProbeSound")
    file.Write(root.."results/"..trace.name..".reload.json",util.TableToJSON(trace))
end
