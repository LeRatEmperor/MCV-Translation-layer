# MCV-Translation-layer

A translation layer that lets Garry's Mod SWEPs written for **other weapon bases** — weapons
that animate through engine activities and sequence-name calls — run perfectly on the
**Military Conflict Vietnam (MCV)** weapon base by the Arctic team.

## Repository Structure

| Path | Contents |
|------|----------|
| [`docs/`](docs/README.md) | **The MCV base audit** — 11 exhaustive system documents (~12,800 lines) with verbatim excerpts, `file:line` citations, and ranked translation-seam analysis. Start at [`docs/README.md`](docs/README.md). |
| [`docs/translation-layer-spec.md`](docs/translation-layer-spec.md) | **The translation layer design** — architecture, the two-homes rule, `MCV.Define` schema, animation roles, synthetic events, hooks. |
| [`lua/`](lua/) | **MCVPort, the translation layer runtime** — `MCV.Define`, the animation role bridges, synthetic timeline events, the hook runner, the `mcvport_gun` base. |
| [`templates/`](templates/) | **Port templates** — pistol, assault rifle, shotgun, sniper, bolt-action, sounds. Copy, fill in the TODOs, done. |
| `reference/mcv/` | Read-only copy of the upstream base (`tacrp/Military-Conflict--Vietnam-SWEPs` @ `06f4a24b`) — the audited source of truth, including upstream's own `AGENTS.md`, `BUGLIST.md`, `weapon_list.md`. |
| `reference/dhrb/` | Read-only example files from Dandy's Hellraiser Base — the `DHR.Define` organizational pattern this layer borrows (cited by the spec). |

## Key Audit Findings

- MCV bypasses the engine activity state machine entirely: discrete actions go through a
  single Lua choke point (`PlayAnimation`/`PlaySequence`), continuous state is carried by
  pose parameters written every frame, and the viewmodel timeline is reconstructed clientside
  from NetworkVars.
- The translation target is the weapon-definition schema (~313 fields) plus a fixed shared
  datatable that derived bases must not redefine.
- The full consolidated seam list lives in [`docs/README.md`](docs/README.md#master-translation-seam-list).

## The Translation Layer

Ports are **full rewrites with a clean cut**: decompile the original mod, fill in a
template gun, port the sounds into plain `sound.Add` files — the result depends on the MCV
base and this layer only. Flat MCV fields carry everything MCV consumes natively; the
`MCV.Define` table carries only translational data (animation roles for models that don't
speak MCV's activities, synthetic timeline events, custom-mechanics hooks). See
[`docs/translation-layer-spec.md`](docs/translation-layer-spec.md) and
[`templates/README.md`](templates/README.md) for the workflow.
