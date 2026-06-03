# Playwright Lifecycle E2E — Design

ABOUTME: Design for the Playwright E2E launch gate that exercises Registry's critical production workflows.
ABOUTME: Covers harness re-enablement in CI and a Morgan -> Nancy -> Amara program lifecycle journey.

- Status: Approved (design)
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

Playwright is currently disabled in CI (`.github/workflows/playwright.yml.disabled`,
commit `6bcddfe "Disable Playwright CI tests and simplify for local-only use"`).
The most heavily invested code path — payment retry (#204), webhook dedup (#158),
idempotent finalization (#205/#212), confirmation email (#206) — has no end-to-end
browser coverage. Nothing currently gates the launch on a working browser journey.

## Decomposition

This is too large for a single spec. It splits into three phases, each with its own
plan and implementation cycle. The ordering reflects "CI gate first": prove the
harness in CI before investing in new specs.

| Phase | Outcome | Depends on |
|-------|---------|------------|
| **1. Harness + CI** | Existing Playwright specs run green in CI and gate PRs | — |
| **2. Lifecycle journey** | Morgan -> Nancy -> Amara free-program journey green in CI | Phase 1 |
| **3. Expand (later)** | Per-flow Morgan depth + paid (Stripe Checkout) variant | Phase 2 |

Each phase is a separate branch/PR. Phases 2 and 3 are out of scope for the first
implementation plan except as outlined here.

---

## Phase 1 — Harness stabilization + CI re-enablement

### Problem

The current fixtures (`t/playwright/fixtures/base.js`) spawn, **per individual
test**, a fresh `Test::PostgreSQL` database (via a long-lived `db_manager.pl`
process) *and* a `morbo` server on a **random port**, then poll `/health`. This
per-test thrash — N databases + N servers + random ports + 30s health waits +
`Test::PostgreSQL` teardown fragility — is the root cause of CI instability and
why Playwright was disabled.

### Approach (chosen): one shared server + one shared DB for the whole run

- A single Registry server and a single database are stood up once per Playwright
  run. `baseURL` is fixed. Specs run **serially** (`workers: 1`, already set for CI).
- Seed data is loaded once before the run; specs that need their own data create it
  with **run-unique identifiers** (timestamp / run-id suffix) rather than hardcoded
  names, and clean up state they mutate.
- This is the cheapest and fastest infra and most production-like, at the cost of
  refactoring the specs that currently assume an empty/fresh database.

Rejected alternatives: per-test isolation (the current flaky model); per-file or
per-worker isolation (lower spec-refactor cost but more harness moving parts and,
for per-worker, residual collision risk with `workers:1`).

### Harness changes

1. **`playwright.config.js`**: enable a `webServer` block that boots one Registry
   server against the shared test DB on a fixed port; set `baseURL` to it; keep
   `workers: 1` and `retries: 2` in CI.
2. **`fixtures/base.js`**: replace the per-test `testDB` + per-test `morbo` spawn
   with thin fixtures that point at the shared server/DB. Preserve the helper
   methods on `registryPage` (`workflowUrl`, `expectWorkflowLayout`,
   `expectHTMXResponse`, etc.) so specs keep working.
3. **Database lifecycle**: one DB provisioned for the run (schema deployed via
   sqitch, workflows/templates imported), torn down at the end. Reuse the
   `Test::PostgreSQL` teardown-ordering fix already in `Test::Registry::DB` where
   applicable, or a dedicated CI service-container DB.

### Spec refactors (from the audit)

Robust as-is (no/low change): `smoke-test`, `auth-journeys`,
`workflow-layout-visual`, `all-workflows-visual`, `component-integration`,
`jordan-landing-journey`. `deploy-validation` runs against production and is left
on its own project.

Require refactor for shared-DB safety:

| Spec | Fix |
|------|-----|
| `custom-domains` | Replace hardcoded domain names with run-unique names; make remove/re-add self-contained; robust pre-test cleanup. |
| `tenant-signup` | Replace hardcoded org names/subdomains with run-unique values; drop empty-table assumptions. |
| `admin-dashboard`, `jordan-admin-dashboard` | Ensure seeded data uses unique ids; log in fresh per test rather than relying on one shared token. |
| `camp-registration`, `parent-dashboard`, `waitlist-flow`, `drop-transfer` | Parameterize `setup_*_test_data.pl` with a run-id so each returns unique ids; assert on owned data only. |
| `amara-attendance` | Unique teacher/student/event ids; assert on owned roster only. |

### CI workflow

Restore `.github/workflows/playwright.yml` (from the `.disabled` copy), updated to:
boot the shared server + DB, install Playwright browsers, run `npx playwright test`,
upload the HTML report and traces on failure. Gate on `pull_request` to `main`.
Reconcile Postgres version with the main CI job.

### Phase 1 success criteria

- `npx playwright test` is green in CI across the existing specs (chromium +
  firefox), run serially against the shared server/DB.
- The Playwright job gates PRs to `main`.
- No per-test `morbo`/`Test::PostgreSQL` spawning remains.

---

## Phase 2 — Morgan -> Nancy -> Amara lifecycle journey

A single narrative, authored as one or more serial spec(s) sharing the Phase 1
harness and one seeded tenant. Uses a **free** program (no Stripe) for this first
gate; the paid variant is Phase 3.

### Leg 1 — Morgan builds a free, registerable program

Magic-link login as a `staff`/`admin` user, then through the browser:

1. `program-creation-enhanced`: program type -> curriculum details -> requirements
   & schedule -> review -> create (program `status='draft'`).
2. `location-management`: create a location.
3. `program-location-assignment`: select program -> choose location -> configure ->
   generate events (creates the session + events, `status='draft'`,
   `events.teacher_id = Amara`).
4. Free pricing: a `pricing_plans` row with `amount = 0` for the session.
5. Publish: `POST /admin/programs/{id}/status {status:'published'}` then
   `POST /admin/sessions/{id}/status {status:'published'}` (program must publish
   first). Publishing is API-driven; there is no UI button today.
6. Assert the program is visible/registerable on the parent storefront
   (requires both program and session `status='published'` and a future end date).

### Leg 2 — Nancy registers a child (free path)

`summer-camp-registration` workflow: landing -> account-check (create account via
magic link) -> select-children -> camper-info -> session-selection (selects
Morgan's published session) -> payment (**$0 -> demo/free enrollment, no Stripe**)
-> complete. Assert an `enrollments` row with `status='active'` linking the child
to Morgan's session, and that a confirmation notification is queued.

### Leg 3 — Amara runs the session (attendance)

Magic-link login as Amara (`staff`); `GET /teacher/` -> attendance for the event
(`events.teacher_id = Amara`) -> roster lists Nancy's child (joined via
`session_events` + active enrollment) -> `POST /teacher/attendance/{event_id}`
marks present. Assert an `attendance_records` row for that child/event.

### Data linkage (the chain under test)

```
program(status=published) -> session(status=published, amount=0)
  -> events(teacher_id=Amara) -> session_events(session_id,event_id)
enrollment(session_id, student=child, status=active)
attendance(event_id, student=child, marked_by=Amara)
```

### Phase 2 prerequisite app fixes (blockers found during tracing)

These are small app changes that must land before the journey can pass cleanly.
Each is a candidate for its own commit/PR ahead of (or within) Phase 2:

1. **Free-payment guard** — in `Registry::DAO::WorkflowSteps::Payment`, when the
   computed total is `0`, skip Stripe entirely and create the enrollment directly,
   regardless of whether `STRIPE_SECRET_KEY` is set. Today the $0 path is only
   reliable when the key is unset.
2. **`select-children` add-a-child path** — confirm (or add) the UI path for adding
   a new child mid-workflow; the journey needs Nancy to enroll a child.
3. **Publish affordance** — acceptable to drive publish via the admin API in the
   test, but note the missing UI button as a product gap (separate issue).
4. **Setup invariants** — Morgan's generated events must set `teacher_id = Amara`
   and the enrollment must be `status='active'` for Amara's roster to populate.

### Phase 2 success criteria

- The three-leg journey passes in CI against the shared harness.
- The asserted DB state proves the Morgan -> Nancy -> Amara linkage.
- No Stripe interaction occurs on the free path.

---

## Phase 3 — Expand (later)

- Per-flow Morgan depth (independent specs for program-type management, curriculum,
  session management, staff/user creation, pricing, locations).
- Paid-registration variant: Morgan sets a priced program; Nancy completes Stripe
  Checkout (test mode, `4242` card, redirect + webhook); assert paid enrollment and
  confirmation email. Exercises the recently-hardened payment path end to end.

## Risks

- **Shared-DB collisions** — the chosen model's main risk; mitigated by the audit's
  per-spec refactor list (run-unique ids, scoped assertions, cleanup).
- **CI flakiness recurrence** — the per-run server/DB plus `Test::PostgreSQL`
  teardown must be solid; reuse the teardown-order fix already landed for the Perl
  suite, or a CI service-container DB.
- **Phase 2 app gaps** — the free-payment guard and child-add path are real
  prerequisites, not just test code; sequence them first.

## Out of scope

- Mobile/webkit browser projects (commented out in config; revisit later).
- Visual-regression snapshot baselines beyond what the existing visual specs do.
- The paid Stripe Checkout journey (Phase 3).
