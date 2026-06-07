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

**Hostname-safe, unique slug — always read from the DB.** Morgan signs up with an
all-alphanumeric org name plus a per-run numeric suffix (e.g. `Lifecycle Arts 1780000000`).
`Tenant->provision` normalizes the slug to underscores (lowercase, separators → `_`), which
**is** a valid subdomain label and passes the `tenant` helper's `[a-z][a-z0-9_]+` sanitizer
(#230 only bites human-named hyphen slugs, which the alphanumeric name avoids). The suffix
prevents the cross-browser `tenants_slug_key` collision we hit in #231 (chromium + firefox
share one DB). **Hard rule:** the spec captures the actual provisioned slug from
`registry.tenants` after Leg 0 — it never derives the slug in JS.

**Per-run uniqueness covers every identity, not just the slug.** Because chromium and
firefox run against the same DB, *every* persona record created during a run must carry the
per-run suffix or it collides on the second browser (exactly as the slug did in #231):
Morgan's org/email, Amara's invite email, Nancy's email/username, and the child's name. Use
one run-scoped suffix (e.g. the Leg 0 timestamp) for all of them.

**Minimal Perl helpers** (in the spec or a small `lifecycle_helpers.pl`), all tenant-aware:
- `freshToken(userId, schema)` — mint a single-use magic-link **login** token. **Hard
  requirement:** it connects via `Registry::DAO->new(url => $dbUrl, schema => $tenantSlug)`
  and writes to `<slug>.magic_link_tokens`. The token's FK references `<slug>.users`, and the
  auth controller resolves it via `$self->dao` (the subdomain's tenant schema), so a
  registry-schema token (the pattern in the old `setup_teacher_test_data.pl`) would be
  unresolvable on the subdomain and must never be used. Always `purpose => 'login'` (see
  Leg 3 on why not `invite`).
- DB assertion helpers — query a given schema for tenant/session/enrollment/attendance
  rows (JSON-aggregated in SQL to avoid `@`-sigil shell-escaping pitfalls, per #228).

**Login mechanics.** Login tokens require verify-then-consume; the existing `loginWithToken`
helper (GET `/auth/magic/<token>` → click submit POST) already drives both steps, so it is
reused as-is. The GET resolves the token via the subdomain's tenant dao — another reason the
token must live in the tenant schema.

## 4. The legs (data flow)

### Leg 0 — Morgan signs up (registry storefront → her tenant exists)
- Drive `tenant-signup` to completion at the platform root: profile (org name → slug),
  **users step inviting Amara as staff** (`invite_pending`), pricing step (select the free
  plan, or it auto-skips when no subscription plans are configured — `TenantPayment` falls
  back to the Solo $0 plan either way, so signup completes regardless), review, payment
  (POST → `Tenant->provision` at payment-time).
- Assert: a `registry.tenants` row for the slug exists, and `<slug>.workflows` is populated
  (schema provisioned). **Capture for later legs:** the slug; Morgan's user id
  (`SELECT id FROM <slug>.users WHERE user_type='admin'`); Amara's user id
  (`WHERE user_type='staff'`). `freshToken` needs these UUIDs, which the signup completion
  page does not emit.
- Provisioning copies **every** registry workflow except `tenant-signup` into Morgan's
  schema (foundation `Tenant->provision`), so `program-creation`, `location-creation`,
  `program-location-assignment`, `admin-dashboard`, `tenant-storefront`, and
  `summer-camp-registration` are all present for the later legs — this is verified, not
  assumed (it is the anti-drift design of provision).

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
- Assert: the free, published session is registerable on Morgan's own storefront. On a
  tenant subdomain, `/` renders the **disk catalog** template
  (`templates/tenant-storefront/program-listing.html.ep`: `grouped_programs` →
  `article.landing-feature-card` per program, each with a `Register` callcc form posting to
  `/tenant-storefront/<run>/callcc/<reg_workflow>`). This is the filesystem fallback because
  #229 leaves the tenant's DB copy of that template unusable — it is *not* the registry
  marketing landing, and not `$programs->[0]` logic. Assert: Morgan's program card is
  present and carries a `Register` callcc form for her session (capture its hidden
  `session_id`). The `reg_workflow` the form targets is `summer-camp-registration` (the
  template's default), which provision copied into the tenant — this settles Leg 2's target.

### Leg 2 — Nancy registers as a new parent (`<slug>.localhost` storefront)
- First verify (build-time gate) that the `tenant-storefront/program-listing` render
  exposes a callcc registration form, and capture the registration workflow slug it targets
  (presumed `summer-camp-registration`, which provision copied into the tenant). The
  callcc runs the target via the subdomain's tenant dao, so it executes in Morgan's schema.
- Unauthenticated, Nancy discovers the free session and enters that registration workflow.
- Through account-check / new-parent: create Nancy's account, add her child, register the
  child into Morgan's session; free total → free-enroll at the standard `payment` step
  (#222, no branching).
- Assert: Nancy (parent) row, her child (`<slug>.family_members`), and an active enrollment
  for the session all exist **in Morgan's schema** (`<slug>`), not in `registry` — this
  proves registration is tenant-scoped end to end.

### Leg 3 — Amara takes attendance (`<slug>.localhost`)
- Amara logs in with a **freshly-minted `login` token** (via `loginWithToken`), NOT her
  signup `invite` token. The auth controller redirects `invite`-purpose tokens to
  `/auth/register-passkey` (Auth.pm), which would derail the test into a WebAuthn ceremony;
  the signup invite's only job was to create Amara's account so Morgan could assign her as
  teacher. (Her account is already usable as a `teacher_id`; formal invite acceptance /
  passkey is out of scope and tested elsewhere.)
- Her teacher dashboard (in Morgan's tenant) shows her assigned event.
- **Roster-linkage gate (where Legs 1–3 meet):** Amara's attendance roster for the event is
  populated only if Nancy's Leg 2 enrollment ties to the session whose event Amara was
  assigned in Leg 1. Verify the chain enrollment → session → event(teacher = Amara) before
  asserting; if the roster is empty, that mismatch is the bug to fix/surface, not a missing
  attendance API.
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
| **Tenant-scoped auth tokens**: are magic tokens for tenant users resolvable on the subdomain? (Confirmed mechanic: token must live in `<slug>.magic_link_tokens`; resolved by `freshToken`'s hard requirement in §3.) | Fix token/schema resolution | — (handled by design) |
| Amara `login`-token verify→consume on the subdomain works via `loginWithToken` | Drive GET+POST explicitly | — |
| **Tenant-scoped registration**: does registration create Nancy+child+enrollment in Morgan's schema? | Fix/route the workflow (real bug) | — (core to the lifecycle; do not seed around) |
| Storefront callcc actually targets a registration workflow present in the tenant | Add the slug / fix the template (#229-adjacent) | — |
| **Location creation** in-tenant misbehaves; confirm slug (`location-creation` vs `location-management`) | Fix if cheap | Seed the location into the tenant |
| Cross-browser collision (#231 class) on any per-run identity (slug, Morgan/Amara/Nancy emails, child) | Per-run unique suffix on ALL of them | — |
| **Email-verification gating**: does login or enrollment require `email_verified_at`? Passwordless signup leaves users unverified; `freshToken` bypasses the email but not a gate. | Set `email_verified_at` in the helper, or drive verification | — |
| **Roster linkage**: Nancy's enrollment must reach the event Amara teaches (Leg 1↔2↔3 seam) | Fix the enrollment→event chain (real bug) | — |

### Resolved-by-foundation (do not re-litigate)
A spec review initially flagged several "blockers" that were artifacts of reading
pre-foundation code; verified resolved on current `main`:
- Workflow-copy completeness — `Tenant->provision` copies all registry workflows except
  `tenant-signup` (the deleted `create_tenant_directly` only copied two).
- `program-location-assignment` present in the tenant — provision copies it.
- generate-events date handling — `GenerateEvents.parse_start_date` accepts the ISO date the
  form submits (fixed in #228); no 1970-epoch trap.
- Underscore slug is hostname-safe and routes (provision normalizes; sanitizer accepts `_`).

### File-don't-fix (surfaced by review, not on the lifecycle path)
- `RegisterTenant._send_invitation_email` mints the invite token against the registry db
  while the invited user lives in the tenant schema — a cross-schema/FK hazard. The
  lifecycle does not use the invite token (Amara uses a `login` token), so it is not
  blocking; file it as a standalone bug.

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
