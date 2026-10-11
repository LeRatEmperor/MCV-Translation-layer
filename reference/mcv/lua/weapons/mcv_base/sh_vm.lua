// Gun bodygroups and pose parameters (called from mcv/weapon_common/sh_vm.lua DoBodygroups
// with gameplay values from Think and visual values before render bone setup).
// The game's ammo_fraction is the magazine's fraction: the chambered round is not in it
// (the PPK's counter has a knot pair per magazine round and one for "all hidden"; the dual
// PPK's right gun with a single chambered round still showed a bullet in the magazine).
function SWEP:MagFraction(count, per)
    per = per or self.Primary.ClipSize
    if per <= 0 then return 0 end
    return math.Clamp(count - self.Primary.Chamber, 0, per) / per
end

function SWEP:DoBodygroupsWeapon(vm, visual, sa, speed)
    // Snapshot only this invocation. The next replay/render call reads restored
    // engine state again; none of these values live in an ordinary Lua cache.
    local reloading, clip, akimbo = self:GetReloading(), self:Clip1(), self:GetAkimbo()
    local now = visual and self:GetViewModelTime() or CurTime()
    local displayRoundsToLoad = reloading
    local magOut = false // the old magazine / belt is out and the new one not yet in

    // A round-at-a-time reload has no magazine to swap. Nothing leaves the gun and nothing waits
    // outside it to go in, so what the counter shows is simply what is loaded, and it only ever
    // goes up. Both of the states below describe a magazine mid-swap, and both were being
    // re-entered on every single insert, because each insert restarts the animation and with it
    // the progress they are timed against: the rounds already in the gun blinked out each time.
    if self.ShotgunReload then
        displayRoundsToLoad = false

    elseif displayRoundsToLoad then
        local reloadprogress = vm:SequenceDuration() - (self:GetAnimLockTime() - now)
        local empty = clip == 0
        local tin = empty and self.MagInTimeEmpty or self.MagInTime
        local tout = empty and self.MagOutTimeEmpty or self.MagOutTime

        displayRoundsToLoad = reloadprogress >= tin
        magOut = !displayRoundsToLoad and !self.MagInClip and tout > 0 and reloadprogress >= tout
    end

    local bodygroupbulletscount = clip
    local clipsize = self.Primary.ClipSize

    // A gun whose cycle animation moves the magazine on itself (the homemade pistol's harmonica:
    // the bolt pull slides it to the next chamber and throws the case at frame 42) keeps
    // showing the count from before the shot until the cycle's own refresh point
    // (CycleClipPoseTime, the game's AE_WPN_CLIP_TO_POSEPARAM at frame 55); shown earlier, the
    // next chamber looked empty the moment the shot went off
    local shown = clip
    // Clip-loaded pose selects how many rounds the hand carries in the insert animation.
    // Keep that selection while the actual ammo transfer waits for the insertion event.
    local pendingInsert = reloading and self.ReloadInsertTime and self:DeferPending("ReloadInsert")
    if pendingInsert then
        local reserve = self:GetInfiniteAmmo() and math.huge or self:Ammo1()
        shown = math.min(shown + math.min(self.ShotgunReloadRounds, reserve), self:GetClip1Capacity())
    end
    if self.CycleClipPoseTime and !reloading then
        // NeedCycle from the shot until the cycle starts, then the networked start time
        // (ActionStart, sh_think.lua) until the refresh point; a Lua-side start time differed
        // between the realms and the server's networked pose parameter fought the client's
        local cycling = self:GetNeedCycle()
        if !cycling and self:GetActionStart() > 0 then
            cycling = now < self:GetActionStart() + self.CycleClipPoseTime
        end
        if cycling then shown = math.min(shown + 1, clipsize) end
    end
    // A round fed in one at a time is counted the moment its animation starts, but the hand is
    // still carrying it to the port then, so the round appeared in the gun before it went in.
    // The model says when it is actually in, through the refresh event the game puts partway
    // through the insert; until then the counter holds the count from before this round.
    if self.ShotgunReload and self.InsertClipPoseTime and reloading then
        local insert = self.ShotgunAltReload and ACT_VM_RELOAD_INSERT or ACT_VM_RELOAD

        if vm:GetSequenceActivity(vm:GetSequence()) == insert
           and vm:SequenceDuration() - (self:GetAnimLockTime() - now) < self.InsertClipPoseTime then
            shown = math.max(shown - (self.ShotgunReloadRounds or 1), 0)
        end
    end

    // the cycle's variant is picked by the count after the shot (the game sets ammo_fraction2
    // from the clip at the bolt pull's first frame)
    if self.CycleAmmoPose2 then
        vm:SetPoseParameter("ammo_fraction2", self:MagFraction(clip, clipsize))
    end

    if akimbo then
        clipsize = clipsize * 2
    end

    if displayRoundsToLoad then
        // What the magazine on its way in is carrying, which is not yet what the gun holds. A
        // clip-fed rifle shows the clip emptying as its rounds go down into the receiver, so it
        // counts what is left to load; everything else shows the fresh magazine full.
        if self.MagInClip then
            local bullets_to_load = math.min(clipsize - clip, self:Ammo1())

            vm:SetPoseParameter("ammo_fraction", self:MagFraction(bullets_to_load, clipsize))
            bodygroupbulletscount = bullets_to_load
        else
            local reserve = self:GetInfiniteAmmo() and math.huge or (clip + self:Ammo1())
            local bullets_to_load = math.min(clipsize, self:GetClip1Capacity(), reserve)

            vm:SetPoseParameter("ammo_fraction", self:MagFraction(bullets_to_load, clipsize))
            bodygroupbulletscount = bullets_to_load
        end
    elseif magOut then
        vm:SetPoseParameter("ammo_fraction", 0)
        bodygroupbulletscount = 0
    else
        vm:SetPoseParameter("ammo_fraction", self:MagFraction(shown, clipsize))
        bodygroupbulletscount = shown
    end

    // Dual wield: the dual models show each gun's magazine through its own bullet counter,
    // blended on ammo_fraction1 (right gun) and ammo_fraction2 (left gun). The shared count
    // splits floor / ceil, since the right gun fires on an even count; a reload's per-gun
    // swap times (AkimboMagInTimes, from the dual model's next-clip events per activity: the
    // right magazine first, the left one later) hand each gun its new count on its own cue.
    if akimbo then
        local n = clip
        local right, left = math.floor(n / 2), math.ceil(n / 2)
        if reloading then
            local reserve = self:GetInfiniteAmmo() and math.huge or (n + self:Ammo1())
            local total = math.min(self:GetClip1Capacity(), reserve)
            local nright, nleft = math.floor(total / 2), math.ceil(total / 2)
            local times = self.AkimboMagInTimes and self.AkimboMagInTimes[vm:GetSequenceActivity(vm:GetSequence())]
            if times then
                local progress = vm:SequenceDuration() - (self:GetAnimLockTime() - now)
                if times[1] and progress >= times[1] then right = nright end
                if times[2] and progress >= times[2] then left = nleft end
            elseif displayRoundsToLoad then
                right, left = nright, nleft
            end
        end
        vm:SetPoseParameter("ammo_fraction1", self:MagFraction(right, self.Primary.ClipSize))
        vm:SetPoseParameter("ammo_fraction2", self:MagFraction(left, self.Primary.ClipSize))
    end

    if self.BulletBodygroups then
        // Keys are round-count thresholds, not list positions. Keep sparse thresholds
        // working while ignoring the BaseClass entry added by SWEP table inheritance.
        for i, bg in pairs(self.BulletBodygroups) do
            if isnumber(i) then
                if i > bodygroupbulletscount then
                    vm:SetBodygroup(bg[1], bg[2])
                else
                    vm:SetBodygroup(bg[1], 0)
                end
            end
        end
    end

    // the belt itself (the game's "clamped" groups, given a blank by port_qc) goes with the rounds
    if self.BeltBodygroups then
        for _, idx in ipairs(self.BeltBodygroups) do
            vm:SetBodygroup(idx, bodygroupbulletscount > 0 and 0 or 1)
        end
    end

    local shouldhammer = self:GetNeedCycle() or self:GetEmptyReload() or ((self.ShotgunReload or !reloading) and clip == 0)

    if self.InvertAnimationHammer then
        shouldhammer = !shouldhammer
    end

    vm:SetPoseParameter("hammerpos", shouldhammer and 0 or 1)

    // 1 = clip empty. The game's SlidePosition / BoltshootMovement layers blend towards the
    // locked-back bolt (and the non-cycling last shot) as this goes from 0.6 to 1. During an
    // empty reload it drops the moment the new magazine is in (MagInTimeEmpty), as the game
    // does at its NEXTCLIP event: held to the end, the layer kept the bolt back while the
    // animation closed it, and the bolt visibly closed and reopened (M14, XM21, M2, vz.58, MAS-49).
    local empty = ((pendingInsert and shown or clip) == 0 and !displayRoundsToLoad) and 1 or 0
    if akimbo and !displayRoundsToLoad then
        // the dual models' SlidePosition has three states: none, the right gun empty (it fires
        // first, so it runs dry first), both empty (knots at 0, 1/3-2/3, 1)
        local n = clip
        empty = n == 0 and 1 or (math.floor(n / 2) == 0 and 0.5 or 0)
    end
    vm:SetPoseParameter("empty", empty)

    vm:SetPoseParameter("ironsight", sa ^ 3)

    // Dual wield pose-driven recoil: 0 = frame 0 of the hand's shoot animation, 1 = at rest.
    if akimbo and self:HasPoseRecoil() then
        local len = math.max(self.AkimboRecoilTime, 0.01)
        vm:SetPoseParameter("recoil_r", math.Clamp((now - self:GetLastShotTimeR()) / len, 0, 1))
        vm:SetPoseParameter("recoil_l", math.Clamp((now - self:GetLastShotTimeL()) / len, 0, 1))
    end

    if self:GetBayonet() then
        vm:SetBodygroup(self.BayonetBodygroup, 1)
    else
        vm:SetBodygroup(self.BayonetBodygroup, 0)
    end

    if self:GetGrenadeLauncher() then
        vm:SetBodygroup(self.GrenadeLauncherBodygroup, 1)

        local reloadprogress = vm:SequenceDuration() - (self:GetAnimLockTime() - now)

        if self:Clip2() > 0 or (reloading and reloadprogress > self.MagInTimeGrenade) then
            vm:SetBodygroup(self.GrenadeBodygroup, 1)
        else
            vm:SetBodygroup(self.GrenadeBodygroup, 0)
        end
    else
        vm:SetBodygroup(self.GrenadeLauncherBodygroup, 0)
        vm:SetBodygroup(self.GrenadeBodygroup, 0)
    end

    if self.RevolverFiremodePose then
        local pose = 0

        local fm = self:GetFiremodeValue()

        if akimbo then
            if fm == MCV.FIREMODE_DA then
                pose = 1
            end
        else
            if fm == MCV.FIREMODE_FAN then
                pose = 1
            elseif fm == MCV.FIREMODE_DA then
                pose = 0.5
            end
        end

        vm:SetPoseParameter("revolver_firemode_pose", pose)
    end
