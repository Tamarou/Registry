# Playwright Harness + CI (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-enable Playwright in CI by replacing the flaky per-test server/DB model with one shared server + one shared database for the whole run, and get the existing specs green and gating PRs.

**Architecture:** A Playwright `globalSetup` provisions one `Test::PostgreSQL` database (schema loaded, all workflows/templates imported) and keeps it alive for the run; the Playwright `webServer` boots a single `morbo` Registry server against that database on a fixed port; specs run serially against it. Per-test database/server spawning is removed. Specs that assumed a fresh DB are refactored to use run-unique data.

**Tech Stack:** Playwright (`@playwright/test`), Node 18, Perl 5.42 / Mojolicious / `morbo`, `Test::PostgreSQL`, `Test::Registry::DB`, PostgreSQL, GitHub Actions.

**Source spec:** `docs/superpowers/specs/2026-06-03-playwright-lifecycle-e2e-design.md` (Phase 1 only).

---

## Ground rules

- This is infrastructure work; "the test" for most tasks is *running the relevant
  Playwright spec(s) and confirming pass/fail*. Always run with `--workers=1`
  locally (the shared DB is only serial-safe).
- The chosen port is **3001** everywhere (config, server, CI).
- The Playwright CI job must **not** set `STRIPE_SECRET_KEY` (keeps registration's
  free path in demo mode for Phase 1; Phase 2 replaces that with a decision step).
- Commit after each task. Do not bundle unrelated changes.

## File structure

| File | Responsibility |
|------|----------------|
| `t/playwright/shared_db.pl` (create) | Provision ONE `Test::PostgreSQL` DB, import all workflows+templates, print `{url,pid}`, stay alive until `SHUTDOWN`. |
| `t/playwright/global-setup.js` (create) | Start `shared_db.pl`, capture the DB URL + helper PID, write them to dotfiles for the server wrapper and teardown. |
| `t/playwright/global-teardown.js` (create) | Signal `shared_db.pl` to stop (kill the recorded PID), remove dotfiles. |
| `t/playwright/start-test-server.sh` (create) | Read the DB URL dotfile, exec `morbo ./registry` on port 3001. |
| `playwright.config.js` (modify) | Fixed `baseURL`/port, `fullyParallel:false`, `webServer`, `globalSetup`/`globalTeardown`. |
| `t/playwright/fixtures/base.js` (modify) | Thin fixtures: no per-test DB/server spawn; keep `registryPage` helpers; `goto` uses `baseURL`. |
| `t/playwright/*.spec.js` (modify, several) | Run-unique data + scoped assertions per the audit table. |
| `t/playwright/setup_*_test_data.pl` (modify, several) | Accept a run-id and emit unique ids. |
| `.github/workflows/playwright.yml` (create from `.disabled`) | CI job that boots the shared harness and runs Playwright. |
| `t/playwright/db_manager.pl` (delete, final task) | Obsolete per-test DB manager. |

---

## Task 1: Shared-DB helper

**Files:**
- Create: `t/playwright/shared_db.pl`

- [ ] **Step 1: Write the helper**

```perl
#!/usr/bin/env perl
# ABOUTME: Provisions one shared Test::PostgreSQL database for a whole Playwright run.
# ABOUTME: Imports all workflows/templates, prints {url,pid} JSON, stays alive until SHUTDOWN.
use 5.42.0;
use strict;
use warnings;
use lib qw(lib t/lib);
use Test::Registry::DB;
use JSON::PP;
use IO::Handle;

STDOUT->autoflush(1);

# Build the DB (schema is loaded from sql/test-schema.sql by Test::Registry::DB).
# Suppress the loader's chatter so STDOUT carries only our JSON line.
open my $orig, '>&', STDOUT or die $!;
open STDOUT, '>', '/dev/null' or die $!;
my $db  = Test::Registry::DB->new;
my $dao = $db->db;
# Import every workflow and template, exactly as production boot does.
$dao->import_workflows( [ glob('workflows/*.yml workflows/*.yaml') ] );
$dao->import_templates if $dao->can('import_templates');
open STDOUT, '>&', $orig or die $!;

print JSON::PP->new->encode({ url => $db->uri, pid => $$, status => 'ready' }), "\n";

# Stay alive so the DB persists for the whole run.
while ( my $line = <STDIN> ) {
    chomp $line;
    last if $line eq 'SHUTDOWN';
}
# Test::PostgreSQL tears down on exit.
```

