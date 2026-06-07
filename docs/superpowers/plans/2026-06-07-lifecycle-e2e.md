# Lifecycle E2E (Morgan → Nancy → Amara) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A single serial Playwright spec that drives one tenant's full lifecycle — Morgan signs up and builds a free program, Nancy enrolls her child, Amara takes attendance — entirely in that tenant's own Postgres schema via the `<slug>.localhost` subdomain.

**Architecture:** Gate-driven E2E. The spec *is* the deliverable, so each leg's TDD loop is RED (drive the real rendered controls; it fails against the running app, frequently surfacing a real prod bug in the in-tenant path) → GREEN (fix-or-file the bug per policy, add the DB assertion, make it pass) → REFACTOR (extract helpers). Legs are serial and share captured state (slug, user ids, program/session/child/event ids). Built on the merged tenant-isolation foundation (#231): `$self->dao` routes to the request tenant, `Tenant->provision` gives a tenant all workflows, signup provisions at payment-time, `<slug>.localhost` resolution is proven.

**Tech Stack:** Perl 5.42 / Mojolicious / PostgreSQL schemas; Playwright (chromium + firefox) under the Phase-1 harness (one Test::PostgreSQL DB + one daemon on :3001, workflows/templates imported from disk per run); `psql` / inline `carton exec perl` for DB assertions.

**Spec:** `docs/superpowers/specs/2026-06-07-lifecycle-e2e-design.md`

---

## Working method (read before starting any task)

This plan is **gate-driven against the running app**, the method that surfaced every foundation bug. For each leg:

