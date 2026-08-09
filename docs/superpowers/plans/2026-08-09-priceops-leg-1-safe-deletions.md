# PriceOps Leg 1: Safe Deletions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete every piece of dead pricing machinery that no later leg needs, and ship the revert-test harness that every later leg's migration will be graded by.

**Architecture:** Leg 1 is the first leg of the PriceOps alignment milestone (spec: `docs/superpowers/specs/2026-08-07-priceops-alignment-design.md`, leg row at `:2964`). It has no dependencies and every other leg depends on it, because it shrinks the surface the rest of the milestone has to reason about and it builds the migration safety net. The work is seven commits in a fixed order: harness first, then Perl deletion, then the database drop, then the data retirement. Code that reads a table is deleted before the table is dropped, so no commit in the sequence leaves a broken tree.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, Minion, PostgreSQL, Sqitch, `Test::PostgreSQL`, `prove`.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include this section.

- **A deployed change is retired by a new change, not by deleting a file.** Never `git rm` a file under `sql/deploy/`, `sql/revert/`, or `sql/verify/` that is named in `sql/sqitch.plan`, and never edit a deployed change's deploy script.
- **A leg that deletes a module greps `t/` for its name, not just `lib/`.** A `use` in `t/` is as load-bearing as a `use` in `lib/`. The whole file is the blast radius, not the line.
- **A leg that drops a database object greps `sql/verify/` for its name in the same commit.**
- The live sqitch plan is **`sql/sqitch.plan`** (67 lines). The root `./sqitch.plan` (44 lines) is stale — do not touch it. `sqitch.conf` sets `top_dir = ./sql` and leaves `plan_file` commented out.
- `sqitch.conf` sets `[deploy] verify = true` and `[rebase] verify = true`. Each change's verify runs **at its own point in the plan**. `t/database/migration-verification.t:24-27` additionally runs `sqitch verify` with **no change argument**, re-running every verify script against the **final** schema. A superseded verify must therefore be **true at both points** — strip the assertions that name dropped objects so the script goes vacuous. **Never invert an assertion**; an inverted assertion fails at its own deploy point.
- Test command is `carton exec prove -lr t/`. Always `-lr`, **never `-r` alone**.
- Single file: `carton exec prove -lv t/path/to/file.t`.
- 100% pass rate, pristine output. No new warnings, no unexpected diagnostics.
- Object::Pad methods take no explicit `$self`. Use the `isa` operator, not `ref eq`.
- Every file starts with two `# ABOUTME: ` comment lines.
- Comments are evergreen — no "recently changed", no "was previously".
- **Never run `t/stripe-live/`** (hits real Stripe) or **`t/playwright/`** (the ambient `STRIPE_PUBLISHABLE_KEY` is a `pk_live_` key and must never reach a browser). Editing those files is fine; executing them is not.
- Local test invocation uses a placeholder that must **not** start with `sk_test_`:
  `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/...`
- Do not touch the dev database. All schema work happens in ephemeral `Test::PostgreSQL` instances.
- Full suite is ~76 minutes. Run it once, at the end (Task 7), not per-task.

## Declared Deviations From The Spec

Two places where this plan does something other than what the spec's Leg 1 row says. Both are deliberate.

