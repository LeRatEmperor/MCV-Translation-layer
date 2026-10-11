# MCV-Translation-layer

A translation layer that lets Garry's Mod SWEPs written for **other weapon bases** — weapons
that animate through engine activities and sequence-name calls — run perfectly on the
**Military Conflict Vietnam (MCV)** weapon base by the Arctic team.

## Repository Structure

| Path | Contents |
|------|----------|
| [`docs/`](docs/README.md) | **The MCV base audit** — 11 exhaustive system documents (~12,800 lines) with verbatim excerpts, `file:line` citations, and ranked translation-seam analysis. Start at [`docs/README.md`](docs/README.md). |
| `reference/mcv/` | Read-only copy of the upstream base (`tacrp/Military-Conflict--Vietnam-SWEPs` @ `06f4a24b`) — the audited source of truth, including upstream's own `AGENTS.md`, `BUGLIST.md`, `weapon_list.md`. |

## Key Audit Findings

- MCV bypasses the engine activity state machine entirely: discrete actions go through a
  single Lua choke point (`PlayAnimation`/`PlaySequence`), continuous state is carried by
  pose parameters written every frame, and the viewmodel timeline is reconstructed clientside
  from NetworkVars.
- The translation target is the weapon-definition schema (~313 fields) plus a fixed shared
  datatable that derived bases must not redefine.
- The full consolidated seam list lives in [`docs/README.md`](docs/README.md#master-translation-seam-list).

The translation layer implementation itself will be built on top of this documentation.
