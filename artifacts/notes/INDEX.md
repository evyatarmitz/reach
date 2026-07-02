# AI Notes Index — Reach

Working notes written by Claude across sessions. Not for users — for continuity
between AI sessions on this specific game.

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
