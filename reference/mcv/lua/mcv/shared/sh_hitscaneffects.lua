// Hitscan effects belong to the firing callback, not a second engine impact hook.
function MCV.HitscanEffects(wep, tr, damage, tracer, noRicochet)
    if CLIENT and !game.SinglePlayer() and !IsFirstTimePredicted() then return end
    local owner = wep:GetOwner()
    local recipients = true
    if SERVER then
        recipients = RecipientFilter()
        recipients:AddPVS(tr.StartPos)
        recipients:AddPVS(tr.HitPos)
        // The shooter already emitted the first predicted command's effects.
        // NPCs and singleplayer have no such client firing callback.
        if !game.SinglePlayer() and IsValid(owner) and owner:IsPlayer() then
            recipients:RemovePlayer(owner)
        end
    end
    local tracerRecipients = recipients
    local showTracer = tracer > 0
    if showTracer and wep.TracerParticle == "vietnam_tracer_silenced_primary" then
        if SERVER then
            // MP players predict their own trail. Only SP needs server delivery;
            // NPC trails have no shooter client. Impacts still use the full PVS.
            showTracer = game.SinglePlayer() and IsValid(owner) and owner:IsPlayer()
            if showTracer then
                tracerRecipients = RecipientFilter()
                tracerRecipients:AddPlayer(owner)
            end
        else
            showTracer = IsValid(owner) and owner == LocalPlayer()
        end
    end
    if showTracer then
        local fx = EffectData()
        fx:SetEntity(wep)
        fx:SetStart(tr.StartPos)
        fx:SetOrigin(tr.HitPos)
        util.Effect("mcv_tracer", fx, true, tracerRecipients)
    end
    local ricochet = !noRicochet and showTracer and MCV.HasTracerStreak(wep.TracerParticle)
        and wep:Clip1() % math.max(wep.TracerFrequency or 1, 1) == 0
    MCV.BulletImpact(tr, damage, recipients, ricochet,
        ricochet and MCV.TracerColor(owner, wep.TracerParticle) or nil)
end
