# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout: single-context

One `CONTEXT.md` + `docs/adr/` at the repo root (no `CONTEXT-MAP.md`, no monorepo structure).

## Before exploring, read these

- **`CONTEXT.md`** at the repo root — exists, holds the domain glossary for 序拼(XùPīn), the repo's first app. Read it before working on anything app-domain-related.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in, always. `0001` (founding rationale, human/AI division of labor) and `0002` (GitHub Flow collaboration mechanics — dispatch, merge authority, gated categories, source-of-truth order) apply to essentially everything done in this repo; `0003` (IME app architecture, security mode) and `0004` (dictionary data source, license) apply specifically to the 序拼 app. Read them before proposing workflow, tooling, or process changes, or before implementing the app.

## Use the glossary's vocabulary

When your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined in `CONTEXT.md`. Don't drift to synonyms the glossary explicitly avoids.

## Flag ADR conflicts

Once `docs/adr/` has entries: if your output contradicts an existing ADR, surface it explicitly rather than silently overriding.
