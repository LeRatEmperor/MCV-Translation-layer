local function surface(effect, pos, normal)
    local body = effect.Body
    if not IsValid(body) then return pos, normal end
    body:SetupBones()
    local nearest, distance, basis, low, high, localPos
    for _, box in ipairs(effect.Hitboxes) do
        local matrix = body:GetBoneMatrix(box.bone)
        local inverse = matrix and matrix:GetInverse()
        if inverse then
            local point = inverse * pos
            local bound = Vector(math.Clamp(point.x,box.low.x,box.high.x), math.Clamp(point.y,box.low.y,box.high.y), math.Clamp(point.z,box.low.z,box.high.z))
            local score = (matrix * bound):DistToSqr(pos) + point:DistToSqr((box.low+box.high)*0.5)*0.001
            if not distance or score < distance then
                nearest, distance, basis, low, high, localPos = bound, score, matrix, box.low, box.high, point
            end
        end
    end
    if not basis or distance > 100 then return pos, normal end
    local center = (low+high)*0.5
    local outward = basis * localPos - basis * center
    if outward:LengthSqr() < 0.001 then outward = normal else outward:Normalize() end
    local direction = normal:Dot(outward) > 0.25 and normal or outward
    local hit = util.IntersectRayWithOBB(pos+direction*32, -direction*64, basis:GetTranslation(), basis:GetAngles(), low, high)
    return hit and hit+direction*0.2 or basis*nearest, direction
end

local function position(effect)
    if not effect.Cue or not IsValid(effect.Driver) then return effect.Position, effect.Direction end
    local points = effect.Cue.points
    local frame = math.Clamp((CurTime() - effect.Start) / effect.Length, 0, 1) * (#points - 1)
    local index = math.floor(frame) + 1
    local a, b = points[index], points[math.min(index + 1, #points)]
    local fraction = frame - math.floor(frame)
    local localPos = LerpVector(fraction, Vector(a[1], a[2], a[3]), Vector(b[1], b[2], b[3]))
    local normal = LerpVector(fraction, Vector(a[4], a[5], a[6]), Vector(b[4], b[5], b[6]))
    normal:Rotate(effect.Driver:GetAngles())
    return surface(effect, effect.Driver:LocalToWorld(localPos), normal:GetNormalized())
end

function EFFECT:Spray(initial)
    local pos, normal = position(self)
    self.Emitter:SetPos(pos)
    if initial and IsValid(self.Body) and HRWounds then
        local kind = self.Index == 1 and 'burst' or self.Sharp and 'spatter' or 'smear'
        HRWounds.Add(self.Body, kind, pos, normal, math.Clamp(0.75 + 0.2 * (self.Intensity - 1), 0.6, 1.1))
    end
    local count = math.ceil((initial and 72 or 12) * self.Intensity)
    local owner = self.Owner
    for i = 1, count do
        local particle = self.Emitter:Add('effects/blood_core', pos + VectorRand() * 1.2)
        if particle then
            local streak = i % 4 == 0
            particle:SetVelocity(normal * math.Rand(90, 180) + VectorRand() * 85 + Vector(0, 0, 25))
            particle:SetDieTime(math.Rand(.7, 1.35))
            particle:SetStartAlpha(240)
            particle:SetEndAlpha(0)
            particle:SetStartSize(math.Rand(1, streak and 2.7 or 4.2))
            particle:SetEndSize(.25)
            if streak then particle:SetStartLength(math.Rand(5, 11)); particle:SetEndLength(1) end
            particle:SetColor(175, 16, 10)
            particle:SetGravity(Vector(0, 0, -500))
            particle:SetAirResistance(35)
            particle:SetCollide(true)
            particle:SetBounce(0)
            if (initial and i <= 8) or (not initial and i <= 2) then
                particle:SetCollideCallback(function(drop, hit, facing)
                    util.Decal('Blood', hit + facing, hit - facing, IsValid(owner) and owner or nil)
                    drop:SetDieTime(0)
                end)
            end
        end
    end
    for i = 1, initial and 8 or 2 do
        local particle = self.Emitter:Add('effects/blood_puff', pos)
        if particle then
            particle:SetVelocity(normal * math.Rand(45, 85) + VectorRand() * 30)
            particle:SetDieTime(math.Rand(.4, .7))
            particle:SetStartAlpha(initial and 200 or 135)
            particle:SetEndAlpha(0)
            particle:SetStartSize(math.Rand(3, 6))
            particle:SetEndSize(math.Rand(12, 19))
            particle:SetRoll(math.Rand(0, 6.28))
            particle:SetColor(155, 14, 9)
            particle:SetAirResistance(65)
        end
    end
end

function EFFECT:Init(data)
    self.Position, self.Direction = data:GetOrigin(), data:GetNormal()
    local weapon = data:GetEntity()
    local profile = IsValid(weapon) and HRExecutions and HRExecutions.Profile(weapon)
    self.Cue = profile and profile.blood_effects and profile.blood_effects[data:GetAttachment()]
    self.Driver = IsValid(weapon) and weapon:GetNW2Entity('hr_execution_driver')
    self.Body = IsValid(weapon) and weapon:GetNW2Entity('hr_execution_body')
    local owner = IsValid(weapon) and weapon:GetOwner()
    self.Owner = IsValid(owner) and owner or nil
    self.Index = data:GetAttachment()
    self.Sharp = not (IsValid(weapon) and weapon.HR and weapon.HR.sharp == false)
    self.Hitboxes = {}
    if IsValid(self.Body) then
        local set = self.Body:GetHitboxSet()
        for i=0,(self.Body:GetHitBoxCount(set) or 0)-1 do
            local bone = self.Body:GetHitBoxBone(i,set)
            local name = self.Body:GetBoneName(bone)
            if string.find(name,'Head',1,true) or string.find(name,'Neck',1,true) or string.find(name,'Spine',1,true) then
                local low, high = self.Body:GetHitBoxBounds(i,set)
                self.Hitboxes[#self.Hitboxes+1] = {bone=bone,low=low,high=high}
            end
        end
    end
    self.Start = IsValid(weapon) and weapon:GetNW2Float('hr_execution_start') or CurTime()
    self.Length = profile and profile.length or 1
    self.Intensity = math.Clamp(self.Cue and self.Cue.intensity or 1, .5, 2.5)
    self.EndTime = self.Cue and self.Cue.stream and math.min(self.Start + self.Cue.time + self.Cue.duration, self.Start + self.Length) or CurTime()+0.32
    self.NextSpray = CurTime() + .07
    self.Emitter = ParticleEmitter(self.Position)
    if self.Emitter then self:Spray(true) end
end

function EFFECT:Think()
    if not self.Emitter then return false end
    if CurTime() >= self.EndTime or not IsValid(self.Driver) then
        self.Emitter:Finish()
        self.Emitter = nil
        return false
    end
    if CurTime() >= self.NextSpray then
        self:Spray(false)
        self.NextSpray = CurTime() + .07
    end
    return true
end

function EFFECT:Render() end
