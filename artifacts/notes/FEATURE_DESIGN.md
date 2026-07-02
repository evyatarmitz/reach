# Feature Design Reference

Cleaned and translated feature list from game analysis (June 2026).
Source: breakdown of X4, Stellaris, NMS, Space Engineers, Minecraft, Black Flag, FTL, Kenshi, RimWorld, Dwarf Fortress, Elite Dangerous.

Rejected/duplicate features have been removed. Special cases carry [NOTE].
This is a design intent document, not a build queue — see TODO.md for what to build next.

---

## Economy & Trade

- Supply chains: production requires real inputs; nothing generates value from nothing
- Dynamic market pricing: supply and demand moves prices; shortages are opportunities
- NPC merchants operate independently, respond to real prices [NOTE: not AI with scripted behavior — NPCs with their own lives and goals who happen to trade; they discover routes, not follow assigned ones]
- Physical cargo limits: storage has hard capacity; you cannot carry or store infinite goods
- Market manipulation: corner supply of a resource to drive its price up
- Operation overview: visibility into income and expenses across your holdings [NOTE: form TBD — should feel in-world, not a sterile dashboard]
- Trade agreements between factions: sustained commerce creates economic dependency

---

## NPC Production Environments

- Stations and outposts are living environments: NPCs work, have morale, can be dissatisfied or rebel — NOT boxes that produce items on a timer
- NPCs have roles: worker, specialist, officer, captain — each role does something and has its own needs
- Habitation is physical space: NPCs live somewhere; conditions matter
- Defense is staffed: no automated turrets unless an NPC is operating one
- Operations need many NPCs with many roles, not a single manager per station
- Stations are physically constructed: a real process, not instant placement

---

## Fleet & Ships

