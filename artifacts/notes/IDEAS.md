# Ideas — design/feature thoughts from seeing the game rendered

A running list of ideas that surfaced from actually *looking* at the game (the
`--autoshot` review captures), not from reading the code or vision. These are candidates,
not commitments — weigh each against `refrences/vision.md` before building. Newest ideas
go at the top of the relevant group. Tag each with the capture that prompted it.

Priority tags: 💡 nice-to-have · ⭐ strong fit, worth scheduling · 🧭 needs a design call.

---

## Layout / HUD

1. ⭐ **Make the "Build ships" shipyard panel collapsible (or context-opened).** *(battle +
   colony captures)* It's docked open on the whole right side at all times — even when you're
   managing a colony nowhere near a shipyard — and it permanently squeezes the selection
   panel into a short lane, pushing battle-readout tails and colony structure-buttons below
   the fold (see REVIEW_LOG O7). A collapse toggle, or only auto-opening it when a
   ship-building context is relevant, would free the right column and remove the squeeze at
   its root. Directly fixes the O7 orange rather than papering over it with scroll.

2. 💡 **Dim/hide zero rates in the top resource bar.** *(all galaxy captures)* The per-day
   rate row is mostly `0.0/d 0.0/d …` when steady/paused, which is visual noise competing
   with the amounts above it. Dim zeros (or color +/- rates green/red) so the eye lands on
   what's actually changing.

3. 💡 **Empire color swatch next to empire names.** *(battle capture)* The battle readout
   names "Ortia Ascendancy" / "Karon Compact" in plain text; a tiny color chip matching the
   map influence colors would tie the words to the territory you see on the map at a glance.

## Combat / map

4. 💡 **Animate the clash marker on battle freshness.** *(battle capture)* The static
   crossed-swords X reads well, but on a large map a subtle pulse keyed to `combat_at` age
   would pull the eye to *new* battles. Maybe a faint fading ring when combat first flags.

5. 🧭 **Compact tier-pip strip for fleet composition.** *(battle capture)* The fleet line
   "F1×24 B1×12 F2×3 B2×4 F3×1 B3×2 F4×1" is dense text. A little row of the same dice-pip
   tier icons the shipyard already uses (sized by count) would let a player read fleet
   strength/shape without parsing codes. Needs a design pass so it doesn't lose the exact
   counts veterans may want.

6. 🧭 **Influence-strength heatmap toggle.** *(zoom + galaxy captures)* Borders read clearly,
   but *why* a border sits where it does (the non-stacking-within-a-system vs neighbor-bonus
   tension — a core vision mechanic) is invisible. An optional heatmap overlay of influence
   strength would make that tension legible and teachable. Vision-aligned: it visualizes the
   exact pillar the border math exists to create.

## Onboarding / systems

7. ⭐ **Stage the intro as contextual first-run coaching instead of one wall of text.**
   *(intro capture)* Even after the scroll fix, the welcome card is a long read up front.
   Splitting it into 3–4 dismissible tips that appear *when relevant* (first planet click →
   "send a construction vessel"; first surplus water → the flow-not-stockpile note; first
   rival contact → borders/influence) would land better than front-loading everything. Keep
   the current card as a fallback / "show intro again."

8. 💡 **Surface planet depth on the map.** *(colony + galaxy captures)* Systems are named
   nodes but the one-planet-per-node model hides how many worlds a system holds. A small
   "3 worlds" badge or orbiting dots on hover/zoom would hint colonization depth without
   making the player open each system to find out.
