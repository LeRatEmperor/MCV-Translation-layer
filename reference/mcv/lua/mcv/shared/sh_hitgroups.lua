function MCV.CancelBodyDamage(ent, dmginfo, hitgroup)
    local tbl = MCV.CancelMultipliers[string.lower(engine.ActiveGamemode())] or MCV.CancelMultipliers[1]

    if IsValid(ent) and (ent:IsNPC() or ent:IsPlayer()) then
        dmginfo:ScaleDamage(1 / (tbl[hitgroup] or 1))
    end

    -- Lambda Players call ScalePlayerDamage and cancel out hitgroup damage... except on the head
    if IsValid(ent) and ent.IsLambdaPlayer and hitgroup == HITGROUP_HEAD then
        dmginfo:ScaleDamage(1 / (tbl[hitgroup] or 1))
    end

    return dmginfo
end