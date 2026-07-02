# Spell Book — AI Usage Guide

This is a local code library. You can search it, retrieve entries, and add new ones using the `sb` CLI.

## Commands

```
sb search <query>       Search by name, language, tags, or contract description
sb get <name|id>        Get full source for an entry
sb add <entry.json>     Add a new entry (see format below)
sb init-ai              (one-time) copies this file into the current folder
sb update               Update sb to the latest release
sb app                  Launch the Spell Book desktop app
```

## Searching

`sb search` matches against name, language, tags, and the contract field.

Examples:
```
sb search collision
sb search python
sb search "2d math"
```

Output format per result:
```
<name>  [<id>]  <language>  <tag1>, <tag2>
```

## Getting an entry

```
sb get resolve-aabb
```

Prints the contract, inputs, outputs, scars, and full source code.

## Adding an entry

Create a JSON file with this structure and run `sb add <file>`:

```json
{
  "id": "my-function-js",
  "name": "myFunction",
  "language": "javascript",
  "tags": ["math", "pure"],
  "origin": "project-name",
  "status": "stable",
  "contract": "One sentence: what this does.",
  "inputs": "param1 (type) — description",
  "outputs": "return value description",
  "scars": "known gotchas, edge cases, things that burned you",
  "notes": "anything else",
  "sourceContent": "function myFunction() { ... }"
}
```

### Field rules

- `id` — lowercase, hyphens only, unique. Convention: `<slug>-<lang-ext>` e.g. `resolve-aabb-js`
- `name` — display name, usually the function/class name as written in code
- `language` — lowercase: `javascript`, `typescript`, `python`, `rust`, `go`, `lua`, `glsl`, etc.
- `status` — `stable` | `scarred` | `experimental`
- `contract` — one sentence, what it does (not how)
- `scars` — the most important field after source. What broke, what surprised you, what to watch for.
- `sourceContent` — the full source as a string. Escape as needed for JSON.

### Minimal valid entry

Only `id`, `name`, `language`, and `sourceContent` are required. All other fields default to empty.
