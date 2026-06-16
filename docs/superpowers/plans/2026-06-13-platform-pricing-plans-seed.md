# Platform Pricing Plans Seed (PR1 / #268) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make platform pricing plans actually present and selectable on a fresh
deploy, seed a platform-scope Free fallback plan, and add a CI guard so no
`sql/deploy/*.sql` is ever orphaned from `sqitch.plan` again.

**Architecture:** Three orphaned-from-`sqitch.plan` symptoms of #268 are fixed by
(a) adding the existing `create-default-pricing-relationships` change to the plan
so platform→plan relationships exist on deploy (which is what
`PricingPlanSelection::prepare_pricing_data` reads to render selectable plans),
(b) a new `seed-free-platform-plan` change that inserts a `plan_scope='platform'`
0% revenue-share plan to serve as #267's no-plan fallback, and (c) a one-line
orphan-check in the CI `lint` job. This is PR1 of a two-PR stack; PR2 (#267,
`feature/plan-driven-revenue-share`) stacks on this and reads the seeded data.

**Tech Stack:** PostgreSQL, Sqitch migrations (deploy/revert/verify triplets),
Perl 5.42 / Object::Pad, Test2::V0, Mojo::Pg, GitHub Actions CI.

**Spec:** `docs/specs/plan-driven-revenue-share.md`

**Branch:** Create `feature/seed-platform-pricing-plans` off `main`. PR2's
`feature/plan-driven-revenue-share` will be rebased onto this branch once it
merges.

---

## Background the worker needs

- **Sqitch layout:** migrations are triplets — `sql/deploy/<name>.sql` (forward),
  `sql/revert/<name>.sql` (undo), `sql/verify/<name>.sql` (assert via
  `SELECT 1/COUNT(*)` so a zero count divides-by-zero and fails). The ordered
  manifest is `sql/sqitch.plan` (NOT the stale `./sqitch.plan` at repo root).
  Each plan line: `<name> [<requires...>] <timestamp> <author> # <note>`.
- **The #268 bug:** `create-default-pricing-relationships.sql` (plus its revert
  and verify) already exist on disk but are absent from `sqitch.plan`, so they
  never deploy. On a fresh/prod DB `registry.pricing_relationships` is therefore
  empty, and `PricingPlanSelection::prepare_pricing_data`
  (`lib/Registry/DAO/WorkflowSteps/PricingPlanSelection.pm:80`) returns zero
  plans — signup shows no plan to select.
- **How selection works:** `prepare_pricing_data` finds
  `registry.pricing_relationships` rows with `provider_id = PLATFORM_UUID`
  (`00000000-0000-0000-0000-000000000000`) and `status = 'active'`, then keeps
  the linked plans whose `plan_scope = 'tenant'`. So a plan is selectable iff it
  is tenant-scoped AND has an active platform relationship.
- **The existing seed:** `sql/deploy/unified-pricing-infrastructure.sql` already
  inserts two tenant-scoped platform plans — "Registry Revenue Share - 2%"
  (`percentage`, `amount 0.02`) and "Registry Standard - $200/month". It does
  NOT seed a Free plan. That file is already deployed in prod and must not be
  edited; new data needs a new migration.
- **`create-default-pricing-relationships` behaviour:** it ensures a platform
  admin user exists, then loops over every `plan_scope='tenant'` plan lacking a
  platform relationship and inserts an `active` one, tagging
  `metadata->>'created_by_migration'`. Its revert deletes exactly those rows. Its
  verify asserts every tenant-scoped plan has an active platform relationship.
- **Free plan is fallback-only, not a signup option.** Seeding it as
  `plan_scope='platform'` (not `'tenant'`) keeps it out of both
  `prepare_pricing_data` (tenant-only filter) and the
  `create-default-pricing-relationships` loop (tenant-only), so it never appears
  as a selectable plan and never gets a spurious relationship. PR2's resolver
  finds it directly by `plan_scope='platform'` + `metadata->>'default'='true'`.
- **Run tests:** `carton exec prove -lv t/path/to.t` (single),
  `carton exec prove -lr t/` (full). Always `-lr`, never `-r` alone. Workflow
  tests need `carton exec ./registry workflow import registry` first.
