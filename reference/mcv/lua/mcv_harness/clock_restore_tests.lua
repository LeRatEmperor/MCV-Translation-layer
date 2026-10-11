if not SERVER then return end
local ply = player.GetHumans()[1]
local classes = {"mcv_m16a1", "mcv_m16a1_m203", "mcv_m37", "mcv_mk2", "mcv_c4", "mcv_wrench", "mcv_lpo50"}
local rows = {}
local deadlines = {"AnimLockTime","NextIdle","HolsterTime","DeferredTime","ActionStart","ActionEnd",
    "NextRepairTime","WindupEnd","HammerReleaseTime","AnimationStart"}
for _, class in ipairs(classes) do
    local w = ply:GetWeapon(class)
    if not IsValid(w) then w = ply:Give(class) end
    assert(IsValid(w),class)
    local before = {clip1=w:Clip1(),clip2=w:Clip2(),mode=w:GetFiremode(),scope=w:GetScopeLevel(),
        cycle=w:GetNeedCycle(),akimbo=w:GetAkimbo(),second=w:GetHasSecond(),launcher=w:GetGrenadeLauncher(),bayonet=w:GetBayonet(),
        reserve=ply:GetAmmoCount(w:GetPrimaryAmmoType())}
    local future = CurTime()+36000
    for _, name in ipairs(deadlines) do w["Set"..name](w,future) end
    w:SetNextPrimaryFire(future) w:SetNextSecondaryFire(future)
    w:SetDeferredAction(1) w:SetActionState(1) w:SetReloading(true)
    w:SetPrimedAttack(true) w:SetHolsterCommand(2000000) w:SetMoveCommand(2000000)
    w:SetLastRecoilTime(future) w:SetAnimationDuration(3)
    w:OnRestore()
    w:OnRestore() // repeated restoration must not grant ammo or replay an action
    assert(not w:StillWaiting() and w:GetNextSecondaryFire()<=CurTime(),class.." input locked")
    assert(not w:GetReloading() and not w:GetPrimedAttack() and w:GetActionState()==0,class.." action remains")
    assert(w:GetDeferredAction()==0 and w:GetHolsterCommand()==0 and w:GetMoveCommand()==0,class.." stale command")
    assert(w:GetAnimationDuration()==0 and w:GetLastRecoilTime()<CurTime(),class.." visual clock")
    for _, name in ipairs(deadlines) do assert(w["Get"..name](w)<=CurTime()+.001,class.." "..name) end
    assert(w:Clip1()==before.clip1 and w:Clip2()==before.clip2 and ply:GetAmmoCount(w:GetPrimaryAmmoType())==before.reserve,class.." ammo changed")
    assert(w:GetFiremode()==before.mode and w:GetScopeLevel()==before.scope and w:GetNeedCycle()==before.cycle,class.." mode changed")
    assert(w:GetAkimbo()==before.akimbo and w:GetHasSecond()==before.second and w:GetGrenadeLauncher()==before.launcher and w:GetBayonet()==before.bayonet,class.." equipment changed")
    rows[#rows+1] = {class=class,ok=true}
end
file.Write("mcv_harness/p27016/results/clock_restore.json",util.TableToJSON({results=rows,ok=true},true))
print("[clock restore] seven weapon families passed")
