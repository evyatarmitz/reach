# TODO — Reach

New project, split from To Infinity (2026-07-02). This game is genuinely novel — almost
nothing from the old codebase transfers directly, because the old build assumed an
embodied player and direct entity control, and Reach has neither.

## Border collision / deformation — IMPLEMENTED in 0.8.0 (spec kept for reference)

STATUS: built as specced below. Resolution of the open same-system question: went
with reading (a) — same-system colonies stay non-stacking (system_influence = max),
and only different systems ADD (friction). The field naturally does this because
sources are per-system system_influence values. Fog of war (0.9.0) gates where the
border is visible. Remaining polish: marching-squares smoothing (edge is blocky at
cell resolution), fragment-shader upgrade if the CPU grid ever hitches.

Original spec ↓

Current influence is wrong per the user: bubbles just grow and OVERLAP. They must
instead **collide and deform** — an empire's influence fills free space up to a
contested border, and where two empires meet the border is *pushed* to the point
where distance-from-source ratio reflects influence ratio.

How bubbles interact (user clarification 2026-07-02):
- Each source's bubble grows to its OWN individual reach radius (A2·i). Range never
  adds — combining influence changes push (friction) at a contested border, never how
  far a bubble reaches.
- Two FRIENDLY bubbles touching → just overlap, same empire owns the union, no border,
  no color change, no calc.
- Two HOSTILE bubbles touching → border calc (the r1/r2=i1/i2 rule below).
- A further friendly bubble reaching that same hostile border → 2v1: the two friendly
  sources' influences ADD against the single hostile one, pushing the border. This
  "adding" is friction at the contested front, gated by each bubble actually reaching
  the point.
