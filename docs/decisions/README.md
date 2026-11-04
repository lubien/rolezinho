# Architecture decisions (`docs/decisions/`)

A record of the project's significant technical decisions, in ADR (Architecture Decision
Record) style. Each file describes **one decision**: the context that motivated it, the
options evaluated, the choice made, and the consequences.

Unlike `docs/flow/` (which describes the current behavior of a product flow), this folder
holds the **why** behind engineering choices — the thing that normally gets lost in git and
turns into "why was it done this way?" months later.

## Principles

- One file per decision. kebab-case name with a sequential numeric prefix:
  `NNNN-short-title.md` (e.g. `0001-event-password-stored-in-plaintext.md`).
- English, no emojis, objective.
- A decision describes the current state and the reasoning. If a decision is revisited
  later, write a new ADR that supersedes it and references the previous one — don't rewrite
  history.
- `updated_at: DD/MM/YYYY` frontmatter.
- ADR candidate: any choice a future reader might mistake for a bug, or would undo without
  knowing the cost.

## Index

| # | Decision | Doc |
| --- | --- | --- |
| 0001 | Event password stored in plaintext | [0001-event-password-stored-in-plaintext.md](0001-event-password-stored-in-plaintext.md) |
| 0002 | Accounts for creation only, via GitHub | [0002-accounts-for-creation-only.md](0002-accounts-for-creation-only.md) |
| 0003 | Settle-up payment plan: integer cents, largest-first matching, always derived | [0003-settle-up-payment-plan.md](0003-settle-up-payment-plan.md) |
