--[[---------------------------------------------------------------------------
    MCVPort — sound declarations for port_nmrih_1911 (Colt M1911, TFA NMRiH)

    Plain vanilla sound.Add blocks, exactly like MCV's own
    sh_soundscript_*.lua files — GMod itself resolves these names, no base is
    involved. The weapon's flat slots and synthetic events reference them:

        SoundSingleShot   -> PORT_1911.Single
        reload events     -> PORT_1911.MagOut / MagIn / SlideRelease

    ⚠ PATH VERIFICATION (one-time, five minutes):
    The wav paths below are best-guess NMRiH layouts ("weapons/1911/...").
    The TFA repack may have re-rooted them (e.g. under "tfa_nmrih/...").
    Open the decompiled mod's sound/ folder, find the 1911 fire set and the
    mag / slide foley, and correct the paths to match. The SCRIPT NAMES are
    ours and final — only the paths need checking.

    sound.Add accepts ONLY: name, channel, volume, level, pitch, sound
    (docs/sound-system.md section 4). Prefixing a path with ")" disables DSP
    for that sample (outdoor crispness on gunshots).
-----------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end
if PORT_SOUNDS_NMRIH_1911 then return end
PORT_SOUNDS_NMRIH_1911 = true

sound.Add({
    name = "PORT_1911.Single",
    channel = CHAN_WEAPON,
    volume = 1.0,
    level = 140,
    pitch = { 95, 105 },
    sound = {
        ")weapons/1911/fire01.wav", -- TODO verify paths against the decompile
        ")weapons/1911/fire02.wav",
        ")weapons/1911/fire03.wav",
    }
})

sound.Add({
    name = "PORT_1911.MagOut",
    channel = CHAN_ITEM,
    volume = 0.9,
    level = 70,
    pitch = { 97, 103 },
    sound = {
        "weapons/1911/magout.wav", -- TODO verify
    }
})

sound.Add({
    name = "PORT_1911.MagIn",
    channel = CHAN_ITEM,
    volume = 0.9,
    level = 70,
    pitch = { 97, 103 },
    sound = {
        "weapons/1911/magin.wav", -- TODO verify
    }
})

sound.Add({
    name = "PORT_1911.SlideRelease",
    channel = CHAN_ITEM,
    volume = 1.0,
    level = 75,
    pitch = { 98, 102 },
    sound = {
        "weapons/1911/sliderelease.wav", -- TODO verify
    }
})

-- Optional fidelity swap (judgment call 11 in the weapon file): once the
-- decompile's dry-fire wav is located, declare this and point the weapon's
-- fire_empty event at it instead of GMod's built-in "Default.ClipEmpty".
--[[
sound.Add({
    name = "PORT_1911.Empty",
    channel = CHAN_ITEM,
    volume = 0.9,
    level = 65,
    pitch = 100,
    sound = {
        "weapons/1911/dryfire.wav", -- TODO verify
    }
})
]]
