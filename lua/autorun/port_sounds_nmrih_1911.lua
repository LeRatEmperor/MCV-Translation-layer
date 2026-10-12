--[[---------------------------------------------------------------------------
    MCVPort — sound declarations for port_nmrih_1911 (Colt M1911, TFA NMRiH)

    Two sound worlds, one file:

    TODAY (works with the TFA NMRiH pack mounted)
    ---------------------------------------------------------------
    The weapon references the NMRiH soundscript names directly —
    "Weapon_1911.Single" for the shot, and the model's own 5004 animation
    events fire "Weapon_1911.clipout / clipin / SlideBack / SlideForward"
    during the reload sequences with the QC's exact frame timing. Those
    names are defined by the TFA pack (its lua or scripts/game_sounds txt
    mount into GMod's sound system), so everything is audible while the
    pack stays mounted. This file deliberately does NOT declare those
    names: a sound.Add under the same name would replace the pack's
    working definition, and our wav paths are not verified yet.

    LATER (severing from the source mod completely)
    ---------------------------------------------------------------
    1. Open the decompiled pack's sound folder and the game_sounds entries
       for the names above; note the wavs they point at (the fire set plus
       the mag / slide foley).
    2. Copy those wavs into this addon at sound/port/nmrih/1911/ and fix
       the paths in the PORT_1911.* declarations below.
    3. Swap the weapon's SoundSingleShot slot to "PORT_1911.Single" and set
       foley = "synthetic" in its MCV.Define, enabling the timed events
       block in the weapon file (same QC timings as the 5004 events).
    4. The TFA pack can then be unmounted — this addon is self-contained.

    sound.Add accepts ONLY: name, channel, volume, level, pitch, sound
    (docs/sound-system.md section 4). Prefixing a path with ")" disables
    DSP for that sample (outdoor crispness on gunshots).
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
        ")port/nmrih/1911/fire_01.wav", -- TODO verify paths against the decompile
        ")port/nmrih/1911/fire_02.wav",
        ")port/nmrih/1911/fire_03.wav",
    }
})

sound.Add({
    name = "PORT_1911.MagOut",
    channel = CHAN_ITEM,
    volume = 0.9,
    level = 70,
    pitch = { 97, 103 },
    sound = {
        "port/nmrih/1911/magout.wav", -- TODO verify (Weapon_1911.clipout)
    }
})

sound.Add({
    name = "PORT_1911.MagIn",
    channel = CHAN_ITEM,
    volume = 0.9,
    level = 70,
    pitch = { 97, 103 },
    sound = {
        "port/nmrih/1911/magin.wav", -- TODO verify (Weapon_1911.clipin)
    }
})

sound.Add({
    name = "PORT_1911.SlideBack",
    channel = CHAN_ITEM,
    volume = 1.0,
    level = 75,
    pitch = { 98, 102 },
    sound = {
        "port/nmrih/1911/slideback.wav", -- TODO verify (Weapon_1911.SlideBack)
    }
})

sound.Add({
    name = "PORT_1911.SlideForward",
    channel = CHAN_ITEM,
    volume = 1.0,
    level = 75,
    pitch = { 98, 102 },
    sound = {
        "port/nmrih/1911/slideforward.wav", -- TODO verify (Weapon_1911.SlideForward)
    }
})