1. Write the leg: drive the **actual rendered controls** (click real buttons; never extract a form `action` and POST it — that crutch hid the #231 blocker), then a **DB assertion in the correct schema**.
2. Run it. When it fails, **read the failure**: for a 500, capture the server exception from the run output / `test-results/<...>/error-context.md`. Do not guess.
3. **Diagnose: prod bug or test bug?**
   - Prod bug **blocking the journey** → fix it (with a test, as the foundation did), or apply a §6 fallback **only with the maintainer's agreement**.
   - Prod bug **tangential** → file an issue (as #225/#226/#229/#230 were) and route the leg around it if the spec allows.
   - Test bug → fix the spec.
4. When a leg is green, **commit**, then move to the next.
5. If a leg hits a wall that needs a non-trivial prod change or a scope decision, **STOP and surface to the maintainer** rather than grinding.

Run a single spec: `npx playwright test lifecycle --workers=1 --project=chromium --reporter=list --timeout=120000` (the harness auto-starts/stops the DB+server; one run at a time — single port). Add `--project=firefox` before the final task.

---

## File structure

- **Create** `t/playwright/lifecycle_helpers.pl` — tenant-aware Perl helpers invoked via `carton exec perl`: mint a tenant-schema login token; run a read query against a named schema returning JSON. One responsibility: cross the JS→Perl→DB boundary safely (scalar sigils only; JSON-aggregate in SQL — the `@`-sigil shell-escape lesson from #228).
- **Create** `t/playwright/lifecycle.spec.js` — the serial spec; one `test()` per leg, sharing captured ids via closure; `mode: 'serial'`.
- **Remove (final task)** `t/playwright/morgan-program-setup.spec.js`, `t/playwright/setup_morgan_lifecycle_data.pl` — superseded.

---

## Task 0: Tenant-aware helpers + spec skeleton

**Files:**
- Create: `t/playwright/lifecycle_helpers.pl`
- Create: `t/playwright/lifecycle.spec.js`

- [ ] **Step 1: Write the helpers (RED — prove they work standalone before the spec leans on them)**

`lifecycle_helpers.pl` exposes two subcommands so the spec can shell out without `@`-sigil pain. Keep the DAO object alive in a variable (Mojo::Pg GC, per #231).

```perl
#!/usr/bin/env perl
# ABOUTME: Tenant-aware helpers for the lifecycle E2E: mint tenant-schema login
# ABOUTME: tokens and run JSON-returning read queries against a named schema.
use 5.42.0;
use lib qw(lib t/lib);
use Registry::DAO;
use Registry::DAO::MagicLinkToken;

my ($cmd, @args) = @ARGV;
my $url = $ENV{DB_URL} or die "DB_URL required\n";

if ($cmd eq 'login-token') {
    my ($schema, $user_id) = @args;
    my $dao = Registry::DAO->new(url => $url, schema => $schema); # keep alive
    my (undef, $plaintext) = Registry::DAO::MagicLinkToken->generate(
        $dao->db, { user_id => $user_id, purpose => 'login', expires_in => 24 }
    );
    print $plaintext;
}
elsif ($cmd eq 'query-json') {
    # query-json <schema> <sql-with-?-placeholders> <bind...>
    my ($schema, $sql, @bind) = @args;
    my $dao = Registry::DAO->new(url => $url, schema => $schema); # keep alive
    my $json = $dao->db->query(
        qq{SELECT COALESCE(json_agg(t), '[]'::json)::text AS j FROM ($sql) t}, @bind
    )->hash->{j};
    print $json;
}
else { die "unknown command: $cmd\n" }
```

JS wrappers in `lifecycle.spec.js` (top of file):

```javascript
const { test, expect } = require('./fixtures/base');
const { execSync } = require('child_process');

function helper(testDB, args) {
  return execSync(
    `carton exec perl t/playwright/lifecycle_helpers.pl ${args.map(a => `'${a}'`).join(' ')}`,
    { cwd: process.cwd(), env: { ...process.env, DB_URL: testDB.dbUrl }, encoding: 'utf8' }
  ).trim();
}
// Mint a login token for a user in a tenant schema, then drive the GET+POST login.
function loginToken(testDB, schema, userId) { return helper(testDB, ['login-token', schema, userId]); }
function queryJson(testDB, schema, sql, ...bind) { return JSON.parse(helper(testDB, ['query-json', schema, sql, ...bind])); }

async function loginWithToken(page, token) {
  await page.goto(`/auth/magic/${token}`);
  await page.waitForSelector('button[type="submit"]');
  await page.click('button[type="submit"]');
  await page.waitForLoadState('networkidle');
}
```

- [ ] **Step 2: Smoke-test the helpers via a throwaway assertion**

Add a temporary `test('helpers smoke', ...)` that creates a tenant via `Tenant->provision` (inline perl), mints a login token for a seeded user in that schema, and asserts `queryJson` returns the row. Run:
`npx playwright test lifecycle --workers=1 --project=chromium --reporter=list -g "helpers smoke"`
Expected: PASS (token minted in tenant schema; query returns the row). If the token or query fails, fix the helper now — every later leg depends on it.

- [ ] **Step 3: Establish the run-scoped suffix + serial skeleton**

In `lifecycle.spec.js`, set `test.describe.configure({ mode: 'serial', timeout: 180000 })`, a module-level `const RUN = String(Date.now())`, and a shared `state = {}` object. Define the personas' unique identities from `RUN`: org name `Lifecycle Arts ${RUN}`, Morgan/Amara/Nancy emails like `morgan_${RUN}@test.com`, Nancy username + child name suffixed with `RUN`. (Per spec §3: **every** identity carries the suffix, not just the slug — chromium+firefox share one DB.)

- [ ] **Step 4: Remove the smoke test, commit the skeleton + helpers**

```bash
git add t/playwright/lifecycle_helpers.pl t/playwright/lifecycle.spec.js
git commit -m "Lifecycle E2E: tenant-aware helpers + serial spec skeleton"
```

---

## Task 1: Leg 0 — Morgan signs up (her tenant comes into existence)

**Files:** Modify `t/playwright/lifecycle.spec.js`

Reference: `t/playwright/tenant-signup.spec.js` already drives the full signup and verifies tenant+schema via the DB (the test I added in #231). Reuse that flow; extend it to (a) invite Amara as staff in the users step, (b) capture user ids.

- [ ] **Step 1: Write Leg 0 (RED)** — `test('Leg 0: Morgan signs up and her tenant is provisioned', ...)`:
  - `goto('/')` at the platform root (bare host → registry); click through `tenant-signup`: profile (org name = `state.orgName`, billing email = Morgan's), **users step** — add Amara as a team member (staff) with `state.amaraEmail` (drive the real "add team member" controls; verify they exist), pricing (select free plan or let it auto-skip), review (accept terms → proceed), payment (click the real submit → provisions).
  - Assert "Welcome to Registry" (or the real completion copy).
  - Capture state from the DB: `state.slug` = `SELECT slug FROM registry.tenants WHERE ...` (match on the unique org/email — do **not** derive the slug in JS); `state.morganId` = `SELECT id FROM <slug>.users WHERE user_type='admin'`; `state.amaraId` = `... WHERE user_type='staff'`.
  - Assert: `<slug>.workflows` count > 0 (schema provisioned) and includes `program-creation`, `program-location-assignment`, `summer-camp-registration`.

- [ ] **Step 2: Run it; diagnose failures per the working method**

`npx playwright test lifecycle --workers=1 --project=chromium --reporter=list -g "Leg 0"`
Likely gate points to verify against reality: the users step's actual field names for inviting staff; whether the invited Amara lands in `<slug>.users` with a usable id (provision copies users — confirm the invited team member is among them). If inviting a team member during signup isn't wired, STOP and surface (it's core to Leg 3's teacher).

- [ ] **Step 3: GREEN** — make Leg 0 pass; fix-or-file any prod bug per policy. **Commit.**

```bash
git add t/playwright/lifecycle.spec.js && git commit -m "Lifecycle E2E Leg 0: Morgan signs up, tenant provisioned, Amara invited"
```

---

## Task 2: Leg 1 — Morgan operates her tenant (subdomain, authenticated)

**Files:** Modify `t/playwright/lifecycle.spec.js`

All requests target `http://${state.slug}.localhost:3001/`. Reference the (registry-schema) `morgan-program-setup.spec.js` for the exact program-creation / program-location-assignment / publish routes and fields — they are verified working; this re-runs them under subdomain auth in Morgan's schema.

- [ ] **Step 1: Morgan logs in on her subdomain (RED→GREEN)**
  - `loginWithToken(page, loginToken(testDB, state.slug, state.morganId))` after navigating the page's baseURL context to the subdomain (set the URL explicitly on each `goto` since the token must be consumed on `<slug>.localhost` so `$self->dao` resolves her tenant).
  - Assert she reaches an authenticated tenant page (e.g. `/admin/dashboard` renders).
  - Gate: confirm the tenant-schema login token resolves on the subdomain (spec §3). If not, this is the auth seam — diagnose before proceeding.

- [ ] **Step 2: Create a program** via `program-creation` (slug confirmed in #228): program-type-selection (`afterschool`) → curriculum-details (name = `state.programName = 'Lifecycle Art ' + RUN`, description) → requirements-and-patterns → review-and-create (confirm). Assert `/complete`. Capture `state.programId` from `<slug>.projects WHERE name=?`.

- [ ] **Step 3: Create a location** via the location-creation workflow. Gate: confirm the workflow slug (`location-creation` vs `location-management`) and its fields against the running app. Drive it to completion; capture `state.locationId` from `<slug>.locations`. (Fallback per §6, only with agreement: seed the location.)

- [ ] **Step 4: Assign + generate** via `program-location-assignment`: select-program (`state.programId`) → choose-locations (`state.locationId`) → configure-location (capacity, `pricing_override = 0`) → generate-events (future `start_date`, duration, **assign Amara as teacher** via `teacher_assignments[<locationId>] = state.amaraId`, confirm) → complete. Capture `state.sessionId` (and the event id) via the `<slug>` session_events→events join (the JSON-agg query from #228). Assert a `<slug>.pricing_plans` row with amount 0 for the session (#218 free plan).

- [ ] **Step 5: Publish** program then session: `POST /admin/programs/${programId}/status` then `/admin/sessions/${sessionId}/status` with `status=published` + CSRF token from `meta[name=csrf-token]` (pattern from #228). Set the session's future `start_date`/`end_date` if generate-events didn't (storefront needs `end_date >= CURRENT_DATE`).

- [ ] **Step 6: Assert storefront registerability (spec §Leg 1, corrected)** — `goto('http://${slug}.localhost:3001/')` unauthenticated; the **disk catalog** template renders `article.landing-feature-card` for Morgan's program with a `Register` callcc form. Assert the card for `state.programName` is visible and its form carries `input[name=session_id][value=state.sessionId]`. Capture `state.regWorkflow` from the form action (expect `summer-camp-registration`).

- [ ] **Step 7: GREEN + commit.** Each sub-step that surfaces a prod bug → fix-or-file. **Commit** when Leg 1 is green.

```bash
git add t/playwright/lifecycle.spec.js && git commit -m "Lifecycle E2E Leg 1: Morgan builds + publishes a free program in her tenant"
```

---

## Task 3: Leg 2 — Nancy registers as a new parent

**Files:** Modify `t/playwright/lifecycle.spec.js`

Reference `t/playwright/camp-registration.spec.js` for the account-check/new-parent controls. The registration runs via the storefront callcc on `<slug>.localhost`, so it executes in Morgan's schema.

- [ ] **Step 1: Enter registration from the storefront (RED)** — unauthenticated on `<slug>.localhost`, submit the `Register` callcc form for Morgan's session (click the real button). Assert landing on the registration workflow (`account-check` step). Workflow steps: landing → account-check → select-children → camper-info → session-selection → payment → complete.

- [ ] **Step 2: New-parent account + child + enroll** — drive account-check's **create_account** path (Nancy's name/email `state.nancyEmail`/username, all `RUN`-suffixed), add her child (`state.childName`), proceed through camper-info and session-selection (choose Morgan's session), reach `payment`. With a $0 total the standard Payment step free-enrolls (#222, no branching) → `complete`.

- [ ] **Step 3: Assert tenant-scoped (spec §Leg 2)** — Nancy's user row in `<slug>.users` (not registry), her child in `<slug>.family_members`, and an **active enrollment** for `state.sessionId` in `<slug>` (capture `state.childId`, `state.enrollmentId`). This proves registration is tenant-scoped end to end.

- [ ] **Step 4: Run, diagnose, GREEN, commit.** The new-parent create flow and tenant-scoped registration are the unknowns here — verify each against reality; fix-or-file. **Commit.**

```bash
git add t/playwright/lifecycle.spec.js && git commit -m "Lifecycle E2E Leg 2: Nancy registers her child and free-enrolls in Morgan's session"
```

---

## Task 4: Leg 3 — Amara takes attendance

**Files:** Modify `t/playwright/lifecycle.spec.js`

Reference `t/playwright/amara-attendance.spec.js` for the dashboard + attendance-marking controls. Amara uses a **login** token (NOT her invite token — invite redirects to `/auth/register-passkey`, spec §Leg 3).

- [ ] **Step 1: Roster-linkage gate (RED, the Leg 1↔2↔3 seam)** — before driving the UI, assert via `queryJson(<slug>)` that the enrollment→session→event chain ties Nancy's child to the event whose `teacher_id = state.amaraId`. If empty, that mismatch is the bug to fix/surface (not a missing attendance API).

- [ ] **Step 2: Amara logs in + opens her event** — `loginWithToken(page, loginToken(testDB, state.slug, state.amaraId))` on the subdomain. Assert her teacher dashboard shows the assigned event; navigate to its attendance page.

- [ ] **Step 3: Mark Nancy's child present** — drive the real attendance control (the Web Component / form `amara-attendance.spec.js` uses). Assert an attendance record for `state.childId` on the event exists in `<slug>` (the table/route confirmed against the attendance code).

- [ ] **Step 4: Run, diagnose, GREEN, commit.**

```bash
git add t/playwright/lifecycle.spec.js && git commit -m "Lifecycle E2E Leg 3: Amara marks attendance for Nancy's child"
```

---

## Task 5: Chain, cross-browser, supersede, full-suite green

**Files:** Modify/remove as below.

- [ ] **Step 1: Full serial run, chromium** — `npx playwright test lifecycle --workers=1 --project=chromium --reporter=list`. All four legs green in one run (state flows leg→leg).

- [ ] **Step 2: Cross-browser run** — add firefox: `npx playwright test lifecycle --workers=1 --project=chromium --project=firefox --reporter=list`. Both green. If firefox collides on any identity, the `RUN` suffix isn't reaching that record — fix (the #231 lesson generalized).

- [ ] **Step 3: Supersede the stepping stones** — delete `t/playwright/morgan-program-setup.spec.js` and `t/playwright/setup_morgan_lifecycle_data.pl`. Grep for any other reference to them and clean up.

- [ ] **Step 4: Full Playwright suite green** — `npx playwright test --workers=1 --project=chromium --reporter=list`. No regression from the removal or new spec. (The repo's known-good baseline; if a pre-existing failure appears, confirm it predates this work.)

- [ ] **Step 5: Commit + open PR**

```bash
git add -A
git commit -m "Lifecycle E2E: chain all legs, run cross-browser, supersede morgan-program-setup"
git push -u origin feat/lifecycle-e2e
gh pr create --base main --title "Lifecycle E2E: Morgan -> Nancy -> Amara in-tenant" --body "..."
```

- [ ] **Step 6: Watch CI to green** (the storefront date-fixtures are fixed on main; if anything else surfaces, diagnose per the working method). Close/—update #224.

---

## Notes for the implementer

- **Never** assert against an extracted form `action`; click the rendered control (the #231 review lesson).
- Every DB assertion names its schema explicitly (`<slug>` or `registry`); tenant data must be in `<slug>`.
- Capture ids from the DB, never derive them (slug especially — spec §3).
- Expect to surface real prod bugs in the in-tenant auth/registration/attendance paths. Fix the blocking ones with tests; file the tangential ones (as #225/#226/#229/#230). When a fix is non-trivial or a scope call is needed, STOP and surface to the maintainer.
- Filed-don't-fix already known: `RegisterTenant._send_invitation_email` cross-schema token hazard (the lifecycle uses login tokens, so it isn't blocking) — file it if not already.
