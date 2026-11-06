# Flow docs (`docs/flow/`)

Product documentation, one file per flow/feature. Each `.md` file in this folder
describes **the current behavior** of a system flow — what the user sees and what happens
behind it, the way it is implemented today.

The `flow-documenter` skill (`.claude/skills/flow-documenter/SKILL.md`) is the **single
source of truth** for the writing/updating workflow and for each doc's template — don't
duplicate the template here. This README holds the principles and the index of documented
flows.

## Principles

- **Current behavior, not history.** A doc describes the present. **No changelog
  section** — change history lives in git.
- **Written from the code**, not from memory: read the LiveViews, contexts, and templates
  before writing.
- **English, no emojis**, objective and direct. Filenames in kebab-case, no accents (e.g.
  `event-page.md`, `password-gating.md`).
- **One flow per file.**
- Every doc carries `updated_at: DD/MM/YYYY` frontmatter, refreshed on each edit.
- An outdated doc is what makes the bug come back: **whoever changes a flow updates the
  doc in the same change.**

## Mandatory coverage

Beyond the template, every flow doc in this project covers:

- **The access level** of each action described: anonymous visitor, session with an event
  unlocked by password, or admin (see `SECURITY.md`). It's the distinction a new reader
  needs most — this app has no user accounts, and anyone arriving with the Phoenix
  ecosystem's default assumptions will read the flow wrong.
- **Live behavior** (PubSub), where present.
- **The three outputs** (page, `.txt`, `.ics`), when the flow touches an event's
  information.

## Index

One entry per doc; update this table when creating a new flow (the `flow-documenter`
skill does it automatically).

| Flow | Type | Doc |
| --- | --- | --- |
| Split method (Método de separação) | Transactional flow | [split-method.md](split-method.md) |

## What doesn't go in a doc

- Changelog / change history (that's git's job).
- Implementation details that don't affect behavior (internal refactors).
- Duplication of a rule that lives in `.claude/rules/`, `SECURITY.md`, or `DESIGN.md` —
  reference it instead.
