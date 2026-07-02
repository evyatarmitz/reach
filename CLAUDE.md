# Reach — Session Bootstrap

Read this file, then follow the steps below before doing any work.

This project was split off from a shared origin ("To Infinity") on 2026-07-02, once it
became clear the original scope was actually three incompatible games glued together.
This folder is fully self-contained — it does not depend on, and should not reference,
its sibling projects (`../legend/`, `../wws/`). Treat it as its own product. Of the
three, this one is the most novel — almost nothing carries over from the parent
codebase, because the parent assumed an embodied player and direct entity control,
and this game has neither.

---

## Step 1: Read the vision

`artifacts/refrences/vision.md` — the founding, non-negotiable design intent for this
specific game. Read this in full before any other work. Summary, for orientation only
(the file is authoritative, not this summary):

- No direct control — you cultivate. No physical body, ever: a deliberate, permanent
  departure from the shared "always embodied" origin, not a gap to fill later.
- Top-down map. Population is the actual protagonist — you supply resources, issue
  directives, clear dangers; it grows and organizes on its own.
- Colonies drain resources until an activation threshold, then start producing.
- No hard population cap, ever — growth ceilings emerge from diminishing returns
  interacting with map geometry, never from a designed number.
- Core tension: same-system colonies don't stack influence (spread within a system);
  nearby systems boost each other (cluster across systems).
- Borders are a live contest resolved by relative influence strength, not fixed lines.
- No war won by one decisive fight — percentage-of-strength attrition, throughput-
  limited production, and a hard ship-power ceiling all independently prevent any
  single empire from steamrolling the map.
- Lane-based movement, construction vessels can't cross borders, anomalies block both
  influence and visibility.

## Step 2: Read your working notes

`artifacts/notes/INDEX.md` lists all AI working notes. Scan it, then read whichever
files are relevant to today's work. Update `TODO.md` before the session ends.

## Step 3: Know where everything lives

```
reach/
  desktop/            ← the actual game code (empty — this is a from-scratch build)
  artifacts/
    notes/            ← AI working notes — read INDEX.md, update before leaving
      INDEX.md
      TODO.md         ← no METHODS_AND_TIPS.md yet — nothing to port in
    refrences/        ← source material, not for casual editing
      vision.md                          ← THE founding document, non-negotiable
      PROTOCOLS.md                       ← decision/implementation/test/bug protocols
      Spatial_Modularity_Mandate.txt     ← relevant part: lane/topology-graph concepts
      npc_system.txt                     ← likely NOT applicable, kept for reference only
      AI_README.md                       ← how to use the spell-book (sb) CLI
```

---

## Protocols

Full detail in `artifacts/refrences/PROTOCOLS.md`. Summary:

- **Autonomy:** Fix bugs you find, make implementation choices, pick reasonable
  numbers — don't ask.
- **Stop and ask:** scope is 3× larger than implied, OR two conflicting design
  directions, OR a bug is unsolvable after deep analysis.
- **Commits:** one per feature/fix, message includes what changed + design choice if
  non-obvious.
- **Bugs:** 2 attempts → deep analysis → 1 targeted attempt → skip and document if
  still broken.
- **Tests:** plan what you're testing before running it; distinguish "test passed"
  from "feature works."

---

## Work pipeline (standing operating protocol)

This governs *how* to work, not *what* to build (that's `TODO.md` / `vision.md`).

### Rules

1. **Keep working** unless there's a continuance discussion in progress. Don't stop
   to ask when you can just proceed.
2. **Keep working** unless you need *urgent* input. Non-urgent questions/notes get
   written down (a note in `TODO.md`) and wait for the next conversation — don't
   block on them.
3. **Always adhere to workplace-culture directives** — e.g. the topology/lane
   concepts in the Spatial Modularity Mandate. Non-negotiable, not a style preference.
4. **Smarter, not harder.** Prefer the design that avoids future rework over the one
   that's fastest to type right now.
5. **Hard now is easier than hard later.** Pay down architecture debt immediately;
   don't defer foundational decisions to "make it work first." This matters more
   here than in the sibling projects — there's no existing engine to lean on, so
   early architecture choices (tech stack, data model for systems/lanes/colonies)
   set the ceiling for everything built after.
6. **Primary source of truth = this folder's `artifacts/`.** Before inventing a new
   mechanic, check `refrences/vision.md` first — the mechanics in it are specific
   and load-bearing (e.g. the exact shape of the border-contest formula, the
   non-stacking-bubble/neighbor-bonus tension). Don't drift from them without a
   documented reason.
7. **Always work according to PROTOCOLS.md** for safe, complete work.
8. **Judgment latitude on non-major systems** — trusted to decide what's best for
   the project on non-major-system calls. Judge those decisions against `vision.md`.
   There is no direct genre inspiration to lean on here (this game is intentionally
   novel) — when in doubt, favor whatever keeps population growth uncapped-but-
   self-limiting and combat un-snowballable, since those are the two design pillars
   everything else was built to protect.
9. **Always work down the priority list** below when free-working (no specific task
   assigned).

### Priority list (highest first)

1. **Currently-discussed implementation** — if a feature's architecture was just
   agreed on, implement immediately, or (with permission) add to `TODO.md` fully
   documented with the conversation's design decisions.
2. **Infrastructure** — things that would force a rewrite of other systems if built
   in the wrong order. Given this is a from-scratch build, this covers a lot: the
   system/lane data model, the colony-state model, and the tech-stack decision are
   all infrastructure-tier and should be settled before feature work starts.
3. **Major systems** — things that are bottlenecks blocking other features.
4. **TODO.md** — the given todo file, mostly pre-approved features.
5. **Judgment-call features** — things worth adopting based on vision fit.
6. **Polishing** — content creation, visual improvement, asset import, idea
   generation, value tuning/rebalancing.

### A note on numbers

Several core constants (diminishing-returns exponent, neighbor-bonus falloff rate,
attrition percentage and grace period) were explicitly discussed as "tune until it
feels right," not handed down as final values. Don't treat placeholder numbers found
anywhere as sacred — they exist to be playtested and adjusted, as long as the
*shape* of the mechanic (uncapped-but-self-limiting growth, unstoppable-empire-proof
combat) is preserved.

---

## Standing instruction

"just keep going till its done unless u need my input"

Implementation order: unblock blockers first, then most sensible coding order.
