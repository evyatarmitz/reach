# Asset Standard & Sourcing — Reach

Status: **not started — deliberately deferred.** Per the 2026-07-02 asset-sourcing pass,
Reach's assets come later than Legend's and WWS's. This is a placeholder capturing what's
different about Reach's needs so the eventual pass doesn't just copy the embodied games'
list.

## Why Reach's asset needs are different

Reach is a top-down, indirect-control map game with **no physical player body and no
walking-around 3D**. It does NOT need the ship-interior, character/crew, first-person, or
detailed-hull assets the embodied games (Legend, WWS) need. Reach mostly needs:

- Clean, readable **UI / iconography** (colony states, resource types, influence
  overlays, border/lane rendering, building types) — legibility at a glance is the whole
  game, so UI art matters more here than model detail.
- Simple **top-down ship/station markers** — likely stylized icons or very low-poly
  tokens, not detailed hulls. A fleet is a number and a marker, not a walkable vessel.
- **Map/space backdrop** — starfield, nebula, system nodes. Poly Haven HDRIs or simple
  procedural backgrounds likely suffice.

## Standard (inherits the shared rules)

Same license/IP rules as the embodied games — see `wws/artifacts/refrences/ASSETS.md` for
the full standard. Short version: **CC0 preferred, CC-BY with tracked attribution OK,
nothing ripped from commercial games, no fan-made copyrighted-IP designs.**

Format note: stack decided 2026-07-02 — Godot 4, top-down 2D (prototype stack, engine
may change; see TODO.md). Asset targets are therefore vector/sprite/icon sets (Kenney
has extensive CC0 UI and icon packs) rather than glTF models. Prefer SVG/PNG sources
that survive an engine swap.

## Sources (same verified CC0 set)

Kenney (kenney.nl — esp. their UI/icon packs), Quaternius, Poly Haven, OpenGameArt (CC0
filter), awesome-cc0 (github.com/madjin/awesome-cc0), itch.io CC0 tag. See the WWS
ASSETS.md for details on each.
