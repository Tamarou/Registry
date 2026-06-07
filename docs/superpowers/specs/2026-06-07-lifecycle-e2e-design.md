# Lifecycle E2E (Morgan → Nancy → Amara) — Design

ABOUTME: Design for the cradle-to-grave lifecycle browser E2E that exercises a tenant's
ABOUTME: full journey in its own schema, building on the tenant-isolation foundation (#231).

- Status: Draft (pending review)
- Date: 2026-06-07
- Tracks: #224 (lifecycle E2E, legs 3–5 + re-base of legs 1–2 onto per-tenant isolation)
- Builds on: #231 (tenant isolation foundation: `$self->dao`, `Tenant->provision`,
  payment-time provisioning, proven `<slug>.localhost` subdomain context), #228
  (program-location-assignment repair), #222 (free-enroll at payment), #218 (session $0
  pricing plan)
- Related/known bugs it may exercise: #225 (events.teacher_id NOT NULL), #229
  (tenant-storefront template_id NULL), #230 (slug hyphen/underscore vs subdomain)

## 1. Goal

A single, serial browser E2E that drives one tenant's entire lifecycle **in that tenant's
own Postgres schema**, with data flowing from persona to persona:

1. **Morgan** (operator) signs up, creating her tenant; then builds her program offering.
2. **Nancy** (parent) discovers Morgan's free session and enrolls her child.
3. **Amara** (teacher) takes attendance for the event Nancy's child is in.

Every persona enters through a **real flow** — Morgan creates everything she would in the
real world (sign up, invite staff, create a program, create a location, assign, generate,
publish); Nancy registers as a brand-new parent; Amara accepts her invite and marks
attendance. There is essentially no fixture seed: the journey bootstraps itself.

