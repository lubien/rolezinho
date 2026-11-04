---
updated_at: 04/11/2026
---

# 0003 — Settle-up payment plan: integer cents, largest-first matching, always derived

## Context

The "Dividir no final" split method (`:settle_up`, see
[split-method.md](../flow/split-method.md)) has no price. Attendees record what they
spent, the total is shared equally among the main list, and the app tells people who
sends how much to whom. Three choices in `Rolezinho.Event.Settlement` look arbitrary
from the outside and are easy to "fix" into a bug:

1. How to divide a total that doesn't split evenly.
2. Which transfers to propose.
3. Whether the plan is stored or recomputed.

## Decision

**Integer cents, leftover cents to the first people on the list.** Shares are
`div(total, people)`, and the `rem(total, people)` leftover cents add one cent each to
the first people. Shares always sum to the total, so transfers always sum to what is
owed — nobody is told to send R$ 33,333..., and nobody is left R$ 0,01 short. Floats
are never used.

**Greedy largest-first matching.** The largest debt pays the largest credit, and the
remainder of whichever side is bigger carries over. This takes at most `people − 1`
transfers, and ties keep list order, so the plan doesn't reshuffle while nobody changes
their numbers. Finding the true minimum number of transfers is NP-hard (it reduces to
subset-sum) and would save a transfer at best in a group of friends; a stable, readable
plan matters more than an optimal one.

**The plan is derived, never stored.** It is recomputed from the main list on every
render and every text export. When someone joins, leaves, or edits what they spent,
the plan follows. The alternative — a "freeze plan" action — needs storage, a way to
unfreeze, and rules for what a ✅ means against a frozen plan that no longer matches the
list. Paid marks live on the attendee and survive recomputation.

## Consequences

- A change to the list after people have sent money can change the amounts in the plan.
  A sender's ✅ stays, even if their share moved; the organizer reconciles, as with the
  paid check everywhere else in the app (declarations, not bank confirmations).
- The leftover cents always land on the first people on the list, not spread at random.
  Deterministic, and at most one cent per person.
- Plan size is bounded by the list size, so recomputing it on each render is cheap; no
  caching is needed.
- `Settlement` is pure (no database, no web), and its test file checks the invariants
  directly: every balance settles to exactly zero and transfers never exceed
  `people − 1`, across randomized inputs.
