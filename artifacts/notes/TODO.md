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

## Status — 0.81.0 (2026-08-21, Godot 4.7) — tier icons + anomaly spread (playtest)

- **Anomalies now spread across the map.** `_place_anomalies` checked clearance from
  systems and lanes but NOT from other anomalies, so they clumped into one open region.
  Added an inter-anomaly minimum separation (~grid spacing of `target` points over the
  map) + more attempts. Probe (3 seeds): closest pair ~500, span most of the map width.
- **Tier icons replace "T1..T5" text.** The fallback font has no dice/numeral/circled
  glyphs (verified), so generated tier-badge textures procedurally: a rounded square in
  the tier's colour (bronze/silver/gold/cyan/violet) with dice-face pips 1-5
  (`_build_tier_icons` / `_make_tier_icon` / `_dice_pips` / `_fill_disc`, cached in
  `_tier_icons`). Used them in:
  - Top bar: `goods_label` is now a RichTextLabel; the alloy line rebuilds each refresh
    as `Alloys [icon] 49.6k [icon] 18k …` via add_image.
  - Ship panel: reworked to a 2-col Fighter|Bomber grid where each build button carries
    the tier badge as its icon (no "T1..T5" text). Fixed the stale "Mil T1-5" note →
    "that tier's alloy".
Verified: 140 tests pass, draw_smoke clean, probes confirm 5 icons build (26px), the
alloy RTL renders inline images, and ship buttons carry icons.

## Status — 0.80.0 (2026-08-20, Godot 4.7) — batch-3 polish (playtest feedback)

Three tweaks after testing 0.79.0.
- **Deposit icons reshaped.** Water is now a proper teardrop (`_draw_water_drop`: 8-point
  drop + rim + glint); minerals a faceted upright gem (`_draw_gem`: diamond body + bright
  top facet + girdle line). Reads by shape, not just colour.
- **Fleets easier to grab.** The click catch-radius is now SCREEN-space (`FLEET_CLICK_R /
  zoom`, floored to icon size) instead of a fixed 12 world-units, so fleets stay clickable
  when zoomed out instead of shrinking to an unhittable dot.
- **Top resource bar de-cluttered.** Dropped the redundant "(water in · pop needs)" label
  (that detail is in the hover tooltip) and the duplicate mil row. Now ordered groups with
  thin separators: [b]Day | Water ±/day  Minerals | Alloys T1·T2·T3·T4·T5 | standing[/b],
  big numbers compacted (49.6k). Two HUD explainers (water/minerals, alloys); removed the
  now-defunct mil_label + the redundant water-balance tip.
Verified: 140 tests pass; a headless probe drew the new deposit shapes with no error.

## Status — 0.79.0 (2026-08-20, Godot 4.7) — GRAPHICS/UI BATCH 3 (from playtest list)

Sharper look with depth + a Paradox-style hover tooltip.
- **Sharper:** enabled 4x MSAA on the 2D canvas (`anti_aliasing/quality/msaa_2d=2`) so
  every drawn circle/line/arc edge (stars, rings, borders, ships) is smooth, not jagged.
  Fog grid finer again (FOG_CELL 30→22, FIELD_MAX_CELLS 100→130 — affordable since the
  bake runs off-thread) for a crisper lit edge.
- **Depth:** `_draw_star` reworked into a layered luminous body — wide faint corona,
  coloured glow falloff, bright core, hot white pip — reads as volume. Map name labels
  now drawn via `_draw_name` with a soft dark drop-shadow so they lift off the fog.
- **Hover tooltip (Paradox-style):** a floating `PanelContainer`+`RichTextLabel` (BBCode,
  dark card w/ border+shadow, mouse-transparent, z=200, cursor-following + screen-clamped).
  `_update_tooltip()` (every frame): shows a HUD explainer when over a registered figure
  (`_ui_tips`: water/minerals, water balance, alloy tiers — each explains the mechanic),
  else a rich node card (`_node_tooltip`: name, coloured owner, deposit, population/city
  status, mine, structures, live-combat, in-view vs last-seen) when over a known map node.
  The old hover line moved into the tooltip; the hint line now just lists controls.
Verified: 140 tests pass; draw_smoke clean; a headless probe confirms the node card and
HUD tips render. Visual polish itself is for the on-machine playtest (no headless render).