- **CRITICAL — the test DB is built from a static dump, not live `sql/`.**
  `Test::Registry::DB->new` fast-path loads `sql/test-schema.sql` (a pre-generated
  `pg_dump`); it only runs sqitch if that dump is missing
  (`t/lib/Test/Registry/DB.pm:60-74`). The current dump has an EMPTY
  `pricing_relationships` table. So **editing `sqitch.plan` does nothing for tests
  until the dump is regenerated** with `make test-schema`. The Makefile rule
  `sql/test-schema.sql: sql/deploy/*.sql sql/sqitch.plan` makes `make test`
  regenerate automatically, but running `prove` directly does NOT — regenerate
  manually after any migration change.
- **Test harness API (verified):** `my $test_db = Test::Registry::DB->new;`
  then `my $dao = $test_db->db;` (a `Registry::DAO`) and `my $db = $dao->db;`
  (the Mojo::Pg `::Database` handle that DAO methods expect). `new_test_db`
  returns a URI string, not a handle — do not use it here. Tests in this repo use
  `Test::More`, not `Test2::V0` (see `t/dao/payment-intent-destination-charge.t`).
- **`Registry::DAO::WorkflowStep` requires** `id`, `slug`, `workflow_id`,
  `description`, AND `class` as constructor params (all `:param` with no default,
  `lib/Registry/DAO/WorkflowStep.pm:9-22`). Constructing one with only
  `id`/`slug` croaks. This plan's test avoids step construction entirely by
  asserting the seeded DB state directly (the exact conditions
  `prepare_pricing_data` reads), which is more robust for a migration-seeding
  test; the end-to-end `prepare_pricing_data` path is already covered by
  `t/dao/tenant-signup-pricing-integration.t` and Alex Leg 1.
- **Scratch-DB migration cycle** (used in verification steps):
  ```bash
  carton exec sqitch deploy db:pg://postgres@localhost/registry_scratch
  carton exec sqitch verify db:pg://postgres@localhost/registry_scratch
  carton exec sqitch revert -y db:pg://postgres@localhost/registry_scratch
  ```

## File Structure

- Create: `sql/deploy/seed-free-platform-plan.sql`,
  `sql/revert/seed-free-platform-plan.sql`,
  `sql/verify/seed-free-platform-plan.sql` — the platform Free fallback plan.
- Modify: `sql/sqitch.plan` — add `seed-free-platform-plan` then
  `create-default-pricing-relationships` (in that order) at the tail.
- Modify: `.github/workflows/ci.yml:130` (`lint` job) — add an orphan-check step.
- Create: `t/dao/platform-pricing-plans-seed.t` — integration test proving plans
  are selectable and the Free fallback exists after deploy.

---

## Task 1: Failing test — plans are selectable + Free fallback exists

**Files:**
- Test: `t/dao/platform-pricing-plans-seed.t`

This test encodes the #268 fix by asserting the seeded DB state that
`PricingPlanSelection::prepare_pricing_data` depends on (active platform
relationship → tenant-scoped plan), plus the platform-scope Free fallback. It
asserts DB state directly rather than constructing a WorkflowStep (see Background
for why). The assertions mirror `prepare_pricing_data`'s exact selection logic
(`PricingPlanSelection.pm:80-106`).

- [ ] **Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
# ABOUTME: Integration test that platform pricing plans are seeded and selectable.
# ABOUTME: Guards #268 — fresh deploys must offer selectable plans + a Free fallback.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

my $PLATFORM = '00000000-0000-0000-0000-000000000000';

subtest 'signup offers selectable plans' => sub {
    # prepare_pricing_data selects: active platform relationship -> tenant-scoped plan.
    my $rows = $db->query(q{
        SELECT p.plan_name
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
         WHERE pr.provider_id = ?
           AND pr.status = 'active'
           AND p.plan_scope = 'tenant'
    }, $PLATFORM)->hashes;
    ok scalar(@$rows) >= 1, 'at least one selectable plan on a fresh deploy';
    ok( (grep { $_->{plan_name} =~ /Revenue Share/ } @$rows),
        'the revenue-share plan is among the selectable plans' );
};

