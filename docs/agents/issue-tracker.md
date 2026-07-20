# Issue tracker: GitHub

Issues and PRDs for this repo live as GitHub issues. Use the `gh` CLI for all operations.

## Conventions

- **Create an issue**: `gh issue create --title "..." --body "..."`. Use a heredoc for multi-line bodies.
- **Read an issue**: `gh issue view <number> --comments`, filtering comments by `jq` and also fetching labels.
- **List issues**: `gh issue list --state open --json number,title,body,labels,comments --jq '[.[] | {number, title, body, labels: [.labels[].name], comments: [.comments[].body]}]'` with appropriate `--label` and `--state` filters.
- **Comment on an issue**: `gh issue comment <number> --body "..."`
- **Apply / remove labels**: `gh issue edit <number> --add-label "..."` / `--remove-label "..."`
- **Close**: `gh issue close <number> --comment "..."`

Infer the repo from `git remote -v` — `gh` does this automatically when run inside a clone.

## Pull requests as a triage surface

**PRs as a request surface: no.** This is a personal learning/practice repo with no outside contributors, so there is no external-PR queue to triage.

## When a skill says "publish to the issue tracker"

Create a GitHub issue.

## When a skill says "fetch the relevant ticket"

Run `gh issue view <number> --comments`.

## Repo-specific notes

- Remote: `github.com/Habit130/harmonyos-dev`, **public**. Started private; switched to public because GitHub only offers branch protection on private repos with a paid plan, and enforcing "no direct push to `main`" technically (not just by convention) was worth that trade-off.
- `main` has branch protection: PR required before merging, direct pushes/force-pushes/branch deletion blocked, enforced even for the repo admin. No required-approving-review count — this repo has one GitHub identity acting as both PR author and reviewer, so a mandatory-approval rule would deadlock (an author can't approve their own PR). Actual review happens at the strong-agent/`advisor` layer per `docs/adr/0002-github-flow-collaboration-mechanics.md`, not GitHub's native review UI.
- The scraped HarmonyOS doc corpus (`docs/harmonyos-guides/`) is intentionally excluded from this remote via `.gitignore` — it's a large (~2G) local reference corpus, not source the team collaborates on. Never suggest un-ignoring it to "fix" a push; that exclusion is deliberate. Being public does not change this — the corpus was never in git history to begin with.