- NPCs captain and crew ships: they have their own behavior, not just order execution
- Fleet formations and hierarchy: groups maintain positions; sub-commanders act independently
- Ship archetypes for different roles (combat, cargo, mining, carrier, etc.) [NOTE: NO hardcoded size tiers — the engine must handle ships of any scale; this is a critical design constraint, biggest complaint about X4]
- Crew experience grows over time in role
- Crew morale affects performance: neglected crew underperforms or causes problems
- Carrier operations: large ships hold and deploy smaller ones
- Field repair is limited: patch up to ~10% hull in the field; full repair needs a facility [NOTE: makes logistics matter — you can't undo a bad fight with a repair ship next to you]
- Supply logistics: ammunition and fuel need physical resupply; no teleportation
- Ship ownership can be transferred: captured ships can be kept, given away, or sold
- Emergency escape: crew can abandon ships
- Blueprint auto-build: player defines a ship design, construction happens automatically over time — one click, long wait [NOTE: replaces manual block-by-block construction; block-level building is very late scope]

---

## Navigation & Space

- Scannable interest points: wrecks, anomalies, unknown signals emit detectable readings [NOTE: concept from X4 signal leaks — exact mechanic TBD, but the idea of "space has things to find if you look" is wanted]
- Abandoned ships: find, board, investigate, claim derelicts
- Space has real travel time: distance costs time and fuel; nothing is instant
- Sector control: factions contest and change ownership of space without player input
- Scanner upgrades: better equipment reveals more of the unknown

---

## Faction System

- Reputation per faction: numerical standing gates what each faction will do with you
- Reputation gates: docking, trade, services, cooperation all depend on standing
- Factions fight each other without player input: the universe acts independently
- Player can support or oppose factions with real assets (ships, money, manpower)
- Named faction NPCs: recurring characters you build relationships with over time
- Faction-driven objectives [NOTE: NOT questlines — more like HOI4/Bannerlord: ongoing situations, war efforts, and faction needs that offer rewards for contribution; no forced narrative arcs or accept/decline screens]
- Rank progression within organizations: rise through a faction over time
- Faction identity is emergent from history and actions, not pregame selection [NOTE: see Empire Identity below]

---

## Player Character

- Physical embodiment always: player is a body in the world at all times
- EVA: operate in vacuum with a suit
- Hacking: directly interact with systems in the environment
- Ship boarding: enter enemy ships, fight through them room by room
- Home base: a specific physical place the player designates as home

---

## Space Combat

- Shield system: absorbs hits, takes time to recharge after depleting
- Subsystem targeting: aim for specific parts (engines, weapons, specific compartments)
- Weapon configuration: different weapons, different targeting modes
- Projectile weapons including area denial (mines, missiles)
- Capital combat: very large ships fight fundamentally differently than small ones
- Ship size is uncapped: no hardcoded size tiers; engine designed to handle any scale [NOTE: this is a foundational design constraint — must be true from the start]
- Everything that fights is crewed: no autonomous combat drones; ships are run by NPCs

---

## Resource Extraction

- Extraction at multiple scales: from personal mining to industrial operation
- Extraction varies by environment: asteroid, gas cloud, planet surface, underground, ocean
- Processing chains: raw material → refined product → manufactured good
- Resource extraction is done by NPCs, not autonomous drones

---

## Empire & Faction Identity

- Different factions have genuinely different characteristics: shaped by their history, choices, and circumstances
- NO pregame trait/ethics/civic selection for player or NPC factions [NOTE: all differences are emergent — you don't pick "militarist" at start; you become militarist through what you do; same for NPC factions]
- Empire identity is observable from the outside by others: reputation, observed behavior, known history

---

## Population Systems

- Population tracked with individual granularity: named individuals or meaningful groups
- Jobs and roles: what someone does determines what gets produced
- Population has needs: housing, food, safety, social contact — unmet needs have consequences
- Player can do whatever they want with populations [NOTE: no moral gating — slavery, liberation, purging, forced labor are all options; the game doesn't lock you out; consequences exist and are real, but the choice is yours]
- Population moves: migration follows opportunity or pressure from the player or events
- Captive and enslaved populations: a full mechanic with real simulation, not a checkbox

---

## Technology Progression

- No tech tree: knowledge advances through finding, capturing, stealing, and reverse-engineering
- Captured enemy technology can be studied and reproduced
- Skills and understanding grow through doing, not abstract menus or XP

---

## Diplomacy & Alliances

- Resource trade between factions: ongoing exchanges with real economic effects
- Movement agreements: populations can cross borders
- Defensive relationships [NOTE: "your people and allies may not stand by you if you don't have this" — not a game mechanic that blocks war declaration; it's a social reality that affects whether they actually show up]
- Coalition building: groups of factions with shared interests; real social dynamics, not menu locks
- Power hierarchy: dominant and subordinate factions with real power dynamics
- Authority weakens with distance [NOTE: "population fatigue" concept — control costs more the further it extends from the center; the further from your power base, the less authority you effectively have]

---

## Planets & Worlds

- Planet characteristics are real traits [NOTE: not flat stat bonuses — "this world has more minerals than average" is a characteristic that plays differently, not a +15% mining yield modifier]
- Terraforming: change what a world is over long timescales with sustained effort
- Planet types play radically differently: not just aesthetics, but what you can do there
- Megaprojects: very large constructions that meaningfully change the game
- World events: things happen requiring player response or decision

---

## Espionage

- Sabotage operations against enemy assets
- Technology theft: stealing tech IS the tech progression mechanic
- Counter-espionage: detect and stop operations against you
- Intelligence networks: built over time, enable more sophisticated actions

---

## Exploration

- Procedural locations: not everything is known at start; the world is discovered
- Environmental hazards: weather, hostile conditions, dangerous regions
- Layered exploration: space, planet surface, underground, underwater, ship interiors
- Abandoned structures with history: lore through exploration, not cutscenes
- Unknown species: first contact with alien life is a real event
- Scanning tools: equipment that reveals what is out there
- Derelict exploration: abandoned ships and stations with content and risk
- Scavenging as economy: salvage from wreckage, sell what you find [NOTE: "no loot chests" — scavenging is about finding physical wreckage and stripping it, not opening a chest with random loot]

---

## Settlements & Infrastructure

- Physical infrastructure: not just ships, but bases, outposts, stations you build
- Infrastructure has real requirements: power, supply lines, crew
- Food and supply production: supply chains include biological needs of NPCs
- Transport networks: move resources between locations you control
- Settlement management: NPCs live in what you build

---

## NPC Depth

- Characters have histories and backstories: who they are shapes behavior
- Personality traits: persistent character-level traits affect how they act
- Characters have needs and moods: unmet needs cause friction
- Characters form relationships with each other: affects loyalty and cooperation
- Skill specialization: characters are better at some things than others
- Permanent death: losing an NPC is real
- Skills grow by doing: not through menus
- Imperfect orders: officers can misunderstand, delay, or ignore orders — authority is not perfect execution
- Characters remember events: what happened to them affects them going forward
- Legendary skill levels: characters can become genuinely exceptional and known for it

---

## Ship Interior Combat

- Boarding: physically enter enemy ships
- Room-by-room fighting: corridors, compartments, chokepoints
- Ship quality affects boarding difficulty [NOTE: NOT boss fight patterns with telegraphed moves — a more important ship has better-armed crew and more of them; the difference is capability, not designed defeat sequences]
- Enemies can capture instead of kill: being taken prisoner is an outcome
- Capturing a ship means it is yours: do whatever you want with it
- Interior fires and hazards: things go wrong inside ships during fights

---

## Consequences & Notoriety

- Actions create enemies: hostile factions escalate their response over time
- Reputation spreads: news of what you do reaches people who care
- Faction responses scale with your history
- Reducing notoriety costs something: bribe, lie low, or deal with the consequences

---

## Fleet Operations

- Send fleets on autonomous tasks while you do other things
- Fleet operations generate income and can accomplish objectives
- Fleet ships can be lost on missions: loss is real
- Fleet composition matters for mission outcomes
- Fleet generates passive income when operating trade routes

---

## FTL-Inspired Ship System Management

- Ship power is finite: total capacity must be allocated between systems (shields, engines, weapons)
- Crew station matters: who is assigned where affects that system's performance
- Per-system damage: each system has its own health; partial damage reduces effectiveness before failure
- Weapon type differentiation: different weapons work differently against different defenses
- Interior room-by-room atmosphere: rooms can lose atmosphere; matters for crew survival

---

## Very Late Scope

These are wanted but should not be built until the core simulation is solid:

- Block-level ship construction (Space Engineers style) — very late; blueprint auto-build covers early needs
- Detailed creature and megafauna simulation — discuss when we address alien biology
- Detailed construction mechanics — covered by blueprint system until then
- Character aging [NOTE: possibly never needed — if nobody plays long enough for it to matter naturally, it adds complexity for no return; revisit if play sessions show players reaching that scale]
- Complex crafting chains (brewing equivalents, etc.)

---

## Pending Discussion

- **World continues without player focus**: when player is in one place, the rest of the world is still acting — this is core to the vision but has deep implications for how time, save/load, and the simulation work. Discuss when we address lore and world simulation design.
- **Alien biology and megafauna**: what does alien life look like, how does it interact with the player's operations? Set aside for a dedicated design session.
