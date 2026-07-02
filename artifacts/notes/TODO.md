# TODO — Reach

New project, split from To Infinity (2026-07-02). This game is genuinely novel — almost
nothing from the old codebase transfers directly, because the old build assumed an
embodied player and direct entity control, and Reach has neither.

## Status

Nothing built yet. `desktop/` is empty. This is the starting point, and unlike Legend
and WWS, there isn't an existing Rust/Bevy foundation to lean on — the whole simulation
core (colony growth curves, influence-bubble math, neighbor-bonus propagation, border
contest resolution, attrition combat) needs to be designed and built from scratch.

## What MIGHT transfer, loosely

- The lane-based topology-graph concept from Spatial_Modularity_Mandate.txt (ships/
  civ-ships move only along lanes) — the underlying graph/pathfinding approach used
  for ship interiors in the old build (`nav.rs`'s A* waypoint graph) might generalize
  to system-to-system lanes, but this needs to be rebuilt for a completely different
  scale (star systems, not ship corridors), not ported.
- The old `sector_control.rs` (per-system faction influence 0-100, contested-state
  detection) is the closest existing analog to Reach's border-contest mechanic — worth
  reading for the general shape (influence values, contest threshold) even though
  Reach's actual math (relative-strength-weighted border position, not a simple
  contested flag) is more sophisticated and needs new implementation.

## Core systems to design and build, in rough dependency order

1. System/planet/lane topology data model — this underlies everything else
2. Colony founding + the established-activation curve (drain-that-tapers, then
   production switches on)
3. Basic resource mining structure + tier-0→tier-1+ conversion chain
4. Population growth curve with per-colony diminishing returns (power-law)
5. Influence bubble (non-stacking, defines where you can colonize) — separate from
6. Neighbor bonus (1/R falloff, compounding, from established centers)
7. Specialization (resource-type bonus, inertia on change, partial propagation via
   neighbor bonus)
8. National vs. civilian resource split, tier-gated resource-type requirements
9. Border contest resolution (relative-influence-weighted line position)
10. Combat: pop-killing bombardment, percentage-of-strength attrition with grace
    period, ship-tier power ceiling, throughput-limited production
11. Support structures: observation post, supply depot, transportation
12. Cosmic anomalies blocking influence + visibility

## Immediate priorities

1. Pin down the actual math for diminishing returns (power-law exponent), neighbor
   bonus falloff (1/R constant), and attrition percentage/grace-period — these were
   discussed as "tunable numbers, get playtested" in design conversation, not final
   values. Start with placeholder constants and expect to retune.
2. Build the smallest possible slice: one system, a few planets, one colony that can
   activate and produce tier-1 output. No combat, no borders, no neighbors yet.
3. Choose the tech stack — nothing forces Rust/Bevy here given there's no embodied
   player and no 3D walking-around requirement. A top-down 2D/UI-heavy stack might
   be a better fit and faster to iterate in. This is worth a real decision, not a
   default inheritance from the other two games.

## Pinned notes

- No physical player body, ever, in this game — that's an intentional, permanent
  departure from the shared "always embodied" principle, not a gap to fill later.
- No hard population cap, anywhere in the design. The ceiling must always emerge from
  the interaction of diminishing returns + map geometry, never from a designed number.
