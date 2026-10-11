--[[---------------------------------------------------------------------------
    MCVPort template — SOUNDS (vanilla sound.Add declarations)

    Copy to:  lua/autorun/port_sounds_<yourclass>.lua

    This is the whole third step of the port workflow: plain sound.Add blocks,
    exactly like MCV's own sh_soundscript_*.lua files (reference/mcv/lua/mcv/
    shared/sh_soundscript_weapons.lua) and DHRB's hr_sounds.lua. No proprietary
    base is involved — GMod itself resolves these names.

    Point the weapon's flat sound slots at the names declared here:
        SoundSingleShot / SoundDoubleShot / SoundReload /
        SoundReloadThirdPerson / SoundReloadLoopThirdPerson /
        SoundCycleThirdPerson / SoundSpecial1 / SoundSpecial2 /
        SoundGrenadeShot / SoundNearlyEmpty / SoundEmpty
    and the same names work inside synthetic events:
        events = { reload = { { t = 0.9, sound = "PORT_X.MagIn" } } }

    sound.Add accepts ONLY these keys (docs/sound-system.md section 4):
        name, channel, volume, level, pitch, sound
    Everything else (attenuation, chance, position) is engine-side or must be
    done with EmitSound parameters at the call site.

    Field cheat sheet:
        channel  CHAN_WEAPON for shots, CHAN_AUTO for foley, CHAN_ITEM for
                 brass tinkles; one channel = later sounds cut earlier ones
        volume   0..1
        level    sound level in dB; 140 carries like a gunshot, 70 is foley
        pitch    number or {min, max} random window
        sound    one path or a list of paths (picked at random);
                 prefix a path with ")" to disable DSP (outdoor crispness)
-----------------------------------------------------------------------------]]

if SERVER then AddCSLuaFile() end
if PORT_SOUNDS_TEMPLATE then return end -- copy guard per addon; rename it

sound.Add({
    name = "PORT_Pistol.Single",
    channel = CHAN_WEAPON,
    volume = 1.0,
    level = 140,
    pitch = { 98, 102 },
    sound = {
        ")port/weapons/pistol/fire_01.wav",
        ")port/weapons/pistol/fire_02.wav",
        ")port/weapons/pistol/fire_03.wav",
    }
})

sound.Add({
    name = "PORT_Pistol.ReloadThirdPerson",
    channel = CHAN_AUTO,
    volume = 0.9,
    level = 70,
    pitch = { 97, 103 },
    sound = {
        "port/weapons/pistol/reload_01.wav",
        "port/weapons/pistol/reload_02.wav",
    }
})

sound.Add({
    name = "PORT_Generic.ClipEmpty_03",
    channel = CHAN_AUTO,
    volume = 0.7,
    level = 65,
    pitch = 100,
    sound = { "port/weapons/generic/clipempty_03.wav" }
})

sound.Add({
    name = "PORT_Generic.NearlyEmptyClick_Pistol",
    channel = CHAN_AUTO,
    volume = 0.6,
    level = 60,
    pitch = { 95, 105 },
    sound = { "port/weapons/generic/nearlyempty_pistol.wav" }
})