end

// Keeps the muzzle flash light attached to the muzzle for the few frames it lives.
// Runs per rendered frame (not per tick) so the light does not lag behind the viewmodel.
function SWEP:UpdateMuzzleLight(vm)
    local lamp = self.MuzzleLight
    if !lamp then return end

    if !IsValid(lamp) or (self.MuzzleLightEnd or 0) < UnPredictedCurTime() then
        if IsValid(lamp) then lamp:Remove() end
        self.MuzzleLight = nil
        return
    end

    local att = vm:GetAttachment(1)
    if !att then return end

    lamp:SetPos(att.Pos)
    lamp:SetAngles(att.Ang)
    lamp:Update()
end

function SWEP:PreDrawViewModelWeapon(vm)
    self.RenderingRTScope = false
    if self:GetHolsterTime() < CurTime() then
        self:DoRTScope()
    end

    self:UpdateMuzzleLight(vm)
end

// Occluded eye gunsight: one eye sees the gun and the dot, the other the scene, and the brain
// overlays them. Drawn as the opaque viewmodel with a copy of the frame from before the
// viewmodel composited on top at OEGSceneAlpha, so the gun reads as one half-transparent
// plane instead of a blend of every face that showed its innards.
SWEP.OEGSceneAlpha = 0.5

// Own copy of the frame: the gun's Refract lens materials refresh _rt_FullFrameFB while the
// viewmodel draws, so a plain screen-effect copy ends up containing the gun.
local scenert = CLIENT and GetRenderTarget("mcv_oeg_scene", ScrW(), ScrH(), false)
local scenemat = CLIENT and CreateMaterial("mcv_oeg_scene", "UnlitGeneric", {
    ["$basetexture"] = scenert:GetName(),
    ["$vertexalpha"] = "1",
    ["$vertexcolor"] = "1",
})
if CLIENT then scenemat:SetTexture("$basetexture", scenert) end

