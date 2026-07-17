# Domain Docs

How the engineering skills should consume this repo's domain documentation when exploring the codebase.

## Layout: single-context

One `CONTEXT.md` + `docs/adr/` at the repo root (no `CONTEXT-MAP.md`, no monorepo structure).

## Before exploring, read these

- **`CONTEXT.md`** at the repo root, if it exists. Doesn't exist yet — no HarmonyOS app-domain term has been resolved. **Proceed silently** about its absence; the `/domain-modeling` skill creates it lazily once there's an actual app to model.
- **`docs/adr/`** — read ADRs that touch the area you're about to work in, always. `0001` (founding rationale, human/AI division of labor) and `0002` (GitHub Flow collaboration mechanics — dispatch, merge authority, gated categories, source-of-truth order) apply to essentially everything done in this repo; read them before proposing workflow, tooling, or process changes.

## Use the glossary's vocabulary

Once `CONTEXT.md` exists: when your output names a domain concept (in an issue title, a refactor proposal, a hypothesis, a test name), use the term as defined there. Don't drift to synonyms the glossary explicitly avoids.

## Flag ADR conflicts

Once `docs/adr/` has entries: if your output contradicts an existing ADR, surface it explicitly rather than silently overriding.