subtest 'Free platform fallback plan exists and is not selectable' => sub {
    my $row = $db->query(q{
        SELECT amount, pricing_model_type
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
    })->hash;
    ok $row, 'a platform-scope default plan exists';
    is $row->{pricing_model_type}, 'percentage', 'Free plan is percentage-typed';
    cmp_ok $row->{amount} + 0, '==', 0, 'Free plan rate is 0';

    my $selectable = $db->query(q{
        SELECT COUNT(*) AS n
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
         WHERE p.plan_scope = 'platform' AND pr.provider_id = ?
    }, $PLATFORM)->hash->{n};
    is $selectable, 0, 'Free fallback has no selectable relationship';
};

done_testing;
```

- [ ] **Step 2: Run test to verify it fails**

Run: `carton exec prove -lv t/dao/platform-pricing-plans-seed.t`
Expected: FAIL — against the current `sql/test-schema.sql` dump,
`pricing_relationships` is empty (so zero selectable plans) and no
platform-scope default plan exists yet. (Do NOT regenerate the dump yet; the red
state is the point.)

- [ ] **Step 3: Commit the failing test**

```bash
git add t/dao/platform-pricing-plans-seed.t
git commit -m "Add failing test: platform plans selectable + Free fallback (#268)"
```

---

## Task 2: Seed the platform Free fallback plan (new migration)

**Files:**
- Create: `sql/deploy/seed-free-platform-plan.sql`
- Create: `sql/revert/seed-free-platform-plan.sql`
- Create: `sql/verify/seed-free-platform-plan.sql`

- [ ] **Step 1: Write the deploy script**

`sql/deploy/seed-free-platform-plan.sql`:
```sql
-- ABOUTME: Seed a platform-scope Free (0%) revenue-share plan.
-- ABOUTME: Serves as the no-plan fallback for plan-driven revenue share (#267).

-- Deploy registry:seed-free-platform-plan to pg
-- requires: unified-pricing-infrastructure

BEGIN;

-- NOTE: offering_tenant_id / target_tenant_id were dropped by
-- remove-pricing-plan-relationship-fields (deploys earlier), so they are NOT
-- columns here. Insert only the columns that exist in the current schema
-- (see sql/test-schema.sql pricing_plans definition).
INSERT INTO registry.pricing_plans (
    plan_scope, plan_name, plan_type,
    pricing_model_type, amount, currency, pricing_configuration, metadata
)
SELECT
    'platform',
    'Registry Free',
    'standard',
    'percentage',
    0.00,
    'USD',
    '{"percentage": 0.00, "applies_to": "customer_payments", "minimum_monthly": 0}'::JSONB,
    '{"default": true, "description": "Platform fallback: no revenue share"}'::JSONB
WHERE NOT EXISTS (
    SELECT 1 FROM registry.pricing_plans
    WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
);

COMMIT;
```

> The `WHERE NOT EXISTS` guard makes the seed idempotent (safe re-deploy). Note
> the launch-rate decision (2% vs 2.5%) is NOT this plan — this is the 0%
> fallback only; the launch rate lives on the existing "Registry Revenue Share"
> plan seeded by `unified-pricing-infrastructure`.

- [ ] **Step 2: Write the revert script**

`sql/revert/seed-free-platform-plan.sql`:
```sql
-- ABOUTME: Revert the platform-scope Free fallback plan.
-- ABOUTME: Removes the default platform plan seeded by the deploy migration.

-- Revert registry:seed-free-platform-plan from pg

BEGIN;

DELETE FROM registry.pricing_plans
WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

COMMIT;
```

- [ ] **Step 3: Write the verify script**

`sql/verify/seed-free-platform-plan.sql`:
```sql
-- ABOUTME: Verify the platform-scope Free fallback plan exists.
-- ABOUTME: Asserts exactly one default platform plan with a zero rate.

-- Verify registry:seed-free-platform-plan on pg

BEGIN;

SELECT 1/COUNT(*) FROM registry.pricing_plans
WHERE plan_scope = 'platform'
  AND metadata->>'default' = 'true'
  AND pricing_model_type = 'percentage'
  AND amount = 0.00;

ROLLBACK;
```

- [ ] **Step 4: Commit**

```bash
git add sql/deploy/seed-free-platform-plan.sql \
        sql/revert/seed-free-platform-plan.sql \
        sql/verify/seed-free-platform-plan.sql
git commit -m "Add seed-free-platform-plan migration triplet (#268)"
```

---

## Task 3: Add both changes to sqitch.plan

**Files:**
- Modify: `sql/sqitch.plan` (append at tail, after `tenant-scoped-payments`)

Order matters: `seed-free-platform-plan` first (creates the Free plan; harmless
to the relationship loop since it is platform-scoped), then
`create-default-pricing-relationships` (its declared requirement
`remove-pricing-plan-relationship-fields` is already in the plan).

- [ ] **Step 1: Append the two lines**

Add to the end of `sql/sqitch.plan` (use the repository's existing author
identity; copy the exact author string from a recent line). Use a fixed
timestamp string — do NOT compute one at runtime:

```
seed-free-platform-plan [unified-pricing-infrastructure] 2026-06-13T00:00:00Z Chris Prather <chris.prather@tamarou.com> # Seed platform-scope Free (0%) fallback plan
create-default-pricing-relationships [remove-pricing-plan-relationship-fields unified-pricing-infrastructure seed-free-platform-plan] 2026-06-13T00:00:00Z Chris Prather <chris.prather@tamarou.com> # Create active platform relationships so tenant plans are selectable
```

- [ ] **Step 2: Deploy/verify/revert/redeploy on a scratch DB**

```bash
createdb registry_scratch 2>/dev/null || true
carton exec sqitch deploy db:pg://postgres@localhost/registry_scratch
carton exec sqitch verify db:pg://postgres@localhost/registry_scratch
carton exec sqitch revert -y --to @HEAD^2 db:pg://postgres@localhost/registry_scratch
carton exec sqitch deploy db:pg://postgres@localhost/registry_scratch
```
Expected: deploy and verify succeed; revert of the two new changes succeeds;
redeploy succeeds (proves revert scripts are correct and migrations are
re-runnable).

- [ ] **Step 3: Regenerate the test-schema dump**

The test DB loads `sql/test-schema.sql`, NOT live `sql/`. Regenerate it so the
new migrations are reflected:

Run: `make test-schema`
Expected: `sql/test-schema.sql` is rewritten; `git diff --stat sql/test-schema.sql`
shows changes (now-populated `pricing_relationships`, the platform admin user,
and the Free plan row).

- [ ] **Step 4: Run the Task 1 test — now green**

Run: `carton exec prove -lv t/dao/platform-pricing-plans-seed.t`
Expected: PASS — at least one selectable tenant-scoped plan with an active
platform relationship; the platform Free fallback exists and is not selectable.

- [ ] **Step 5: Commit**

```bash
git add sql/sqitch.plan sql/test-schema.sql
git commit -m "Plan seed-free-platform-plan and create-default-pricing-relationships (#268)"
```

---

## Task 4: Fix existing tests that now collide with the seeded platform admin

**Files:**
- Modify: `t/dao/pricing-plan-selection-workflow-step.t` (~line 26)
- Modify: `t/dao/tenant-signup-pricing-integration.t` (~line 26)

`create-default-pricing-relationships` creates a `platform_admin` user
(username `platform_admin`) at deploy time. `registry.users.username` is
`UNIQUE` (`sql/deploy/users.sql:14`). Both tests above currently insert their
own `platform_admin` user **unconditionally**, which now duplicates the
seeded one once the dump is regenerated → `prove` fails with a unique-violation.
These tests pre-create that user so platform pricing relationships can be set up;
with the seed migration that user already exists.

- [ ] **Step 1: Run both tests to observe the new failure**

Run:
```bash
carton exec prove -lv t/dao/pricing-plan-selection-workflow-step.t \
                      t/dao/tenant-signup-pricing-integration.t
```
Expected: FAIL with a duplicate-key violation on `registry.users.username`
(`platform_admin`).

- [ ] **Step 2: Make the platform-admin insert idempotent in each test**

In each file, change the unconditional `INSERT INTO registry.users (...) VALUES
(... 'platform_admin' ...)` to reuse the existing row when present. Minimal
change — add an `ON CONFLICT (username) DO NOTHING` and then look the id up:
```perl
$dao->db->query(q{
    INSERT INTO registry.users (id, username, passhash, user_type)
    VALUES (?, ?, ?, ?)
    ON CONFLICT (username) DO NOTHING
}, $platform_user_id, 'platform_admin', '$2b$12$DummyHashForSystemUser', 'admin');

# Use whichever row now owns the username (seeded or just-inserted).
$platform_user_id = $dao->db->query(
    q{SELECT id FROM registry.users WHERE username = 'platform_admin'}
)->hash->{id};
```
Apply the same pattern to the dependent `user_profiles` / `tenant_users` inserts
(add `ON CONFLICT DO NOTHING`) so they don't double-insert for the reused id.
Keep the change minimal and matching each file's surrounding style.

- [ ] **Step 3: Run both tests — green**

Run: `carton exec prove -lv t/dao/pricing-plan-selection-workflow-step.t t/dao/tenant-signup-pricing-integration.t`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add t/dao/pricing-plan-selection-workflow-step.t t/dao/tenant-signup-pricing-integration.t
git commit -m "Make platform_admin test fixtures idempotent vs seeded admin (#268)"
```

> If the full suite (Task 6) surfaces *other* tests that assumed empty pricing
> data, fix them with the same minimal-change discipline and note them in the PR.

---

## Task 5: CI orphan-check guard

**Files:**
- Modify: `.github/workflows/ci.yml` (`lint` job, after the Perl::Critic step ~line 151)

- [ ] **Step 1: Add a blocking orphan-check step**

Add under the `lint` job's `steps:` (it already checks out code):
```yaml
    - name: Check for orphaned sqitch changes
      run: |
        # Every sql/deploy/*.sql must have a matching sql/sqitch.plan entry.
        orphans=0
        for f in sql/deploy/*.sql; do
          n=$(basename "$f" .sql)
          grep -q "^$n " sql/sqitch.plan || { echo "ORPHAN: $n"; orphans=1; }
        done
        if [ "$orphans" -ne 0 ]; then
          echo "::error::Orphaned sql/deploy files are not in sql/sqitch.plan"
          exit 1
        fi
        echo "No orphaned sqitch changes."
```

- [ ] **Step 2: Run the check locally to confirm it is green now**

Run:
```bash
orphans=0; for f in sql/deploy/*.sql; do n=$(basename "$f" .sql); \
  grep -q "^$n " sql/sqitch.plan || { echo "ORPHAN: $n"; orphans=1; }; done; \
  echo "orphans=$orphans"
```
Expected: `orphans=0`. The three previously-orphaned migrations
(`fix-pricing-validation-trigger`, `resource-aware-pricing-plans`,
`restructure-data-model`) were already DELETED in PR0
(`feature/cleanup-orphaned-migrations`, which this branch stacks on). Task 3 of
this plan adds the last orphan (`create-default-pricing-relationships`) to
`sql/sqitch.plan`. So by this point zero orphans remain and the check is green
and safe to make blocking. If `orphans` is non-zero here, STOP — something in
Task 3 didn't land.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "CI: fail on sql/deploy files orphaned from sqitch.plan (#268)"
```

---

## Task 6: Full-suite verification

- [ ] **Step 1: Ensure the dump is current, import workflows, run the full suite**

Run:
```bash
make test-schema                      # no-op if already regenerated in Task 3
carton exec ./registry workflow import registry
carton exec prove -lr t/
```
Expected: 100% pass, pristine output (no warnings). Pay attention to any
pricing/signup tests that previously tolerated zero plans or pre-created the
platform admin — Task 4 fixes the two known ones; fix any others the same way.

- [ ] **Step 2: Confirm the deferred items are untouched**

- `REVENUE_SHARE_PERCENT` still exists (its removal is PR2, not this PR).
- No `platform_pricing_plan_id` column yet (PR2).
- Launch-rate number unchanged.

---

## Definition of done (PR1)

- `seed-free-platform-plan` and `create-default-pricing-relationships` are in
  `sql/sqitch.plan`; deploy/verify/revert/redeploy all pass on a scratch DB.
- `t/dao/platform-pricing-plans-seed.t` passes: signup offers selectable plans;
  a platform-scope Free (0%) fallback exists and is not selectable.
- CI orphan-check is in place and blocking; `orphans=0` (PR0 deleted the three
  abandoned orphans; Task 3 plans `create-default-pricing-relationships`).
- Full suite green and pristine.
- Branch `feature/seed-platform-pricing-plans` opened as a PR stacked on PR0
  (#274); PR2 will stack on this.