1. **The `seti_test` replacement is an env guard, not a `t/lib/` move.** The spec says to "move what the tests need into `t/lib/`". That is unnecessary: `TenantPayment::process` already has an environment-guarded no-keys branch that produces a byte-identical result hash to the `seti_test` branch, and `t/controller/tenant-create-session.t` already passes through it today (verified: the payment template renders `<input type="hidden" name="setup_intent_id" value="">` at `templates/tenant-signup/payment.html.ep:91`, and `process_workflow` applies server-issued hidden values on top of caller data at `t/lib/Test/Registry/Helpers.pm:168`, so that test's `seti_test_123` never reaches the step). The replacement is therefore: delete both `seti_test` branches, add the one-line `BEGIN { delete @ENV{...} }` the codebase already uses, and drop the dead form keys. Smaller diff, same coverage, and it removes an unguarded production bypass rather than relocating it.

2. **Superseded verify scripts go vacuous, not corrected.** The spec says the old scripts are "edited to match the schema as of the end of the plan". Taken literally that means asserting the tables are absent, which **fails** at the script's own deploy point under `[deploy] verify = true`, where the tables are present. The correct edit is to remove every assertion naming a dropped object, leaving a comment that points at the retiring change. `sql/verify/drop-installment-schedules.sql` is where the absence gets asserted.

## Spec Gaps This Plan Closes

Three stranded callers the spec's Leg 1 row does not name, found by grep:

- **The `seti_test` test consumers.** `t/controller/tenant-create-session.t:66`, `t/user-journeys/alex/01-acquire-tenant.t:82-85,199-208,331-348`, `t/user-journeys/alex/03-platform-billing.t:77-78,164-172,214,216`. Exactly the shape the spec's own stranded-caller rule warns about.
- **`templates/pricing-plan-creation/review-activate.html.ep:163-185`** reads the seven discount keys the orphaned form writes. The spec names the form and the step class but not this reader.
- **`t/dao/pricing-plan-workflow.t:216-222,242`** posts the discount keys straight into `RequirementsRules->process` and asserts on what comes back. Deleting the step's discount blocks without touching this file leaves a failing assertion.

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `t/database/revert-round-trip.t` | For each listed change: deploy to its parent → clone a tenant schema → dump → deploy the change → revert it → dump → diff. Fails when a revert script does not restore the schema. |
| `sql/deploy/drop-installment-schedules.sql` | Drops `payment_schedules` and `scheduled_payments` from `registry` and every tenant schema. |
| `sql/revert/drop-installment-schedules.sql` | Recreates both tables exactly as they stand at the plan tip, in `registry` and every tenant schema. |
| `sql/verify/drop-installment-schedules.sql` | Asserts both tables are absent everywhere. |
| `sql/deploy/retire-registry-plus-plan.sql` | Suspends the seeded Registry Plus hybrid plan and its relationships. |
| `sql/revert/retire-registry-plus-plan.sql` | Un-suspends only the rows this change stamped. |
| `sql/verify/retire-registry-plus-plan.sql` | Asserts no active relationship offers the hybrid plan. |
| `t/database/retire-registry-plus-plan.t` | Asserts the data revert round-trips (the schema harness cannot see data changes). |

**Deleted:** 5 library modules, 2 more library modules, 10 test files (enumerated in Tasks 2-4).

**Modified:** `lib/Registry/Controller/Webhooks.pm`, `lib/Registry/DAO/Family.pm`, `lib/Registry/DAO/PricingPlan.pm` (comment only), `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm`, `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`, two `templates/pricing-plan-creation/` templates, `t/controller/payment-failures.t`, `t/dao/family.t`, `t/dao/pricing-plan-amount-cents.t`, `t/dao/pricing-plan-workflow.t`, `t/dao/tenant-payment-schema-isolation.t`, `t/controller/tenant-create-session.t`, two `t/user-journeys/alex/` files, `t/stripe-live/service-version.t` (comment only — never executed), `t/database/migration-verification.t`, `sql/revert/refund-amounts-cents.sql` (the bug Task 1's harness finds), `sql/sqitch.plan`, four `sql/verify/` scripts, `sql/test-schema.sql`.

Note the one exception to "never edit a deployed change": `sql/revert/refund-amounts-cents.sql`. The Global Constraint forbids editing a deployed change's **deploy** script, and it stands. Revert scripts are outside `script_hash` (`App::Sqitch::Plan::Change.pm:164-169`), so editing one changes nothing about what is already deployed — see Task 1 Step 3.

**Deliberately untouched:**

- `lib/Registry/DAO/PricingPlan.pm` keeps `installments_allowed` (`:19`), `installment_count` (`:20`), their validation (`:42-47`) and `installment_amount_cents` (`:199-201`). The columns survive Leg 1; they are dropped with the table in Leg 9b.
- `lib/Registry/DAO/WorkflowSteps/PricingModel.pm:73-74` and `ReviewActivatePlan.pm:109-110,178-179` write those surviving columns. Leave them.
- `lib/Registry/DAO/WorkflowSteps/ResourceAllocation.pm:65,148` uses `installment_payments` as a resource-picker string. That is Leg 5's authoring rewrite.
- `.github/workflows/ci.yml:128`'s false comment about the stripe-e2e workflow belongs to Leg 3a, whose table row names it explicitly.

---

### Task 1: The revert-test harness

**Files:**
- Create: `t/database/revert-round-trip.t`
- Modify: `t/database/migration-verification.t:46-49`
- Modify: `sql/revert/refund-amounts-cents.sql:43` — the harness fails on its first subject; see Step 3.

**Interfaces:**
- Consumes: `Test::Registry::DB::_find_pg_tool($tool)` (`t/lib/Test/Registry/DB.pm:23-33`) — returns an executable path for `pg_dump`/`psql`, searching `$tool`, `/usr/bin/$tool`, and `/usr/lib/postgresql/{17,16,15,14}/bin/$tool`.
- Produces: the `@CHANGES` list in `t/database/revert-round-trip.t`. Tasks 6 and 7 each append their change name to that list in the same commit that adds the change to `sql/sqitch.plan`; that append is the whole registration mechanism.

**Why this is first:** every later leg ships migrations, and today nothing proves a revert script works. `t/database/migration-verification.t:46-49` currently reads:

```perl
subtest 'Verify migration rollback' => sub {
    # Skip complex rollback testing for now - focus on deploy/verify
    pass("Skipping rollback tests - focus on deploy and verify");
};
```

That is the #296 defect shape: a green assertion that asserts nothing. It is replaced by a pointer at the real harness.

**CI appears to contradict "nothing proves a revert script works" — it does not.** `.github/workflows/ci.yml:262-276` has a step named `Test schema rollback`, and it is the same lie in a different file. Its revert is `carton exec sqitch revert -n 3 ... || true` (`:271`), so a revert script that errors is swallowed; it then redeploys and compares nothing, so a revert that silently leaves the schema wrong is indistinguishable from one that works. And the whole `database-compatibility` job is gated on `:200`, `github.event_name == 'schedule' || contains(github.event.head_commit.modified, 'sql/') || ...` — `head_commit` is null on `pull_request`, and `contains()` tests list membership, so no file path is ever equal to the string `sql/`. The job runs on the nightly schedule and nowhere else. **Do not edit `ci.yml` in this leg** — it is not in the spec's Leg 1 row, and it is on the issue list.

**Scope note:** the harness compares `pg_dump --schema-only`. It grades **schema** round-trips. A data-only change (Task 7) is invisible to it, is deliberately kept off `@CHANGES`, and gets its own test.

**Two requirements the spec pins, which drive the shape below.**

- **It runs against a schema built by `clone_schema`, not against `registry` alone** (spec `:872`: "a harness that only exercises `registry` cannot see this class of failure at all"). This is load-bearing for Task 6. A migration-only database has exactly two schemas — `sql/test-schema.sql:26` `CREATE SCHEMA registry;` and `:35` `CREATE SCHEMA sqitch;` — and `registry.tenants` holds two rows, `registry` and `registry-platform` (`sql/test-schema.sql:2513-2514`). `registry-platform` has no schema, so `to_regnamespace(...) IS NULL` skips it; `registry` is skipped by the `to_regclass` guards. Without a provisioned tenant the tenant half of Task 6's deploy *and* revert executes zero times and the harness grades none of it.
- **It grades every change this milestone adds, not just the tip** (spec `:3455`: "Every migration in this milestone ships with a revert that is tested by reverting it"). Pinning `@HEAD^` grades whichever change happens to be last. Task 7 appends a data-only change on top of Task 6, and a data-only change round-trips trivially under a schema dump — so a tip-only harness stops grading Task 6's hundred-line revert one commit after it is written.

**Three things about this harness are counter-intuitive. Each was established by running it, not by reasoning about it.**

1. **The direction is deploy-then-revert, not revert-then-redeploy.** The invariant worth testing is "the revert script undoes the deploy script", which is `schema(@HEAD^) == schema(deploy tip; revert tip)`. The obvious formulation — dump at `@HEAD`, revert, redeploy, dump again — tests the *opposite* implication, and for a change whose deploy is a `DROP` it is vacuous: both dumps have the tables absent no matter what the revert script contains. Task 6 ships exactly such a change, so the wrong direction would let a hand-written hundred-line revert script through ungraded.

2. **A trailing `^` works after a change name but not after `@`.** `App::Sqitch::Plan::ChangeList::_offset` (`local/lib/perl5/App/Sqitch/Plan/ChangeList.pm:33-38`) strips a trailing `^` only when it is **not** preceded by a punctuation character, and its `$punct` class at `:31` contains `@`. So in `@^` the caret is never recognised as an offset, the literal string `@^` is looked up as a change name, and nothing is found; `@HEAD^` works because the caret follows `D`. The same rule is what makes `drop-installment-schedules^` valid — the caret follows `s` — which is how the harness below addresses "the change before change X" by name instead of pinning the tip.

3. **The comparison is over sorted lines, not the raw dump.** `pg_dump` prints columns in `attnum` order, and a revert that re-adds a dropped column puts it at the end of the table rather than back in its original position — Postgres offers no way to place it. The tip's own revert does this today: `sql/revert/refund-amounts-cents.sql` restores `refund_amount_requested` and `refund_amount` after the columns that followed them, so a raw diff fails on the current tip before this leg changes anything. Sorting the filtered lines compares the *multiset* of schema statements: a missing or altered column, index, constraint, trigger or comment still fails; pure attnum drift does not. Verified: raw comparison fails on today's tip, sorted comparison passes.

Also note `pg_dump` emits a random `\restrict <key>` / `\unrestrict <key>` pair per invocation. The token is not a comment, so a comment filter does not remove it and every run would differ. `--restrict-key` pins it.

`--restrict-key` is not an 18-only flag. The `\restrict` mechanism was backported to 17.6, 16.10, 15.14 and 14.19 as the fix for CVE-2025-8714, and the flag arrived with it. Verified by `pg_dump --help | grep -c -- '--restrict-key'` returning `1` on locally installed 14.23, 15.18, 16.14, 17.10 and 18.4. CI installs `postgresql-client` from Ubuntu with `apt-get update` first (`ci.yml:41-44`), so it gets a patched minor and the flag is present. A client older than those minors would fail with `unrecognized option`; if that ever happens, the fix is to upgrade the client, not to drop the flag — without it every dump differs and the test can never pass.

- [ ] **Step 1: Write the harness**

Create `t/database/revert-round-trip.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Proves each listed sqitch change reverts cleanly: deploy to its parent, dump, deploy it, revert it, dump, diff.
# ABOUTME: A revert script that fails to restore the schema fails here instead of in production.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Test::Registry::DB ();

# Changes graded here, in plan order.  A leg that ships a migration appends its
# change name in the same commit; that is the whole registration mechanism.
# Pinning '@HEAD^' instead would grade only whichever change happens to be last,
# and Task 7's data-only change -- which round-trips trivially under a schema
# dump -- would then mask Task 6's hundred-line revert.
#
# refund-amounts-cents is the plan tip as this file is written.  It is a real
# subject rather than a placeholder: its revert re-adds two dropped columns and
# so exercises the attnum tolerance the sorted comparison exists for.
my @CHANGES = qw(
    refund-amounts-cents
);

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

my $pg_dump = Test::Registry::DB::_find_pg_tool('pg_dump');

# --restrict-key pins the random \restrict token pg_dump 18 emits per
# invocation; it is not a comment, so the filter below would miss it.
# --exclude-schema=sqitch drops the deploy-history tables, which legitimately
# differ between the two dumps.
#
# The result is sorted: pg_dump prints columns in attnum order and a revert that
# re-adds a dropped column cannot put it back in its original position.  Sorting
# compares the multiset of schema statements, so a missing or altered column,
# index, constraint, trigger or comment still fails and attnum drift does not.
sub dump_schema () {
    my @lines = qx{$pg_dump --schema-only --no-owner --no-privileges --restrict-key=rt --exclude-schema=sqitch '$uri'};
    $? == 0 or die 'pg_dump failed';
    # Drop comment lines and blanks: pg_dump emits version banners that vary.
    return [ sort grep { !/^--/ && /\S/ } @lines ];
}

my $sqitch = App::Sqitch->new();
my $n      = 0;

for my $change (@CHANGES) {
    # One tenant schema per change, so a second entry on @CHANGES does not
    # collide on tenants_slug_key (sql/test-schema.sql:3269-3273).  Earlier
    # iterations' schemas stay behind and appear in both dumps, which is
    # harmless -- the comparison is before-vs-after, not against a fixture.
    my $slug = sprintf 'rt_%d_%d', $$, $n++;

    subtest "$change reverts cleanly" => sub {
        # 'NAME^' resolves to the change before NAME.  Legal because the caret
        # follows a letter; '@^' would not be (see the header note).
        $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$change^" );

        # The tenant loops in these migrations are the half most likely to be
        # wrong, and a migration-only database has no tenant schema at all --
        # only 'registry' and 'sqitch'.  clone_schema is what provisioning
        # actually uses, so it is what the revert has to satisfy.  It copies
        # triggers as a separate step that LIKE ... INCLUDING ALL does not.
        #
        # Call it schema-qualified: the function lives in 'registry'
        # (fix-clone-schema-identifier-quoting.sql:7 sets the search_path for
        # its own creation), and a bare Mojo::Pg connection searches
        # '"$user", public', where it is not found.
        my $db = Mojo::Pg->new($uri)->db;
        $db->query('INSERT INTO registry.tenants (name, slug) VALUES (?, ?)',
            "Round Trip $n", $slug);
        $db->query('SELECT registry.clone_schema(?)', $slug);

        my $before = dump_schema();
        ok scalar( grep { /\Q$slug\E\./ } @$before ),
            "dump at $change^ includes the cloned tenant schema $slug";

        $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $change );
        $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$change^", '-y' );

        is_deeply dump_schema(), $before,
            "deploying $change and reverting it restores the schema exactly";

        # Leave the database at the parent so the next iteration's deploy --to
        # is a forward move rather than a no-op.
    };
}

done_testing;
```

`is_deeply` rather than `is`: on failure it names the first differing element instead of printing six hundred lines of schema twice.

The first assertion greps for the slug rather than asserting the dump is merely non-empty. A non-empty dump proves nothing: if `clone_schema` silently did nothing, the tenant half of every migration would go ungraded and this test would still be green — which is the failure mode the whole file exists to prevent.

The tenant is created by direct `INSERT` plus `clone_schema` rather than by `Registry::DAO::Tenant->provision`, because `provision` also copies users and seed data (`Tenant.pm:171`) and needs a `Registry::DAO::User` to exist. None of that changes the schema, which is the only thing this test reads.

- [ ] **Step 2: Run it and watch it fail — this is the red step**

Run: `carton exec prove -lv t/database/revert-round-trip.t`

Expected: **FAIL**, and the failure is real rather than staged. Takes roughly fifty seconds: the subtest deploys the plan up to the change's parent, then deploys and reverts one change, and runs `pg_dump` twice. The output is:

```
ok 1 - dump at refund-amounts-cents^ includes the cloned tenant schema rt_2972935_0
not ok 2 - deploying refund-amounts-cents and reverting it restores the schema exactly
#     Structures begin differing at:
#          $got->[2420] = 'COMMENT ON COLUMN rt_2972935_0.enrollments.refund_status IS ...'
#     $expected->[2420] = 'COMMENT ON COLUMN rt_2972935_0.enrollments.refund_amount IS 'Amount refunded for dropped enrollment';'
```

Exactly one line is in the "before" dump and missing from the "after" dump, and nothing is present in "after" that was not in "before". **Do not stage a canary to prove the harness can fail.** It already failed, on its first subject, on a bug that has been deployed since the cents conversion — which is a better red step than any injected one, and it skips the risk of leaving a canary behind in a deployed script.

**The bug.** `sql/deploy/drop-transfer-business-rules.sql:66` put a comment on `registry.enrollments.refund_amount`. `clone_schema` copies tables with `CREATE TABLE ... (LIKE src INCLUDING ALL)` (`fix-clone-schema-identifier-quoting.sql:367`), and `INCLUDING ALL` includes `INCLUDING COMMENTS`, so every tenant schema carries that comment too. `sql/revert/refund-amounts-cents.sql` restores the comment for `registry` at `:17-18` but its tenant loop (`:31-54`) re-adds the column and stops. Revert a tenant schema and the comment is gone for good.

- [ ] **Step 3: Fix the tenant loop in the revert script**

Editing a **revert** script is safe in a way editing a deploy script is not. Sqitch's modification detection compares `script_hash`, which is the SHA-1 of the **deploy** script alone (`local/lib/perl5/App/Sqitch/Plan/Change.pm:164-169`, `builder => '_deploy_hash'`), so changing a revert script does not mark the change as modified and nothing needs redeploying anywhere. This revert has never run in production; the fix only changes what happens the first time it does.

In `sql/revert/refund-amounts-cents.sql`, after `:43`:

```sql
        EXECUTE format('ALTER TABLE %I.enrollments DROP COLUMN refund_amount_cents', s);
```

add:

```sql
        EXECUTE format(
            'COMMENT ON COLUMN %I.enrollments.refund_amount
                IS ''Amount refunded for dropped enrollment''', s);
```

Doubled single quotes because the whole statement is a `format` string literal. The text must match `drop-transfer-business-rules.sql:66` exactly — a comment that differs by one character is a diff like any other.

Fix only the revert. The **deploy**'s tenant loop is asymmetric the same way — it comments `registry.enrollments.refund_amount_cents` at `:21` and not the tenant copies — but that asymmetry is invisible to this harness (both dumps lack the comment) and correcting it would edit a deployed deploy script, which the Global Constraints forbid. It goes on the issue list instead.

- [ ] **Step 4: Run it again and confirm it passes**

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: PASS, one subtest — `refund-amounts-cents reverts cleanly` — containing two assertions.

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: PASS.

- [ ] **Step 5: Replace the fake rollback subtest**

In `t/database/migration-verification.t`, replace lines 46-49. Do not widen the range upward: `:43` is the closing brace of the for-loop inside the preceding subtest, `:44` is that subtest's closing `};`, and `:45` is blank. Lines 46-49 are the whole of the rollback subtest and nothing else:

```perl
subtest 'Verify migration rollback' => sub {
    # Skip complex rollback testing for now - focus on deploy/verify
    pass("Skipping rollback tests - focus on deploy and verify");
};
```

with:

```perl
# Rollback is graded by t/database/revert-round-trip.t, which for each listed
# change deploys to its parent, deploys the change, reverts it, and diffs the
# schema dumps.  Asserting it again here would only duplicate a full deploy.
```

- [ ] **Step 6: Run both database tests**

Run: `carton exec prove -lv t/database/`
Expected: PASS, and `migration-verification.t` now reports one fewer subtest.

- [ ] **Step 7: Commit**

```bash
git add t/database/revert-round-trip.t t/database/migration-verification.t \
        sql/revert/refund-amounts-cents.sql
git commit -m "Add a revert-test harness and fix the bug it found on its first subject

The rollback subtest passed by calling pass(). The new harness takes a list of
sqitch changes and, for each one, deploys an ephemeral database to that
change's parent, provisions a tenant schema with clone_schema, deploys the
change, reverts it, and diffs the schema dumps -- so a revert script that does
not restore the schema fails here rather than in production. A leg that ships a
migration adds its change name to the list in the same commit.

It failed immediately. refund-amounts-cents restores the refund_amount column
comment for registry but not for tenant schemas, which get the comment from
clone_schema's LIKE ... INCLUDING ALL, so reverting a tenant schema dropped it
permanently. The revert's tenant loop now restores it."
```

---

### Task 2: Delete the installment machinery

**Files:**
- Delete: `lib/Registry/DAO/PaymentSchedule.pm`, `lib/Registry/DAO/ScheduledPayment.pm`, `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm`, `lib/Registry/PriceOps/PaymentSchedule.pm`, `lib/Registry/PriceOps/ScheduledPayment.pm`
- Delete: `t/controller/admin-installment-payment-dashboard.t`, `t/controller/installment-payment-webhooks.t`, `t/controller/subscription-webhook-routing.t`, `t/dao/payment-schedule-race-condition.t`, `t/dao/payment-schedule.t`, `t/dao/scheduled-payment.t`, `t/e2e/installment-payment-enrollment.t`, `t/integration/installment-webhook-processing.t`, `t/unit/installment-breakdown.t`
- Modify: `lib/Registry/Controller/Webhooks.pm:8,69-72,204-289`
- Modify: `t/controller/payment-failures.t:3,13,16,22-24,26-30,34-36,71-79,92-272,274`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Registry::Controller::Webhooks::stripe` keeps exactly two branches after this task — the tenant-billing branch and the enrollment-payment branch. Task 6 relies on no Perl code naming `payment_schedules` or `scheduled_payments`.

**Context:** issue #295 records that installments are unreachable. Verified: `grep -rn "PaymentSchedule\|ScheduledPayment\|InstallmentPayment" lib/Registry/DAO.pm lib/Registry.pm workflows/` returns nothing. The step class is wired into no workflow YAML and is not in `Registry::DAO`'s module list (`lib/Registry/DAO.pm:11-28`). The only live entry point is the webhook `elsif`, removed below.

- [ ] **Step 1: Delete the five modules and nine test files**

```bash
git rm lib/Registry/DAO/PaymentSchedule.pm \
       lib/Registry/DAO/ScheduledPayment.pm \
       lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm \
       lib/Registry/PriceOps/PaymentSchedule.pm \
       lib/Registry/PriceOps/ScheduledPayment.pm \
       t/controller/admin-installment-payment-dashboard.t \
       t/controller/installment-payment-webhooks.t \
       t/controller/subscription-webhook-routing.t \
       t/dao/payment-schedule-race-condition.t \
       t/dao/payment-schedule.t \
       t/dao/scheduled-payment.t \
       t/e2e/installment-payment-enrollment.t \
       t/integration/installment-webhook-processing.t \
       t/unit/installment-breakdown.t
```

- [ ] **Step 2: Unwire the webhook branch**

In `lib/Registry/Controller/Webhooks.pm`, delete the import at `:8`:

```perl
use Registry::DAO::PaymentSchedule;
```

Then replace the dispatch at `:69-72`. The range **must** run through `:72`: that line is `            } else {`, whose `}` closes the installment `elsif` being deleted. Deleting only `:69-71` leaves the `}` at `:68` immediately followed by `} else {`, which does not compile. Both blocks below are indented twelve spaces, matching the file.

```perl
            # Determine if this is an installment payment or tenant billing event
            elsif ($self->_is_installment_payment_event($event)) {
                $self->_process_installment_payment_event($dao->db, $event);
            } else {
```

with:

```perl
            else {
```

- [ ] **Step 3: Delete the four orphaned webhook methods**

Delete these four methods from `lib/Registry/Controller/Webhooks.pm` in full, along with their leading comments:

- `_is_installment_payment_event` (`:204-227`)
- `_process_installment_payment_event` (`:229-255`)
- `_handle_installment_subscription_updated` (`:257-275`)
- `_handle_installment_subscription_cancelled` (`:277-289`)

- [ ] **Step 4: Confirm nothing else names them**

Run:

```bash
grep -rn "PaymentSchedule\|ScheduledPayment\|InstallmentPayment\|_is_installment_payment_event\|_process_installment_payment_event" lib/ t/ templates/ workflows/
```

Expected: only `t/controller/payment-failures.t` (fixed in the next step). Nothing under `lib/`.

- [ ] **Step 5: Re-cut `t/controller/payment-failures.t`**

Three of its four subtests are installment-based and die once the DAOs are gone. The fourth — `'refund updates payment and enrollment status'` (`:276-353`) — touches only `registry.payments` and `enrollments`. Keep only the fourth, and take out the setup that existed solely to feed the other three. If any of it survives, Task 6 Step 10's grep for `payment_schedules` under `t/` fails.

**Work bottom-up.** Every range below is a line number in the file as it stands now; deleting from the top first shifts the ones underneath.

1. `:92-272` — one contiguous block: the `# Helper to create a payment schedule with 3 installments` comment, `create_test_schedule`, the `post_webhook` helper and its four-line comment, and all three webhook subtests (`4.1 Card Decline` `:135-165`, `4.2 Duplicate Webhook` `:170-215`, `4.3 Failed Installment` `:220-271`), through the blank line at `:272`. The refund subtest's own banner starts at `:273`.
2. `:71-79` — the `$pricing` plan and its trailing blank. Its only reader was `create_test_schedule` at `:96`.
3. `:34-36` — the Mojo app and its trailing blank:
   ```perl
   my $t = Test::Registry::Mojo->new('Registry');
   $t->app->helper(dao => sub { $dao });
   ```
   `$t` was referenced only inside `post_webhook` (`:125,129`). Nothing left in the file makes an HTTP request.
4. `:26-30` — the fake-key block and its trailing blank:
   ```perl
   # Fake Stripe key so PriceOps::ScheduledPayment constructor doesn't die.
   # No actual Stripe calls are made in these tests.
   local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_webhook_tests';
   local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_fake_for_webhook_tests';
   ```
5. `:22-24` — three now-unused imports:
   ```perl
   use Registry::DAO::PricingPlan;
   use Registry::DAO::PaymentSchedule;
   use Registry::DAO::ScheduledPayment;
   ```
6. `:16` — `use Digest::SHA qw(hmac_sha256_hex);`. Its only caller was `post_webhook` at `:123`. **Keep `:17` `use Mojo::JSON qw(encode_json);`** — the refund subtest calls `encode_json` at `:291,337`.
7. `:13` — `use Test::Registry::Mojo;`, unused once `$t` is gone.
8. `:3` — rewrite the second ABOUTME line from:
   ```perl
   # ABOUTME: Tests card decline, duplicate webhook, failed installment, and refund at HTTP and DAO layers.
   ```
   to:
   ```perl
   # ABOUTME: Tests that a refund updates the payment row and the enrollment it paid for.
   ```
9. Renumber the surviving banner. `4.1` through `4.3` no longer exist, so `:274` becomes:
   ```perl
   # Refund Processing (DAO level - no webhook handler for refunds)
   ```

Leave `use Test::Registry::Fixtures;` (`:15`) alone. It is unused today and was unused before this leg — an unrelated cleanup.

- [ ] **Step 6: Run the affected tests**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-failures.t t/controller/webhooks.t t/controller/payment-intent-webhook.t`
Expected: PASS, pristine. `payment-intent-webhook.t` is in the list because Step 2 rewrites the `if`/`elsif`/`else` chain it drives; it is the fastest check that the surviving two branches still dispatch.

- [ ] **Step 7: Run the wider controller and DAO suites**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/controller/ t/dao/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A lib/Registry/DAO lib/Registry/PriceOps lib/Registry/Controller/Webhooks.pm t/
git commit -m "Delete the installment machinery (#295)

Installments were reachable only through a webhook branch: no workflow YAML
names the step class and Registry::DAO does not load the DAOs. Five modules,
nine test files, and the webhook elsif go together. payment-failures.t keeps
its refund subtest; the other three needed a payment schedule to exist."
```

**No coverage gap here, and the reason is worth stating so nobody re-adds one.** The deleted `4.2 Duplicate Webhook` subtest (`:170-215`) graded event-ID dedup on the *installment* path: it posts `invoice.paid` twice and asserts one `registry.scheduled_payments` row went to `completed`. Both the path and the table go away in this leg, so the assertion has nothing left to guard. Dedup on the path that survives is already covered — `t/controller/payment-intent-webhook.t:97` `'duplicate delivery of the same event is deduped (#158)'` posts the same `payment_intent.succeeded` event twice and asserts no second enrollment and no second confirmation, and `:103` covers the harder case of a distinct event id against the same payment.

---

### Task 3: Delete `Client::Stripe` and `PriceOps::PricingPlan`

**Files:**
- Delete: `lib/Registry/Client/Stripe.pm`, `lib/Registry/PriceOps/PricingPlan.pm`
- Modify: `t/dao/pricing-plan-amount-cents.t:11,146-166`
- Modify: `t/stripe-live/service-version.t:16-18` (comment only — edit it, never run it)
- Modify: `lib/Registry/DAO/PricingPlan.pm:196-198`

**Interfaces:**
- Consumes: Task 2 must be complete. `InstallmentPayment.pm`, `PriceOps/ScheduledPayment.pm` and `PriceOps/PaymentSchedule.pm` are the bulk of both modules' callers, and Task 2 is what deletes them.
- Produces: `Registry::Service::Stripe` becomes the only Stripe client in the tree. Later legs add methods there, not to a second client.

- [ ] **Step 1: Confirm both modules are unreferenced apart from the one test**

Run:

```bash
grep -rn "Client::Stripe\|PriceOps::PricingPlan" lib/ t/ templates/ workflows/ bin/
```

Expected, **and only after Task 2 has landed** — before it, `InstallmentPayment.pm:12,78,95,178`, `PriceOps/ScheduledPayment.pm:12,18`, `PriceOps/PaymentSchedule.pm:12,19` and `t/unit/installment-breakdown.t:2,11,13` all still match, and Steps 2-3 would strand them:

| Match | Disposition |
|---|---|
| `lib/Registry/Client/Stripe.pm:8` | the class statement — deleted in Step 2 |
| `lib/Registry/PriceOps/PricingPlan.pm:8` | the class statement — deleted in Step 2 |
| `lib/Registry/DAO/PricingPlan.pm:198` | a comment — rewritten in Step 4 |
| `t/dao/pricing-plan-amount-cents.t:11,158` | the import and its one user — deleted in Step 3 |
| `t/stripe-live/service-version.t:16` | a comment — rewritten in Step 3a |

Five files, no more. Anything else means Task 2 is incomplete; stop and finish it first.

- [ ] **Step 2: Delete both modules**

```bash
git rm lib/Registry/Client/Stripe.pm lib/Registry/PriceOps/PricingPlan.pm
```

- [ ] **Step 3: Re-cut `t/dao/pricing-plan-amount-cents.t`**

Delete the import at `:11`:

```perl
use Registry::PriceOps::PricingPlan;
```

Delete the whole subtest at `:146-166`, `'a dollar-denominated discount is scaled before it meets a cents price'`. It is the only user of `my $ops = Registry::PriceOps::PricingPlan->new;` (`:158`, used at `:160,162,164`).

Keep the final subtest at `:168-182` — it calls `$plan->calculate_price`, which lives on the surviving DAO.

**What goes with it:** `calculate_plan_price` (`PriceOps/PricingPlan.pm:87-118`) is the only code in the tree that scales a `sibling_discount` from dollars to cents (`:112`), and this subtest is its only test. Both disappear together. That is not a coverage gap — Task 4 deletes the rest of the sibling-discount surface for the same reason, that nothing reaches it. `Registry::DAO::PricingPlan::calculate_price` (`:136-149`) handles `percentage_discount` only and is unaffected.

- [ ] **Step 3a: Fix the comment in the stripe-live fixture**

`t/stripe-live/service-version.t:16-18` names the module being deleted:

```perl
# The PRODUCTION client, constructed exactly as Payment.pm / Client::Stripe.pm
# do: api_key only, so the default api_version is exercised and sent as the
# Stripe-Version header on the request below.
```

Replace with:

```perl
# The PRODUCTION client, constructed exactly as Payment.pm does: api_key only,
# so the default api_version is exercised and sent as the Stripe-Version
# header on the request below.
```

Edit only. **Do not run `t/stripe-live/`** — it bills a real Stripe account.

- [ ] **Step 4: Fix the comment that the deletion makes false**

`lib/Registry/DAO/PricingPlan.pm:196-198` currently reads:

```perl
    # Get installment amount, in cents. Integer division drops the remainder,
    # so the installments can sum to less than the plan price -- see
    # Registry::PriceOps::PricingPlan for the breakdown that carries it.
```

Replace with:

```perl
    # Get installment amount, in cents. Integer division drops the remainder,
    # so the installments can sum to less than the plan price. Nothing collects
    # installments today; the columns survive until the table is versioned.
```

- [ ] **Step 5: Run the tests**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/pricing-plan-amount-cents.t`
Expected: PASS with one fewer subtest.

- [ ] **Step 6: Commit**

```bash
git add -A lib/Registry t/dao/pricing-plan-amount-cents.t t/stripe-live/service-version.t
git commit -m "Delete Client::Stripe and PriceOps::PricingPlan

Neither had a caller outside one subtest. Service::Stripe is now the only
Stripe client in the tree, which is where later legs add methods."
```

---

### Task 4: Delete the orphaned discount surface and the silent-pass test

**Files:**
- Delete: `t/dao/pricing-plan-clean-architecture.t`
- Modify: `lib/Registry/DAO/Family.pm:67-82` (delete `sibling_discount_eligible`)
- Modify: `t/dao/family.t:219-252`
- Modify: `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm:2,11,45-94,163-167`
- Modify: `t/dao/pricing-plan-workflow.t:216-222,242,292-294,411`
- Modify: `templates/pricing-plan-creation/requirements-rules.html.ep:77-171,344-355`
- Modify: `templates/pricing-plan-creation/review-activate.html.ep:163-185`

**Interfaces:**
- Consumes: nothing.
- Produces: the `requirements-rules` workflow step keeps every non-discount field it has today. Leg 5's authoring rewrite starts from that reduced form.

**Why these three go together:** all three are code that produces or asserts values nothing reads. `sibling_discount_eligible` has only test callers. The discount form writes `early_bird_enabled`, `early_bird_discount`, `early_bird_cutoff_date`, `family_discount_enabled`, `family_discount_type`, `family_discount_amount`, `min_children`, `volume_discount_enabled`, `volume_tiers` — and the calculators read different keys entirely (`percentage_discount` at `lib/Registry/DAO/PricingPlan.pm:143`, `sibling_discount` at the now-deleted `PriceOps/PricingPlan.pm:112`). `volume_discount_enabled` and `volume_tiers` have zero readers anywhere. `pricing-plan-clean-architecture.t` is issue #296: it calls `pass("Skipping test due to database issue")` at `:61,83,129,198`, so it asserts nothing at all.

- [ ] **Step 1: Delete the #296 silent-pass test**

```bash
git rm t/dao/pricing-plan-clean-architecture.t
```

It is also the only file with `use Registry::DAO::PricingRelationship;` at `:16`, so confirm that module still has callers:

Run: `grep -rn "PricingRelationship" lib/ t/`
Expected: matches under `lib/` remain. If none do, stop and report — the module would then be dead too, which is out of this task's scope.

- [ ] **Step 2: Delete `sibling_discount_eligible` and its two test callers**

In `lib/Registry/DAO/Family.pm`, delete `:67-82` — the sub and the comment that introduces it:

```perl
    # Get sibling discount eligibility
    sub sibling_discount_eligible ($class, $db, $family_id, $session_id) {
```

`:67` is the comment, `:68` the `sub` line, `:82` its closing brace. Take the comment too: it describes only this sub, and `:83` is the class's own closing `}`, so leaving the comment behind strands it against the end of the file.

In `t/dao/family.t`, delete the whole `'Sibling discount eligibility'` subtest, `:219-251`. The two `sibling_discount_eligible` calls at `:237` and `:249` are the subtest's **only** assertions — deleting just those two lines leaves a subtest whose body creates a session and two enrollments and then asserts nothing, which `Test::More` reports as `No tests run for subtest`, a failure. The whole block goes, including its setup and the two `Registry::DAO::Enrollment->create` calls that exist to make the second assertion true.

`:217` closes the preceding subtest and `:253` opens the next one, so `:219-251` plus the blank line at `:252` is a clean cut; take `:219-252`.

Run: `grep -rn "sibling_discount_eligible" lib/ t/ templates/`
Expected: no matches.

- [ ] **Step 3: Delete the discount blocks from the step class**

In `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm`, the three discount blocks are adjacent — early bird `:45-68`, family/group `:70-76`, volume `:78-93` — so delete `:45-94` as one contiguous cut. `:44` is the blank line after the `prerequisite_programs` block and `:95` is `# Seasonal availability`; both stay.

Then delete `:11`:

```perl
    use DateTime;
```

`DateTime->new` at `:54` was its only caller, inside the early-bird cutoff-date validation. Leave `use Carp qw( croak );` at `:10` — it is unused today and was unused before this leg.

Then delete `:163-167` from the hash `get_template_data` returns — the blank line and the `discount_types` list:

```perl

            discount_types => [
                { value => 'percentage', label => 'Percentage off' },
                { value => 'fixed', label => 'Fixed amount off' },
            ]
```

Its only reader is `templates/pricing-plan-creation/requirements-rules.html.ep:150` (`my $types = stash('step_data')->{discount_types} || [];`), which Step 4 deletes inside its `:77-171` cut. `:162` is the `],` closing `trial_feature_levels` and `:168` is `};`; a trailing comma before the closing brace is fine, so no other edit is needed.

Finally rewrite the second ABOUTME line at `:2`, which the discount deletions make false:

```perl
# ABOUTME: Configures discounts, eligibility criteria, and renewal policies
```

to:

```perl
# ABOUTME: Configures eligibility criteria, trial terms, and renewal policies
```

- [ ] **Step 4: Delete the discount fields from the form template**

In `templates/pricing-plan-creation/requirements-rules.html.ep`, delete two ranges, **bottom-up**:

1. `:344-355` — the two toggle functions and the blank line between and after them:
   ```javascript
   function toggleEarlyBird() { ... }

   function toggleFamilyDiscount() { ... }

   ```
   `:343` is `<script>` and `:356` is `function toggleTrial() {`, which stays.
2. `:77-171` — one contiguous cut covering both field groups: the `<!-- Early Bird Discount -->` section (`:77-114`), the blank at `:115`, and the `<!-- Family/Group Discounts -->` section (`:116-170`) through the blank at `:171`. `:75` closes the preceding section and `:172` is `<!-- Renewal Policies -->`.

Deleting only the inner field groups (`:82-98`, `:121-162`) is wrong: it strands the two section `<div class="border-b pb-6">` wrappers, their `<h3>` headings, and the `onclick="toggleEarlyBird()"` / `onclick="toggleFamilyDiscount()"` checkboxes at `:86` and `:125`, which would then call functions that no longer exist.

- [ ] **Step 5: Delete the stranded reader in the review template**

In `templates/pricing-plan-creation/review-activate.html.ep`, delete `:163-185` — the whole `<% if ($summary->{requirements}) { %>` block that displays `$reqs->{early_bird_enabled}`, `early_bird_discount`, `early_bird_cutoff_date`, `family_discount_enabled`, `family_discount_amount`, `family_discount_type`, and `min_children`. Once the form stops writing those keys, this block is a reader for data that no longer exists.

The whole block, not just the two `<% if %>` bodies: `:163` opens the guard, `:164` binds `my $reqs`, `:165` opens the `<dl>`, `:184` closes it and `:185` closes the guard. Deleting only `:166-183` leaves an empty `<dl>` inside a guard whose only remaining statement is an unused `my $reqs`. `:187` starts the `$summary->{rules}` block, which stays.

- [ ] **Step 5a: Fix the stranded caller in `t/dao/pricing-plan-workflow.t`**

This file drives `RequirementsRules->process` directly and asserts on what it stored. Once Step 3 lands, its assertion at `:242` reads a key the step no longer writes and fails on `undef`. Four edits, **bottom-up**:

1. `:411` — delete the commented-out assertion, now permanently false:
   ```perl
       # is($created_plan->requirements->{family_discount_amount}, 20, 'Family discount persisted');
   ```
2. `:292-294` — delete the three inert fixture keys inside the hand-built `requirements_rules` hash for the Step 5 subtest:
   ```perl
                   early_bird_enabled => 1,
                   early_bird_discount => 20,
                   early_bird_cutoff_date => '2024-11-01'
   ```
   Leave `requirements => {` at `:291` and `},` at `:295`; an empty hash is the honest fixture now. That subtest's assertions cover `plan_name`, `pricing_model_type`, `amount_cents` and `pricing_configuration` only, so nothing reads these three.
3. `:242` — delete the assertion:
   ```perl
       is($run_data->{requirements_rules}{requirements}{early_bird_discount}, 15, 'Early bird discount stored');
   ```
   The two around it (`min_age` at `:241`, `trial_days` at `:243`) stay — both are non-discount fields the step still writes.
4. `:216-222` — delete the seven discount keys posted to `process`:
   ```perl
           early_bird_enabled => 1,
           early_bird_discount => 15,
           early_bird_cutoff_date => '2024-12-01',
           family_discount_enabled => 1,
           min_children => 2,
           family_discount_type => 'percentage',
           family_discount_amount => 10,
   ```
   `:215` (`location_restrictions`) and `:223` (`auto_renew`) stay; the hash remains well-formed.

- [ ] **Step 6: Confirm no discount key survives without both a writer and a reader**

Run:

```bash
grep -rn "early_bird_\|family_discount_\|min_children\|volume_discount_enabled\|volume_tiers\|discount_types" lib/ t/ templates/ workflows/
```

**Run this gate only after Task 3 has landed.** `lib/Registry/PriceOps/PricingPlan.pm:100,130` match the pattern and are not survivors — Task 3 Step 2 deletes that file. Running the gate before Task 3 produces two matches that are not on the table below and the check reads as a miss.

Expected: **matches remain, and every one must be on this list.** The nine keys this task removes are the ones the orphaned *form* wrote. `early_bird_cutoff_date` and `min_children` are also read by two surviving `PricingPlan` methods that key on `plan_type`, not on the form:

| Survivor | Why it stays |
|---|---|
| `lib/Registry/DAO/PricingPlan.pm:154,155,170,172,181,183,186` | `requirements_met` and `is_early_bird_available`. Both are live readers reached through `plan_type eq 'early_bird'` / `'family'`, which the enhanced-pricing-model migration backfills. Out of scope for Leg 1. `:181` is the `method is_early_bird_available` declaration itself — the pattern `early_bird_` matches inside the method name, so the line shows up in the grep. |
| `t/dao/pricing-plans.t:69,76,86,92,139,155,172,198,206` | tests those two methods. |
| `t/dao/tenant-summer-camp.t:172` | a fixture for the same `plan_type` path. |

Nineteen matches, no more. Anything **not** on that list is a miss — in particular any match under `templates/`, under `workflows/`, or in `RequirementsRules.pm`, all of which must be gone.

`t/e2e/admin-program-management.t` does **not** appear, despite writing `pricing => { standard => 180.00, early_bird => 150.00 }` at `:138,148`. Its key is `early_bird`, with no trailing underscore, so the pattern `early_bird_` never matches it. It is named here only so nobody adds it to the table on sight of the file.

`sql/` is excluded from the grep on purpose: `enhanced-pricing-model.sql`, `summer-camp-module.sql` and their revert and verify scripts all name these columns, and they are deployed changes that must not be edited.

- [ ] **Step 7: Run the affected tests**

No workflow re-import. `workflows/pricing-plan-creation.yaml:25-28` stores the step's **class name**, not its code, and the class name has not changed — so the stored definition is still correct. `carton exec ./registry workflow import registry` would also write the **dev** database (`lib/Registry/Command/workflow.pm` takes its DAO from `$self->app->dao`), which this plan's Global Constraints forbid.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/family.t t/dao/pricing-plan-workflow.t t/dao/pricing-plans.t`
Expected: PASS. `family.t` reports one fewer subtest.

(`t/dao/pricing-plan.t` does not exist — the singular-named files are `pricing-plans.t`, `pricing-plan-workflow.t` and `pricing-plan-amount-cents.t`.)

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/dao/ t/controller/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add -A lib/Registry t/dao templates/pricing-plan-creation
git commit -m "Delete the orphaned discount surface and the test that passed by skipping (#296)

The requirements-rules form wrote nine discount keys. The calculators read
different keys; volume_discount_enabled and volume_tiers had no reader at all.
The review template displayed the orphaned keys, so it goes with the form.
Family::sibling_discount_eligible had only test callers.

pricing-plan-clean-architecture.t called pass() four times with an explanation
instead of asserting anything."
```

---

### Task 5: Delete the `seti_test` signup bypass

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:40-47,294-307,373`
- Modify: `t/controller/tenant-create-session.t:65-67`
- Modify: `t/user-journeys/alex/01-acquire-tenant.t:5,82-85,199-208,331-348`
- Modify: `t/user-journeys/alex/03-platform-billing.t:5,77-78,164-172,214,216`

**Interfaces:**
- Consumes: nothing.
- Produces: `TenantPayment::process` dispatches on three conditions only — a real `setup_intent_id`, `collect_payment_method` with no Stripe keys configured, and the bare page load. No branch keys on the value of a client-supplied string.

**The defect:** `TenantPayment.pm:43` and `:295` both branch on `$form_data->{setup_intent_id} =~ /^seti_test/` — a client-supplied string with no environment guard. In production, where both Stripe keys are set, a POST carrying `setup_intent_id=seti_test_anything` provisions a tenant with a fake subscription. The no-keys branch immediately below produces a byte-identical result hash and **is** environment-guarded, so it can never fire in production.

**Verified before writing this task:**
- The two branches produce the same hash: both build `{ stripe_subscription_id => 'sub_test_' . time(), trial_ends_at => time() + (30*24*60*60), status => 'trialing' }`, call `$run->update_data`, call `_provision_tenant`, and return `{ next_step => 'complete', tenant_created => 1, %$result }`. `TenantPayment.pm:371-373` says so itself: "This is the single provisioning path for all completion scenarios".
- `t/controller/tenant-create-session.t` already exercises the no-keys branch today. Its `BEGIN { delete @ENV{qw(STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY)} }` is at `:7`, and its `setup_intent_id => 'seti_test_123'` at `:66` never reaches the step: `templates/tenant-signup/payment.html.ep:91` renders `<input type="hidden" name="setup_intent_id" value="">`, and `t/lib/Test/Registry/Helpers.pm:168` builds the submission as `my %submit = ( $data->%{@$fields}, %$hidden );` — server-issued hidden values win. The test passes (117 tests, verified).
- The two alex journeys post directly with `Test::Mojo`, bypassing the template, so they are the only genuine consumers.
- `handle_setup_completion` constructs `Registry::DAO::Subscription->new(db => $db)` at `:291`, **before** the `seti_test` check, and `lib/Registry/DAO/Subscription.pm:18` dies without `STRIPE_SECRET_KEY`. Removing the bypass means the alex journeys stop reaching that constructor entirely, which is why deleting the key is safe.

**Named risk and its fallback:** if an alex journey turns out to need a `Subscription` object after all, the in-repo pattern is `local *Registry::Service::Stripe::create_payment_intent_async = sub {...}` (`t/user-journeys/alex/02-activate-and-collect.t:421`, `t/integration/tenant-paid-enrollment.t:237`, and eight more sites). It works on Object::Pad methods. Put such a helper in `t/lib/`, not in a production class.

- [ ] **Step 1: Add the env guard to both alex journeys and prove they fail**

In `t/user-journeys/alex/01-acquire-tenant.t`, after the existing line `:5`:

```perl
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
```

add:

```perl
# The payment step provisions directly when no Stripe keys are configured.
# Ambient keys would send it to create_setup_intent and a live API call.
BEGIN { delete @ENV{qw(STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY)} }
```

Make the identical addition after `:5` in `t/user-journeys/alex/03-platform-billing.t`.

- [ ] **Step 2: Run them and watch them fail**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/user-journeys/alex/01-acquire-tenant.t`
Expected: FAIL. The POST still carries `setup_intent_id=seti_test_acquire_$$`, so dispatch reaches `handle_setup_completion`, which constructs `Registry::DAO::Subscription` and dies with `STRIPE_SECRET_KEY not set`.

This is the red step: it demonstrates that the `seti_test` branch, not the no-keys branch, is what those tests exercise today.

- [ ] **Step 3: Delete the bypass in `process`**

In `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`, delete `:40-47`. The block below is `:40-46` — `:40` is the comment, not the `if` — plus the blank line at `:47`. `:39` is already blank, so cutting only `:40-46` leaves two consecutive blanks:

```perl
        # Handle payment method collection with setup intent (testing scenario)
        if ($form_data->{collect_payment_method} && $form_data->{setup_intent_id}) {
            # Special case for testing: if we have both flags, go directly to completion
            if ($form_data->{setup_intent_id} =~ /^seti_test/) {
                return $self->handle_setup_completion($db, $run, $form_data);
            }
        }
```

`:48` is `# Handle setup intent completion`, which stays.

- [ ] **Step 4: Delete the bypass in `handle_setup_completion`**

Delete `:294-307` — the block below is `:294-306`, plus the blank at `:307`, on the same reasoning: `:293` is already blank and `:308` is `# For non-test modes, validate the setup_intent_id matches what was stored`.

```perl
        # Test mode: setup_intent_id starts with 'seti_test' — skip Stripe validation.
        if ($form_data->{setup_intent_id} && $form_data->{setup_intent_id} =~ /^seti_test/) {
            my $mock_subscription = {
                stripe_subscription_id => 'sub_test_' . time(),
                trial_ends_at => time() + (30 * 24 * 60 * 60), # 30 days from now
                status => 'trialing',
            };

            $run->update_data($db, { subscription => $mock_subscription });

            my $result = $self->_provision_tenant($db, $run);
            return { next_step => 'complete', tenant_created => 1, %$result };
        }
```

- [ ] **Step 5: Correct the `_provision_tenant` comment**

`:373` currently reads:

```perl
    # scenarios (no-Stripe mock, seti_test mock, real-Stripe).
```

Replace with:

```perl
    # scenarios (no-Stripe mock, real-Stripe).
```

- [ ] **Step 6: Stop the alex journeys posting the deleted key**

In `t/user-journeys/alex/01-acquire-tenant.t`, replace the POST at `:199-208`:

```perl
# -- Step: payment (POST via seti_test seam) ------------------------------
# POST collect_payment_method=1 + setup_intent_id=seti_test_... dispatches
# to handle_setup_completion -> _provision_tenant (TenantPayment.pm:43-46,
# 283-294).  The seti_test branch wins on dispatch order before the no-keys
# branch, so Stripe env keys are irrelevant to this POST.
# Expected: 302 -> /tenant-signup/<run-id>/complete
$t->post_ok($payment_url => form => {
    collect_payment_method => 1,
    setup_intent_id        => 'seti_test_acquire_' . $$,
})->status_is(302)
```

with:

```perl
# -- Step: payment (POST, no Stripe keys configured) ----------------------
# collect_payment_method=1 with no Stripe keys in the environment provisions
# directly (TenantPayment.pm, the !STRIPE_PUBLISHABLE_KEY && !STRIPE_SECRET_KEY
# branch).  The BEGIN block at the top of this file guarantees the condition.
# Expected: 302 -> /tenant-signup/<run-id>/complete
$t->post_ok($payment_url => form => {
    collect_payment_method => 1,
})->status_is(302)
```

Make the matching edit at `t/user-journeys/alex/03-platform-billing.t:164-172`, dropping `setup_intent_id => 'seti_test_billing_' . $$,` (`:171`) and rewriting the five comment lines at `:164-168` the same way. Note that file's POST ends `})->status_is(302);` with a semicolon and no `header_like` chain — do not paste `01`'s version over it.

- [ ] **Step 7: Update the funnel-documentation comments**

`t/user-journeys/alex/01-acquire-tenant.t:82-85`:

```perl
#   payment     — 'collect_payment_method' + 'setup_intent_id' (seti_test...)
#                 trigger the test-mode provision path in TenantPayment.pm:43-46.
#                 The seti_test branch wins on dispatch order before the no-keys
#                 branch, so Stripe env keys are irrelevant to this POST.
```

becomes:

```perl
#   payment     — 'collect_payment_method' with no Stripe keys in the
#                 environment triggers the direct-provision path in
#                 TenantPayment.pm.  The BEGIN block above unsets the keys.
```

`t/user-journeys/alex/03-platform-billing.t:77-78`:

```perl
#   payment     — 'collect_payment_method' + 'setup_intent_id' (seti_test…)
#                 trigger the test-mode provision path.
```

becomes:

```perl
#   payment     — 'collect_payment_method' with no Stripe keys in the
#                 environment triggers the direct-provision path.
```

- [ ] **Step 8: Rename the assertions that name the removed seam**

The assertions themselves survive unchanged — the no-keys branch produces the same `'sub_test_' . time()` — but their names must stop naming a path that no longer exists.

`t/user-journeys/alex/01-acquire-tenant.t:331-348`:

- `# Assertion 4: billing fields are set correctly for the seti_test path.` → `# Assertion 4: billing fields are set correctly on the direct-provision path.`
- `# (set by handle_setup_completion on the seti_test branch).` → `# (set by process on the no-Stripe-keys branch).`
- `subtest 'tenant row carries billing fields from seti_test path' => sub {` → `subtest 'tenant row carries billing fields from direct-provision path' => sub {`
- `'billing_status is "trial" on the seti_test provision path'` → `'billing_status is "trial" on the direct-provision path'`
- `'stripe_subscription_id starts with sub_test_ (seti_test seam)'` → `'stripe_subscription_id starts with sub_test_ (direct-provision path)'`

`t/user-journeys/alex/03-platform-billing.t:214,216`:

- `'stripe_subscription_id starts with sub_test_ (seti_test provision path)'` → `'stripe_subscription_id starts with sub_test_ (direct-provision path)'`
- `'billing_status is "trial" on the seti_test path'` → `'billing_status is "trial" on the direct-provision path'`

- [ ] **Step 9: Remove the dead form keys from the controller test**

In `t/controller/tenant-create-session.t`, delete `:65-67`:

```perl
            # Mock payment data to satisfy workflow
            setup_intent_id  => 'seti_test_123',
            payment_method_id => 'pm_test_123',
```

Keep `collect_payment_method => '1',` — that key **is** rendered by the form and is what selects the provision branch.

- [ ] **Step 10: Confirm the string is gone**

Run: `grep -rn "seti_test" lib/ t/ templates/`
Expected: no matches.

- [ ] **Step 11: Run the three affected tests green**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/tenant-create-session.t t/user-journeys/alex/01-acquire-tenant.t t/user-journeys/alex/03-platform-billing.t`
Expected: PASS, pristine.

- [ ] **Step 12: Commit**

```bash
git add -A lib/Registry/DAO/WorkflowSteps/TenantPayment.pm t/controller/tenant-create-session.t t/user-journeys/alex
git commit -m "Delete the seti_test signup bypass

Two branches keyed on a client-supplied string with no environment guard: a
POST carrying setup_intent_id=seti_test_anything provisioned a tenant with a
fake subscription in production. The no-keys branch directly below produces an
identical result hash and is guarded, so the tests that needed the bypass only
needed the keys unset.

tenant-create-session.t was never a real consumer -- the payment template
renders setup_intent_id as an empty hidden field and the form helper lets
server-issued values win, so its seti_test_123 never reached the step."
```

---

### Task 6: Drop the installment tables

**Files:**
- Create: `sql/deploy/drop-installment-schedules.sql`, `sql/revert/drop-installment-schedules.sql`, `sql/verify/drop-installment-schedules.sql`
- Modify: `sql/sqitch.plan` (append one line)
- Modify: `sql/verify/installment-payment-schedules.sql`, `sql/verify/simplify-installment-schema-for-stripe.sql`, `sql/verify/schedule-amounts-cents.sql`, `sql/verify/tenant-scoped-payments.sql:26`
- Modify: `t/dao/tenant-payment-schema-isolation.t:3,7,11,38-39,43,93-223`
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: `t/database/revert-round-trip.t` from Task 1 — this change lands at the tip, so the harness grades its revert. Task 2 must be complete: no Perl may name the dropped tables.
- Produces: sqitch change `drop-installment-schedules`, which becomes the required dependency for Task 7's change.

**The four stranded verify scripts,** found by `grep -rln "payment_schedules\|scheduled_payments" sql/`. Three fail hard against a schema without the tables:

| Script | What breaks | Edit |
|---|---|---|
| `installment-payment-schedules.sql` | `SELECT ... FROM registry.payment_schedules WHERE FALSE` (`:10-14`, `:18-22`) and two `SELECT 1/count(*)` index checks (`:25-26`) — the latter divide by zero | fully vacuous |
| `simplify-installment-schema-for-stripe.sql` | `conrelid = 'registry.payment_schedules'::regclass` (`:24`) throws on a missing relation | fully vacuous |
| `schedule-amounts-cents.sql` | the `FOREACH c SLICE 1` loop raises for every missing column (`:15-49`) | fully vacuous |
| `tenant-scoped-payments.sql` | `FOREACH tbl IN ARRAY ARRAY['payments','payment_items','payment_schedules','scheduled_payments']` (`:26`) raises for the two dropped tables | remove two array elements only |

- [ ] **Step 1: Add the change to the plan**

```bash
carton exec sqitch add drop-installment-schedules \
  --requires schedule-amounts-cents \
  --requires tenant-scoped-payments \
  -n 'Drop the installment schedule tables from registry and every tenant schema'
```

Confirm `sql/sqitch.plan` gained exactly one line at the end and that the three stub files appeared under `sql/deploy/`, `sql/revert/`, `sql/verify/`.

Then register the change with Task 1's harness, in this same commit. In `t/database/revert-round-trip.t`, extend `@CHANGES`:

```perl
my @CHANGES = qw(
    refund-amounts-cents
    drop-installment-schedules
);
```

The harness grades only what is on that list. Skipping this append is the failure mode Task 1's list exists to prevent, and it is silent — the suite stays green and the hundred-line revert script below is never run.

- [ ] **Step 1a: Check what the drop would destroy in production**

`DROP TABLE` is not reversible for rows. The revert below recreates both tables empty. Before merging, count what is there. Run this **read-only** against the Render production database `dpg-ckq1i8o5vl2c73d61070-a` (registry-db), the same target Task 7 Step 1 uses:

```sql
SELECT (SELECT count(*) FROM registry.payment_schedules)  AS schedules,
       (SELECT count(*) FROM registry.scheduled_payments) AS payments;
```

Expected: `0` and `0`. Issue #295 says installments are unreachable, and Task 2 has already established that no code path creates a schedule — but "unreachable now" and "never reached" are different claims, and only the count settles it. **Non-zero means stop and report to perigrin**; this leg's premise is that these tables hold nothing, and dropping rows a customer paid against is not a decision this plan gets to make.

Read-only queries only. Do not deploy anything to production from this task.

- [ ] **Step 2: Write the deploy script**

Overwrite `sql/deploy/drop-installment-schedules.sql`:

```sql
-- ABOUTME: Drop the installment schedule tables from registry and every tenant schema.
-- ABOUTME: Nothing reads them: no workflow names the step class and the DAOs are gone.

-- Deploy registry:drop-installment-schedules to pg
-- requires: schedule-amounts-cents
-- requires: tenant-scoped-payments

BEGIN;

SET client_min_messages = 'warning';

-- scheduled_payments references payment_schedules, so it goes first.
DROP TABLE IF EXISTS registry.scheduled_payments;
DROP TABLE IF EXISTS registry.payment_schedules;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        EXECUTE format('DROP TABLE IF EXISTS %I.scheduled_payments', s);
        EXECUTE format('DROP TABLE IF EXISTS %I.payment_schedules', s);
    END LOOP;
END $$;

COMMIT;
```

- [ ] **Step 3: Write the revert script**

The revert must restore both tables exactly as they stand at the plan tip — that is, after `simplify-installment-schema-for-stripe` removed five columns and `schedule-amounts-cents` swapped three money columns for cents. Every column, index, constraint, trigger and comment must come back; the harness compares the multiset of `pg_dump` lines, so anything missing or differently typed fails. Column *order* is the one thing it does not grade (see Task 1's third note), but the declaration order below follows the deploy chain anyway — it is how you check the list is complete.

**Two things the tenant loop must get right.** `registry.tenants` is seeded with a row whose slug is `registry` (`sql/deploy/tenant-on-boarding.sql:23-28`), and `registry` is a real schema, so `CONTINUE WHEN to_regnamespace(...) IS NULL` does not skip it. Without a second guard the loop reaches `CREATE TABLE registry.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)` and the revert aborts with *relation already exists*. The in-repo answer is the `IF to_regclass(...) IS NULL THEN` guard that `sql/deploy/tenant-scoped-payments.sql:255,266` uses for these same two tables; it skips `registry` for free because the block above has already created them there. And `payment_schedules` gets no foreign keys on `enrollment_id` or `pricing_plan_id` — the original migration left them plain `UUID NOT NULL` (`tenant-scoped-payments.sql:260-262` says so explicitly). Only `scheduled_payments` needs its two FKs re-added, because `LIKE ... INCLUDING ALL` does not copy them.

Overwrite `sql/revert/drop-installment-schedules.sql`:

```sql
-- ABOUTME: Recreate the installment schedule tables as they stood at the plan tip.
-- ABOUTME: LOSSY -- structure only; rows dropped by the deploy cannot be recovered.

-- Revert registry:drop-installment-schedules from pg

-- LOSSY REVERT.  The deploy DROPs both tables, so their rows are gone.  This
-- script restores structure exactly -- every column, index, constraint, trigger
-- and comment, in registry and in every tenant schema -- and restores no data.
-- The deploy is gated on both tables being empty in production (see the plan's
-- Step 1a); if that gate was honoured there is nothing to recover.

BEGIN;

SET client_min_messages = 'warning';

CREATE TABLE registry.payment_schedules (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    enrollment_id UUID NOT NULL,
    pricing_plan_id UUID NOT NULL,
    stripe_subscription_id VARCHAR(255),
    installment_count INTEGER NOT NULL,
    status VARCHAR(20) DEFAULT 'active',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    total_amount_cents INTEGER NOT NULL DEFAULT 0,
    installment_amount_cents INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE registry.scheduled_payments (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    payment_schedule_id UUID NOT NULL
        REFERENCES registry.payment_schedules(id) ON DELETE CASCADE,
    payment_id UUID REFERENCES registry.payments(id),
    installment_number INTEGER NOT NULL,
    status VARCHAR(20) DEFAULT 'pending',
    paid_at TIMESTAMP WITH TIME ZONE,
    failed_at TIMESTAMP WITH TIME ZONE,
    failure_reason TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    amount_cents INTEGER NOT NULL DEFAULT 0
);

-- Named constraints, in the order the original chain created them, so that
-- pg_get_constraintdef output matches name for name.
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT payment_schedules_status_check
    CHECK (status IN ('active', 'completed', 'cancelled', 'suspended', 'past_due'));
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_count CHECK (installment_count > 1);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_installment_amount CHECK (installment_amount_cents > 0);
ALTER TABLE registry.payment_schedules
    ADD CONSTRAINT check_total_amount CHECK (total_amount_cents > 0);

ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT scheduled_payments_status_check
    CHECK (status IN ('pending', 'completed', 'failed', 'cancelled'));
ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_installment_number CHECK (installment_number > 0);
ALTER TABLE registry.scheduled_payments
    ADD CONSTRAINT check_scheduled_amount CHECK (amount_cents > 0);

CREATE INDEX idx_payment_schedules_enrollment
    ON registry.payment_schedules(enrollment_id);
CREATE INDEX idx_payment_schedules_pricing_plan
    ON registry.payment_schedules(pricing_plan_id);
CREATE INDEX idx_payment_schedules_stripe_subscription
    ON registry.payment_schedules(stripe_subscription_id);
CREATE INDEX idx_payment_schedules_status
    ON registry.payment_schedules(status);

CREATE INDEX idx_scheduled_payments_schedule
    ON registry.scheduled_payments(payment_schedule_id);
CREATE INDEX idx_scheduled_payments_payment
    ON registry.scheduled_payments(payment_id);
CREATE INDEX idx_scheduled_payments_status
    ON registry.scheduled_payments(status);

CREATE TRIGGER update_payment_schedules_updated_at
    BEFORE UPDATE ON registry.payment_schedules
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

CREATE TRIGGER update_scheduled_payments_updated_at
    BEFORE UPDATE ON registry.scheduled_payments
    FOR EACH ROW
    EXECUTE FUNCTION registry.update_updated_at_column();

COMMENT ON TABLE registry.payment_schedules
    IS 'Payment schedules managed via Stripe subscriptions';
COMMENT ON COLUMN registry.payment_schedules.stripe_subscription_id
    IS 'Stripe subscription ID - required for all schedules';
COMMENT ON TABLE registry.scheduled_payments
    IS 'Individual installment tracking - status updated via Stripe webhooks';

-- Tenant copies.  LIKE ... INCLUDING ALL copies indexes, defaults, checks and
-- comments but NOT foreign keys and NOT triggers, so both are re-added.
-- payment_schedules has no FKs to re-add: enrollment_id and pricing_plan_id
-- are plain UUID NOT NULL in the original migration.
--
-- The triggers fire a function in the TENANT's schema, not registry's.  A
-- clone_schema-provisioned tenant carries its own update_updated_at_column and
-- its triggers bind to that copy; %I.update_updated_at_column() reproduces it.
--
-- The to_regclass guards also skip the seeded 'registry' tenant, whose tables
-- the block above has already created.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        IF to_regclass(format('%I.payment_schedules', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)', s);
            EXECUTE format(
                'CREATE TRIGGER update_payment_schedules_updated_at
                    BEFORE UPDATE ON %I.payment_schedules
                    FOR EACH ROW EXECUTE FUNCTION %I.update_updated_at_column()',
                s, s);
        END IF;

        IF to_regclass(format('%I.scheduled_payments', s)) IS NULL THEN
            EXECUTE format(
                'CREATE TABLE %I.scheduled_payments (LIKE registry.scheduled_payments INCLUDING ALL)', s);
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_schedule_id_fkey
                    FOREIGN KEY (payment_schedule_id) REFERENCES %I.payment_schedules(id) ON DELETE CASCADE',
                s, s);
            EXECUTE format(
                'ALTER TABLE %I.scheduled_payments
                    ADD CONSTRAINT scheduled_payments_payment_id_fkey
                    FOREIGN KEY (payment_id) REFERENCES %I.payments(id)',
                s, s);
            EXECUTE format(
                'CREATE TRIGGER update_scheduled_payments_updated_at
                    BEFORE UPDATE ON %I.scheduled_payments
                    FOR EACH ROW EXECUTE FUNCTION %I.update_updated_at_column()',
                s, s);
        END IF;
    END LOOP;
END $$;

COMMIT;
```

**Where the two `CREATE TRIGGER` calls come from, and the one behaviour they change.** `tenant-scoped-payments.sql:255-283` builds the tenant copies with `LIKE ... INCLUDING ALL` and no triggers, so tenants that existed when *that* migration ran have none. But `clone_schema` — the path every tenant provisioned since has taken (`Tenant.pm:155`) — copies triggers in a separate loop (`sql/deploy/fix-clone-schema-identifier-quoting.sql:445-455`) after its own `LIKE ... INCLUDING ALL` at `:367`. Verified by provisioning a tenant against a fully deployed database and reading `pg_get_triggerdef`:

```
CREATE TRIGGER update_payment_schedules_updated_at BEFORE UPDATE ON probe_t.payment_schedules
    FOR EACH ROW EXECUTE FUNCTION probe_t.update_updated_at_column()
CREATE TRIGGER update_scheduled_payments_updated_at BEFORE UPDATE ON probe_t.scheduled_payments
    FOR EACH ROW EXECUTE FUNCTION probe_t.update_updated_at_column()
```

Note the function is `probe_t.update_updated_at_column`, not `registry.`'s — hence `%I.update_updated_at_column()` above. The same run confirms `clone_schema` copies the two FKs under exactly the names re-added here (`scheduled_payments_payment_id_fkey` with no `ON DELETE`, `scheduled_payments_payment_schedule_id_fkey` with `ON DELETE CASCADE`), so those lines are already right.

Without the trigger statements, Task 1's harness fails on its cloned tenant: the pre-drop dump has two trigger lines the reverted dump does not. **Deliberate consequence:** on the older, pre-`tenant-scoped-payments` tenants that never had these triggers, this revert *adds* them. That is the lesser evil — it matches `registry` and matches every tenant provisioned since — and it is recorded here so it is not mistaken for an oversight.

- [ ] **Step 4: Write the verify script**

Overwrite `sql/verify/drop-installment-schedules.sql`:

```sql
-- ABOUTME: Verify the installment schedule tables are absent from every schema.
-- ABOUTME: A surviving copy in one tenant schema is the failure this catches.

-- Verify registry:drop-installment-schedules on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    IF to_regclass('registry.payment_schedules') IS NOT NULL THEN
        RAISE EXCEPTION 'registry.payment_schedules still exists';
    END IF;
    IF to_regclass('registry.scheduled_payments') IS NOT NULL THEN
        RAISE EXCEPTION 'registry.scheduled_payments still exists';
    END IF;

    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;
        IF to_regclass(format('%I.payment_schedules', s)) IS NOT NULL THEN
            RAISE EXCEPTION 'tenant schema %.payment_schedules still exists', s;
        END IF;
        IF to_regclass(format('%I.scheduled_payments', s)) IS NOT NULL THEN
            RAISE EXCEPTION 'tenant schema %.scheduled_payments still exists', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
```

- [ ] **Step 5: Supersede `sql/verify/installment-payment-schedules.sql`**

Replace the entire file with:

```sql
-- ABOUTME: Superseded verify for the original installment schedule tables.
-- ABOUTME: Those tables are dropped by drop-installment-schedules; this asserts nothing.

-- Verify registry:installment-payment-schedules on pg

BEGIN;

-- Every object this change created is dropped by drop-installment-schedules,
-- whose verify asserts their absence.  Asserting anything here would have to be
-- true both at this point in the plan, where the tables exist, and at the end,
-- where they do not -- and nothing about these tables is true at both points.

ROLLBACK;
```

- [ ] **Step 6: Supersede `sql/verify/simplify-installment-schema-for-stripe.sql`**

Replace the entire file with:

```sql
-- ABOUTME: Superseded verify for the installment schema reshape.
-- ABOUTME: Both reshaped tables are dropped by drop-installment-schedules.

-- Verify registry:simplify-installment-schema-for-stripe on pg

BEGIN;

-- This change only reshaped payment_schedules and scheduled_payments, both
-- dropped by drop-installment-schedules.  See that change's verify.

ROLLBACK;
```

- [ ] **Step 7: Supersede `sql/verify/schedule-amounts-cents.sql`**

Replace the entire file with:

```sql
-- ABOUTME: Superseded verify for the installment schedule cents conversion.
-- ABOUTME: The tables it checked are dropped by drop-installment-schedules.

-- Verify registry:schedule-amounts-cents on pg

BEGIN;

-- Both converted tables are dropped by drop-installment-schedules, whose
-- verify asserts their absence.  The sibling conversions for payments and
-- pricing_plans keep their own verify scripts.

ROLLBACK;
```

- [ ] **Step 8: Narrow `sql/verify/tenant-scoped-payments.sql`**

This one is partial. At `:26`, replace:

```sql
        FOREACH tbl IN ARRAY ARRAY['payments','payment_items','payment_schedules','scheduled_payments'] LOOP
```

with:

```sql
        FOREACH tbl IN ARRAY ARRAY['payments','payment_items'] LOOP
```

Leave everything else — the FK-schema check (`:32-57`) and the leftover-registry-rows check (`:64-70`) are still true at both points.

- [ ] **Step 9: Rewrite `t/dao/tenant-payment-schema-isolation.t`**

It seeds both dropped tables and must change in this same commit. Five edits, **bottom-up**.

1. **`:93-223` — delete the entire migration-replay section.** This is the edit that is easy to get wrong, so here is why it is all-or-nothing. The section reads the `DO` block out of `sql/deploy/tenant-scoped-payments.sql` at `:107-114` and replays it against the live test database. Both subtests below it run that block: `'migration move-logic: rows land in tenant schema'` at `:150` and `'migration schedule-guard: ...'` at `:204,214`. The extracted block names `registry.scheduled_payments` (`tenant-scoped-payments.sql:150`) and does `CREATE TABLE %I.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)` (`:255-284`). Once this task drops those tables, **every** `$db->query($do_block)` raises *relation does not exist*. Deleting only the schedule-guard subtest leaves the move-logic subtest replaying the same block and the file fails hard — not "PASS with one fewer subtest".

   The cut runs from the `# ---- migration move-logic tests ---` banner at `:93` through `};` at `:222` and the blank at `:223`. `:92` is blank and `:224` is `# ---- behavioral block (#237 repro) ---`, which stays, as do the structural subtests above `:93` and everything from `:224` down.

2. **`:42-49` — narrow the table list.** In `subtest 'payment tables exist in tenant schema'`, at `:43` replace:

   ```perl
       for my $tbl (qw(payments payment_items payment_schedules scheduled_payments)) {
   ```

   with:

   ```perl
       for my $tbl (qw(payments payment_items)) {
   ```

3. **`:38-39` — fix the comment that names the dropped tables.** Replace:

   ```perl
   # clone_schema copies all registry tables (including payments/payment_items/
   # payment_schedules/scheduled_payments) at provisioning time.
   ```

   with:

   ```perl
   # clone_schema copies all registry tables (including payments and
   # payment_items) at provisioning time.
   ```

4. **`:11` — delete `use Mojo::Home;`.** Its only caller was `:107`, inside the deleted section.

5. **`:7` — drop the two now-unused imports.** Replace:

   ```perl
   use Test::More import => [qw(done_testing is ok subtest note like)];
   ```

   with:

   ```perl
   use Test::More import => [qw(done_testing is ok subtest)];
   ```

   `like` appeared only at `:207` and `note` only at `:217`, both inside the deleted section. Leave `is` — the FK assertions at `:75-76` still use it.

   Then rewrite the second ABOUTME at `:3`, which claims coverage the file no longer has:

   ```perl
   # ABOUTME: Structural invariant tests, migration move/guard logic, and the #237 behavioral repro.
   ```

   to:

   ```perl
   # ABOUTME: Structural invariant tests and the #237 behavioral repro.
   ```

**Coverage gap opened, deliberately — and it is wider than one subtest.** Deleting `:93-223` removes the only test of `tenant-scoped-payments`' row-move path *and* of its scheduled-payments pre-flight guard. The guard's subject is gone, so that half is dead weight; the row-move half is not. The move logic stays deployed and is now untested. It is named in the commit message and belongs in the issue backlog, not in this leg: re-testing it means rewriting the replay to skip the schedule branches, which is a different change from dropping the tables.

- [ ] **Step 10: Confirm no file outside the deployed migration chain names the tables**

Run:

```bash
grep -rln "payment_schedules\|scheduled_payments" sql/ lib/ t/ templates/ workflows/
```

Expected exactly: the three `sql/deploy/` scripts in the original chain, `sql/deploy/tenant-scoped-payments.sql`, the three `sql/revert/` scripts in the original chain, the three new `drop-installment-schedules` scripts, `sql/verify/simplify-installment-schema-for-stripe.sql`, and `sql/test-schema.sql` (regenerated next). **No `lib/`, no `t/`.**

`sql/verify/simplify-installment-schema-for-stripe.sql` is on the list because Step 6 leaves the table names in its explanatory comment, not in an assertion. That is the only `sql/verify/` match besides the new one; the other three superseded scripts (Steps 5, 7, 8) no longer name the tables at all. If a *fourth* verify script appears, or if that file matches on a line that is not a comment, the supersession is incomplete.

- [ ] **Step 11: Regenerate the test schema dump**

```bash
make test-schema
```

`sql/test-schema.sql` is a build product of `sql/deploy/*.sql` and `sql/sqitch.plan` (see the `Makefile` rule). Confirm the two tables are gone from it:

Run: `grep -c "payment_schedules" sql/test-schema.sql`
Expected: `0`.

- [ ] **Step 12: Run the migration tests, including the harness**

Run: `carton exec prove -lv t/database/`
Expected: PASS. `revert-round-trip.t` now grades `drop-installment-schedules` — because Step 1 appended it to `@CHANGES`; if that append was missed, this step passes and grades nothing.

What it catches: a missing column, a wrong type or default, a missing index, a constraint whose `pg_get_constraintdef` text differs, a missing trigger, a missing comment. Column *order* it does not — the comparison is over sorted lines. The tenant half is graded too: the harness provisions a `clone_schema` tenant before the first dump (Task 1 Step 1), so a tenant schema left without its copies, left without the two `updated_at` triggers, or given its copies twice all fail here rather than in production.

- [ ] **Step 13: Run the isolation test and the DAO suite**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/tenant-payment-schema-isolation.t`
Expected: PASS with **two** fewer subtests — both migration-replay subtests go, not just the schedule-guard one. The three structural subtests and the `#237` behavioural block at the end all still run.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/dao/ t/integration/`
Expected: PASS.

- [ ] **Step 14: Commit**

```bash
git add sql/ t/database/revert-round-trip.t t/dao/tenant-payment-schema-isolation.t
git commit -m "Drop the installment schedule tables

A deployed change is retired by a new change, so drop-installment-schedules
removes payment_schedules and scheduled_payments from registry and every tenant
schema rather than the old migrations being deleted. Both tables were empty in
production when this was written; the revert restores structure only and says
so at the top.

Four already-deployed verify scripts named those tables and three failed hard
without them. Each is stripped of the assertions that name a dropped object --
they have to stay true both at their own point in the plan and at the end, and
inverting them would fail the former. tenant-scoped-payments loses two array
elements and keeps the rest.

tenant-payment-schema-isolation.t replayed the tenant-scoped-payments DO block
against the live database, so both of its migration subtests died with the
tables. Opens a coverage gap: that migration's row-move path is now untested.

The change is added to revert-round-trip.t's list, so its revert is graded --
including the tenant half, against a clone_schema-provisioned schema."
```

- [ ] **Step 15: Close the two installment issues as won't-do**

Spec `:2803`: *"Close #295 and #279 as won't-do."* Both are installment issues, and this is the commit that finishes removing installments — the code went in Task 2, the tables here. Do it now rather than at the end of the leg, while the evidence is in the commit you just wrote.

A `Closes #295` keyword in the commit message would be wrong: GitHub closes as *completed*, and neither issue was completed. Close them explicitly with the reason:

```bash
gh issue close 295 --reason "not planned" \
  --comment "Installments are cut in the PriceOps alignment milestone (Leg 1). The code is deleted and payment_schedules/scheduled_payments are dropped by the drop-installment-schedules migration. Both tables were empty in production."
gh issue close 279 --reason "not planned" \
  --comment "Superseded by the PriceOps alignment milestone (Leg 1), which removes the installment machinery entirely rather than fixing it."
```

Read #279 before writing its comment — the wording above assumes it is an installment defect report, which is why the spec pairs it with #295. If it turns out to be something else, leave it open and report to perigrin rather than closing an issue this leg does not resolve.

---

### Task 7: Retire the seeded Registry Plus hybrid plan

**Files:**
- Create: `sql/deploy/retire-registry-plus-plan.sql`, `sql/revert/retire-registry-plus-plan.sql`, `sql/verify/retire-registry-plus-plan.sql`, `t/database/retire-registry-plus-plan.t`
- Modify: `sql/sqitch.plan` (append one line)
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: sqitch change `drop-installment-schedules` from Task 6 is the plan predecessor; the declared requirement is `suspend-rateless-tenant-plans`, whose metadata-stamp pattern this change copies.
- Produces: no active `pricing_relationships` row offers a *tenant-scoped* `hybrid` plan — the platform signup menu has no hybrid entry. Customer-scoped hybrid plans, which tenants author for their own programs, are out of scope here and are dealt with by Leg 4's component model. This change is not on Task 1's `@CHANGES`; it carries `t/database/retire-registry-plus-plan.t` instead.

**What is being retired:** `sql/deploy/unified-pricing-infrastructure.sql:128-140` seeds a plan named `'Registry Plus - $100/month + 1%'` (`:133`) with `plan_type` and `pricing_model_type` both `'hybrid'` — the column is `pricing_model_type` (`:21-22`), not `pricing_model` — `amount` `100.00`, and `pricing_configuration` (`:138`) `{"monthly_base": 100.00, "percentage": 0.01, "applies_to": "customer_payments"}`. Note `amount` is how the *seed migration* wrote it; by this point in the plan `pricing-plans-amount-cents` has replaced the column with `amount_cents` and the row reads `10000` (`sql/test-schema.sql:2388`). That row is `plan_scope = 'tenant'`; its single `pricing_relationships` row, `status = 'active'`, is at `:2408`. It is the only tenant-scoped hybrid row in the seed — the other two relationships (`:2407`, `:2409`) are Revenue Share and the already-suspended Standard. The design has no hybrid plan type; leaving an active offer means a tenant could select a plan nothing can price.

**Why `suspend-rateless-tenant-plans` did not already catch it:** that change keys on `COALESCE(p.pricing_configuration->>'percentage', CASE WHEN p.pricing_model_type = 'percentage' THEN p.amount::text END) IS NULL` (`:30-33`; its alias for `pricing_plans` is `p`, not `pp`). The hybrid plan's configuration carries `"percentage": 0.01`, so the `COALESCE` is non-NULL and the row survives. The premise holds and this change has work to do. (`p.amount` in that expression is a column `pricing-plans-amount-cents` later drops. The already-deployed script is unaffected — it ran before the drop — but do not copy that arm into a new script.)

**Pattern to copy:** `sql/deploy/suspend-rateless-tenant-plans.sql`. It stamps each row it touches so the revert can find exactly its own work:

```sql
UPDATE registry.pricing_relationships pr
   SET status     = 'suspended',
       metadata   = pr.metadata
                  || '{"suspended_by_migration": "suspend-rateless-tenant-plans"}'::jsonb,
       updated_at = CURRENT_TIMESTAMP
```

with a revert keyed on `WHERE metadata->>'suspended_by_migration' = 'suspend-rateless-tenant-plans'`.

Copy the shape, not the expression. `pricing_relationships.metadata` is nullable (`sql/deploy/consolidate-pricing-relationships.sql:10-20` gives it `DEFAULT '{}'` but no `NOT NULL`), and in Postgres `NULL || '{...}'::jsonb` is `NULL`. A row with explicit NULL metadata would be suspended and left unstamped, and the revert — which finds its work by the stamp — would leave it suspended forever. The version below wraps the left operand in `COALESCE(..., '{}'::jsonb)`. The deployed change has the same latent hole; it is not this leg's to fix, and it is on the issue list.

- [ ] **Step 1: Count production subscribers before writing anything**

This is a data change against production. Spec `:644` requires it explicitly: *"Re-run that count in the Leg 1 branch before merging"* — the fact that no tenant is on Plus was checked on 2026-08-09 and the signup funnel has been open since.

**The count the spec means is over `tenants.platform_pricing_plan_id`, not over `pricing_relationships`.** That column is the subscription (`sql/deploy/tenant-platform-pricing-plan.sql:10`, written by `TenantPayment.pm:429` and `Tenant.pm:144`). A `pricing_relationships` row for a tenant-scoped plan is a *menu entry*: `create-default-pricing-relationships.sql:69-71` inserts one per plan with `provider_id = platform_id` and `consumer_id = platform_admin_id`, so every such row belongs to the platform and to nobody else. Joining `tenants` on `provider_id` therefore returns `registry-platform` for every row no matter which tenants exist, and joining `users` on `consumer_id` returns the platform admin — neither answers "is a tenant paying for this".

Run this **read-only** against the Render production database `dpg-ckq1i8o5vl2c73d61070-a` (registry-db):

```sql
SELECT t.slug, t.name, pp.plan_name
  FROM registry.tenants t
  JOIN registry.pricing_plans pp ON pp.id = t.platform_pricing_plan_id
 WHERE pp.plan_type = 'hybrid';
```

Expected: zero rows. **Any row means a tenant is subscribed to Plus — stop and report to perigrin before continuing.** Suspending a plan someone is billed on is not a safe deletion, and Leg 1 would need a migration path this plan does not contain.

Then, for context on what the `UPDATE` will touch, list the menu rows:

```sql
SELECT pr.id, pr.status, pp.plan_name, pp.plan_scope
  FROM registry.pricing_relationships pr
  JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
 WHERE pp.plan_type = 'hybrid';
```

Expected: one `active` row, `plan_name = 'Registry Plus - $100/month + 1%'`, `plan_scope = 'tenant'`. A row with `plan_scope = 'customer'` is a tenant-authored plan and must **not** be suspended — see Step 3.

Read-only queries only. Do not deploy anything to production from this task.

- [ ] **Step 2: Add the change**

```bash
carton exec sqitch add retire-registry-plus-plan \
  --requires suspend-rateless-tenant-plans \
  -n 'Stop offering the seeded Registry Plus hybrid plan'
```

- [ ] **Step 3: Write the deploy script**

**`plan_type = 'hybrid'` alone is not a safe predicate — it must be paired with `plan_scope = 'tenant'`,** exactly as `suspend-rateless-tenant-plans.sql:29` pairs them. `plan_scope` defaults to `'customer'` (`sql/deploy/unified-pricing-infrastructure.sql:17-18`), and a tenant authoring a plan through the pricing workflow picks both fields: `lib/Registry/DAO/WorkflowSteps/PricingPlanBasics.pm:76-81` offers `hybrid` in the plan-type list and `:88-92` lets the same author set any `plan_scope`. So a customer-scoped hybrid plan is a thing a tenant can create in the product, today, and it is not what this change retires — the seeded Plus row is `plan_scope = 'tenant'` (`sql/deploy/unified-pricing-infrastructure.sql:128-140`). Without the guard this migration reaches into a tenant's own pricing and suspends it.

Overwrite `sql/deploy/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Stop offering the seeded Registry Plus hybrid plan.
-- ABOUTME: Nothing can price a hybrid plan, so an active offer is a plan that cannot bill.

-- Deploy registry:retire-registry-plus-plan to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

-- Scoped to tenant plans, matching suspend-rateless-tenant-plans:29.  plan_scope
-- defaults to 'customer' and a tenant can author a customer-scoped hybrid plan
-- through PricingPlanBasics; that is the tenant's pricing, not the platform's
-- signup menu, and this change has no business suspending it.
--
-- Stamp each row so the revert restores exactly what this change suspended and
-- leaves rows suspended for other reasons alone.  metadata is nullable, and
-- NULL || jsonb is NULL: without the COALESCE a row with no metadata would be
-- suspended without a stamp, and the revert would never find it again.
UPDATE registry.pricing_relationships pr
   SET status     = 'suspended',
       metadata   = COALESCE(pr.metadata, '{}'::jsonb)
                  || '{"suspended_by_migration": "retire-registry-plus-plan"}'::jsonb,
       updated_at = CURRENT_TIMESTAMP
  FROM registry.pricing_plans pp
 WHERE pp.id = pr.pricing_plan_id
   AND pp.plan_type = 'hybrid'
   AND pp.plan_scope = 'tenant'
   AND pr.status = 'active';

COMMIT;
```

- [ ] **Step 4: Write the revert script**

**The stamp is a handle, not a licence.** `metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'` says *this change is the one that suspended the row* — it does not say the row is still suspended. An operator who cancels a suspended relationship afterwards leaves the stamp in place, and an unconditional `SET status = 'active'` would resurrect it into the signup menu on the next revert. Add `AND status = 'suspended'`: revert what this change did, to rows still in the state it left them.

Overwrite `sql/revert/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Re-activate only the relationships this change suspended.
-- ABOUTME: The migration stamp is the handle; rows suspended for other reasons stay suspended.

-- Revert registry:retire-registry-plus-plan from pg

BEGIN;

SET client_min_messages = 'warning';

-- status = 'suspended' as well as the stamp: the stamp records who suspended the
-- row, not what state it is in now.  A row an operator has since cancelled must
-- stay cancelled rather than be resurrected as 'active'.
UPDATE registry.pricing_relationships
   SET status     = 'active',
       metadata   = metadata - 'suspended_by_migration',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
   AND status = 'suspended';

COMMIT;
```

`suspended_by_migration` is a single key shared with `suspend-rateless-tenant-plans` (`sql/deploy/suspend-rateless-tenant-plans.sql:24`), so the deploy's `||` overwrites any stamp already there. That cannot happen along any sqitch path — the earlier change only stamps rows it also sets to `'suspended'`, and this deploy touches `status = 'active'` rows only — so no guard is added for it. It becomes reachable if an operator re-activates a `suspend-rateless-tenant-plans` row by hand and leaves the stamp behind; the shared key name is on the issue list with that migration's `NULL || jsonb` hole.

- [ ] **Step 5: Write the verify script**

Two things this verify has to survive, and neither is optional.

**It must carry the same `plan_scope = 'tenant'` guard as the deploy.** A verify runs twice: once at its own point in the plan, and again against the finished schema, because `t/database/migration-verification.t:26` runs a bare `sqitch verify`. An unguarded predicate is therefore not merely imprecise — it is a standing assertion that no tenant anywhere has an active customer-scoped hybrid plan, forever. The first tenant to author one through `PricingPlanBasics.pm:76-92` turns CI red and there is no code change that fixes it short of editing this file.

**It must not strand at Leg 9b.** Spec `:3852-3859` enumerates nine verify scripts that read `pricing_relationships`, `plan_scope` or `plan_type` and are all superseded when Leg 9b drops them; `:3861` puts the total at sixteen files. A verify written here that reads all three joins that list as a tenth. Wrap the body in `IF to_regclass('registry.pricing_relationships') IS NOT NULL THEN` — the same guard shape Task 6 uses — and it goes vacuous rather than red when the table is gone, which is what the ABOUTME already claims.

Overwrite `sql/verify/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Verify no active pricing relationship offers a tenant-scoped hybrid plan.
-- ABOUTME: True at this point in the plan and at the end of it, including after Leg 9b.

-- Verify registry:retire-registry-plus-plan on pg

BEGIN;

DO $$
BEGIN
    -- Leg 9b drops pricing_relationships.  Every verify runs again against the
    -- final schema (t/database/migration-verification.t:26), so this one goes
    -- vacuous instead of erroring on a missing table.
    IF to_regclass('registry.pricing_relationships') IS NULL THEN
        RETURN;
    END IF;

    -- plan_scope = 'tenant' matches the deploy.  Unguarded, this asserts that no
    -- tenant ever authors a customer-scoped hybrid plan -- an assertion a tenant
    -- can falsify from the product, turning CI permanently red.
    IF EXISTS (
        SELECT 1
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
         WHERE pp.plan_type  = 'hybrid'
           AND pp.plan_scope = 'tenant'
           AND pr.status     = 'active'
    ) THEN
        RAISE EXCEPTION 'a tenant-scoped hybrid pricing plan is still offered by an active relationship';
    END IF;
END $$;

ROLLBACK;
```

- [ ] **Step 6: Write the data round-trip test**

**Do not append `retire-registry-plus-plan` to Task 1's `@CHANGES`.** That harness diffs `pg_dump --schema-only`, and this change touches no schema — both dumps would match no matter what the deploy did, including if it did nothing at all. Adding it would buy a green assertion that cannot fail, which is the exact shape of #296 that this leg exists to delete. The change gets a real test instead, and Task 1's list stays honest about what a schema diff can grade.

The test does three jobs: it proves the deploy suspends the seeded tenant-scoped offer, proves it does **not** touch a customer-scoped hybrid plan (the guard added in Step 3, which is otherwise untested and would rot), and proves the revert restores exactly the rows the deploy touched — by id, not by count. Counts matching does not mean the same rows came back.

Two details in the fixture that will bite if guessed. `pricing_plans` has no `amount` column at this point in the plan — `pricing-plans-amount-cents` replaced it with `amount_cents integer DEFAULT 0 NOT NULL` (`sql/test-schema.sql:1215`), so the insert can omit it entirely; the only `NOT NULL` without a default is `plan_name` (`:1204`). And `pricing_relationships` needs a `provider_id` and `consumer_id` that satisfy FKs to `tenants` and `users` (`sql/deploy/consolidate-pricing-relationships.sql:12-13`), so the fixture copies them off an existing seeded row rather than inventing users.

Create `t/database/retire-registry-plus-plan.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: The hybrid-plan retirement is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it suspends the seeded tenant offer, spares customer plans, and reverts by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

# Deploy up to this change's parent so a fixture can be planted before it runs.
# 'NAME^' is sqitch's one-before offset.  Naming the change under test rather
# than whichever change happens to precede it keeps this correct when a later
# leg appends to the plan.
$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan^' );

my $db = Mojo::Pg->new($uri)->db;

# A customer-scoped hybrid plan is something a tenant can author through
# PricingPlanBasics.  The migration must leave it alone.
my $customer_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type)
      VALUES ('Tenant-authored hybrid', 'hybrid', 'hybrid')
      RETURNING id}
)->hash->{id};

my $customer_rel_id = $db->query(
    q{INSERT INTO registry.pricing_relationships
          (provider_id, consumer_id, pricing_plan_id, status)
      SELECT provider_id, consumer_id, ?, 'active'
        FROM registry.pricing_relationships
       ORDER BY id
       LIMIT 1
      RETURNING id}, $customer_plan_id
)->hash->{id};

sub active_hybrid_ids ($scope) {
    return $db->query(
        q{SELECT pr.id FROM registry.pricing_relationships pr
            JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
           WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = ? AND pr.status = 'active'
           ORDER BY pr.id}, $scope
    )->arrays->flatten->to_array;
}

sub stamped_ids {
    return $db->query(
        q{SELECT id FROM registry.pricing_relationships
           WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
           ORDER BY id}
    )->arrays->flatten->to_array;
}

my $before = active_hybrid_ids('tenant');
ok scalar @$before, 'the seed offers a tenant-scoped hybrid plan before the change runs';

$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' );

is_deeply active_hybrid_ids('tenant'), [],
    'no active relationship offers a tenant-scoped hybrid plan';
is_deeply stamped_ids(), $before,
    'the change stamped exactly the rows it suspended';
is_deeply active_hybrid_ids('customer'), [$customer_rel_id],
    'a tenant-authored customer-scoped hybrid plan is left active';

$sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'retire-registry-plus-plan^', '-y' );

is_deeply active_hybrid_ids('tenant'), $before,
    'reverting re-activates exactly the rows the change suspended';
is_deeply stamped_ids(), [],
    'reverting removes the migration stamp';

done_testing;
```

- [ ] **Step 7: Run the new test and watch the first assertion**

Run: `carton exec prove -lv t/database/retire-registry-plus-plan.t`
Expected: PASS, six assertions. **The load-bearing one is the first**: if `@$before` is empty the test fails at "the seed offers a tenant-scoped hybrid plan before the change runs", and that is the intended behaviour — a migration that suspends nothing means the seed data changed and this plan's premise needs rechecking. Every later assertion would pass vacuously against an empty set, which is why the precondition is asserted rather than assumed.

- [ ] **Step 8: Regenerate the test schema dump**

```bash
make test-schema
```

The seeded relationship rows live in the dump. Before the change there are three (`sql/test-schema.sql:2407-2409`): Revenue Share `active`, Plus `active`, and Standard already `suspended` and stamped `suspend-rateless-tenant-plans`. Confirm the Plus row has joined it:

Run: `grep -c "retire-registry-plus-plan" sql/test-schema.sql`
Expected: at least `2` — one in the `pricing_relationships` data for the Plus row, one in the `sqitch.changes` data for the change itself. Grepping for the bare key `suspended_by_migration` instead is ambiguous: the Standard row already carries it.

- [ ] **Step 9: Run the database suite**

Run: `carton exec prove -lv t/database/`
Expected: PASS. `revert-round-trip.t` is unchanged and does not grade this change — Step 6 says why. `migration-verification.t` does exercise it, twice: once deploying the full plan, and once running `sqitch verify` against the finished schema (`:26`), which is the run that would catch an over-broad predicate in Step 5's verify.

- [ ] **Step 10: Run the full suite**

This is the end of Leg 1, so the whole tree gets checked once. Takes roughly 76 minutes.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/`
Expected: 100% pass, pristine output.

Known pre-existing pristine-output violations that are **not** this leg's to fix (do not silence them, and do not let them be mistaken for regressions): the `MOJO_SECRET not set` warning, an SMTP failure diagnostic, and an uninitialized-value warning from `lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm:71`.

- [ ] **Step 11: Commit**

```bash
git add sql/ t/database/retire-registry-plus-plan.t
git commit -m "Retire the seeded Registry Plus hybrid plan

Nothing prices a hybrid plan, so an active relationship offering one is a plan
a tenant can select and Registry cannot bill. The change stamps every row it
suspends so the revert restores exactly its own work and leaves rows suspended
by suspend-rateless-tenant-plans alone.

Scoped to plan_scope = 'tenant', matching suspend-rateless-tenant-plans. A
tenant can author a customer-scoped hybrid plan through PricingPlanBasics;
that is the tenant's own pricing, not the platform signup menu. The verify
carries the same guard, because every verify runs again against the finished
schema and an unguarded one would go red the first time a tenant did that.

The schema revert harness diffs pg_dump --schema-only and is blind to a
data-only change, so this one is deliberately kept off its list and carries
its own round-trip test -- which compares row ids, not counts, and asserts the
customer-scoped fixture is untouched."
```

---

## Task Dependency Order

Strictly sequential. Each arrow is a real dependency, not a preference.

```
1 (harness) → 2 (installment code) → 6 (installment tables) → 7 (plan retirement)
                    └───────────→ 3 (Stripe client, PriceOps plan) → 4 (discount surface, #296)

                    5 (seti_test bypass) — independent of everything above
```

- Task 1 before Task 6: the migration must land under a harness that already exists and is already proven able to fail.
- Task 2 before Task 6: code that reads a table is deleted before the table is dropped, so no commit leaves a tree that cannot run its own tests.
- Task 6 before Task 7: Task 7's change is appended after Task 6's in `sql/sqitch.plan`, and Task 6's Step 15 closes the installment issues that Task 7's commit would otherwise be mistaken for closing.
- Task 2 before Task 3: this one is real, not conventional. Task 3 Step 1's grep is the gate that says both modules are unreferenced, and until Task 2 lands they are both still referenced — `InstallmentPayment.pm:12,78,95,178` names `Registry::PriceOps::PricingPlan`, and `PriceOps/ScheduledPayment.pm:12,18` and `PriceOps/PaymentSchedule.pm:12,19` name `Registry::Client::Stripe`. Run Task 3 first and its own gate fails.
- Task 3 before Task 4: also real. Task 4 Step 6's grep is the gate that says no discount key survives without both a writer and a reader, and `lib/Registry/PriceOps/PricingPlan.pm:100,130` match its pattern until Task 3 Step 2 deletes that file. Run Task 4 first and the gate reports two matches that are not on its table, which reads as a miss.
- Task 5 touches files disjoint from every other task. Its position is convention, not necessity.

## Coverage Gaps This Leg Opens

Named here so they are found by reading, not by an incident.

1. **Webhook deduplication is untested** from Task 2 until Leg 0 restores it against the enrollment path. The subtest that covered it needed a payment schedule to exist.
2. **The `tenant-scoped-payments` schedule pre-flight guard is untested** from Task 6 onward. The guard remains deployed and correct; there is simply no longer a table whose rows could trip it. Nothing in the milestone re-creates one.
3. **The `tenant-scoped-payments` row-move path is untested** from Task 6 onward. Task 6 Step 9 deletes the whole migration-replay section of `t/dao/tenant-payment-schema-isolation.t` (`:93-223`) because both of its subtests re-run a `DO` block that names the dropped tables. That block also moved existing rows into the tenant schemas, and nothing else in the tree exercises it. The migration stays deployed; it is the only test of it that goes. This is on the issue list rather than being fixed here — restoring it means writing a fixture for a migration whose tables no longer exist.

## Self-Review

**Spec coverage.** Every item in the spec's Leg 1 row (`:2964`) maps to a task: installments → 2; `Client::Stripe` and `PriceOps/PricingPlan.pm` → 3; `Family::sibling_discount_eligible`, misfiled tests, #296, discount form → 4; `seti_test` signup bypass → 5; the Registry Plus retirement → 7; the sqitch change dropping both tables with its verify and revert, the four stranded verify scripts, and `t/dao/tenant-payment-schema-isolation.t` → 6; the revert-test harness → 1. Three items the spec's row does not name are covered anyway: the three `seti_test` test consumers (Task 5), `review-activate.html.ep:163-185` (Task 4), and the four early-bird/sibling assertions in `t/dao/pricing-plan-workflow.t:216-222,242` (Task 4).

**Placeholders.** None. Every code step carries the actual Perl or SQL. Every line range was read before being cited.

**Type consistency.** The sqitch change name `drop-installment-schedules` is used identically everywhere it appears: Task 6's creation, deploy header, revert header, verify header, `@CHANGES` append and commit. Task 7 does not name it at all — its test addresses the change under test as `retire-registry-plus-plan^`, so appending a change later cannot silently retarget it. `Test::Registry::DB::_find_pg_tool` is called with the same single-string signature the definition takes at `t/lib/Test/Registry/DB.pm:23`. The `suspended_by_migration` metadata key is spelled the same in Task 7's deploy, revert, verify and test, and matches the deployed `suspend-rateless-tenant-plans` (`:24`) it deliberately shares a namespace with.