- KEY: these are not separate code paths — they all emerge from one field calc (see
  processing approach). Do NOT implement as collision-event detection ("two bubbles
  touched → make a border → third arrived → switch to 2v1"); that's the version that
  IS too complicated. The field read gives all three for free.

Core rule (matches vision's contested formula):
- Border between source 1 and source 2 sits where **r1/r2 = i1/i2** (r = distance
  from source to the border point). Equivalently r1/i1 = r2/i2 → each point belongs
  to the source with the smaller r/i (i.e. the larger claim i/r). This is a
  multiplicatively-weighted (Apollonius) Voronoi boundary.

Multi-source merge (an empire with several sources pushing one border region):
- combined influence  i1 = Σ i_k  (sum of contributing sources)
- combined distance    r1 = Σ(r_k · i_k) / Σ i_k  (influence-weighted mean distance)
- then use r1/i1 in the ratio rule above.

OPEN QUESTION (user to confirm; proceeding on the first reading meanwhile):
"if in same system i1=i11+i12" — does "same system" mean (a) the same EMPIRE's set of
sources merged for a border, regardless of star system [LEANING: yes — the weighted-
mean r formula is pointless for co-located sources, so it's meant for sources at
different positions; and this preserves the "spread out within a system" pillar], or
(b) literally two colonies in the same STAR system now SUM influence [this would
override the 0.4.0 non-stacking rule and weaken the spread-within pillar]?

PROCESSING APPROACH (user asked per-point vs integral; recommendation = field sample):
- Represent influence as a scalar field; assign each point to the max-claim empire
  (per-empire effective (i,r) via the merge rule above, claim = i/r, only among
  sources whose reach A2·i covers the point; points beyond all reach = neutral).
  The deformed border is just where the argmax changes (marching-squares for a smooth
  line, or draw differing cell edges).
- Start with a coarse CPU grid (cells × empires × sources — cheap); upgrade the
  per-cell function to a fragment shader if resolution/perf demands. Trivially handles
  any number of sources/empires.
- Do NOT trace border curves analytically or integrate: closed-form Apollonius is only
  clean for two single sources; the merge rule + N empires make the curve arrangement
  fiddly. Sampling sidesteps all of it.
- Keep the existing analytic per-system claim (sim.claim_strength/system_owner) for
  discrete LOGIC queries (who owns system X, can I colonize/mine here) — exact at the
  system center and cheap. Two representations: analytic for logic, sampled field for
  the visual border + "is this free-space point mine." Prereq for going bigger than
  one screen: camera pan/zoom (not built yet).

## Status — through 0.22.0 (2026-07-02, Godot 4.7)

**81 headless test assertions, all passing.** Batch 0.19.0–0.22.0:
- **0.19.0** Pacing (GROWTH_RATE 0.01→0.004 so the first center stops ballooning
  past expansion); fleet icon drawn above the system (system stays clickable);
  borders drawn side-by-side at a seam (each empire's curve nudged into its own
  side) instead of overlapping.
- **0.20.0** Topology VR: visibility follows the SYSTEMS you hold (full VR) + a
  one-lane-jump partial ring, not a raw influence radius. Fleets grant full VR at
  their system + partial one jump. (Fixes the "VR expands with influence value"
  bug; retreat already worked.)
- **0.21.0** Fleet merge (strengths add) / split (halve). Build is repeatable.
- **0.22.0** Clicking a system opens a planet-LIST side menu (galaxy stays up); no
  more orbital view. Fleet selection shows a fleet panel with merge/split.
- Neighbor bonus "showed 0": not a bug — it's 0 only with all colonies in one
  system; the pacing fix lets multi-system expansion happen so it shows (+11% seen).

STILL CORE-MISSING (correcting "all systems implemented"): the anti-snowball COMBAT
pillar is only half done — bombardment exists, but fleet-vs-fleet combat,
percentage-of-strength attrition, and the hard ship-power ceiling do NOT. Those are
core design pillars, not content. Everything economic/spatial is largely in.

VISION features not yet built (content + the combat tail): observation post, supply
depot, transportation infra; construction/civ vessel to build structures (instead of
instant press) — vision says construction vessels can't cross borders; national vs
civilian resource split + higher-tier production needing resource VARIETY; cosmic
anomalies blocking influence+visibility. Balance knobs still open: influence reach
(A2·pop) scaling, mine richness vs conversion capacity (T0 stockpiles balloon).

## Status — through 0.18.0 (2026-07-02, Godot 4.7)

Batch 0.13.0–0.18.0:
- **0.13.0** Neighbor bonus recomputed as Σ A·influence/R (A=0.1) — reward for being
  near a major center; multiplicative on growth; growth retuned (base ~1%, softcap
  ~2000 so a lone colony flattens there but the bonus carries a cluster past it).
- **0.14.0** Encourage-immigration toggle — a colony sheds 0.1%/tick to the empire's
  other colonies, shifting population/influence where it matters.
- **0.15.0** Variable mine richness (25–65/day, per-deposit, hidden) — planet view
  shows an estimate band before building, actual output after.
- **0.16.0** Procedural map — density-heatmap scatter, MST-guaranteed connectivity,
  N empires (default 4), seeded/deterministic, all knobs in default_map_config for
  future game-settings.
- **0.17.0** Fog rework: three states (live / gray-explored-with-stale-data / black
  never-seen), VR rides ~1.5× the actual border, half-lanes into the fog; plus the
  border-curve fix (bubble-vs-empty edges now draw).
- **0.18.0** Fleets — build at a shipyard (alloys), lane-only movement (BFS path),
  bombardment kills/destroys enemy colonies parked over. Foundation + bombardment;
  fleet-vs-fleet combat + attrition + ship-ceiling are the next combat pass.

**OPEN BALANCE ISSUE (needs a design decision):** influence reach = A2·pop is linear
over a ~13× pop range (150→2000+), so a mature colony's reach (~3600) exceeds the map
and one big colony "reaches" everywhere, making fog/borders coarse. Options: sublinear
reach, lower pop ceiling, bigger map, or a reach cap — a design call, deferred per
"tune after testing". Also: mine richness >> city conversion capacity, so raw T0
stockpiles balloon (another tuning knob).

## Status — through 0.12.0 (2026-07-02, Godot 4.7)

The economic + spatial foundation is built, tested, and playable. Both core design
pillars are in and covered by tests. Build/run: `run.bat`, or `godot --path desktop`.
Tests: `godot --headless --path desktop --script res://tests/run_tests.gd` (after a
one-time `--import`). Visual: `godot --path desktop -- --autoshot`. **61 headless
test assertions, all passing** (economy suite rewritten for the resource model).

Recent batch (0.10.0–0.12.0):
- **0.10.0** Two-tier resource economy. Two T0 (water, minerals) from two deposit
  types (same mine); established cities refine water→food, minerals→alloys (partial
  if input-limited). Population is food-driven, empire-wide: end-of-tick food balance
  >0 grow / =0 steady / <0 SHRINK (pops can decrease now — fixed the "empty stockpile
  but pop climbing" bug). Alloys pay for colonies+mines. Food ceiling emerges from
  sublinear conversion capacity vs linear demand + mine throughput (homeworld ~500 pop
  on one water mine vs old unbounded ~3900).
- **0.11.0** Fog: sight = 1.5× a colony's influence reach (scales with strength;
  mines a flat sensor range), and unseen space is fully DARK (black bg, seen area lit,
  unseen systems/lanes not drawn) — not a grey map.
- **0.12.0** Border is a smooth marching-squares CURVE (per-empire margin zero-contour,
  interpolated), player's colour on top at the seam. Not a staircase.
- 0.9.1 (earlier): fixed a border-recompute stall that froze mouse input.

Done so far (one commit each, 0.1.0 → 0.9.0):
- **0.1.0** Colony lifecycle: founding (flat cost) → drain phase → activation at a pop
  threshold → tapering upkeep → tier-1 production. Growth uses a power-law
  diminishing-returns curve (uncapped, only asymptotically flattening). Real-time
  speed dial (pause/1x/3x/10x, space+number keys). Fixed-size deterministic ticks.
- **0.2.0** Deposits + mines (only raw income) + input-consuming production
  (throughput-limited — anti-snowball pillar #1).
- **0.3.0** Multi-system galaxy: 7 systems, 10 lanes, galaxy view ↔ per-system view.
- **0.4.0** Empires + influence: influence=A1·pop (non-stacking, max per system),
  reach=A2·influence, contested border at the influence-ratio point (live, moves on
  outgrowth). Colonizing/mining are influence-gated.
- **0.5.0** Neighbor bonus: cross-system established centers boost growth, 1/R,
  compounding. Same-system gives nothing. This is the "cluster across systems" half
  of the core tension (the "spread within a system" half is non-stacking influence).
- **0.6.0** AI rival empire — plays through the *same* command methods and gating as
  the player, deterministic, expands on a day-cadence. Demo has a red rival on the
  far side; the border between the two empires is live and unscripted.
- **0.7.0** 50-system map (deterministic 10×5 grid, generated names) + camera
  pan/zoom (right-drag/wheel in galaxy, locked in system view) + slower pacing
  (growth 0.02, clock 0.4 days/s).
- **0.8.0** Deformed influence borders: influence is a sampled scalar field; where
  hostile bubbles overlap the border sits at r1/r2=i1/i2, friendly sources ADD
  (friction) across systems, range never adds (reach-gated), same-system stays
  non-stacking. Drawn as a bold two-colour edge (each empire's frontier in its
  colour), on a 0.3s-refreshed CPU grid.
- **0.9.0** Fog of war: player sees within SIGHT_RANGE of presence (colony/mine),
  separate from influence. Unseen systems dim to "unknown", borders only drawn where
  seen, selection gated to sensor range, faint vision discs mark the seen area. AI
  is full-info for now.

Architecture as built: sim core in `desktop/sim/` is pure engine-free GDScript
(`sim.gd` orchestrates; `empire.gd`/`star_system.gd`/`planet.gd`/`colony.gd` are
state; `empire_ai.gd` is a rival brain; `constants.gd` holds all tunables). The
Godot layer is just `desktop/game/main.gd` — it reads sim state, draws, forwards
input, and knows no game rules. Swapping engines = rewriting only main.gd.

Deliberate limitations / open design calls (not bugs):
- No combat yet — bombardment, attrition, ship-power ceiling (build-order step 10).
  Borders are currently pure influence; nothing can kill population.
- Starved colonies stall but don't decline (vision doesn't specify decline outside
  bombardment — decide alongside combat).
- Goods have no sink yet (no military/higher-tier consumers).
- Resources are single-type "raw" — no national/civilian split, no resource-type
  variety gating (build-order steps 3 tail, 8).
- Balance note: with A2=1.8 a colony's influence bubble grows large as population
  climbs; a lone empire can blanket a wide region. This is faithful to the formula
  and the check on it is rival contest + growth flattening, not a smaller bubble —
  but it wants a real playtest pass once combat exists to confirm it feels right.
- Border render is blocky at cell resolution (marching-squares smoothing later) and
  recomputed on a 0.3s CPU-grid timer (fragment-shader upgrade if it hitches).
- Fog is a soft dim, not a hard pixel overlay (shader later); unseen systems can't be
  opened; no "explored-but-stale" memory yet (unseen = unknown live state).
- AI empires are full-info (fog is player-only) — revisit if AI should scout.

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

1. ~~System/planet/lane topology data model~~ ✅ 0.3.0
2. ~~Colony founding + established-activation curve~~ ✅ 0.1.0
3. Basic resource mining structure ✅ 0.2.0 / tier-0→tier-1+ conversion chain
   ✅ 0.2.0 (still single-type; multi-type variety gating is step 8)
4. ~~Population growth curve with per-colony diminishing returns~~ ✅ 0.1.0
5. ~~Influence bubble (non-stacking)~~ ✅ 0.4.0
6. ~~Neighbor bonus (1/R, compounding, established centers)~~ ✅ 0.5.0
7. **Specialization** (resource-type bonus, inertia on change, partial propagation
   via neighbor bonus) — NEXT
8. **National vs. civilian resource split**, tier-gated resource-type requirements
9. ~~Border contest resolution~~ ✅ 0.4.0 (per-system) + ✅ 0.8.0 (deformed field
   borders, r1/r2=i1/i2 with friendly friction-add)
10. **Combat**: pop-killing bombardment, percentage-of-strength attrition with grace
    period, ship-tier power ceiling, throughput-limited production (throughput limit
    ✅ 0.2.0). The big remaining pillar — makes borders more than influence.
11. **Support structures**: observation post (extends the SIGHT_RANGE added in 0.9.0,
    doubles influence), supply depot, transportation (strengthens the neighbor bonus —
    hook noted in constants.gd).
12. **Cosmic anomalies** blocking influence + visibility (visibility/fog now exists as
    of 0.9.0, so anomalies have something to block).

Also done outside the numbered list: 50-system map + camera pan/zoom (0.7.0),
fog of war / player sight range (0.9.0).

Suggested next session order: 7 (specialization) or 8 (resource split) are low-risk
economic depth; 10 (combat) is the highest-value remaining pillar but the largest —
it needs ships, lane movement, and the attrition/ceiling math, so budget for it.

## Decisions made (2026-07-02, with user)

- **Tech stack: Godot 4 (GDScript), as a prototype stack.** User dislikes webapps;
  choice was between web-stack and Godot, Godot chosen. Explicitly provisional — the
  engine may be replaced later, so the sim core is a pure, engine-free module (no
  Node/rendering imports) that Godot only renders and feeds input to. That split is
  non-negotiable (see PROTOCOLS.md architecture principles).
- **Real-time with a speed dial, not turn-based.** Boring stretches → player speeds
  up time. Slow mechanics are allowed to be slow.
- **Multiplayer later, single-player first.** Rivals are AI empires on exactly the
  same rules/code paths as the player. No player-only special cases, but also no
  multiplayer infrastructure before a single-player release.
- **Border/influence formulas restored to vision.md** (they'd been lost in
  iteration): influence = A1×pop_count; uncontested border_length = A2×influence;
  contested border1/border2 = influence1/influence2. The 1/R falloff belongs to the
  neighbor bonus only, not the border math.

## Immediate priorities (next session)

1. Pick up at build-order step 7 (specialization) or 8 (resource split) for
   low-risk economic depth, or commit to step 10 (combat) as the next real pillar.
2. All core constants in `constants.gd` are still placeholders ("tune until it feels
   right"): GROWTH_RATE/SOFTCAP/EXP, INFLUENCE_A1, BORDER_A2, NEIGHBOR_COEF,
   GOODS_RAW_PER_GOOD, activation/upkeep values, AI cadence. The test suite locks the
   *shapes*, not the numbers — a playtest/tuning pass is worthwhile before combat.
3. When combat lands, revisit the two open design calls: (a) can starved populations
   decline, and (b) does the influence bubble need reining in, or does rival pressure
   handle it.

## Pinned notes

- No physical player body, ever, in this game — that's an intentional, permanent
  departure from the shared "always embodied" principle, not a gap to fill later.
- No hard population cap, anywhere in the design. The ceiling must always emerge from
  the interaction of diminishing returns + map geometry, never from a designed number.
