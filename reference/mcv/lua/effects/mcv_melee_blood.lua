// The effect owns the particles, so a lethal hit/removal cannot cut them off.
function EFFECT:Init(data)
    local name = MCV.MeleeBloodParticles[data:GetColor()]
    if !name then return end
    local pos, normal = data:GetOrigin(), data:GetNormal()
    if normal:LengthSqr() < 0.5 then normal = vector_up end
    local ang = normal:Angle()
    self:SetPos(pos)
    self:SetAngles(ang)
    local ps = CreateParticleSystem(self, name, PATTACH_ABSORIGIN_FOLLOW, 0)
    if !IsValid(ps) then return end
    for cp = 0, 1 do
        ps:SetControlPoint(cp, pos)
        ps:SetControlPointOrientation(cp, ang:Forward(), ang:Right(), ang:Up())
    end
    // The original velocity initializers use CP2 as a vector, not a position.
    ps:SetControlPoint(2, vector_origin)
    ps:StartEmission()
    self.DieTime = CurTime() + 4
end

function EFFECT:Think()
    return self.DieTime != nil and CurTime() < self.DieTime
end

function EFFECT:Render() end
