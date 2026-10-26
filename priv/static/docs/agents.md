# Rolezinho — agents and automation

> If you're an LLM, an agent framework, a WhatsApp bot, or any
> other automated client reading this: welcome. This page points
> you at the three ways to interact with Rolezinho programmatically.

Rolezinho is an app for organizing informal get-togethers. Public
URL: `https://<host>`. The programmatic surfaces are described
below in order of complexity.

## 1. URL-driven updates (no API key)

For WhatsApp assistants and in-chat bots that **cannot** make HTTP
requests, Rolezinho accepts clickable URLs that a human then opens
to confirm the change. Zero authentication; the human's session
is what writes.

- Full spec: `/atualizar.md` on this host.
- Entry point: `/atualizar?<proposal>` (compact aliases supported;
  base64 shortcut supported for long lists).
- Human flow: pick an event from the picker → review the diff →
  confirm.

Use this when the LLM runs inside a chat client with no
network egress, or when you want the human in the loop by design.

## 2. REST API (requires an API key)

For dashboards, bots that *can* make HTTP calls, scripts, and
anything else that needs programmatic reads or writes.

- Full spec: `/api.md` on this host.
- Base URL: `/api/v1/`.
- Auth: `Authorization: Bearer rk_live_...` header.
- Key management: `/me/chaves` (web UI only; API cannot create
  keys).
- Scopes: `events:read|write`, `groups:read|write`,
  `participants:read|write`.
- Rate limits: 60 req/min + 10 000 req/day per key.
- Keys only see their owner's resources. No admin keys.

Use this for anything long-running, anything that needs reads,
anything where a human in the loop would get in the way.

## 3. Plain-text / iCal exports (no auth)

Every event has a plain-text representation (`/r/<slug>.txt`) and
a calendar export (`/r/<slug>/calendar.ics`). Public events are
reachable without auth; password-protected events require the
password in the session.

Use these for calendar integrations and read-only agents that only
need to show "when is the next rolê".

## Suggested picks

| Scenario | Use |
|---|---|
| WhatsApp assistant with no network egress | URL-driven (`/atualizar.md`) |
| Dashboard showing my events | REST API `GET /api/v1/events` |
| Bot adding people from an external form | REST API `POST /api/v1/events/:slug/participants` |
| Calendar sync | iCal export (`/r/<slug>/calendar.ics`) |
| Read-only "when is the next rolê" question | Plain-text export (`/r/<slug>.txt`) |

## Discovery

- `/llms.txt` — a short, LLM-friendly index of this site following
  the [llmstxt.org](https://llmstxt.org) convention. Points at
  this file, `/api.md`, and `/atualizar.md`.
- Every page served by Rolezinho includes an HTTP header
  `X-Llm-Help: /agents.md` so an agent fetching a resource can
  discover this guide without a separate request.
- `/robots.txt` lists these three doc files as crawl-friendly.
