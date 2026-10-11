MCV.FIREMODE_AUTO = 0
MCV.FIREMODE_SEMI = 1
MCV.FIREMODE_BURST = 2
MCV.FIREMODE_SA = 3
MCV.FIREMODE_DA = 4
MCV.FIREMODE_FAN = 5
MCV.FIREMODE_BOLT = 6
MCV.FIREMODE_PUMP = 7
MCV.FIREMODE_FAST = 8
MCV.FIREMODE_SLOW = 9
MCV.FIREMODE_VOLLEY = 10
MCV.FIREMODE_HE = 11
MCV.FIREMODE_BUCKSHOT = 12

// Bounded overlap per weapon: recordings can have 60-100 ms of mechanism before
// the report. Replacing them every shot cuts that report out on fast automatics.
// Four slots per layer preserve the attack without CHAN_STATIC's unbounded tails.
MCV.SHOT_SOUND_SLOTS = 4
MCV.CHAN_SHOT = CHAN_USER_BASE
MCV.CHAN_SHOT_DISTANT = CHAN_USER_BASE + MCV.SHOT_SOUND_SLOTS

MCV.FiremodeAmmo = {
    [MCV.FIREMODE_HE] = "smg1_grenade",
    [MCV.FIREMODE_BUCKSHOT] = "buckshot",
}


MCV.FiremodeNames = {
    [MCV.FIREMODE_AUTO] = "Automatic",
    [MCV.FIREMODE_SEMI] = "Single-Fire",
    [MCV.FIREMODE_BURST] = "3-Round Burst",
    [MCV.FIREMODE_SA] = "Single-Action",
    [MCV.FIREMODE_DA] = "Double-Action",
    [MCV.FIREMODE_FAN] = "Fan Fire",
    [MCV.FIREMODE_BOLT] = "Bolt-Action",
    [MCV.FIREMODE_PUMP] = "Pump-Action",
	[MCV.FIREMODE_FAST] = "Fast-Fire",
	[MCV.FIREMODE_SLOW] = "Slow-Fire",
    [MCV.FIREMODE_VOLLEY] = "Volley",
    [MCV.FIREMODE_HE] = "HE",
    [MCV.FIREMODE_BUCKSHOT] = "Buckshot"
}

MCV.CancelMultipliers = {
    [1] = {
        [HITGROUP_HEAD]     = 2,
        [HITGROUP_LEFTARM]  = 0.25,
        [HITGROUP_RIGHTARM] = 0.25,
        [HITGROUP_LEFTLEG]  = 0.25,
        [HITGROUP_RIGHTLEG] = 0.25,
        [HITGROUP_GEAR]     = 0.25,
    },
    ["terrortown"] = {
        [HITGROUP_HEAD]     = 1,
        [HITGROUP_LEFTARM]  = 0.55,
        [HITGROUP_RIGHTARM] = 0.55,
        [HITGROUP_LEFTLEG]  = 0.55,
        [HITGROUP_RIGHTLEG] = 0.55,
        [HITGROUP_GEAR]     = 0.55,
    },
}


// Ammo types for equipment, named after the game's primary_ammo values. Registered on both
// realms at load so weapons can use them in Primary.Ammo.
MCV.AmmoTypes = {"mcv_grenade", "mcv_molotov", "mcv_mine", "mcv_explosive_charge", "mcv_flamethrower_fuel",
                 "mcv_crossbowbolt", "mcv_flareround", "mcv_ammobox", "mcv_medicbox", "mcv_flame_cartridge"}

for _, name in ipairs(MCV.AmmoTypes) do
    game.AddAmmoType({
        name = name,
        dmgtype = DMG_GENERIC,
        tracer = TRACER_NONE,
        plydmg = 0,
        npcdmg = 0,
        force = 0,
        minsplash = 0,
        maxsplash = 0,
    })
end

MCV.ShellTypes = {
    [1] = {
        Model = "models/weapons/shells/shell_762x39sov.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [2] = {
        Model = "models/weapons/shells/shell_12g.mdl",
        Sound = "MCV_Bounce.ShotgunShell"
    },
    [3] = {
        Model = "models/weapons/shells/shell_145x114.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [4] = {
        Model = "models/weapons/shells/shell_556x45n.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [5] = {
        Model = "models/weapons/shells/shell_762x25t.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [6] = {
        Model = "models/weapons/shells/shell_762x38mmr.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [7] = {
        Model = "models/weapons/shells/shell_762x51n.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [8] = {
        Model = "models/weapons/shells/shell_762x54mmr.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [9] = {
        Model = "models/weapons/shells/shell_792x33ku.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [10] = {
        Model = "models/weapons/shells/shell_792x57ma.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [11] = {
        Model = "models/weapons/shells/shell_9x18m.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [12] = {
        Model = "models/weapons/shells/shell_9x19.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [13] = {
        Model = "models/weapons/shells/shell_flare.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [14] = {
        Model = "models/weapons/shells/shell_gren.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [15] = {
        Model = "models/weapons/shells/shell_x22lr.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [16] = {
        Model = "models/weapons/shells/shell_x30-06.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [17] = {
        Model = "models/weapons/shells/shell_x30.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [18] = {
        Model = "models/weapons/shells/shell_x45apc.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [19] = {
        Model = "models/weapons/shells/shell_x50bmg.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [20] = {
        Model = "models/weapons/shells/lmg_chain_m60.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [21] = {
        Model = "models/weapons/shells/lmg_chain_rp46.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [22] = {
        Model = "models/weapons/shells/lmg_chain_rpd.mdl",
        Sound = "MCV_Bounce.Shell"
    },
    [23] = {
        Model = "models/weapons/shells/lmg_chain_stoner63.mdl",
        Sound = "MCV_Bounce.Shell"
    },
}