The lifecycle spec **supersedes** `t/playwright/morgan-program-setup.spec.js` (a registry-
schema stepping stone from #228, which contradicts per-tenant isolation). That file and its
helper `setup_morgan_lifecycle_data.pl` are removed once the lifecycle's Morgan legs are
green in-tenant.

## 2. Non-goals

- Negative/edge-case coverage (invalid input, permission denials, waitlist, payment
  failure). Those belong in focused specs; the lifecycle is the happy-path spine.
- Real Stripe charges. Tenant signup completes on the **free Solo plan** ($0), which
  provisions without invoking Stripe (foundation §4.4). The harness also strips Stripe keys.
- Fixing #229/#230/#225 as such — but the lifecycle will *exercise* their code paths and
  may surface fresh issues; the policy in §6 governs what we fix vs. file.

## 3. Architecture

One Playwright spec, `t/playwright/lifecycle.spec.js`, `mode: 'serial'` so the legs run in
order and share state. It runs under the existing Phase-1 harness (one Test::PostgreSQL DB
+ one daemon on :3001, workflows/templates imported from disk per run).

**Tenant context = subdomain.** Every tenant-scoped request targets
`http://<slug>.localhost:3001/`. Chromium and Firefox resolve `*.localhost` to loopback;
the server's `_extract_tenant_from_subdomain` reads `<slug>` from the Host header and
`$self->dao` (foundation) routes to that schema. Registry-level steps (Morgan's signup at
the platform storefront) use the bare `127.0.0.1:3001` / default host → `registry`.

**Hostname-safe, unique slug.** Morgan signs up with an all-alphanumeric org name plus a
per-run numeric suffix (e.g. `Lifecycle Arts 1780000000`). The signup slug generator
lowercases and collapses separators; with no hyphens the result is a valid DNS label and
sidesteps #230. The suffix prevents the cross-browser `tenants_slug_key` collision we hit
in #231 (chromium + firefox share one DB). The spec captures the actual provisioned slug
from the DB rather than assuming the exact transform.

**Minimal Perl helpers** (in the spec or a small `lifecycle_helpers.pl`), all tenant-aware:
- `freshToken(userId, schema)` — mint a single-use magic-link login token in the right
  schema (tenant users live in the tenant schema).
- DB assertion helpers — query a given schema for tenant/session/enrollment/attendance
  rows (JSON-aggregated in SQL to avoid `@`-sigil shell-escaping pitfalls, per #228).

## 4. The legs (data flow)

### Leg 0 — Morgan signs up (registry storefront → her tenant exists)
- Drive `tenant-signup` to completion at the platform root: profile (org name → slug),
  **users step inviting Amara as staff** (`invite_pending`), pricing (free Solo), review,
  payment (POST → `Tenant->provision` at payment-time).
- Assert: a `registry.tenants` row for the slug exists, and `<slug>.workflows` is populated
  (schema provisioned). Capture the slug for later legs.

### Leg 1 — Morgan operates her tenant (`<slug>.localhost`, authenticated)
- Log in via magic link (token minted for Morgan; she is the tenant's primary user).
- **Create a program** via `program-creation` (afterschool type, copied into her schema by
  provision).
- **Create a location** via the location-creation workflow (Morgan creates everything).
- **Assign + generate** via `program-location-assignment`: select her program, choose her
  location, `pricing_override = 0` (→ #218 free PricingPlan), generate sessions **assigning
  Amara as the teacher** (→ satisfies #225 NOT-NULL), future dates.
- **Publish** program then session via `POST /admin/programs/:id/status` and
  `/admin/sessions/:id/status`.
- Assert: the free, published session is registerable on Morgan's own storefront. In her
  tenant there is exactly one program, so the storefront marketing template's
  `$programs->[0]` IS hers (the contamination that broke #228's registry-schema assertion
  does not arise in an isolated tenant). Assert via the storefront predicate + a rendered
  callcc registration form for her session.

### Leg 2 — Nancy registers as a new parent (`<slug>.localhost` storefront)
- Unauthenticated, Nancy discovers the free session and enters registration.
- Through account-check / new-parent: create Nancy's account, add her child, register the
  child into Morgan's session; free total → free-enroll at the standard `payment` step
  (#222, no branching).
- Assert: Nancy (parent) + child + an active enrollment for the session exist in Morgan's
  schema.

### Leg 3 — Amara takes attendance (`<slug>.localhost`)
- Amara accepts her invite / logs in via magic link; her teacher dashboard (in Morgan's
  tenant) shows her assigned event.
- Open the event's attendance page; mark Nancy's child present.
- Assert: an attendance record for the child on that event exists in Morgan's schema.

## 5. Components / decomposition

- `t/playwright/lifecycle.spec.js` — the serial spec; one `test()` per leg, sharing
  captured ids (slug, programId, sessionId, childId, eventId) across legs via closure.
- `t/playwright/lifecycle_helpers.pl` (or inline) — tenant-aware token + DB-query helpers.
- Removed: `t/playwright/morgan-program-setup.spec.js`,
  `t/playwright/setup_morgan_lifecycle_data.pl`.
- No production code changes are *planned*; any that prove necessary (a missing/ broken
  real flow) follow §6.

## 6. Risks and the gate-driven policy

This spec is built **gate-driven against the running app**, the method that surfaced every
foundation bug. Each leg is verified against reality (routes/fields/behavior), never
assumed. When a leg's underlying flow is missing or broken, **stop and surface** (capture
the server exception, decide with the maintainer, file the bug) rather than silently
seeding around it. The named fallbacks below are the exception, applied only when the
maintainer agrees a flow is out of this spec's scope.

| Unknown | If it fails | Fallback (only with agreement) |
| --- | --- | --- |
| Invite **acceptance**: can an `invite_pending` Amara log in / appear on the teacher dashboard before accepting? | Add an accept-invite step | Mint Amara a tenant login token directly |
| **Tenant-scoped auth tokens**: are magic tokens for tenant users resolvable on the subdomain? | Fix token/schema resolution | Generate tokens in tenant schema explicitly |
| **Tenant-scoped registration**: does registration create Nancy+child+enrollment in Morgan's schema? | Fix/route the workflow (real bug) | — (core to the lifecycle; do not seed around) |
| **Location creation** in-tenant misbehaves | Fix if cheap | Seed the location into the tenant |
| Slug not hostname-safe / not routable (#230) | Constrain org name to alphanumeric | — |
| Cross-browser slug collision (#231 class) | Per-run unique suffix | — |

Production bugs blocking the journey get fixed (with TDD/tests as the foundation work did);
tangential ones get filed (as #225/#226/#229/#230 were).

## 7. Testing strategy

- The spec **is** the integration/E2E test. Run: `npx playwright test lifecycle --workers=1
  --project=chromium --reporter=list` (one harness at a time; add firefox before merge).
- Every leg asserts both a UI outcome (driving real controls) and a DB fact in the correct
  schema. No action-extraction crutches (per the #231 review): drive the actual rendered
  buttons.
- Success = all legs green on chromium and firefox; the superseded Morgan spec removed; full
  Playwright suite still green.

## 8. Open questions (to resolve during build)

- Exact teacher-invite lifecycle (acceptance vs. immediate usability) — verified in Leg 0/3.
- Whether the registration workflow already carries tenant context end-to-end on the
  subdomain, or needs a fix — verified in Leg 2.
- The precise admin publish routes/fields in-tenant (they worked in registry for #228;
  confirm under subdomain auth).
