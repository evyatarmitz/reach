# Visual Review Log — Reach

A running log of screenshot-driven visual/UX reviews. Process (set by the user, "free
walk time"): capture a screenshot of a representative situation → triage findings into
🔴 red (fix now) / 🟠 orange (should fix, not urgent) / 🟢 green (working well, leave
alone) → write them here → fix the reds → re-capture → repeat. This gives us a durable
record of what's solid and what still needs a look.

Screenshots come from the built-in `--autoshot` harness (`dist\Reach.exe -- --autoshot`),
which self-arranges a two-empire border contest, builds a fleet, and saves PNGs to
`%APPDATA%\Godot\app_userdata\Reach\autoshot*.png`. Only renders from the windowed build
(not headless).

---

## Cycle 1 — 2026-09-03 — galaxy view, fleet selected

Capture: `autoshot_galaxy.png` (0.3.4). Two-empire border contest, a player fleet
selected and hovering the home system, shipyard + fleet-info panels both open on the
right.

### 🔴 Red (fixing this cycle)
- **R1 — Fleet-info panel overlaps the shipyard panel, and both are see-through.** ✅ FIXED.
  The right-side selection panel (`panel`, drawn around vertical center) and the shipyard
  panel (`sp`, top-right, ~290px tall) collided at common window heights, and neither had
  an opaque background — so the fleet readout rendered on top of the shipyard's helper
  text. Fix: made both panels opaque (`UiStyle.make_opaque`); re-anchored the selection
  panel to a right-edge lane BELOW the shipyard, and dock its top to the shipyard's real
  laid-out bottom at runtime (`_dock_selection_panel`, driven by `ship_panel.resized`) so
  the two can never overlap regardless of font/DPI. Verified in both the galaxy (Fleet)
  and system (Karon) captures — solid backgrounds, zero overlap, all text legible.

### 🟠 Orange (logged, not urgent)
- **O1 — Top resource bar is cramped and low-contrast.** `Min 940 ⊙4.5k 📦84 ▧8 ▨4 ▨6`
  over a row of `0.0/d 0.0/d …`; tiny unlabeled tier icons, per-day row hard to line up
  with its stock, faint against the map. The top bar (`top`) is also semi-transparent.
  Ideas: make the top bar opaque; label/tooltip the tiers; verify the amount/rate table
  columns line up.
- **O2 — `--autoshot` only ever captures the galaxy view.** ✅ FIXED (this cycle, since it
  gates review coverage). The harness set `view_system_id` for the 2nd shot but left
  `selected_fleet_id` set, and `_refresh_ui()` returns on the fleet branch before the
  system branch — plus it never refreshed the UI / redrew before grabbing the frame, so
  both PNGs came out identical. Fix in `_autoshot()`: clear `selected_fleet_id`, drop the
  hover hold, then `_refresh_ui()` + `queue_redraw()` before the 2nd save. `autoshot.png`
  now correctly shows the system/planet panel (verified: Karon colony readout).
- **O3 — Top-left hint line can overlap the date/water labels.** ✅ FIXED (cycle 4). Was
  pinned at a fixed (16, 40) that tucked under the now-opaque top bar. Added
  `_dock_top_labels` (driven by `top_bar.resized`) to park the hint + event feed just
  below the bar's real laid-out height — same runtime-dock pattern as the selection panel.
- **O4 — Selection panel can overflow the bottom edge (found after O2's fix let us see the
  system panel).** The selection panel now docks below the shipyard, giving it a shorter
  vertical lane; a content-heavy OWN colony (planet list + 6-line body + up to ~6 action
  buttons) can run past the bottom of the screen, cutting off the lowest buttons. Not a
  regression in kind (it could overflow before too) but the shorter lane makes it likelier.
  Fix: wrap the panel's VBox in a ScrollContainer so it never overflows. → cycle 2's red.

---

## Cycle 2 — 2026-09-03 — system/planet view

Capture: `autoshot.png` (now works, per O2). Player's own established city (Karon)
selected, full stat readout + action buttons.

### 🔴 Red (fixed this cycle)
- **R2 (was O4) — Selection panel could overflow the bottom edge, cutting off action
  buttons.** ✅ FIXED. Wrapped the selection panel's VBox in a `ScrollContainer`
  (horizontal scroll disabled) and dropped the `panel_body` EXPAND_FILL so content takes
  natural height. The panel's solid background now fills its whole lane to the bottom and
  any overflow scrolls — no button can be pushed off-screen and left unreachable. Verified
  in the system capture: readout intact, opaque, docked below the shipyard.

### 🟢 Green (confirmed this cycle)
- System/planet readout is clear and well-ordered: name, owner, status, pop, refining
  capacity + the T3 gate, water deposit rate — good information hierarchy.
- The `_dock_selection_panel` runtime dock holds correctly in the system view too.

---

## Cycle 3 — 2026-09-03 — top resource bar

Capture: `autoshot_galaxy.png` (rebuilt). Focus: the top HUD bar.

### 🔴 Red (fixed this cycle)
- **R3 (was O1) — Top resource bar was semi-transparent and low-contrast over the map.**
  ✅ FIXED. Added `UiStyle.opaque_bar()` / `make_opaque_bar()` (a solid edge-docked bar
  variant: square corners, thin inner-edge border, one shared HUD palette with the panels)
  and applied it to the top bar. The date / water / minerals+alloy figures now read
  cleanly against a solid strip. Verified in the galaxy capture.

### 🟢 Green / acceptable-by-design
- The alloy tiers use small dice-pip badge icons rather than "T1..T5" text, with the
  per-figure detail on hover (intentional, per the HUD comment). With the bar now opaque
  the amount/rate table lines up and reads fine — closing the "cramped/label the tiers"
  part of O1 as acceptable. Revisit only if playtesting shows people can't tell tiers apart.

---

## Cycle 4 — 2026-09-03 — top-left labels

Capture: `autoshot_galaxy.png` (rebuilt). Fixed R4/O3 (hint dock). Verified: the hint
line clears the opaque bar with a clean gap.

---

## Status after cycle 4

Every item from cycle 1's triage is resolved (R1, R2/O4, R3/O1, O3, O2). Both captured
views — galaxy (fleet selected) and system (colony selected) — now read cleanly: opaque
panels, no overlaps, nothing cut off.

**What the current harness can't show us (candidates for a wider review):** `--autoshot`
staged one scenario (two empires, a moving fleet, a home colony). Added a zoomed-in pose
this pass (see cycle 5). Still worth adding later: a live fleet battle (the pin/combat
readout + crossed-swords marker), the one-time intro overlay, and a multi-planet owned
system (to stress the new panel scroll). Not urgent — noted for a future coverage-widening
cycle.

---

## Cycle 5 — 2026-09-03 — zoomed-in view (new harness pose)

Added a 3rd `--autoshot` pose (`autoshot_zoom.png`): galaxy centered on home at 2.5x, no
selection, so we can judge close-up legibility. Capture reviewed.

### 🟢 Green (working well at zoom)
- System nodes read cleanly: cyan ownership rings, star cores, and names (Rotia, Karon,
  Lolex) all legible. The fleet marker (arrow + green count) and the capital diamond are
  clear. Lanes are thin but traceable.

### 🟠 Orange (logged, low severity — not fixing now)
- **O5 — Fleet arrow overlaps its home star node at high zoom.** The fleet icon's small
  upward offset isn't enough at 2.5x, so the arrow sits on the node glow. Cosmetic; it's
  genuinely at that system, so the overlap isn't misleading. Consider scaling the offset
  with zoom if it bothers in play.
- **O6 — Structure glyphs need the legend to decode.** A small blue-outlined square marker
  (depot/obs-post/transport?) sits by a system with no inline label. Fine given the L
  legend, but a one-cycle pass to make the structure glyphs more self-evident could help
  new players. Low priority.

No reds at zoom — the close-up view is in good shape.

---

## Cycle 6 — 2026-09-03 — WIDER COVERAGE: battle, colony, intro (3 new harness poses)

Taught `--autoshot` three new poses (per the user's "update your tool set whenever it
becomes unsatisfactory"): a **live fleet battle** (`autoshot_battle.png`), a **content-heavy
own-city panel** (`autoshot_colony.png`), and the **one-time intro overlay**
(`autoshot_intro.png`). Staging code lives at the end of `_autoshot()` in
`desktop/game/main.gd`: the battle spawns an enemy fleet in the home system and ticks once
so `_resolve_combat` pins both sides and flags `combat_at/combat_kind`; the colony funds
the empire and selects the best-stocked established city; the intro just shows the overlay.

### 🔴 Red (fixed this cycle)
- **R5 — Intro overlay's "Begin" button pushed off the bottom of the screen at 1280×720.**
  ✅ FIXED. The welcome card was a fixed 320px-tall centered box, but the copy is ~510px
  tall, so it overflowed the viewport and the only control that dismisses the intro and
  starts the game ("Begin") sat below the screen edge — a genuine new-game blocker at a
  common resolution, and there was no scroll to reach it. Fix (`_build_intro`): the body
  now lives in a height-capped `ScrollContainer` (540×440, horizontal scroll off) while the
  title and Begin button stay OUTSIDE it, and the card is content-sized with `grow_*=BOTH`.
  Begin is now always on-screen regardless of copy length or window size; the body scrolls.
  Verified in the re-captured `autoshot_intro.png`: contained card, visible scrollbar,
  Begin pinned at the bottom.

### 🟢 Green (working well — leave alone)
- **Live battle reads excellently.** `autoshot_battle.png`: Karon shows the crossed-swords
  clash marker over the node, the fleet arrow + count, a top-left "⚔ Battle at Karon" event
  line, and the Fleet panel renders the full who-vs-who readout ("you: 406⚔ / Ortia
  Ascendancy: 289⚔ / → upper hand"). This is the combat design pillar surfacing clearly —
  the highest-value coverage the harness had been missing, and it's solid.
- **Colony panel** (`autoshot_colony.png`): Orron reads cleanly — owner (Karon Compact),
  ESTABLISHED CITY, pop, refine capacity + T-gate, deposit, immigration + specialize
  actions, docked below the shipyard on its opaque background. The R2 ScrollContainer holds.

### 🟠 Orange (logged, not urgent)
- **O7 — The always-open "Build ships" shipyard panel permanently squeezes the selection
  panel into a short lane.** ✅ FIXED (cycle 7). In the battle shot the fleet readout's tail
  ("🔒 held in the fight…") and in the colony shot the system-structure buttons (depot / obs
  post / transport) sat below the fold and needed a scroll to reach. Nothing was lost (the
  ScrollContainer worked), but time-relevant info/actions being below the fold by default was
  a real cost. Root cause was layout — see cycle 7.

---

## Cycle 7 — 2026-09-03 — collapsible shipyard (fixes O7)

Made the top-right "Build ships" shipyard panel collapsible: its header is now a button
(▾ expanded / ▸ collapsed) that hides the tier grid + cost note (`ship_body`). The shipyard
is a *global* action unrelated to the current selection, so it shouldn't permanently squeeze
the selection panel. Collapsing it shrinks the panel, whose `resized` signal re-docks the
selection panel up under the collapsed header — reusing the runtime-dock already in place, so
no hard-coded heights. Added an 8th harness pose (`autoshot_colony_collapsed.png`) that
collapses the shipyard on the Orron city view to verify.

### 🟢 Green (verified this cycle)
- **`autoshot_colony_collapsed.png`:** with the shipyard collapsed to a single "▸ Build ships"
  header, the Orron selection panel reclaims the whole right column and shows EVERY action
  without scrolling — Immigration, Specialize refining, and all three structure buttons
  (Build supply depot / observation post / transport hub) that were below the fold when
  expanded (`autoshot_colony.png`). Confirms both the O7 squeeze and its fix.
- Expanded state unchanged bar the new caret header ("▾ Build ships — by tier"); tier grid,
  costs, and hotkeys note all read as before.

### 🟢 Green (working well — leave alone)
- Border contest reads clearly (blue vs. gold influence field, deformed border).
- Fog-of-war states legible: bright in-sight, dim last-seen, black unknown.
- Star ownership rings + star-type colours are clear.
- Selected fleet's travel path (dashed line to destination) is easy to follow.
- Anomalies (magenta nebulae) look good and clearly break up the lane network.