function SWEP:PreDrawViewModelBlend(vm, sa)
    // the hooks run for all three viewmodels; only the gun's own pass gets the frame copy,
    // a later pass would copy the drawn gun and composite it over itself
    if vm != self:GetOwner():GetViewModel() then return end
    self.OEGComposite = false
    if self.OEGScope and sa > 0.216 then // 0.6 ^ 3
        render.CopyRenderTargetToTexture(scenert)
        self.OEGComposite = true
    end
end

function SWEP:PostDrawViewModelWeapon(vm)
    if self.RenderingRTScope then
        render.OverrideDepthEnable(false, false)
    end
    if !self.OEGComposite or vm != self:GetOwner():GetViewModel() then return end
    self.OEGComposite = false
    self:DrawOEGSceneComposite()
end

// Finish the normal OEG blend before the late scope layer captures its pixels.
function SWEP:DrawOEGSceneComposite()
    local a = Lerp(math.Clamp((self:GetSightAmountVisual() - 0.6) / 0.4, 0, 1), 0, self.OEGSceneAlpha)
    if a <= 0 then return end
    cam.Start2D()
        surface.SetMaterial(scenemat)
        surface.SetDrawColor(255, 255, 255, a * 255)
        surface.DrawTexturedRect(0, 0, ScrW(), ScrH())
    cam.End2D()
end
