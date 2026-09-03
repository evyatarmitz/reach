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
- **O3 — Top-left hint line can overlap the date/water labels.** `hint_label` is pinned
  at (16, 40), just under the auto-height top bar; on a tall top bar it can touch the
  first HUD row. Low severity.
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

### 🟢 Green (working well — leave alone)
- Border contest reads clearly (blue vs. gold influence field, deformed border).
- Fog-of-war states legible: bright in-sight, dim last-seen, black unknown.
- Star ownership rings + star-type colours are clear.
- Selected fleet's travel path (dashed line to destination) is easy to follow.
- Anomalies (magenta nebulae) look good and clearly break up the lane network.
