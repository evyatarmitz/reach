# AI Notes Index — Reach

Working notes written by Claude across sessions. Not for users — for continuity
between AI sessions on this specific game.

## Where the code lives (as of 0.6.0)

- `desktop/sim/` — the simulation core, pure engine-free GDScript. `sim.gd` is the
  orchestrator + public command API (found_colony, build_mine, influence/border math,
  tick); `empire.gd`, `star_system.gd`, `planet.gd`, `colony.gd` are state;
  `empire_ai.gd` is a rival brain that uses the same public API; `constants.gd` holds
  every tunable. **Never import Godot rendering/Node here** — the engine is swappable.
- `desktop/game/main.gd` — the only Godot-facing file: reads sim state, draws the
  galaxy/system views, camera pan/zoom, the sampled deformed-border field, and fog
  of war. Forwards input. Knows no game rules.
- `desktop/tests/run_tests.gd` — 79 headless test assertions. Run:
  `godot --headless --path desktop --script res://tests/run_tests.gd`.
- `run.bat` — launches the game (finds the winget Godot).

Key sim entry points: `point_owner`/`empire_claim_at` (deformed-border influence
field), `system_owner`/`claim_strength` (per-system logic queries), `sight_positions`/
`is_point_visible` (fog), `neighbor_growth_multiplier`, `found_colony`/`build_mine`
(the shared player+AI command API).

## Files

- [TODO.md](TODO.md) — Active tasks, what to build next
- [../refrences/vision.md](../refrences/vision.md) — Founding vision, non-negotiable
  for this game specifically. Read first, every session. This game has no methods/tips
  file yet — nothing from the old codebase directly applies, it's genuinely new design.
- [../refrences/PROTOCOLS.md](../refrences/PROTOCOLS.md) — Decision/implementation/
  test/bug protocols
- [../refrences/Spatial_Modularity_Mandate.txt](../refrences/Spatial_Modularity_Mandate.txt)
  — CommsBus, LayoutValidator, data-driven topology rules (the topology-graph parts of
  this — lanes, chokepoints — are directly relevant to Reach's lane-based movement)
- [../refrences/npc_system.txt](../refrences/npc_system.txt) — Full NPC design spec.
  Likely NOT directly applicable — Reach has no embodied individuals, population is
  abstract. Keep for reference in case indirect population modeling wants to borrow
  concepts, but don't assume it transfers.

## Inherited historical note

- [FEATURE_DESIGN.md](FEATURE_DESIGN.md) — the full feature analysis (X4/Stellaris/NMS/
  etc.) that produced the three-game split. Reach's slice is distilled in vision.md.
  Kept here as origin context only — most of this list describes the embodied, direct-
  control games (Legend/WWS), NOT Reach. The code-state notes (GAPS/DECISIONS) were
  deliberately NOT copied here because Reach inherits no code from the old build.

## How to use these

At the start of any session, read `CLAUDE.md` in this game's root first — it bootstraps
everything else. Then scan this index and read whichever notes are relevant to the
planned work. Update TODO.md before the session ends.
