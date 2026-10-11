local combine = {
    "npc/combine_soldier/pain1.wav",
    "npc/combine_soldier/pain2.wav",
    "npc/combine_soldier/pain3.wav",
}
local voices = {
    npc_zombie = "Zombie.Pain",
    npc_zombie_torso = "Zombie.Pain",
    npc_fastzombie = "NPC_FastZombie.Pain",
    npc_fastzombie_torso = "NPC_FastZombie.Pain",
    npc_poisonzombie = "NPC_PoisonZombie.Pain",
    npc_zombine = "Zombine.Pain",
    npc_combine_s = combine,
    npc_metropolice = "NPC_MetroPolice.Pain",
    npc_vortigaunt = "npc/vort/vort_pain3.wav",
    npc_antlion = "NPC_Antlion.Pain",
    npc_headcrab = "NPC_HeadCrab.Pain",
    npc_headcrab_fast = "NPC_FastHeadcrab.Pain",
    npc_headcrab_poison = "NPC_BlackHeadcrab.Pain",
    npc_headcrab_black = "NPC_BlackHeadcrab.Pain",
}
local classifications = {
    [CLASS_ZOMBIE] = "Zombie.Pain",
    [CLASS_COMBINE] = combine,
    [CLASS_METROPOLICE] = "NPC_MetroPolice.Pain",
    [CLASS_VORTIGAUNT] = voices.npc_vortigaunt,
    [CLASS_ANTLION] = voices.npc_antlion,
    [CLASS_HEADCRAB] = voices.npc_headcrab,
}

local function resolve(voice)
    if voice == false or voice == "male" or voice == "female" then return voice end
    if isstring(voice) then
        local properties = sound.GetProperties(voice)
        voice = properties and properties.sound or voice
        if isstring(voice) then voice = {voice} end
    end
    if istable(voice) and #voice > 0 then return voice end
    return false
end

return function(victim)
    local override = DHR.RunHook("HRExecutionVoice", victim)
    if override ~= nil then return resolve(override) end

    if victim:IsNPC() then
        local voice = voices[victim:GetClass()] or classifications[victim:Classify()]
        if voice then return resolve(voice) end
    end
    if victim:GetBloodColor() ~= BLOOD_COLOR_RED then return false end

    local model = string.lower(victim:GetModel() or "")
    return (model:find("female", 1, true) or model:find("fcultist", 1, true)
        or model:find("alyx", 1, true) or model:find("mossman", 1, true)) and "female" or "male"
end
