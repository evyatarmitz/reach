# Reach — AI Collaboration Protocols

Working agreements governing how Claude makes decisions, implements features, and
verifies work in an open-ended autonomous session. Updated as the project evolves.

Rewritten 2026-07-02 for Reach specifically — the original file was inherited verbatim
from the parent "To Infinity" project and described an embodied X4+NMS hybrid with a JS
toolchain, both of which contradict this game. The decision/test/bug protocols below are
preserved from the original (they were always game-agnostic); the vision context,
toolchain, and telemetry sections are Reach's own.

---

## Vision Context

**Goal:** An indirect-control population god-game. No physical body, ever. Top-down
map. The population is the protagonist — the player supplies resources, issues
directives, and clears dangers; the population grows and organizes on its own.
`vision.md` is the authoritative design document; this section is orientation only.

**Core niche:** Novel — no direct genre inspiration. Closest tonal cousins are
indirect-control god games (conditions, not commands), not traditional 4X.

**Two design pillars everything else protects:**
1. Population growth is uncapped-but-self-limiting — ceilings emerge from diminishing
   returns × map geometry, never from a designed number.
2. Combat is un-snowballable — percentage-of-own-strength attrition, ship-power
   ceiling, and throughput-limited production independently prevent steamrolling.

**Scope rule:** vision.md is the floor AND the ceiling for core mechanics. New
mechanics get judged against it; drift requires a documented reason.

**Architecture mandate:** The simulation core must be engine-agnostic — pure logic
with no rendering/engine dependencies, driven by a tick, readable as plain data. The
current engine (Godot 4, chosen 2026-07-02 for the prototype) is explicitly
provisional and may be replaced; the sim core must survive that replacement. Systems
interact through data (state, events), not direct references, where avoidable.

---

## Decision Protocol

### Full autonomy — do without asking or flagging
- Anything explicitly in the session task list / TODO.md
- Bug fixes discovered while implementing — fix it, note it in the commit
- API changes, data format changes, interface renames — fine as long as (1) it works,
  (2) we know what changed and why, (3) it moves toward the goal
- Choosing between equivalent implementations — pick simpler, name the choice in
  commit message
- Balance numbers (growth exponents, falloff constants, attrition %, costs, rates) —
  pick reasonable values, state rationale in commit. Core constants were explicitly
  designated "tune until it feels right" — preserve the *shape* of the mechanic, not
  the placeholder number.

### Pick an approach, mention it in the session summary
- Ambiguous scope: interpret minimally, name what was skipped and the tradeoff
- New subsystem where design direction matters — state the interpretation, implement
  it, flag it so we can discuss direction

### Stop and ask
- Discovered scope is genuinely 3x larger than implied — describe actual scope before
  committing
- Two conflicting design directions neither of which is clearly better for the core
  pillars — describe the fork
- Cannot find root cause of a bug after deep analysis (see Bug Protocol) — describe
  symptoms, affected systems, and what's been ruled out, then skip it

**Note:** Changing APIs and data formats does NOT require asking. The project is
pre-release and internal. Breaking changes are fine as long as they're working and
documented.

---

## Implementation Protocol

**Sequence for every change:**

1. **Read** all files to be touched before editing anything
2. **Edit** — minimal changes that accomplish the task; no scope creep
3. **Static check** — the project must load with zero script errors. Headless check:
   `godot --headless --check-only` (or open + quit: import/parse errors surface in
   stderr). Sim-core code must not import engine rendering/UI classes.
4. **Test** — follow Test Protocol below. Sim logic gets headless deterministic tests
   (`godot --headless -s <test script>`); UI/rendering gets a run + screenshot read.
5. **Commit** — one commit per feature or bug-fix group

**Commit message format:**
```
0.X.Y - short description

- what changed and why
- design choice: what I picked and why (if non-obvious)
- limitations: documented here, not hidden
```

**What NOT to do:**
- No WIP commits
- No "while I'm here" refactors beyond what the task requires
- No comments that describe WHAT the code does; only WHY if non-obvious
- Do not add features not in the session scope — note gaps in TODO.md instead

---

## Test Protocol

Testing is a three-step process, not a one-step verification. The goal is *knowledge*,
not *confirmation*. Partial success and partial confirmation are different: partial
success means some things worked and some failed; partial confirmation means some
things worked and we don't know about the rest.

### Step 1: Plan the test before writing it

Before touching the test tool, answer these questions:

**Visibility conditions:**
- Under what exact conditions is the new feature supposed to be visible or measurable?
- Are there conditions where it would appear to work but isn't (false positive)?
- Are there conditions where it would appear broken but isn't (false negative)?