## Status — 0.78.0 (2026-08-20, Godot 4.7) — ECONOMY BATCH 2 (from playtest list)

Three interlocked economy changes from the user's list.
- **Neighbor bonus OFF.** `NEIGHBOR_BONUS_ENABLED = false`; `neighbor_growth_multiplier`
  early-returns 1.0. All the code kept for a possible future mode. (Flat mesh has no real
  clusters and it always compounded into a late-game pop explosion.)
- **Food removed; WATER is population's need, as a FLOW (not banked).** Dropped `food`
  and the untiered `alloys` empire fields. Mines feed `water_income` per tick (reset each
  tick); population demand = pop·WATER_PER_POP; the SIGN of income−demand sets growth. No
  bank -> pop settles where water income supports it (income/WATER_PER_POP, a map-geometry
  ceiling) and can't over-grow then crash. Balance report now shows final = 100% of peak
  (was boom-bust). Raised GROWTH_RATE 0.004→0.014 to compensate for the lost neighbor
  growth and make WATER the actual limiter (pop was growth-limited, not water-limited).
- **Single alloy PYRAMID (minerals→T1→…→T5), no separate "alloys".** Each established
  city splits a budget (REFINE_COEF·pop^0.8) EQUALLY across the tiers it qualifies for
  (MIL_CUTOFF pop gates + variety for T3+), each tier yielding TIER_YIELD^tier per unit
  budget; a tier whose input ran out passes its budget UP. TIER_YIELD tuned 0.5→0.3 to get
  a clean stockpile pyramid (seed 7: minerals capped ~1k, T1 49609 / T2 18008 / T3 1364 /
  T4 23 / T5 42). Construction + tier-1 ships cost nat[0] (T1). Removed the food/refining
  spec (only the refining spec remains). HUD top bar: "Water ±/day · Minerals" +
  "(water in · pop needs)" + "Alloys T1-5" — no more duplicated alloys/mil rows.
- Balance across seeds 3/7/11: no boom-bust (100% of peak), no steamroll (leader 52-63%,
  4 empires alive), clean pyramid. 140 assertions pass (economy tests rewritten for the
  new model), draw_smoke clean.

NOTES / open tuning for the user: (a) T4/T5 are very rare (tens of units) — high-tier
ships are a real investment now; raise TIER_YIELD if that's too harsh. (b) The map leader
sits at ~55-63% — under the 75% steamroll line but combat batch 1 made things decisive;
watch it. (c) Numbers (REFINE_COEF, TIER_YIELD, GROWTH_RATE, WATER_PER_POP, mine richness)
are all playtest knobs.

## Status — 0.77.0 (2026-07-07, Godot 4.7) — COMBAT BATCH 1 (from playtest list)

First batch off the user's fix list. (Deferred by the user, next batch: bombers start
bombing before a lopsided fleet battle ends.)
- **Force-ratio scaling.** The old flat POWER_CEILING=200 damage cap made every ratio
  (10:1, 100:1, 1000:1) kill at the SAME tiny rate. Removed the per-battle cap in
  `_fight` (full stack power now sets the kill rate) and raised COMBAT_RATE 0.02→0.06.
  Result (probe): 10:1 wipes the loser in ~1.5 days (~3.8s at 1x); 100:1 in ~0.2 days
  (~0.5s). Ratio, not absolute size, drives speed (50:5 == 10:1), which is correct
  (Lanchester). Vision's "hard ship-power ceiling" now lives PER SHIP (tier ATK caps =
  no god-ships); un-steamroll still held by throughput-limited production + overstay
  attrition + slow population bombardment. POWER_CEILING kept only as the AI's
  "massed a decisive strike" threshold.