- [ ] **Step 2: Verify it boots and reports a URL**

Run: `cd /home/perigrin/dev/Registry && echo SHUTDOWN | carton exec perl t/playwright/shared_db.pl`
Expected: a single JSON line like `{"url":"postgresql://...","pid":12345,"status":"ready"}`, then clean exit.

> Note: `import_workflows`/`import_templates` are the real DAO entry points; if the
> exact method names differ, fall back to shelling `DB_URL=<url> carton exec
> ./registry workflow import registry` and `template import registry`. Confirm
> against `lib/Registry/DAO.pm` and `bin`/`registry` before settling.

- [ ] **Step 3: Commit**

```bash
git add t/playwright/shared_db.pl
git commit -m "Add shared Test::PostgreSQL helper for Playwright runs"
```

---

## Task 2: globalSetup / globalTeardown / server wrapper

**Files:**
- Create: `t/playwright/global-setup.js`, `t/playwright/global-teardown.js`, `t/playwright/start-test-server.sh`

- [ ] **Step 1: Write `global-setup.js`**

```javascript
// ABOUTME: Playwright global setup -- starts one shared DB for the whole run.
// ABOUTME: Writes the DB URL and helper PID to dotfiles consumed by the server + teardown.
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');

module.exports = async () => {
  const proc = spawn('carton', ['exec', 'perl', 't/playwright/shared_db.pl'], {
    cwd: process.cwd(),
    stdio: ['pipe', 'pipe', 'inherit'],
  });
  // Keep the helper alive past setup; detach our handles after capturing the URL.
  proc.unref();

  const info = await new Promise((resolve, reject) => {
    let buf = '';
    const timer = setTimeout(() => reject(new Error('shared_db.pl timeout')), 120000);
    proc.stdout.on('data', (d) => {
      buf += d.toString();
      const nl = buf.indexOf('\n');
      if (nl >= 0) {
        clearTimeout(timer);
        try { resolve(JSON.parse(buf.slice(0, nl))); }
        catch (e) { reject(e); }
      }
    });
    proc.on('error', reject);
  });

  fs.writeFileSync(URL_FILE, info.url);
  fs.writeFileSync(PID_FILE, String(info.pid));
  console.log(`[playwright] shared DB ready (pid ${info.pid})`);
};
```

- [ ] **Step 2: Write `global-teardown.js`**

```javascript
// ABOUTME: Playwright global teardown -- stops the shared DB and removes dotfiles.
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const URL_FILE = path.join(DIR, '.shared-db-url');
const PID_FILE = path.join(DIR, '.shared-db-pid');

module.exports = async () => {
  try {
    const pid = parseInt(fs.readFileSync(PID_FILE, 'utf8'), 10);
    process.kill(pid, 'SIGTERM'); // triggers Test::PostgreSQL cleanup
  } catch (e) { /* already gone */ }
  for (const f of [URL_FILE, PID_FILE]) { try { fs.unlinkSync(f); } catch (e) {} }
};
```

- [ ] **Step 3: Write `start-test-server.sh`**

```bash
#!/usr/bin/env bash
# ABOUTME: Boots one morbo Registry server for Playwright against the shared DB.
# ABOUTME: Reads the DB URL written by global-setup.js.
set -euo pipefail
cd "$(dirname "$0")/../.."
export DB_URL="$(cat t/playwright/.shared-db-url)"
export EMAIL_SENDER_TRANSPORT=Test
exec carton exec morbo ./registry -l http://127.0.0.1:3001
```

Then: `chmod +x t/playwright/start-test-server.sh`

