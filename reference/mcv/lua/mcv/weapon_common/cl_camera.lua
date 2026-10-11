SWEP.SmoothedMagnification = 1

function SWEP:CalcView(ply, pos, ang, fov)
    local rec = (self:GetLastRecoilTime() + self.ShakeDuration) - CurTime()

    rec = math.max(rec, 0) * self.ShakeScale

    if rec > 0 then
        ang.r = ang.r + (math.sin(CurTime() * self.ShakeFreq) * rec)
    end

    local mag = Lerp(self:GetSightAmountVisual() ^ 3, 1, 90 / self:GetZoomMagnification())

    local realistic = MCV.RealisticShooting()

    if realistic then
        // the view pulls back a little as a burst goes on
        mag = mag + (0.15 * (1 / ((self:GetBurstCount() / 25) + 1))) - 0.15
    end

    local diff = math.abs(self.SmoothedMagnification - mag)

    self.SmoothedMagnification = math.Approach(self.SmoothedMagnification, mag, FrameTime() * diff * (self.SmoothedMagnification > mag and 10 or 5))

    fov = fov / self.SmoothedMagnification

    self.LastFOV = fov

    fov = fov - rec

    if realistic then
        // most of the punch comes back out of the picture: the kick moves the aim, not the camera
        ang = ang - (ply:GetViewPunchAngles() * 0.75)
    end

    // GetViewModelPosition needs the actual rendered camera, including recoil
    // suppression and the final zoom/shake FOV, rather than the owner's base FOV.
    self.ViewmodelCameraAngle = Angle(ang.p, ang.y, ang.r)
    self.ViewmodelCameraFOV = fov
    self.ViewmodelCameraFrame = FrameNumber()
    return pos, ang, fov
end

function SWEP:GetLookMagnification()
    return 90 / self:GetZoomMagnification()
end

function SWEP:AdjustMouseSensitivity()
    local mag = Lerp(self:GetSightAmountVisual() ^ 3, 1, self:GetLookMagnification())
    return 1 / mag
end