- **FTL inhibitor (Stellaris-style pin).** Fleet gained `prev_system` (set each hop).
  `fleet_pin(f)`: 2 = LOCKED when an enemy fleet is present (a battle — no jump until
  it's decided), 1 = RETREAT-ONLY when sitting over an enemy colony (may only fall back
  to prev_system; can't advance deeper — take the world or withdraw), 0 = free.
  `order_fleet` now returns bool and enforces it, so the AI can no longer teleport-dodge
  out of a losing fight. (Interpretation per the user's own examples: the retreat-only
  clause was described for the colony case; the battle case is "no one leaves until
  someone wins" = fully locked. Flag if you want retreat-from-battle too.)
- **Combat readout.** Fleet panel now shows a who-vs-who block: each belligerent by name
  + combat power (yours marked), a plain verdict by power ratio ("crushing them",
  "evenly matched — a grind", "being overwhelmed — retreat?"), and the pin state
  (🔒 held / ⚓ retreat-only). Refused move orders now log why (pin), instead of silence.
Tests: replaced the obsolete hard-cap test with `_test_combat_scaling` (big fleet kills
>4x faster) and added `_test_fleet_pin`; 140 assertions pass. draw_smoke clean.

## Status — 0.75.0 (2026-07-05, Godot 4.7) — fix rival border flicker inside VR

Playtest: "other players' border phases in and out of frame despite being obviously
inside VR." Root cause: the border-draw VR gate probed 12px INTO the owning side of each
contour segment. For a RIVAL's border that's 12px into RIVAL territory, where the
player's VR is marginal/zero — so as the rival's border drifted each rebake, a
fluctuating subset of segments crossed the VR threshold and dropped out → flicker. The
12px push was a stale workaround from when VR feathered to 0 AT the border; since 0.70.0
VR is FULL at the border and feathers PAST it, so the contour point itself is the right,
stable test. Fix: gate on the segment midpoint (`_player_vr_at(mid, …)`), drop the probe.
Repro (robo mode): tests/border_flicker.gd runs both empires as AI until borders meet,
then per cycle counts rival-border points that are inside player VR but that the OLD
12px-probe rule would hide — nonzero and swinging (3→10→7→6→4→9), i.e. the flicker; the
mid gate keeps them all. 139 tests pass; draw_smoke.gd clean.

## Status — 0.74.0 (2026-07-05, Godot 4.7) — threaded field rebake (no pan hitch)

Playtest after 0.73.0: "better but still skips a frame here and there when I move it."
The 0.73.0 coarsening shrank the rebake spike but it still ran synchronously on the main
thread, so it dropped a frame whenever it landed during a pan. Proper fix: run the bake
off-thread. Split `_recompute_borders` into:
- `_prep_field()` (main thread): snapshots each empire's influence sources into flat
  arrays + resolves per-system owner/VR/explored/stale. Returns a job dict.
- `_bake_field(job)` (threadable, PURE): fog Image + border-contour segments from the
  snapshot. Reads only job arrays, static map bounds, immutable anomalies (via the pure
  _claim_at/_vr_at helpers), and _fog_seen (worker-owned per rebake). No sim mutation,
  no rendering calls.
- `_apply_field(res)` (main thread): uploads the fog texture + swaps border segments.
Live loop: `_start_rebake()` runs prep + kicks a Thread on _bake_field; `_poll_rebake()`
applies the result the frame the worker finishes. `_recompute_borders()` stays as a
synchronous prep+bake+apply for startup/autoshot. `_exit_tree` joins any live worker.
Safe because sim.anomalies is immutable after gen (only appended in generate_map/load)
and the source arrays are snapshotted on the main thread before the worker starts.
Verified: 139 tests pass; draw_smoke.gd now also drives the async path (ASYNC REBAKE OK).

## Status — 0.73.0 (2026-07-05, Godot 4.7) — border-rebake hitch + VR reach +20%

Playtest: "fr is ok even at high speeds but at normal speeds camera movement lags" +
"give the vr around 20% more from border."
- Camera-pan stutter: `_recompute_borders()` (every 0.5s) samples up to two grids (fog
  + per-empire border claims) and calls `_claim_at`/`_vr_at` per cell — millions of
  inner ops, a synchronous main-thread spike ~2x/sec. FR was fine (per-frame draw is
  cheap now) but the rebake spike stuttered pans, most felt at normal speed when you're
  actively panning (at high speed you're watching, not moving). Coarsened the grids:
  FIELD_MAX_CELLS 150→100, FOG_CELL 22→30, BORDER_CELL 18→26, BORDER_REFRESH 0.5→0.6.
  Cost ~cells², so this is a >2x cut; fog is linearly filtered and the border is a
  smooth contour, so coarser grids barely change the look. (If still not smooth, the
  deeper fix is amortizing the rebake across frames or threading it off a sim snapshot.)
- VR reach +20%: VR_SIGHT_REACH 1.5→1.8 (open-space sight past your bubble) and
  VR_BORDER_FEATHER 0.18→0.30 (contested band bleeds further into a rival's side) — so
  VR shows ~20% more ground past the border in both open and contested cases.
Verified: 139 tests pass; draw_smoke.gd clean. Visual/feel is for on-machine playtest.

## Status — 0.72.0 (2026-07-05, Godot 4.7) — fix white flashing from 0.71.0

0.71.0's redraw throttle (~30 Hz) caused the screen to flash white a few times/sec: in
this project the viewport does NOT retain the canvas between frames, so any frame that
skipped `queue_redraw()` showed a cleared background. Reverted to redrawing EVERY frame;
removed DRAW_REFRESH/`_draw_timer`. The pan-lag fix now rests entirely on making each
_draw cheap — the viewport CULLING + zoom-gated LABELS from 0.71.0 are kept (those were
never the problem). So: per-frame redraw, but each redraw only touches on-screen systems
and skips labels when zoomed out. Verified via draw_smoke.gd (no runtime error) — visual
confirmation still needs an on-machine playtest (headless can't render here).

## Status — 0.71.0 (2026-07-05, Godot 4.7) — RENDER PERF: pan lag (from playtest)

Playtest: "movement still laggy on a mid map right from the start." That's not tick
cost (0.70.0 fixed that; early game has few colonies anyway) — it was per-frame RENDER
cost. `_process` called `queue_redraw()` EVERY frame, and `_draw_galaxy` re-drew every
system with two `draw_string`s each (text shaping is expensive) — so every pan frame
re-shaped 100s of labels. But the camera is a real Camera2D over world-space content:
panning is a transform, the content doesn't move, so a per-frame redraw was pure waste.
- main.gd: redraw throttled to ~30 Hz (DRAW_REFRESH) via `_draw_timer`; `_apply_camera`
  stays every frame so pan/zoom is still buttery. Autoshot forces a `queue_redraw()`
  before each capture since it no longer happens per-frame.
- Labels (system name + colony count `draw_string`) only draw at zoom ≥ LABEL_ZOOM
  (0.85). Zoomed out they overlap into mush anyway; the hover hint-line still names the
  hovered system.
- Viewport culling in `_draw_galaxy`: systems outside the visible world rect (camera ±
  half-viewport/zoom, padded) are skipped entirely. Net effect: zoomed OUT → all systems
  on screen but labels off (cheap: just stars); zoomed IN → labels on but only for the
  few on-screen systems (cheap). Both ends stay light regardless of map size.

## Status — 0.70.0 (2026-07-05, Godot 4.7) — VR-AT-BORDER + TICK PERF (from playtest)

Two issues from the flat-mesh playtest ("game runs faster, AI uses ships, but…"):

- **VR pulled back from the border.** The contested-branch feather in `_vr_at`
  faded brightness to 0 *at* the border, so when your border met a rival's, the lit
  fog stopped short and your own border floated outside the visible area. Fixed:
  feather now runs FULL brightness across owned ground and fades only in a thin band
  just PAST the border (VR_BORDER_FEATHER=0.18), so the border sits on the lit edge.
  `return clampf((pc_real/rival - (1-FEATHER))/FEATHER, 0, 1)`.
- **High-speed lag from the very start (not just endgame).** Root cause: `claim_strength`
  iterated EVERY system as a candidate influence source on every call, and `system_owner`
  (O(empires·planets)) was hammered by AI pathfinding + gating → O(empires·planets²)
  ownership resolution per tick, independent of colony count (so it bit even an empty
  early map). Fixes in sim.gd, all per-tick caches keyed on `day`:
  - `_influence_sources(empire)` — the few systems that actually project influence,
    built once per tick; `claim_strength` now iterates only those, not all planets.
  - `owner_cached(sid)` — `system_owner` memoised once per tick; wired into
    `lane_path_friendly`, `is_under_influence`, attrition, and structure-flip.
  - `_adj` adjacency cache for `lane_neighbors` (was O(lanes) per call in BFS).
  - Caches invalidate on any mid-tick source change (add_system/add_planet/inject/
    destroy colony) via `_invalidate_influence_caches()` so a frozen `day` can't
    hand back stale ownership.
  - main.gd: MAX_TICKS_PER_FRAME=8 cap so a hitched frame can't spiral day_accum and
    starve input; backlog is dropped, not accumulated.
  Tests: 139 assertions pass (border-contest test now calls _invalidate after its
  direct pop write). 400-planet autoshot renders; VR hugs the border.

## Status — 0.68.0–0.69.0 (2026-07-05, Godot 4.7) — FLAT PLANET MESH (design pivot)

Big deliberate pivot from a play session: DROP multi-planet star systems for a flat
mesh of individual planets. User's call — accepts losing the vision's same-system
"spread within / cluster across" tension; wants less compounding, cleaner visuals,
and map SIZE as the expansion limiter (longer games). Chose the low-risk path:
KEEP the engine (StarSystem stays as the map node) but one planet per node.
- **0.68.0** generate_map: 1 planet/node, still clustered (heatmap); map size DERIVES
  from planet count at fixed density (MAP_AREA_PER_PLANET) so bigger = more room,
  not denser; default 50→120. _place_empires reworked for 1-planet homes (home =
  water world + water mine + colony; nearest planet = mineral mine). UI: click a
  node → its single planet's actions directly (no planet-list); relabelled
  system→planet/world. Influence stacking LEFT AS-IS (test first, per user).
- **0.69.0** Map-size settings: Small 60 / Medium 120 / Large 250 + a Custom slider
  to 1000. Fog/border field uses ADAPTIVE cell size (FIELD_MAX_CELLS ≤150/axis) so
  the recompute stays bounded on big maps. Verified 400-planet gen + tick.

KNOWN / NEXT: per-source field cost still scales with planet count → 500+ planet
maps may spike (needs source spatial-partitioning). Influence stacking on dense
own-planet clumps is untuned by design — playtest, then decide cap/falloff. On a
huge map, 4 empires expand very slowly (few colonies by day 400) — that's the
intended length increase, but empire count vs map size is a knob to feel out.

## Status — 0.63.0–0.67.0 (2026-07-04, Godot 4.7) — PERF + BALANCE + VR FROM PLAYTEST

Four issues from a play session:
- **0.63.0 PERFORMANCE (was choking).** The HUD recomputed sim.system_owner() for
  every system EVERY FRAME (O(systems²·empires)) — blocked the main thread, laggy
  pan/input. Now standing reads the cached _system_owner; HUD/panel/hover throttled
  to ~15 Hz (camera+redraw stay per-frame); coarser field sampling (BORDER_CELL 18,
  FOG_CELL 22) + BORDER_REFRESH 0.5s shrink the periodic spike.
- **0.64.0 Neighbor bonus runaway.** In-system boost (0.29.0) contradicted the
  vision (same-system COMPETE) and drove compounding; now cross-system only, and
  capped at NEIGHBOR_MAX_BONUS (≤4×). Largest colony 20k→~760 (AI). Tunable if the
  user wants bigger cities (raise the cap / COEF).
- **0.65.0 VR follows the border, not influence.** Was pc×SIGHT≥rival, so sight
  crept into rival space as you grew. Now _vr_at has two regimes: contested → lit
  where your REAL claim beats the rival (stops AT the border); open space → extend
  to sight reach. Border-draw gate probes just inside owned side (else it dashed).
- **0.66.0 AI actually uses fleets.** Was idle at capital (only attacked adjacent).
  Now masses a power-ceiling stack then marches to the nearest enemy colony.
- **0.67.0 Bombardment slow (vision).** 0.66 exposed that bombardment wiped colonies
  in ~a day, depopulating the map. BOMBARD_RATE=0.15 → slow grind; colonies
  remaining 25→66, pop stable, no steamroll.

Remaining flagged: AI still doesn't retreat when losing / defend a threatened
colony (behaviour refinements). City sizes and war intensity are tunable knobs.

## Status — 0.59.0–0.62.0 (2026-07-04, Godot 4.7) — AI + COMBAT INDICATION

- **0.59.0** Clearer fleet combat: sim exposes combat_kind (0 battle / 1 bombard)
  per tick; renderer shows a LIVE pulsing indicator (ring + crossed swords for a
  battle; yellow streaks for bombardment) while combat is ongoing, the fading
  starburst only as an afterglow. Hovering a combat system reads out the
  belligerents and their combat power. New helper fleet_powers_in().
- **0.60.0** AI stopped throwing ships away: it consolidates stationary fleets into
  one stack and attacks an adjacent enemy colony only when undefended or when it
  out-powers the defenders (else holds and keeps massing).
- **0.61.0** AI parity on support structures — builds a transport hub at its
  capital, else an observation post on a frontier, via the same commands as the
  player. Balance re-verified (100% retention, no steamroll 36/24/22/18).
- **0.62.0** Fleet panel shows the live matchup ("⚔ IN BATTLE — enemy X vs your Y"
  / "☄ bombarding") for the selected fleet.

Remaining AI ideas (not done): defensive fleet posture (recall/hold when a colony
is threatened), retreat when losing a battle, target prioritisation beyond
lowest-id. Combat is now legible; these are behaviour refinements.

## Status — 0.55.0–0.58.0 (2026-07-04, Godot 4.7) — VISION MAJOR SYSTEMS

The remaining vision features (user: "go ahead and finish this"). All keep the
sim/render split, are covered by tests, and were balance-re-verified.
- **0.55.0** Observation post (doubles a system's influence reach → border + VR
  early warning) and Transportation hub (multiplies its colonies' neighbor bonus).
  Built per-system in influence, captured with the border, side-panel buttons + map
  markers. (AI doesn't build these yet — a same-rules parity refinement.)
- **0.56.0** Cosmic anomalies — circular regions that block influence AND visibility
  (no claim inside, none crosses); placed in open space clear of systems/lanes so
  movement/connectivity are never cut. Rendered as magenta nebulae.
- **0.57.0** Construction vessels — colonies/mines are delivered by a vessel that
  travels lanes from the capital and can't cross enemy territory (paid at dispatch,
  placed on arrival, refunded if spoiled). AI uses the same path. BONUS: logistics-
  paced expansion eliminated the pop boom-bust (100% peak/final retention).
- **0.58.0** National/civilian resource split — the economy already splits civilian
  (water→food→growth) from national (mineral→alloy→military); added the vision's
  variety-gating: top military tiers (T3+) require mining BOTH deposit types,
  rewarding diverse territory over hoarding one kind. (Happiness dimension +
  additional raw types left as a documented future refinement.)

Vision feature set is now COMPLETE. Remaining is tuning/content, not new systems.

## Status — 0.41.0–0.49.0 (2026-07-03, Godot 4.7) — GRAPHICS + BALANCE PASS

Later commits in the same autonomous session:
- **0.45.0** Border glow (translucent underlay), colour-coded resource bar
  (raw blue / goods green / military warm), landing page starfield.
- **0.46.0** Star size scales with system population; hover ring feedback.
- **0.47.0** Combat feedback — a fading red clash starburst on visible systems
  where a fight/bombardment happened (Sim.combat_at, transient/not saved).
- **0.48.0** Top-bar player standing: systems / pop / colonies (player-only).
- **0.49.0** New-game welcome/intro overlay (goal + first steps; paused; skipped
  on load/autoshot).

Earlier in the session (detail below):

Autonomous polish/graphics/balance session (user away).
- **0.41.0** Graphics: deep-space starfield backdrop (seeded, static) + systems
  render as spectral glowing stars (per-system colour, soft glow + core), live
  bright / explored dim.
- **0.42.0** Graphics: heading-aware fleet arrowheads (point along travel) +
  shape-coded planet glyphs (colony disc w/ rim, water droplet, mineral diamond,
  mine bracket) — readable without relying on colour.
- **0.43.0** Polish: toggleable legend (L) keying every map symbol/colour/state.
- **0.44.0** BALANCE PASS. Built `tests/balance_report.gd` — a headless all-AI
  probe that runs a full game and reports the two pillars + economy health. Run:
  `godot --headless --path desktop --script res://tests/balance_report.gd`
  (args: `seed= systems= empires= days=`). Findings + fixes:
  - **T0 stockpile balloon** (raw water+minerals hit ~1.3M unused — mines
    out-produced refining several ×): MINE_RICHNESS 25-65 → 12-30, halving it to
    ~0.55M. Raw is now closer to a real constraint. (Still ~0.5M — a candidate for
    a further cut or a raw-stockpile cap; left as a playtest knob.)
  - **Military tiers 3-5 were DEAD CONTENT** (cities never reached the old
    900/1600/2500 cutoffs, so T3-5 always showed 0): MIL_CUTOFF lowered to
    [50,150,350,700,1200]. All five tiers now produce (verified in the probe).
  - **Pillar checks (healthy):** no steamroll ever (final map share ~34/28/20/18,
    nobody >75%); growth self-limits to a stable plateau.
  - **Pop boom-bust — ROOT-CAUSED & largely FIXED in 0.52.0.** The overshoot was a
    famine: the raw WATER stockpile ballooned (mines >> refining), let refining run
    hot so pop boomed, then the buffer drained and food collapsed to mine-throughput
    → uniform pop shrink (colony COUNT held, ruling out bombardment). Same root cause
    as the T0 balloon. Fix: cap raw stockpiles to ~20 days of the empire's refining
    capacity (RAW_STOCK_DAYS/MIN). Result: T0 balloon gone (545k → ~2.5k) AND the
    overshoot roughly halved (peak/final retention 28% → 51%). A mild residual
    overshoot remains for the largest, most-spread empire (its cap scales with its
    big refining capacity) — acceptable, self-corrects, violates neither pillar.
    Earlier dead-ends (neighbor-bonus cap, food-stockpile buffer) were the wrong
    lever and stay reverted.
  - **Verified across all player-selectable configs** (balance_report.gd): Small
    30sys/2emp → 100% pop retention (no overshoot), 50/50 split; Medium 50/4 → 51%,
    34/28/20/18; Large 80/6 → 73%, 31/25/16/13/9/6. No steamroll (nobody >75%) in
    any; growth self-limits; T0 stays bounded (≤~7k even at 80 systems); all five
    military tiers produce. Balance is solid across the range.

## Status — through 0.40.0 (2026-07-03, Godot 4.7) — FOG/VR POLISH + FOW MEMORY

Post-alpha fixes, all from user playtest feedback on the fog of war:
- **0.35.0** VR sight factor 1.5→3.0 (the claim-ratio margin at 1.5 reached only
  ~10% past a contested border, so VR looked flush with it).
- **0.36.0** Smooth fog: bake the fog to an ImageTexture drawn with LINEAR filtering
  (was thousands of 34px draw_rect → staircase edges) + feather the VR value by
  claim so it reads as the influence SHAPE, no blocks, no hard reach disc.
- **0.37.0 → reverted by 0.38.0** First attempt at "border lost in fog" pulled the
  border INWARD; wrong — it made systems sit outside their own border.
- **0.38.0** Correct fix: border stays at the real influence edge; the FOG is pushed
  PAST it. Sight samples the player's claim with an extended reach (VR_SIGHT_REACH
  1.5× influence reach); ownership + border contour keep the real reach. Same
  extended reach feeds system-visibility + border-draw gate so what's revealed
  matches the fog. Knobs: VR_SIGHT_REACH, VR_CLAIM_FLOOR (main.gd).
- **0.39.0** Fog-of-war MEMORY: explored-but-out-of-VR (grey) systems now show ONLY
  a frozen last-seen snapshot — system/planet names + positions + lanes + deposits
  (static, always shown once seen), colonies (existence + owner, NO population),
  mines found, depot — all frozen at last full-VR sighting. The side panel and hover
  symbols were reading LIVE sim for any explored system (leaking live pop, colonies
  built after you left, ownership changes); both now route through the snapshot when
  a system isn't currently live. Borders only ever draw in live VR (unchanged).
  `_stale` expanded from {owner,colonies} to a full per-planet snapshot; save/load
  updated.
- **0.40.0** Build panel clarifies ship cost: ships are paid in the TIER'S military
  resource ("Mil T1-5" in the top bar), not alloys — footer note added.

## Status — through 0.34.0 (2026-07-03, Godot 4.7) — ALPHA SHELL COMPLETE

**116 headless test assertions, all passing.** Batch 0.31.0–0.34.0 (the shell to
turn the systems into a playable alpha):
- **0.31.0** Field-shaped fog: VR follows the actual influence field and reaches
  ~1.5x IN FRONT of the contested border (coarse influence-shaped fill), not radius
  discs around systems. System visibility + drawn border use the same field VR.
- **0.32.0** Config + difficulty: Session singleton hands new-game settings to the
  game; Empire.efficiency (AI production multiplier) applied to mining + refining;
  player stays 1.0.
- **0.33.0** Save/load: Sim.serialize()/deserialize() round-trip the whole sim
  through JSON; main.gd save_game/load_game (user://reach_save.json) also persist
  the fog memory + camera. F5/F9 quick save/load.
- **0.34.0** Landing page (menu scene = main scene): New Game (map size / empires /
  difficulty), Continue, Quit; in-game Menu overlay (Resume/Save/Quit to menu);
  game-over (defeat: no player colonies; victory: only player left).

This is a self-contained playable ALPHA: menu -> new game (settings) -> play (all
systems) -> save/continue -> win/lose. Remaining before beta = balance tuning +
real playtesting (the alpha activity), plus optional content (construction vessel,
observation post, transportation, national/civilian split, anomalies).

## Status — through 0.30.0 (2026-07-03, Godot 4.7)

Batch 0.29.0–0.30.0:
- **0.29.0** Mines & supply depots now change hands to the system's current owner
  as the influence border shifts (colonies still require bombardment — flagged in
  case you want colonies to flip too). Neighbor growth bonus now also applies
  WITHIN a system (in-system distance), so a big city lifts its own-system
  neighbours, not only across systems.
- **0.30.0** Map indicators: hovering a known system shows a symbol row beneath it
  (per-planet colony/deposit/mine glyphs + depot); fleet markers show a stripe per
  10 fighters and a star per 10 bombers.

## Status — through 0.28.0 (2026-07-03, Godot 4.7)

Batch 0.27.0–0.28.0 (creative-freedom
pass: completed the anti-snowball COMBAT PILLAR — the "no war won by one decisive
fight" promise is now fully enforced):
- **0.27.0** Hard ship-power ceiling: an empire's combat damage in a battle caps at
  POWER_CEILING; extra ships add hull (survivability), not punch. Big stacks win by
  outlasting, never one-shot.
- **0.28.0** Overstay attrition (a fleet in unowned, unsupplied space bleeds hull ∝
  its own size past a grace period) + supply depot (buildable structure that negates
  attrition in its system + one jump, doesn't stack).
- Combat safeguards now all in: throughput-limited production (0.2.0) + ship-power
  ceiling (0.27.0) + percentage/absolute overstay attrition (0.28.0).

REMAINING (roadmap): construction/civ VESSEL to build structures instead of instant
press (vision: can't cross borders); observation post (extend VR beyond one jump) +
transportation (boost neighbor bonus); national vs civilian resource split; cosmic
anomalies blocking influence+visibility; a real balance pass once there's more play.

## Status — through 0.26.0 (2026-07-02, Godot 4.7)

Overnight batch 0.23.0–0.26.0
(fleets finished + military economy + specialization; all per user spec):
- **0.23.0** Tiered military resources (nat[1-5]): a refining chain in cities, tier
  T from tier T-1, gated by pop cutoffs (100/400/900/1600/2500). A maxed city feeds
  the top tier; small cities only make tier 1 — spreading cities gives a resource mix.
- **0.24.0** Fighter/bomber ships, tiers 1-5. Top-right shipyard: an F and B button
  per tier, enabled only when that tier's resource can pay; each click builds one
  above the most-populated city. **Automatic combat**: fleets of two empires in a
  system fight (attrition ∝ enemy combat power, fighters win); otherwise a fleet
  bombards enemy colonies weakest-first, destroying them under 100 pop.
- **0.25.0** Planet specialization (FOOD/ALLOY, +60% at full, ramps over 60 days,
  resets on switch = inertia) + mine upgrades (needs a big same-planet colony +
  alloys; +50% output/level, up to L4).
- **0.26.0** AI now builds ships and attacks adjacent enemy systems — combat is
  two-sided in a real game.

DESIGN DECISIONS made autonomously (flag if you disagree): military chain is
tier-from-previous (drains lower tiers into the top → spread cities for a mix);
ship stats/costs and pop cutoffs are first-pass numbers to tune after playing;
combat is pure attrition (no ship-power ceiling yet — see below).

NEXT / STILL OPEN:
- Ship-power CEILING (vision pillar): investment past a cap becomes capacity, not
  raw strength. Not yet in — combat is currently unbounded attrition.
- Supply depot (reduces fleet attrition — pairs with a grace period), observation
  post (extend VR beyond one jump), transportation (boost neighbor bonus).
- Construction/civ VESSEL to build structures (vision: can't cross borders) instead
  of instant press — the user wants this for buildings.
- National vs civilian resource split; anomalies blocking influence+visibility.
- Balance pass once there's more play/content (user: hard to judge before then):
  influence-reach scaling, mine-richness vs conversion capacity, ship/tier numbers.

## Status — through 0.22.0 (2026-07-02, Godot 4.7)

Batch 0.19.0–0.22.0:
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
