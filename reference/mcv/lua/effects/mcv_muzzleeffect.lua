function EFFECT:Init(data)
    local wpn = data:GetEntity()

    if !IsValid(wpn) then self:Remove() return end
    local owner = wpn:GetOwner()
    if !IsValid(owner) or wpn:IsDormant() or owner:IsDormant() then self:Remove() return end

    local muzzle = {wpn.MuzzleParticle, wpn.MuzzleParticleSmoke}

    local att = data:GetAttachment() or 1

    local wm = false

    if (LocalPlayer():ShouldDrawLocalPlayer() or owner != LocalPlayer()) then
        wm = true
    end

    local parent = wpn

    if !wm then
        parent = LocalPlayer():GetViewModel()

        if wpn:GetSightAmount() >= 1 then
            muzzle = {wpn.MuzzleParticleIronsighted, wpn.MuzzleParticleIronsightedSmoke}
        end
    else
        // the world model drawn by hand (cl_worldmodel.lua): its muzzle is where the gun is;
        // magnitude 1 marks the left-hand gun of a dual
        parent = wpn.GetWorldModelFor and wpn:GetWorldModelFor(data:GetMagnitude() >= 0.5) or wpn
        att = parent:LookupAttachment("muzzle")
        if att <= 0 then att = 1 end
        muzzle = wpn.MuzzleParticle3rdPerson
    end

    if !IsValid(parent) then self:Remove() return end

    if muzzle then
        if !istable(muzzle) then
            muzzle = {muzzle}
        end

        for _, muzzleeffect in ipairs(muzzle) do
            if muzzleeffect == "" then continue end // Crossbows/launchers can have no flash.
            local pcf = CreateParticleSystem(parent, muzzleeffect, PATTACH_POINT_FOLLOW, att)

            if IsValid(pcf) then
                pcf:StartEmission()

                if !wm then
                    // Viewmodel particles are drawn manually in SWEP:PostDrawViewModel
                    pcf:SetShouldDraw(false)
                    table.insert(wpn.PCFs, pcf)
                end
            end
        end
    end
end

function EFFECT:Think()
    return false
end

function EFFECT:Render()
    return false
end
