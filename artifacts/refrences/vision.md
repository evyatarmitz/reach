# Reach — Vision

- You do not command directly — you cultivate. There is no physical body; this is a
  deliberate departure made for this game specifically.
- The map is top-down. Your population is the actual protagonist: you supply basic
  resources, issue directives, and clear dangers, and it grows and organizes largely
  on its own.
- Colonize any planet in a system under your influence for a flat, repeatable cost.
  New colonies are a genuine drain — elevated resource cost, a small pull on national
  resources — until they cross an activation threshold, where those costs taper away
  and the colony begins producing and can specialize.
- Extracting the basic raw resources everything else depends on requires a dedicated
  mining structure, built wherever deposits exist within reach.
- There is no hard population cap. Diminishing returns flatten any single colony's
  growth well before its highest tier — the only way past that wall is growing near
  other established centers (a compounding proximity bonus) and investing in
  transportation to strengthen it further. The ceiling that exists in practice is
  emergent — a product of the cluster you found and how well you exploit it — not a
  designed number.
- The core spatial puzzle: colonies in the same system compete for the same
  influence area, pushing you to spread out within a system — but nearby systems
  boost each other, pushing you to cluster across systems. That tension is the
  actual game.
- Resources split into national (military and production) and civilian (happiness
  and growth); higher production tiers need a wider variety of resource types, not
  just more volume, rewarding diverse territory over hoarding one kind.
- Borders are not fixed lines — they're a live contest, sitting wherever relative
  influence strength puts them, moved by outgrowing a rival or by direct attack.
  Ships stationed over an enemy population center slowly kill its population —
  bombardment, not conquest by a single battle.
- No war is won by one decisive fight: killing population is slow, and an opponent
  keeps producing elsewhere while you're engaged. Fleets that overstay their welcome
  take attrition proportional to their own strength, so bigger fleets bleed more in
  absolute terms. Ship power has a hard ceiling — further investment becomes
  capacity, not raw strength — and production is limited by real resource
  throughput, not theoretical maximums.
- Ships and construction vessels travel only along lanes, making chokepoints real
  and defensible. Construction vessels cannot cross into another empire's territory
  even where influence nominally reaches. Cosmic anomalies block both influence and
  visibility, forcing routes around them physically.
- Beyond colonies and mining: an observation post (doubles influence range, adds a
  separate visibility range for early warning on a border), a supply depot (reduces
  nearby fleet attrition, doesn't stack), and transportation infrastructure
  (strengthens the proximity bonus between established centers).

## Core formulas

Restored 2026-07-02 — these were part of the original design conversation and got lost
in iteration. The constants (A1, A2, the 1/R coefficient) are tunable; the *shapes*
are the design.

- **Influence:** `influence = A1 × pop_count` — a center's influence scales linearly
  with its population.
- **Border reach, uncontested:** `border_length = A2 × influence` — how far a border
  extends from a center when nothing pushes back.
- **Border position, contested:** `border1 / border2 = influence1 / influence2` — the
  border between two rival centers sits where their distances to it are in the ratio
  of their influences. Outgrow the rival and the line moves toward them; no fixed
  lines anywhere.
- **Neighbor bonus falloff:** `1/R` — the compounding proximity bonus between
  established centers falls off with distance as 1/R. (This falloff belongs to the
  neighbor bonus only — it is not part of the border math.)

## Time and pacing

Real-time with a speed dial, not turn-based. Boring stretches are handled by the
player speeding time up, not by compressing the design — slow mechanics (population
growth, bombardment, activation thresholds) are allowed to be slow.

## Multiplayer posture

The design is multiplayer-shaped — every empire, player or rival, runs on exactly the
same rules — but a released single-player game comes first. Until then, rivals are AI
empires using the same mechanics and code paths as the player. Nothing may be built
in a way that assumes a single human forever (e.g. player-only special-case rules),
but no multiplayer infrastructure gets built before the single-player release.

## Inspiration

None directly — this one is novel. Closest tonal cousins are indirect-control god
games (population as protagonist, conditions not commands), not traditional 4X.