- [ ] **Step 4: Commit**

```bash
git add t/playwright/global-setup.js t/playwright/global-teardown.js t/playwright/start-test-server.sh
git commit -m "Add Playwright global setup/teardown and shared server wrapper"
```

---

## Task 3: Rework `playwright.config.js` for the shared harness

**Files:**
- Modify: `playwright.config.js`

- [ ] **Step 1: Apply config changes**

Set/replace these keys (keep the existing `deploy-validation` project and reporters):

```javascript
module.exports = defineConfig({
  testDir: './t/playwright',
  fullyParallel: false,                 // shared DB is serial-only
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 2 : 0,
  workers: 1,                           // serial against the shared DB
  globalSetup: require.resolve('./t/playwright/global-setup.js'),
  globalTeardown: require.resolve('./t/playwright/global-teardown.js'),
  reporter: [['html'], ['junit', { outputFile: 'test-results/junit.xml' }], ['list']],
  use: {
    baseURL: 'http://127.0.0.1:3001',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    video: 'retain-on-failure',
  },
  webServer: {
    command: 'bash t/playwright/start-test-server.sh',
    url: 'http://127.0.0.1:3001/health',
    reuseExistingServer: !process.env.CI,
    timeout: 120 * 1000,
  },
  projects: [
    { name: 'chromium', use: { ...devices['Desktop Chrome'] } },
    { name: 'firefox',  use: { ...devices['Desktop Firefox'] } },
    { /* keep existing deploy-validation project unchanged */ },
  ],
});
```

- [ ] **Step 2: Commit**

```bash
git add playwright.config.js
git commit -m "Point Playwright config at one shared server and DB (serial)"
```

---

## Task 4: Slim `fixtures/base.js` to use the shared server

**Files:**
- Modify: `t/playwright/fixtures/base.js`

- [ ] **Step 1: Remove the per-test `TestDB` and per-test `morbo` spawn.** Replace
  the `testDB` and `registryPage` fixtures so that:
  - `testDB` exposes the shared DB URL by reading `t/playwright/.shared-db-url`
    (so specs that pass `DB_URL` to a seed script keep working).
  - `registryPage` is just `page` plus the existing helper methods
    (`workflowUrl`, `workflowRunStepUrl`, `expectWorkflowLayout`,
    `expectHTMXResponse`, `expectUTF8Rendering`). Do **not** override `page.goto`;
    rely on `baseURL`. Remove all `spawn('carton', ...)` server logic.

```javascript
// ABOUTME: Base Playwright fixtures -- shared server + shared DB model.
const base = require('@playwright/test');
const fs = require('fs');
const path = require('path');

const dbUrl = () =>
  fs.readFileSync(path.join(__dirname, '.shared-db-url'), 'utf8').trim();

const test = base.test.extend({
  testDB: async ({}, use) => { await use({ dbUrl: dbUrl() }); },
  registryPage: async ({ page }, use) => {
    page.workflowUrl = (slug) => `/${slug}`;
    page.workflowRunStepUrl = (slug, runId, step) => `/${slug}/${runId}/${step}`;
    page.expectWorkflowLayout = async () => {
      await base.expect(page.locator('html')).toHaveAttribute('lang');
      await base.expect(page.locator('head meta[charset]')).toBeAttached();
      await base.expect(page.locator('script[src*="htmx"]')).toBeAttached();
    };
    page.expectHTMXResponse = async (trigger, expected) => {
      await page.locator(trigger).click();
      await base.expect(page.locator(expected)).toBeVisible({ timeout: 5000 });
    };
    await use(page);
  },
});

module.exports = { test, expect: base.expect };
```

> Confirm the exact workflow URL shape (`/:slug` vs `/:slug/:run/:step`) against
> `lib/Registry.pm:661` and `Registry::Controller::Workflows` before finalizing
> `workflowUrl`/`workflowRunStepUrl`.

- [ ] **Step 2: Commit**

```bash
git add t/playwright/fixtures/base.js
git commit -m "Slim Playwright fixtures to the shared-server model"
```

