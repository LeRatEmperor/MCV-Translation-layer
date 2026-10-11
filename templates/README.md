# MCVPort Templates

Copy these files to port a weapon onto the MCV base. They encapsulate the five
archetypes that cover MCV's main functional surface — everything else (bayonet,
bipod, rifle grenade, UBGL, akimbo...) is a mix-and-match block noted inside
the relevant template, applying to all of them.

| Template | Copy to | Archetype |
|---|---|---|
| `port_pistol.lua` | `lua/weapons/<yourclass>.lua` | semi-auto pistol, mag reload, optional akimbo / revolver notes |
| `port_assaultrifle.lua` | `lua/weapons/<yourclass>.lua` | select-fire rifle, bayonet / bipod / rifle-grenade blocks |
| `port_shotgun.lua` | `lua/weapons/<yourclass>.lua` | pump action, shell-by-shell reload |
| `port_sniper.lua` | `lua/weapons/<yourclass>.lua` | scoped, two-stage zoom, adjustable zero |
| `port_boltaction.lua` | `lua/weapons/<yourclass>.lua` | manual cycle, stripper clip |
| `port_sounds.lua` | `lua/autorun/port_sounds_<yourclass>.lua` | vanilla `sound.Add` declarations |

## The port workflow

1. **Decompile** the original mod (models, sounds, lua).
2. **Fill in a template** — copy it to `lua/weapons/<yourclass>.lua`, work
   through every `TODO`, write the port header comment (source, date, judgment
   calls), then set `SWEP.Spawnable = true`.
3. **Port the sounds** — copy `port_sounds.lua` to
   `lua/autorun/port_sounds_<yourclass>.lua`, declare every name the weapon's
   flat slots and synthetic events reference, and point the paths at the
   decompiled wavs.
4. **Done.** The weapon depends on the MCV base and this layer only.

## Reading order while porting

- `docs/translation-layer-spec.md` — how the layer works, the two-homes rule
- `docs/weapon-definitions.md` — the full flat-field catalogue
- `docs/animation-system.md` section 5 — the activity/sequence contract the
  `anims` roles translate
- `mcvport_report` in console — registration + resolution health

## Rules of thumb

- **Native first.** If a flat MCV field expresses it (timings, damage, sounds,
  particles), it stays a flat field. `MCV.Define` carries only translational
  data and custom mechanics.
- **Provenance lives in the header comment**, not in code.
- Foreign models run in *discrete mode*: every action plays its sequence, but
  MCV's blended continuous states (ironsight blend, ammo gauge, movement
  layers) need MCV-rigged pose parameters and no-op gracefully without them.
- Leave `AnimationHandlesHammer = false` on foreign bolt-actions — the native
  `true` path reads a generated table that only covers shipped MCV models.