**Tool coverage:**
- Can current tools (headless sim runner, state dumps, screenshots) actually test this?
- Are we testing existence ("the value is present") or functionality ("the value is
  correct")?
- If functionality can't be tested, say so explicitly — don't let an existence check
  stand in for a functionality check

**Coverage gaps:**
- What aspect of this feature can we NOT test with current tools?
- Is the gap significant enough to build a new tool first?

### Step 2: Create or upgrade tools if needed, then test

If the plan reveals a tool gap:
- Implement the minimal tool that closes the gap (new dump field, new headless test
  entry point, new snapshot comparison)
- Then run the test

Test commands should be explicit sequences that would catch both "broken" and "subtly
wrong":
- Don't just verify it doesn't error — verify the output values make sense
- For growth: snapshot population, tick N times, verify the curve *shape* (diminishing
  returns actually diminish; neighbor bonus actually compounds)
- For borders: place two centers with known influence, verify the border sits at the
  influence-ratio position, then change one population and verify the border moves
- For visual/UI: read the screenshot PNG and describe what's in it — don't just
  confirm the file exists

### Step 3: Analyze results with precision

State results as one of:
- **Confirmed:** test proves the feature works as designed under tested conditions
- **Partial success:** X worked, Y failed — specific about which
- **Partial confirmation:** X worked, Y was not tested — specific about the gap
- **Failed:** describe what happened vs what was expected
- **Cannot test:** describe what's missing and why

Always distinguish between "the feature works" and "the test passed" — these are not
the same if the test has coverage gaps.

---

## Bug Protocol

### Attempt 1–2: Direct investigation
- Read the relevant code paths
- Check for obvious causes: wrong variable, off-by-one, wrong condition
- If found: fix it, commit, done

### If still broken: Deep analysis before attempt 3

Ask and answer these questions before touching code:

1. **System map:** What systems touch the broken component? Draw the call chain
   mentally.
2. **Specificity:** Is it failing completely, or failing in a specific case only?
   Specific failures point to edge cases; complete failures point to initialization
   or wiring.
3. **Isolation:** Can it be reproduced in a simpler state? (e.g., a two-colony map
   instead of the full scenario, or tick 1 instead of tick 10,000?)
4. **Tool validity:** Could the test tool itself be wrong? Am I measuring the right
   thing?
5. **Recent change:** Did this work before? What changed since then?

### Attempt 3: One targeted fix based on the analysis

If it works: commit, document root cause.
If it still doesn't work: **skip it**. Document:
- What's broken and how to reproduce it
- What was tried
- Which systems are involved
- The most likely hypothesis

Continue with the rest of the session. Flag it in the summary. Discuss later.

**Do not spiral.** A bug that survives 3 attempts + deep analysis needs a fresh
session or user input. The project is too large to let one blocker stall everything.

---

## Telemetry & Diagnosis Tools

None exist yet (from-scratch build). Build them as the sim grows — the sim core being
plain data makes these cheap, and per the Test Protocol, tool gaps get closed before
features get declared working. Planned set:

| Tool | Purpose |
|---|---|
| Headless sim runner | Run N ticks with a fixed seed, no rendering — the backbone of every sim test |
| `dump` (state → JSON) | Full sim state snapshot for before/after comparison |
| Scenario loader | Boot the sim into a hand-authored map state (two colonies, one contested border, …) instead of playing there manually |
| Screenshot | Visual verification — the PNG must be READ and described, not just created |

---

## Architecture Principles

- **Sim/render split is the prime directive.** The simulation is a pure, deterministic,
  tick-driven module; Godot nodes only read its state and forward player input. The
  engine is replaceable; the sim is not.
- Deterministic where possible: fixed seed → identical run. This is what makes the
  headless test tooling trustworthy, and keeps the door open for the eventual
  multiplayer version (lockstep needs determinism).
- One data model for space: systems, planets, and lanes form a topology graph.
  Everything spatial (movement, influence, borders, anomaly blocking) derives from it.
- Reuse over duplication: rivals are AI empires playing by exactly the same rules and
  the same code paths as the player — no separate AI-side mechanics.
- Systems interact through data (state, events) not direct references where avoidable.

---

## Session Rhythm (for open-ended sessions)

1. Read `CLAUDE.md` in the game root, then `artifacts/refrences/vision.md`, then
   `artifacts/notes/INDEX.md` to orient
2. Pick up from TODO.md where the last session left off
3. Complete one feature fully (implemented + tested + committed) before starting the
   next
4. At the end: update TODO.md, then summarize what was done, what was skipped, any
   bugs found (fixed or deferred), and what's next
