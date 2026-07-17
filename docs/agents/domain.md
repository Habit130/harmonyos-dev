# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout: single-context

One `CONTEXT.md` + `docs/adr/` at the repo root (no `CONTEXT-MAP.md`, no monorepo structure).

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, if it exists.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in.

Neither exists yet. **Proceed silently** — don't flag their absence, don't suggest creating them upfront. The `/domain-modeling` skill (reached via `/grill-with-docs` and `/improve-codebase-architecture`) creates them lazily when terms or decisions actually get resolved, once there's an actual app to model.

## Use the glossary's vocabulary

Once `CONTEXT.md` exists: when your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined there. Don't drift to synonyms the glossary explicitly avoids.

## Flag ADR conflicts

Once `docs/adr/` has entries: if your output contradicts an existing ADR, surface it explicitly rather than silently overriding.