---

## Task 5: GATE — smoke-test green on the shared harness

**Files:** none (verification)

- [ ] **Step 1: Run the smoke test**

Run: `cd /home/perigrin/dev/Registry && npx playwright test smoke-test.spec.js --workers=1 --project=chromium`
Expected: PASS. The run should start ONE server + ONE DB (see the
`[playwright] shared DB ready` line), not one per test.

- [ ] **Step 2: If it fails**, debug the harness wiring (globalSetup URL handoff,
  server wrapper port, `/health` readiness) before proceeding. Do not migrate specs
  until the smoke test is green. This is the integration-risk gate.

- [ ] **Step 3: Commit any harness fixes**

```bash
git commit -am "Fix shared-harness wiring so smoke test passes"
```

---

## Task 6: Migrate the robust specs (no/low change)

**Files:** none expected (verification), small fixes if needed.

- [ ] **Step 1: Run them serially**

Run: `npx playwright test smoke-test auth-journeys workflow-layout-visual component-integration jordan-landing-journey --workers=1 --project=chromium`
Expected: PASS. `auth-journeys` already uses timestamped emails; the visual specs
are read-only. Fix any `page.goto` assumptions broken by removing the override.

- [ ] **Step 2: Commit any fixes**

```bash
git commit -am "Adjust robust specs for the shared-server fixtures"
```

---

## Task 7: Fix `all-workflows-visual.spec.js` (bad slugs + URL prefix)

**Files:**
- Modify: `t/playwright/all-workflows-visual.spec.js`

- [ ] **Step 1:** Replace the slug list `['tenant-signup','session-creation','user-registration','event-creation','payment-processing']` with slugs that exist (`tenant-signup`, `session-creation`, `event-creation`, `user-creation`) and change navigation from `/workflow/${slug}` to `/${slug}` (the `any('/:workflow')` route). If a workflow needs prior data to render, either seed it in `shared_db.pl` or drop it from the list.

- [ ] **Step 2: Run**

Run: `npx playwright test all-workflows-visual --workers=1 --project=chromium`
Expected: PASS (no 404s).

- [ ] **Step 3: Commit**

```bash
git commit -am "Fix all-workflows-visual slugs and workflow URL prefix"
```

---

## Task 8: Parameterize the seed scripts for run-unique data

**Files:**
- Modify: `t/playwright/setup_registration_test_data.pl`, `setup_admin_test_data.pl`,
  `setup_teacher_test_data.pl`, `setup_drop_test_data.pl`,
  `setup_waitlist_test_data.pl`, `setup_domain_test_data.pl`

- [ ] **Step 1:** Give each script a run-unique suffix (read `$ARGV[0]` or
  `$ENV{RUN_ID}`, default to `time()`), and use it on every slug/username/email/org
  name/domain it creates, returning those ids in its JSON. Tenant find-or-create on a
  fixed slug (e.g. `super-awesome-cool-pottery`) may stay shared, but any row a spec
  later mutates or counts must be unique per call.
  **`setup_teacher_test_data.pl`/`setup_registration_test_data.pl`: set event dates to
  `DateTime->now->ymd`** (today), not fixed 2026 dates, so "today's events" populate.

- [ ] **Step 2: Verify each script still emits valid JSON**

Run (example): `DB_URL=$(cat t/playwright/.shared-db-url) carton exec perl t/playwright/setup_teacher_test_data.pl | head -c 200`
Expected: JSON with unique-looking ids and today's date.

- [ ] **Step 3: Commit**

```bash
git commit -am "Make Playwright seed scripts emit run-unique data and today-dated events"
```

---

## Task 9: Refactor the fragile specs for shared-DB safety

Do these one spec at a time; run each with `--workers=1 --project=chromium` after.

- [ ] **custom-domains**: replace hardcoded domain names with run-unique names; make
  remove/re-add self-contained; robust pre-test cleanup. Run; commit.
