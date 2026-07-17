# Triage Labels

The skills speak in terms of two category roles and five state roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

## Category roles

| Label in mattpocock/skills | Label in our tracker | Meaning                       |
| --------------------------- | --------------------- | ------------------------------ |
| `bug`                       | `bug`                  | Something is broken            |
| `enhancement`               | `enhancement`          | New feature or improvement     |

## State roles

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| --------------------------- | --------------------- | ----------------------------------------- |
| `needs-triage`              | `needs-triage`         | Maintainer needs to evaluate this issue  |
| `needs-info`                | `needs-info`           | Waiting on reporter for more information |
| `ready-for-agent`           | `ready-for-agent`      | Fully specified, ready for an AFK agent  |
| `ready-for-human`           | `ready-for-human`      | On an issue: requires human implementation. On a PR: strong-agent verification passed but the diff touches a gated category (see `docs/adr/0002-github-flow-collaboration-mechanics.md`), so a human must do the actual merge. |
| `wontfix`                   | `wontfix`              | Will not be actioned                     |

Every triaged issue carries exactly one category role and one state role. No repo-specific label vocabulary exists yet beyond this — using the defaults as-is. Edit the right-hand columns if this repo's GitHub labels ever diverge from the defaults.
