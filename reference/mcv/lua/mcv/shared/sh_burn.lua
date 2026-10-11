// Fire damage over time without Entity:Ignite(): the engine's entity_flame takes over the
// damage attribution, cannot be shortened and drops its own fire sprite on the model. This keeps
// a burn timer per entity, deals DMG_BURN in ticks the way the M202's fire does, and plays the
// game's own burning-character particle on the victim.
MCV = MCV or {}

MCV.BurnTickRate = 0.25
MCV.BurnParticle = "burning_character"

local burning = {}

function MCV.IsBurning(ent)
    return IsValid(ent) and (ent.MCV_BurnEnd or 0) > CurTime()
end

// Sets or extends a burn: `seconds` of `dps` damage per second, credited to attacker /
// inflictor. Water puts it out. Server only.
function MCV.Burn(ent, seconds, attacker, inflictor, dps)
    if CLIENT or !IsValid(ent) then return end
    if !(ent:IsPlayer() or ent:IsNPC() or ent:IsNextBot() or ent:GetClass() == "prop_physics") then return end
    if ent:IsPlayer() and !ent:Alive() then return end
    if ent:WaterLevel() >= 2 then return end

    local was = MCV.IsBurning(ent)
    ent.MCV_BurnEnd = math.max(ent.MCV_BurnEnd or 0, CurTime() + seconds)
    ent.MCV_BurnDPS = math.max(was and ent.MCV_BurnDPS or 0, dps or 10)
    ent.MCV_BurnAttacker = IsValid(attacker) and attacker or ent.MCV_BurnAttacker
    ent.MCV_BurnInflictor = IsValid(inflictor) and inflictor or ent.MCV_BurnInflictor
    burning[ent] = true

    if !was then
        ParticleEffectAttach(MCV.BurnParticle, PATTACH_ABSORIGIN_FOLLOW, ent, 0)
        ent:EmitSound("ambient/fire/fire_small_loop2.wav", 75, 100, 0.7, CHAN_STATIC)
        ent.MCV_BurnNextTick = CurTime()
    end
end

function MCV.Extinguish(ent)
    if CLIENT or !IsValid(ent) then return end
    ent.MCV_BurnEnd = 0
    burning[ent] = nil
    if ent.StopParticlesWithNameAndAttachment then
        ent:StopParticlesWithNameAndAttachment(MCV.BurnParticle, 0)
    else
        ent:StopParticles()
    end
    ent:StopSound("ambient/fire/fire_small_loop2.wav")
end

if SERVER then
    hook.Add("Think", "mcv_burn", function()
        local now = CurTime()
        for ent in pairs(burning) do
            if !IsValid(ent) then
                burning[ent] = nil
                continue
            end
            if now >= ent.MCV_BurnEnd or ent:WaterLevel() >= 2 or (ent:IsPlayer() and !ent:Alive()) then
                MCV.Extinguish(ent)
                continue
            end
            if now < (ent.MCV_BurnNextTick or 0) then continue end
            ent.MCV_BurnNextTick = now + MCV.BurnTickRate

            local attacker = IsValid(ent.MCV_BurnAttacker) and ent.MCV_BurnAttacker or game.GetWorld()
            local inflictor = IsValid(ent.MCV_BurnInflictor) and ent.MCV_BurnInflictor or attacker
            local dmg = DamageInfo()
            dmg:SetDamage(ent.MCV_BurnDPS * MCV.BurnTickRate)
            dmg:SetDamageType(DMG_BURN)
            dmg:SetAttacker(attacker)
            dmg:SetInflictor(inflictor)
            dmg:SetDamagePosition(ent:WorldSpaceCenter())
            ent:TakeDamageInfo(dmg)
        end
    end)

    hook.Add("PlayerDeath", "mcv_burn", function(ply) MCV.Extinguish(ply) end)
    hook.Add("PlayerSpawn", "mcv_burn", function(ply) MCV.Extinguish(ply) end)
end