- [ ] **tenant-signup**: run-unique org names/subdomains; drop empty-table
  assumptions. Run; commit.
- [ ] **admin-dashboard** + **jordan-admin-dashboard**: consume unique seeded ids;
  log in fresh per test rather than one shared `beforeAll` token. Run; commit.
- [ ] **camp-registration**, **parent-dashboard**, **waitlist-flow**,
  **drop-transfer**: pass a run-id to their seed scripts; assert only on their own
  ids. Run; commit.
- [ ] **amara-attendance**: unique teacher/student/event ids; rely on today-dated
  events from Task 8; assert on its own roster. Run; commit.

Commit message pattern: `Make <spec> shared-DB safe`.

---

## Task 10: GATE — full local suite green, serial

**Files:** none (verification)

- [ ] **Step 1: Run everything except the production-only project**

Run: `npx playwright test --workers=1 --project=chromium` then `--project=firefox`
Expected: PASS for all non-`deploy-validation` specs on both browsers.

- [ ] **Step 2:** Triage any remaining failures back to the owning spec/task. Do not
  proceed to CI until this is green.

---

## Task 11: Restore the CI workflow

**Files:**
- Create: `.github/workflows/playwright.yml` (from `.disabled`, rewritten)
- Delete: `.github/workflows/playwright.yml.disabled`

- [ ] **Step 1:** Write `.github/workflows/playwright.yml`:
  - Trigger: `pull_request` to `main` (and `push` to `main`).
  - Steps: checkout; setup-perl 5.42; setup-node 18; install Perl deps (carton);
    `npm install`; `npx playwright install --with-deps`; run
    `npx playwright test --project=chromium --project=firefox`.
  - **No `STRIPE_SECRET_KEY`.** Set `EMAIL_SENDER_TRANSPORT=Test`.
  - The shared DB is created by `globalSetup` (Test::PostgreSQL on the runner), so no
    Postgres service container is needed; ensure the runner has Postgres server
    binaries (GitHub `ubuntu-latest` provides them). If `Test::PostgreSQL` proves
    unreliable on the runner, fall back to a `postgres:17` service container and have
    `shared_db.pl` target it via `DB_URL`.
  - Upload `playwright-report/` and `test-results/` on failure.

- [ ] **Step 2:** `git rm .github/workflows/playwright.yml.disabled`.

- [ ] **Step 3: Validate YAML**

Run: `python3 -c "import yaml; yaml.safe_load(open('.github/workflows/playwright.yml')); print('ok')"`
Expected: `ok`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/playwright.yml && git rm .github/workflows/playwright.yml.disabled
git commit -m "Re-enable Playwright in CI against the shared harness"
```

---

## Task 12: Remove the obsolete per-test DB manager

**Files:**
- Delete: `t/playwright/db_manager.pl`
- Modify: `t/playwright/get_test_db.pl` if it references the old manager

- [ ] **Step 1:** Confirm nothing references `db_manager.pl`:
  Run: `grep -rn "db_manager" t/ .github playwright.config.js`
  Expected: no matches (or only this plan).
- [ ] **Step 2:** `git rm t/playwright/db_manager.pl`; remove any dead references.
- [ ] **Step 3: Final local run** to confirm nothing broke (Task 10 command).
- [ ] **Step 4: Commit**

```bash
git commit -am "Remove obsolete per-test Playwright DB manager"
```

---

## Done criteria (Phase 1)

- [ ] `npx playwright test --workers=1` is green locally (chromium + firefox) with a
      single server + single DB for the whole run.
- [ ] `.github/workflows/playwright.yml` runs the same and gates PRs to `main`.
- [ ] No per-test `morbo`/`Test::PostgreSQL` spawning remains; `db_manager.pl` is gone.
- [ ] The Playwright CI job sets no `STRIPE_SECRET_KEY`.

## Out of scope (later phases)

- The Morgan -> Nancy -> Amara lifecycle journey and the payment-decision step
  (Phase 2, its own plan).
- Paid Stripe Checkout variant (Phase 3, its own spec).
