# Playwright Lifecycle E2E — Design

ABOUTME: Design for the Playwright E2E launch gate that exercises Registry's critical production workflows.
ABOUTME: Covers harness re-enablement in CI and a Morgan -> Nancy -> Amara program lifecycle journey.

- Status: Approved (design), revised after spec review
- Date: 2026-06-03
- Author: perigrin (with Claude)

## Goal

The production-launch gate is a set of Playwright E2E tests that *exercise* the
critical production workflows in a real browser against a running app — not unit
or integration coverage. This design defines how to get there.

The headline journey proves the full operational lifecycle hangs together:

> **Morgan** (manager / program developer) builds a free, registerable program ->
> **Nancy** (parent) registers a child into that program ->
> **Amara** (teacher) runs the session by taking attendance for that child.

All three legs operate on the *same* program, session, and event on one tenant,
so the test proves the data linkage end to end, in the browser.

## Why now

Playwright is disabled in CI (`.github/workflows/playwright.yml.disabled`, commit
`6bcddfe`). The most heavily invested code path — payment retry (#204), webhook
dedup (#158), idempotent finalization (#205/#212), confirmation email (#206) — has
no end-to-end browser coverage, and nothing gates the launch on a working journey.

## Verified ground truth (confirmed against source, not assumed)

These facts were checked in the repo and shape the design. Implementers must
re-confirm exact field names and step slugs against the running app; do not trust
prose route lists.

- **Workflows are dispatched through a single catch-all** `any('/:workflow')` ->
  `workflows#` controller (`lib/Registry.pm:661`). There are *no* bespoke
  per-workflow routes like `/program-creation-enhanced/<run>/<step>`. Run/step
  navigation happens under the generic workflow controller. The exact Morgan setup
  path (a single orchestrating workflow vs. `program-setup` dispatching to
  sub-workflows via callcc) must be confirmed against the running app before the
  Morgan leg is written.
- **Publishing is an API POST, not a UI button**: `POST /admin/programs/:id/status`
  and `POST /admin/sessions/:id/status` (`lib/Registry.pm:599,602`); a program must
  be published before its session. Tests drive these via `page.request.post(...)`.
- **Decision steps are custom step classes, not declarative if/else.** A step's
  `process()` can return `next_step => '<slug>'` to branch, overriding the default
  linear `depends_on` chain (see `Registry::DAO::WorkflowSteps::AdminDropDecision`
  returning `next_step => 'process-decision'`; routing handled in
  `WorkflowRun.pm`). This is the idiomatic way to make payment optional.
- **Payment is currently env-coupled, which is the smell we fix.** `Payment.pm:31`
  creates enrollments directly when `agreeTerms` is set **and `STRIPE_SECRET_KEY` is
  absent**; otherwise (`Payment.pm:36`) it calls Stripe regardless of total. That
  conflates "does this program require payment?" (a pricing/workflow concern) with
  "is Stripe configured?" (an environment concern). The design replaces this with a
  decision step (below); `STRIPE_SECRET_KEY` then means only "is Stripe reachable
  (test vs live)," never "is payment required."
- `db_manager.pl` imports only `tenant-signup.yml`; a full `workflow import` is
  required for any other workflow to resolve.

## Decomposition

Too large for a single spec. Three phases, each its own plan and PR. Ordering
reflects "CI gate first."

| Phase | Outcome | Depends on |
|-------|---------|------------|
| **1. Harness + CI** | Existing Playwright specs run green in CI and gate PRs | — |
| **2. Lifecycle journey** | Morgan -> Nancy -> Amara free-program journey green in CI | Phase 1 |
| **3. Expand (separate spec)** | Per-flow Morgan depth + paid (Stripe Checkout) variant | Phase 2 |

---

## Phase 1 — Harness stabilization + CI re-enablement

### Problem

`t/playwright/fixtures/base.js` spawns, **per individual test**, a fresh
`Test::PostgreSQL` DB (via a long-lived `db_manager.pl`) *and* a `morbo` server on a
**random port**, then polls `/health`. This per-test thrash is the root cause of CI
instability and why Playwright was disabled.

### Approach (chosen): one shared server + one shared DB for the whole run

Single server + single DB, stood up once per run; fixed `baseURL`; specs serial.
Cheapest, fastest, most production-like, at the cost of refactoring specs that
assume an empty/fresh DB.

### Harness changes (ordered)

1. **Port + config alignment (first atomic commit).** `playwright.config.js`
   `baseURL` is `localhost:3001`; the disabled CI file boots morbo on `:3000`; the
   fixture overrides `page.goto` to a random port. Pick **one port (3001)**, align
   the CI server command, uncomment/enable the `webServer` block, and remove the
   `page.goto` override and per-test server spawn from `registryPage`.
2. **`fullyParallel: false`** (or document `--workers=1` for local runs). The shared
   DB is only safe serially; `fullyParallel: true` + `workers:1` in CI still leaves
   local parallel runs colliding. Make the config self-consistent.
3. **`globalSetup`**: provision one DB (sqitch deploy), then run
   `carton exec ./registry workflow import registry` and `template import registry`
   so **all** workflows resolve (not just `tenant-signup`). Tear down at run end.
4. **`fixtures/base.js`**: thin fixtures pointing at the shared server/DB; preserve
   `registryPage` helpers (`workflowUrl`, `expectWorkflowLayout`,
   `expectHTMXResponse`); drop the server/DB spawning entirely.
5. Reuse the `Test::PostgreSQL` teardown-order fix already in `Test::Registry::DB`,
   or use a CI service-container DB.

### Spec refactors (from the audit)

Robust as-is: `smoke-test`, `auth-journeys`, `workflow-layout-visual`,
`component-integration`, `jordan-landing-journey`. `deploy-validation` stays on its
own project (runs against production).

| Spec | Fix |
|------|-----|
| `all-workflows-visual` | **Distinct from collision fixes:** references non-existent slugs (`user-registration` -> use `user-creation`; `payment-processing` -> no equivalent; `session-creation` and `event-creation` do exist) **and** uses the wrong URL prefix `/workflow/:slug` instead of `/:slug` per the `any('/:workflow')` catch-all (`lib/Registry.pm:661`). Rewrite with real slugs and correct URLs, or delete. |
| `custom-domains` | Run-unique domain names; self-contained remove/re-add; robust pre-test cleanup. |
| `tenant-signup` | Run-unique org names/subdomains; drop empty-table assumptions. |
| `admin-dashboard`, `jordan-admin-dashboard` | Unique seeded ids; log in fresh per test rather than one shared token. |
| `camp-registration`, `parent-dashboard`, `waitlist-flow`, `drop-transfer` | Parameterize `setup_*_test_data.pl` with a run-id; assert on owned data only. |
| `amara-attendance` | Unique teacher/student/event ids; **seed events at today's date** (see Phase 2). |

### CI workflow

Restore `.github/workflows/playwright.yml` from `.disabled`, updated to: boot the
shared server + DB on the agreed port, install browsers, `npx playwright test`,
upload report/traces on failure. Gate on `pull_request` to `main`. Reconcile the
Postgres version with the main CI job. **Do not set `STRIPE_SECRET_KEY`** in this
job (keeps the free path in demo mode).

### Phase 1 success criteria

- Intermediate: all existing spec files pass **locally** with `--workers=1` against
  a single shared DB.
- Then: `npx playwright test` is green in CI (chromium + firefox), serial.
- The Playwright job gates PRs to `main`; no per-test `morbo`/`Test::PostgreSQL`
  spawning remains.

---

## Phase 2 — Morgan -> Nancy -> Amara lifecycle journey

One narrative spec sharing the Phase 1 harness and a single seeded tenant. Uses a
**free** program (no Stripe). State is handed across legs via a single
`lifecycle-setup.pl` that seeds the tenant + three users (Morgan/Nancy/Amara) and
emits a JSON state bag read once in `test.beforeAll` (the pattern
`amara-attendance.spec.js` already uses). All event dates are seeded at
**`DateTime->now`** so the teacher dashboard ("today's events") is populated on the
day the test runs.

### Leg 1 — Morgan builds a free, registerable program

Magic-link login as a `staff`/`admin` user, then through the workflow UI
(`/:workflow` dispatch — confirm exact slug/steps against the running app):
program -> location -> assign program to location and generate events
(`status='draft'`, `events.teacher_id = Amara`, dated today+). Set a `pricing_plans`
row with `amount = 0`. Publish via `POST /admin/programs/:id/status` then
`POST /admin/sessions/:id/status`. Assert the program is visible on the parent
storefront (both program and session `status='published'`, future end date).

### Leg 2 — Nancy registers a child (free path)

Registration workflow: landing -> account-check (create account, magic link) ->
select-children (**verify the HTMX add-a-child path is handled by the workflow
controller** — a Phase 1 prerequisite check) -> camper-info -> session-selection
(Morgan's published session) -> **payment-required decision step** -> [free path]
complete. Because Morgan's session is priced at $0, the decision step routes around
`payment` to a free-enrollment/`complete` path (no Stripe). Assert an `enrollments`
row, `status='active'`, linking the child to Morgan's session; confirmation
notification queued.

### Leg 3 — Amara runs the session (attendance)

Magic-link login as Amara (`staff`); `GET /teacher/` -> attendance for the event
(`teacher_id = Amara`, dated today) -> roster lists Nancy's child (via
`session_events` + active enrollment) -> `POST /teacher/attendance/:event_id` marks
present. Assert an `attendance_records` row for that child/event.

### Data linkage (the chain under test)

```
program(status=published) -> session(status=published, amount=0)
  -> events(teacher_id=Amara, date=today) -> session_events(session_id,event_id)
enrollment(session_id, student=child, status=active)
attendance(event_id, student=child, marked_by=Amara)
```

### Phase 2 prerequisites (verify/fix before the journey can pass)

1. **Payment-required decision step (small app change, TDD).** Add a custom decision
   step class before `payment` in the registration workflow that computes the
   enrollment total (`Registry::DAO::Payment->calculate_enrollment_total`) and
   returns `next_step => 'payment'` when total > 0, or routes to a free-enrollment
   path (creates the enrollment, no charge) when total == 0. Wire it into the
   registration workflow YAML. This decouples payment from `STRIPE_SECRET_KEY`; the
   env var no longer decides whether payment happens. The legacy
   `!$ENV{STRIPE_SECRET_KEY}` branch in `Payment.pm:31` becomes dead for this path
   and should be removed as cleanup. `STRIPE_SECRET_KEY` continues to select Stripe
   test-vs-live only.
2. **HTMX add-a-child** (`SelectChildren.pm` returns `htmx_response => 1`): confirm
   `Registry::Controller::Workflows` handles that response so a child added inline
   actually appears. If not, use the full-page path or fix the controller. Verify
   as a standalone check in Phase 1, not mid-Phase-2.
3. **Setup invariants**: generated events set `teacher_id = Amara` and dates =
   today; enrollment ends `status='active'` (else Amara's roster is empty).
4. Publishing via the admin API is acceptable for the test; the missing UI publish
   button is a separate product gap (file an issue).

### Phase 2 success criteria

- The three-leg journey passes in CI on the shared harness.
- Asserted DB state proves the Morgan -> Nancy -> Amara linkage.
- The free path is taken because the decision step sees a $0 total (pricing-driven),
  not because of any `STRIPE_SECRET_KEY` setting; no Stripe interaction occurs.

---

## Phase 3 — Expand (separate spec)

Tracked as its own design doc, not implemented here.

- Per-flow Morgan depth (program-type management, curriculum, session management,
  staff/user creation, pricing, locations).
- **Paid variant**: Morgan sets a priced program; Nancy completes Stripe Checkout
  (test mode, `4242`, redirect + webhook); assert paid enrollment + confirmation
  email. **Hard dependencies not present today**: Stripe test-mode keys in CI and a
  webhook-delivery mechanism (Stripe CLI forwarding or a stubbed webhook endpoint).
  (The $0-vs-paid decision is already handled by the Phase 2 decision step, so the
  paid variant only adds the Stripe-charge branch and its assertions.)

## Risks

- **Shared-DB collisions** — the chosen model's main risk; mitigated by the audit's
  per-spec refactor list (run-unique ids, scoped assertions, cleanup) and
  `fullyParallel: false`.
- **Over-specified routes** — the earlier flow tracing invented per-workflow URLs
  that do not exist; implementers must confirm the actual `/:workflow` navigation
  against the running app before writing each leg.
- **Date-sensitive assertions** — seed events at `DateTime->now`, not fixed dates.
- **CI flakiness recurrence** — the per-run server/DB plus `Test::PostgreSQL`
  teardown must be solid; reuse the landed teardown-order fix or a service-container DB.

## Out of scope

- Mobile/webkit browser projects (commented out in config).
- Visual-regression snapshot baselines beyond the existing visual specs.
- The paid Stripe Checkout journey (Phase 3, separate spec).
