# Working on this addon

Military Conflict: Vietnam's weapons ported to Garry's Mod. `work/PORTING.md` is the long
reference for the porting pipeline; `BUGLIST.md` is the running log of what has been fixed.

The install is split by nation: this `mcv` folder is Part 1 (Eastern + all shared bases/code),
and sibling `../mcv-2` is Part 2 (Western content only, requires Part 1). Search both folders
for weapons/assets. Source and custom compile files remain under this folder's `work/`;
use `work/pack_paths.py` to resolve runtime destinations. See `work/pack_split/README.md`.

## Convars

Every convar the addon has must appear in the Q menu, under **Options > Military Conflict:
Vietnam**, so nothing has to be typed into the console. There are two pages there, **Server**
and **Client**, because the two kinds answer to different people: the server ones are replicated
and shared by everyone playing, the client ones are that player's own. Adding one is two steps:

1. Register it. Gameplay convars that both realms read go in `lua/mcv/shared/sh_convars.lua`
   through `MCV.RegisterConVar` (archived, replicated, notify) with an accessor beside it.
   A client's own preference is a `CreateClientConVar` in a file under `lua/mcv/client/`;
   pass `true` for userinfo where other players need to see the choice, as the tracer colour
   does. The effect preferences live together in `cl_effectsettings.lua` with an accessor each,
   so shared files that read them (`sh_effects.lua`) never have to guess at a convar name.
2. Add one entry to `SERVER_SETTINGS` or `CLIENT_SETTINGS` in `lua/mcv/client/cl_settings.lua`,
   whichever page it belongs on. An entry with `choices` is a dropdown, one with `slider` a
   number, anything else a checkbox; `section` starts a heading. Give every entry a `help`
   line saying what it does in plain words.

`lua/mcv/shared/sh_categories.lua` holds the per-category stat multipliers: one convar per
category and stat, `mcv_cat_<category>_<stat>`, all defaulting to 1. Adding a stat is an entry
in `MCV.CategoryStats` plus the one line in the weapon code that reads it through
`SWEP:StatMult`; adding a category is an entry in `MCV.Categories`. The menu builds its
dropdown and sliders from those two tables, so it needs nothing further. A stat marked
`projectile = true` is only shown for categories that hold a weapon which launches something,
worked out from the weapons themselves.

`MCV.CATEGORY_ALL` is a category in that same table but not one any weapon sits in: every
weapon reads it as well as its own, the two multiplying together, so a stat can be moved across
the board without setting nineteen of them. `MCV.CategoryMult` folds it in, so nothing calling
`SWEP:StatMult` has to know it exists.

A projectile's basic numbers, explosion damage, explosion radius and launch speed, belong to
the weapon that fires it, not to the entity: the entity has no category for a multiplier to
reach. The entity keeps them as defaults and `LaunchProjectile` overrides and scales them, the
way the thrown grenades and planted charges already work. A rifle grenade or underbarrel round
answers to `MCV.CATEGORY_RIFLE_GRENADE` rather than the host rifle's category.

Anything registering a convar through `MCV.RegisterConVar` must be loaded after
`sh_convars.lua`. The autorun loader takes the shared files in name order and loads that one
first for exactly this reason.

The `mcv_wm_*` convars are deliberately left out of the menu: they are for tuning world model
placement by hand against Crowbar and hold raw numbers, not settings anyone plays with.

## House rules

* Do not launch or run in-game verification unless the user explicitly requests it.
  Use file, syntax, dependency and archive build/extraction checks by default.
* Never regenerate a whole weapon lua to change a few fields. The generators drop hand-tuned
  keys (sights, secondaries, rifle-grenade keys, placement offsets). Copy the values you mean
  to change into the committed file instead.
* Hand-tuned iron sight offsets are the user's. `work/fix_sight_offsets.py` leaves them alone
  without `--sights`, and the generator reuses whatever the lua already has. Do not sweep them.
* Stage files explicitly when committing. `git add -A lua` has swept the user's uncommitted
  work into unrelated commits more than once, and a `git checkout` across `lua/weapons` has
  destroyed hand tuning that was never committed. Stash first if the tree has to be cleaned.
* Check Lua with `python work/glua_check.py "lua/weapons/*.lua" "../mcv-2/lua/weapons/*.lua"` after editing; there is no
  luac on this machine and the checker translates GLua before compiling it.
* Write patch scripts with the file tool rather than shell heredocs, which mangle backslashes
  in regular expressions.
* Models only load when Garry's Mod starts. A Lua change needs a map change; a recompiled model
  needs a full restart. Say which in the report.
