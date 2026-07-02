# To Infinity — AI Collaboration Protocols

Working agreements governing how Claude makes decisions, implements features, and verifies work in an open-ended autonomous session. Updated as the project evolves.

---

## Vision Context

**Goal:** The largest scope space sim ever built, expanded incrementally over time with no fixed endpoint.

**Core niche:** Management depth of X4 Foundations + embodied presence of No Man's Sky. The player doesn't manage from a god screen — they physically exist in the world. They fly to the meeting, walk to the trade terminal, fight in the cockpit and on foot. Empire-scale systems (economy, factions, fleet AI) and personal-scale systems (FPS combat, NPC relationships, ship interior) must coexist and reinforce each other.

**Scope rule:** If X4 has it AND NMS has it → we probably want it eventually. That's the floor, not the ceiling.

**Architecture mandate:** Modular, reusable systems. The spell-book library (sb) captures reusable components. New systems should be designed for reuse: if I build trade routes, build them so they work for player ships, NPC freighters, and faction fleets — not just the one case I'm implementing today.

---

## Decision Protocol

### Full autonomy — do without asking or flagging
- Anything explicitly in the session task list
- Bug fixes discovered while implementing — fix it, note it in the commit
- API changes, data format changes, interface renames — fine as long as (1) it works, (2) we know what changed and why, (3) it moves toward the goal
- Choosing between equivalent implementations — pick simpler, name the choice in commit message
- Balance numbers (prices, HP, spawn counts, ranges) — pick reasonable values, state rationale in commit

### Pick an approach, mention it in the session summary
- Ambiguous scope: interpret minimally, name what was skipped and the tradeoff
- New subsystem where design direction matters (e.g., "add economy" could mean 3 very different things) — state the interpretation, implement it, flag it so we can discuss direction
- When adding a system that exists in X4 or NMS, note which game's version I'm approximating and why

### Stop and ask
- Discovered scope is genuinely 3x larger than implied — describe actual scope before committing
- Two conflicting design directions neither of which is clearly better for the core niche — describe the fork
- Cannot find root cause of a bug after deep analysis (see Bug Protocol) — describe symptoms, affected systems, and what I've ruled out, then skip it

**Note:** Changing APIs and data formats does NOT require asking. The project is pre-release and internal. Breaking changes are fine as long as they're working and documented.

---

## Implementation Protocol

**Sequence for every change:**

1. **Read** all files I will touch before editing anything
2. **Edit** — minimal changes that accomplish the task; no scope creep
3. `npx tsc --noEmit` — zero errors before proceeding
4. `npx vite build` — confirm clean build
5. **Test** — follow Test Protocol below
6. **Commit** — one commit per feature or bug-fix group

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
- Do not add features not in the session scope — if I notice a gap, spawn_task it

---

## Test Protocol

Testing is a three-step process, not a one-step verification. The goal is *knowledge*, not *confirmation*. Partial success and partial confirmation are different: partial success means some things worked and some failed; partial confirmation means some things worked and we don't know about the rest.

### Step 1: Plan the test before writing it

Before touching the test tool, answer these questions:

**Visibility conditions:**
- Under what exact conditions is the new feature supposed to be visible or measurable?
- Are there conditions where it would appear to work but isn't (false positive)?
- Are there conditions where it would appear broken but isn't (false negative)?

**Tool coverage:**
- Can our current tools (robot CLI, dump, snapshot, screenshot) actually test for this?
- Are we testing existence ("the command returns something") or functionality ("the values are correct")?
- If functionality can't be tested, say so explicitly — don't let an existence check stand in for a functionality check

**Coverage gaps:**
- What aspect of this feature can we NOT test with current tools?
- Is the gap significant enough to build a new tool first?

### Step 2: Create or upgrade tools if needed, then test

If the plan reveals a tool gap:
- Implement the minimal tool that closes the gap (new robot CLI command, new dump field, new snapshot field)
- Then run the test

Test commands should be explicit sequences that would catch both "broken" and "subtly wrong":
- Don't just verify the command doesn't error — verify the output values make sense
- For economy: buy something, verify credits decreased by the right amount, verify cargo increased
- For AI: dump ships before and after tick, verify positions changed in expected direction
- For visual: read the PNG and describe what's in it — don't just confirm the file exists

### Step 3: Analyze results with precision

State results as one of:
- **Confirmed:** test proves the feature works as designed under tested conditions
- **Partial success:** X worked, Y failed — specific about which
- **Partial confirmation:** X worked, Y was not tested — specific about the gap
- **Failed:** describe what happened vs what was expected
- **Cannot test:** describe what's missing and why

Always distinguish between "the feature works" and "the test passed" — these are not the same if the test has coverage gaps.

---

## Bug Protocol

### Attempt 1–2: Direct investigation
- Read the relevant code paths
- Check for obvious causes: wrong variable, off-by-one, wrong condition
- If found: fix it, commit, done

### If still broken: Deep analysis before attempt 3

Ask and answer these questions before touching code:

1. **System map:** What systems touch the broken component? Draw the call chain mentally.
2. **Specificity:** Is it failing completely, or failing in a specific case only? Specific failures point to edge cases; complete failures point to initialization or wiring.
3. **Isolation:** Can I reproduce it in a simpler state? (e.g., does it fail right at boot, or only after certain actions?)
4. **Tool validity:** Could the test tool itself be wrong? Am I measuring the right thing?
5. **Recent change:** Did this work before? What changed since then?

### Attempt 3: One targeted fix based on the analysis

If it works: commit, document root cause.
If it still doesn't work: **skip it**. Document:
- What's broken and how to reproduce it
- What was tried
- Which systems are involved
- The most likely hypothesis

Continue with the rest of the session. Flag it in the summary. Discuss later.

**Do not spiral.** A bug I can't fix in 3 attempts + deep analysis is a bug that needs a fresh session or user input. The project is too large to let one blocker stall everything.

---

## Telemetry & Diagnosis Tools

| Tool | When to use |
|---|---|
| `dump` | Quick terminal summary during active debugging |
| `snapshot <name>` | Persistent JSON for state comparison (before/after) |
| `screenshot` | Visual — I must READ the PNG and describe what's visible |
| `cinema on` + `lookat <target>` | View any object from any angle |
| `dump ships` | AI/fleet state: positions, velocities, HP distribution, LOD |
| `dump econ` | Credits, cargo, faction rep |
| `dump map` | Entity placement, distances, spawn positions |
| `dump player` | Player position, velocity, HP — for verifying robot mode state |

---

## Architecture Principles (from modularity mandate)

- Every system should work at two scales: empire-level and personal-level
- Reuse over duplication: if building trade routes, build them for all actors (player, NPC, factions)
- The spell-book library captures systems that are complete enough to reuse
- New systems get added to the spell-book when they're stable and self-contained
- Systems interact through data (positions, prices, flags) not through direct references where avoidable

---

## Session Rhythm (for open-ended "go wild" sessions)

1. Read vision files under `project_artifacts/references/` to orient
2. Pick up from the phase plan where we left off
3. Complete one feature fully (implemented + tested + committed) before starting the next
4. At the end: summarize what was done, what was skipped, any bugs found (fixed or deferred), and what's next
