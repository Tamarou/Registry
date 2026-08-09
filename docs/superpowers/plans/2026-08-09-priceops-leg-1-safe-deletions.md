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
| `t/database/revert-round-trip.t` | Deploy → dump → revert tip → redeploy → dump → diff. Fails when a revert script does not restore the schema. |
| `sql/deploy/drop-installment-schedules.sql` | Drops `payment_schedules` and `scheduled_payments` from `registry` and every tenant schema. |
| `sql/revert/drop-installment-schedules.sql` | Recreates both tables exactly as they stand at the plan tip, in `registry` and every tenant schema. |
| `sql/verify/drop-installment-schedules.sql` | Asserts both tables are absent everywhere. |
| `sql/deploy/retire-registry-plus-plan.sql` | Suspends the seeded Registry Plus hybrid plan and its relationships. |
| `sql/revert/retire-registry-plus-plan.sql` | Un-suspends only the rows this change stamped. |
| `sql/verify/retire-registry-plus-plan.sql` | Asserts no active relationship offers the hybrid plan. |
| `t/database/retire-registry-plus-plan.t` | Asserts the data revert round-trips (the schema harness cannot see data changes). |

**Deleted:** 5 library modules, 2 more library modules, 10 test files (enumerated in Tasks 2-4).

**Modified:** `lib/Registry/Controller/Webhooks.pm`, `lib/Registry/DAO/Family.pm`, `lib/Registry/DAO/PricingPlan.pm` (comment only), `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm`, `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`, two `templates/pricing-plan-creation/` templates, `t/controller/payment-failures.t`, `t/dao/family.t`, `t/dao/pricing-plan-amount-cents.t`, `t/dao/pricing-plan-workflow.t`, `t/dao/tenant-payment-schema-isolation.t`, `t/controller/tenant-create-session.t`, two `t/user-journeys/alex/` files, `t/stripe-live/service-version.t` (comment only — never executed), `t/database/migration-verification.t`, `sql/sqitch.plan`, four `sql/verify/` scripts, `sql/test-schema.sql`.

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

**Interfaces:**
- Consumes: `Test::Registry::DB::_find_pg_tool($tool)` (`t/lib/Test/Registry/DB.pm:23-32`) — returns an executable path for `pg_dump`/`psql`, searching `$tool`, `/usr/bin/$tool`, and `/usr/lib/postgresql/{17,16,15,14}/bin/$tool`.
- Produces: nothing importable. Tasks 6 and 7 rely on this file existing and being run; adding a change to the tip of `sql/sqitch.plan` automatically puts that change under test.

**Why this is first:** every later leg ships migrations, and today nothing proves a revert script works. `t/database/migration-verification.t:46-49` currently reads:

```perl
subtest 'Verify migration rollback' => sub {
    # Skip complex rollback testing for now - focus on deploy/verify
    pass("Skipping rollback tests - focus on deploy and verify");
};
```

That is the #296 defect shape: a green assertion that asserts nothing. It is replaced by a pointer at the real harness.

**Scope note:** the harness compares `pg_dump --schema-only`. It grades **schema** round-trips. A data-only change (Task 7) is invisible to it and gets its own test.

**Three things about this harness are counter-intuitive. Each was established by running it, not by reasoning about it.**

1. **The direction is deploy-then-revert, not revert-then-redeploy.** The invariant worth testing is "the revert script undoes the deploy script", which is `schema(@HEAD^) == schema(deploy tip; revert tip)`. The obvious formulation — dump at `@HEAD`, revert, redeploy, dump again — tests the *opposite* implication, and for a change whose deploy is a `DROP` it is vacuous: both dumps have the tables absent no matter what the revert script contains. Task 6 ships exactly such a change, so the wrong direction would let a hand-written hundred-line revert script through ungraded.

2. **The offset is `@HEAD^`, not `@^`.** `App::Sqitch::Plan::ChangeList::_offset` (`local/lib/perl5/App/Sqitch/Plan/ChangeList.pm:31-38`) strips a trailing `^` only when it is **not** preceded by a punctuation character, and its `$punct` class at `:31` contains `@`. So in `@^` the caret is never recognised as an offset, the literal string `@^` is looked up as a change name, and nothing is found. In `@HEAD^` the caret follows `D` and resolves to `index_of('@HEAD') - 1`.

3. **The comparison is over sorted lines, not the raw dump.** `pg_dump` prints columns in `attnum` order, and a revert that re-adds a dropped column puts it at the end of the table rather than back in its original position — Postgres offers no way to place it. The tip's own revert does this today: `sql/revert/refund-amounts-cents.sql` restores `refund_amount_requested` and `refund_amount` after the columns that followed them, so a raw diff fails on the current tip before this leg changes anything. Sorting the filtered lines compares the *multiset* of schema statements: a missing or altered column, index, constraint, trigger or comment still fails; pure attnum drift does not. Verified: raw comparison fails on today's tip, sorted comparison passes.

Also note `pg_dump` 18 emits a random `\restrict <key>` / `\unrestrict <key>` pair per invocation. The token is not a comment, so a comment filter does not remove it and every run would differ. `--restrict-key` pins it.

- [ ] **Step 1: Write the harness**

Create `t/database/revert-round-trip.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: Proves the tip sqitch change reverts cleanly: deploy to its parent, dump, deploy it, revert it, dump, diff.
# ABOUTME: A revert script that fails to restore the schema fails here instead of in production.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use File::Temp qw(tempdir);
use Test::Registry::DB ();

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

my $pg_dump = Test::Registry::DB::_find_pg_tool('pg_dump');
my $dir     = tempdir( CLEANUP => 1 );

# The sqitch registry schema records deploy history, which legitimately differs
# between the two dumps.  --restrict-key pins the random \restrict token pg_dump
# 18 emits per invocation; it is not a comment, so the filter below misses it.
#
# The result is sorted: pg_dump prints columns in attnum order and a revert that
# re-adds a dropped column cannot put it back in its original position.  Sorting
# compares the multiset of schema statements, so a missing or altered column,
# index, constraint, trigger or comment still fails and attnum drift does not.
sub dump_schema ($label) {
    my $out = "$dir/$label.sql";
    system( "$pg_dump --schema-only --no-owner --no-privileges --restrict-key=rt"
          . " --exclude-schema=sqitch '$uri' > '$out'" ) == 0
        or die "pg_dump failed for $label";
    open my $fh, '<', $out or die "open $out: $!";
    # Drop comment lines and blanks: pg_dump emits version banners that vary.
    return [ sort grep { !/^--/ && /\S/ } <$fh> ];
}

my $sqitch = App::Sqitch->new();

# '@HEAD^' and not '@^': ChangeList::_offset refuses a caret preceded by
# punctuation, and its punctuation class contains '@'.
$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', '@HEAD^' );
my $before = dump_schema('before');
ok scalar @$before, 'schema dumped at the change before the tip';

$sqitch->run( 'sqitch', 'deploy', '-t', $uri );
$sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', '@HEAD^', '-y' );
my $after = dump_schema('after');

is_deeply $after, $before,
    'deploying the tip change and reverting it restores the schema exactly';

done_testing;
```

`is_deeply` rather than `is`: on failure it names the first differing element instead of printing six hundred lines of schema twice.

- [ ] **Step 2: Run it and confirm it passes on the current tip**

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: PASS. The tip is `refund-amounts-cents`. Takes roughly two minutes — it deploys the plan twice over.

- [ ] **Step 3: Prove the harness can fail (the genuine red step)**

A passing harness that cannot fail is worth nothing. Temporarily append a canary to the tip's revert script:

```bash
echo "ALTER TABLE registry.payments ADD COLUMN revert_harness_canary integer;" \
  >> sql/revert/refund-amounts-cents.sql
```

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: FAIL — "deploying the tip change and reverting it restores the schema exactly" fails, because the reverted schema carries a `revert_harness_canary` line the pre-tip schema does not.

- [ ] **Step 4: Restore the revert script**

```bash
git checkout sql/revert/refund-amounts-cents.sql
```

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: PASS.

- [ ] **Step 5: Replace the fake rollback subtest**

In `t/database/migration-verification.t`, replace lines 46-49 (line 44 is the preceding for-loop's closing brace and line 45 closes the subtest that contains it — replacing 44-47 leaves the file syntactically broken):

```perl
subtest 'Verify migration rollback' => sub {
    # Skip complex rollback testing for now - focus on deploy/verify
    pass("Skipping rollback tests - focus on deploy and verify");
};
```

with:

```perl
# Rollback is graded by t/database/revert-round-trip.t, which deploys the whole
# plan, reverts the tip, redeploys, and diffs the schema dumps.  Asserting it
# again here would only duplicate a ninety-second deploy.
```

- [ ] **Step 6: Run both database tests**

Run: `carton exec prove -lv t/database/`
Expected: PASS, and `migration-verification.t` now reports one fewer subtest.

- [ ] **Step 7: Commit**

```bash
git add t/database/revert-round-trip.t t/database/migration-verification.t
git commit -m "Add a revert-test harness and retire the rollback subtest that skipped

The rollback subtest passed by calling pass(). The new harness deploys the
whole plan to an ephemeral database, reverts the tip change, redeploys, and
diffs the schema dumps -- so every change that lands at the tip is graded on
its way in."
```

---

### Task 2: Delete the installment machinery

**Files:**
- Delete: `lib/Registry/DAO/PaymentSchedule.pm`, `lib/Registry/DAO/ScheduledPayment.pm`, `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm`, `lib/Registry/PriceOps/PaymentSchedule.pm`, `lib/Registry/PriceOps/ScheduledPayment.pm`
- Delete: `t/controller/admin-installment-payment-dashboard.t`, `t/controller/installment-payment-webhooks.t`, `t/controller/subscription-webhook-routing.t`, `t/dao/payment-schedule-race-condition.t`, `t/dao/payment-schedule.t`, `t/dao/scheduled-payment.t`, `t/e2e/installment-payment-enrollment.t`, `t/integration/installment-webhook-processing.t`, `t/unit/installment-breakdown.t`
- Modify: `lib/Registry/Controller/Webhooks.pm:8,69-71,204-289`
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

Then replace the dispatch at `:69-71`:

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

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-failures.t t/controller/webhooks.t`
Expected: PASS, pristine.

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
its refund subtest; the other three needed a payment schedule to exist.

Opens a coverage gap: webhook deduplication is now untested until Leg 0
restores it against the enrollment path."
```

**Coverage gap opened, deliberately:** deleting the duplicate-webhook subtest leaves webhook deduplication untested. Leg 0 restores it against the enrollment path. This is named in the commit message so it cannot be discovered later as a surprise.

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

**What goes with it:** `calculate_plan_price` (`PriceOps/PricingPlan.pm:87-118`) is the only code in the tree that scales a `sibling_discount` from dollars to cents (`:112`), and this subtest is its only test. Both disappear together. That is not a coverage gap — Task 4 deletes the rest of the sibling-discount surface for the same reason, that nothing reaches it. `Registry::DAO::PricingPlan::calculate_price` (`:136-147`) handles `percentage_discount` only and is unaffected.

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
- Modify: `lib/Registry/DAO/Family.pm:68` (delete `sibling_discount_eligible`)
- Modify: `t/dao/family.t:219-251`
- Modify: `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm:11,45-94`
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

In `lib/Registry/DAO/Family.pm`, delete the whole sub beginning at `:68`:

```perl
sub sibling_discount_eligible ($class, $db, $family_id, $session_id) {
```

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
grep -rn "early_bird_\|family_discount_\|min_children\|volume_discount_enabled\|volume_tiers" lib/ t/ templates/ workflows/
```

Expected: **matches remain, and every one must be on this list.** The nine keys this task removes are the ones the orphaned *form* wrote. `early_bird_cutoff_date` and `min_children` are also read by two surviving `PricingPlan` methods that key on `plan_type`, not on the form:

| Survivor | Why it stays |
|---|---|
| `lib/Registry/DAO/PricingPlan.pm:154,155,170,172,183,186` | `requirements_met` and `is_early_bird_available`. Both are live readers reached through `plan_type eq 'early_bird'` / `'family'`, which the enhanced-pricing-model migration backfills. Out of scope for Leg 1. |
| `t/dao/pricing-plans.t:66-92,137-206` | tests those two methods. |
| `t/dao/tenant-summer-camp.t:172` | a fixture for the same `plan_type` path. |
| `t/e2e/admin-program-management.t:138,148` | `pricing => { early_bird => ... }`, a fixture key of its own, unrelated to the form. |

Anything **not** on that list is a miss — in particular any match under `templates/`, under `workflows/`, or in `RequirementsRules.pm`, all of which must be gone.

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
- Modify: `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:41-46,294-306,373`
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

In `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`, delete `:41-46`:

```perl
        # Handle payment method collection with setup intent (testing scenario)
        if ($form_data->{collect_payment_method} && $form_data->{setup_intent_id}) {
            # Special case for testing: if we have both flags, go directly to completion
            if ($form_data->{setup_intent_id} =~ /^seti_test/) {
                return $self->handle_setup_completion($db, $run, $form_data);
            }
        }
```

- [ ] **Step 4: Delete the bypass in `handle_setup_completion`**

Delete `:294-306`:

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
- Modify: `t/dao/tenant-payment-schema-isolation.t:39-40,43,170-223`
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
-- ABOUTME: Column order matches the deploy chain so a schema dump round-trips exactly.

-- Revert registry:drop-installment-schedules from pg

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

-- Tenant copies, rebuilt the same way tenant-scoped-payments builds them:
-- LIKE ... INCLUDING ALL copies indexes, defaults, checks and comments but not
-- foreign keys, so scheduled_payments' two FKs are re-added explicitly.
-- payment_schedules has no FKs to re-add: enrollment_id and pricing_plan_id
-- are plain UUID NOT NULL in the original migration.
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
        END IF;
    END LOOP;
END $$;

COMMIT;
```

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

It seeds both dropped tables and must change in this same commit.

At `:43`, replace:

```perl
    for my $tbl (qw(payments payment_items payment_schedules scheduled_payments)) {
```

with:

```perl
    for my $tbl (qw(payments payment_items)) {
```

Delete the whole subtest at `:170-222`, `'migration schedule-guard: blocks move when scheduled_payments reference target'`. It inserts into `registry.payment_schedules` (`:185-191`) and `registry.scheduled_payments` (`:195-201`), asserts `like $guard_err, qr/pre-flight FAILED/` at `:206`, and then cleans up after itself at `:210-211` — so the subtest runs to `};` at `:222`, not `:206`. Stopping at `:206` would leave nineteen orphaned lines and an unbalanced brace. `:169` is the blank line after the preceding subtest and `:223` is blank, so take `:170-223`.

The guard it tested lives in `sql/deploy/tenant-scoped-payments.sql` and remains deployed; there is simply no longer a table to trip it.

Also fix the comment at `:39-40`, which names both dropped tables. Replace:

```perl
# clone_schema copies all registry tables (including payments/payment_items/
# payment_schedules/scheduled_payments) at provisioning time.
```

with:

```perl
# clone_schema copies all registry tables (including payments and
# payment_items) at provisioning time.
```

- [ ] **Step 10: Confirm no file outside the deployed migration chain names the tables**

Run:

```bash
grep -rln "payment_schedules\|scheduled_payments" sql/ lib/ t/ templates/ workflows/
```

Expected exactly: the three `sql/deploy/` scripts in the original chain, `sql/deploy/tenant-scoped-payments.sql`, the three `sql/revert/` scripts in the original chain, the three new `drop-installment-schedules` scripts, and `sql/test-schema.sql` (regenerated next). **No `lib/`, no `t/`, no `sql/verify/` apart from the new one.**

- [ ] **Step 11: Regenerate the test schema dump**

```bash
make test-schema
```

`sql/test-schema.sql` is a build product of `sql/deploy/*.sql` and `sql/sqitch.plan` (see the `Makefile` rule). Confirm the two tables are gone from it:

Run: `grep -c "payment_schedules" sql/test-schema.sql`
Expected: `0`.

- [ ] **Step 12: Run the migration tests, including the harness**

Run: `carton exec prove -lv t/database/`
Expected: PASS. `revert-round-trip.t` now grades `drop-installment-schedules`: a missing column, a wrong type or default, a missing index, a constraint whose `pg_get_constraintdef` text differs, a missing trigger or a missing comment all fail here. Column *order* does not — the comparison is over sorted lines. If a tenant schema is left without its copies, or the `registry` copies are created twice, this is also where it shows.

- [ ] **Step 13: Run the isolation test and the DAO suite**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/tenant-payment-schema-isolation.t`
Expected: PASS with one fewer subtest.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/dao/ t/integration/`
Expected: PASS.

- [ ] **Step 14: Commit**

```bash
git add sql/ t/dao/tenant-payment-schema-isolation.t
git commit -m "Drop the installment schedule tables

A deployed change is retired by a new change, so drop-installment-schedules
removes payment_schedules and scheduled_payments from registry and every tenant
schema rather than the old migrations being deleted.

Four already-deployed verify scripts named those tables and three failed hard
without them. Each is stripped of the assertions that name a dropped object --
they have to stay true both at their own point in the plan and at the end, and
inverting them would fail the former. tenant-scoped-payments loses two array
elements and keeps the rest.

tenant-payment-schema-isolation.t seeded both tables; its schedule-guard
subtest goes with them."
```

---

### Task 7: Retire the seeded Registry Plus hybrid plan

**Files:**
- Create: `sql/deploy/retire-registry-plus-plan.sql`, `sql/revert/retire-registry-plus-plan.sql`, `sql/verify/retire-registry-plus-plan.sql`, `t/database/retire-registry-plus-plan.t`
- Modify: `sql/sqitch.plan` (append one line)
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: sqitch change `drop-installment-schedules` from Task 6 is the plan predecessor; the declared requirement is `suspend-rateless-tenant-plans`, whose metadata-stamp pattern this change copies.
- Produces: no active `pricing_relationships` row offers a `hybrid` plan. Leg 4's component model has no hybrid case to support.

**What is being retired:** `sql/deploy/unified-pricing-infrastructure.sql:128-140` seeds a plan named `'Registry Plus - $100/month + 1%'` (`:133`) with `plan_type` and `pricing_model_type` both `'hybrid'` — the column is `pricing_model_type` (`:21-22`), not `pricing_model` — `amount` `100.00`, and `pricing_configuration` (`:138`) `{"monthly_base": 100.00, "percentage": 0.01, "applies_to": "customer_payments"}`. The plan row is at `sql/test-schema.sql:2388`; its single `pricing_relationships` row, `status = 'active'`, is at `:2408`. The design has no hybrid plan type; leaving an active offer means a tenant could select a plan nothing can price.

**Why `suspend-rateless-tenant-plans` did not already catch it:** that change keys on `COALESCE(pp.pricing_configuration->>'percentage', CASE WHEN pp.pricing_model_type = 'percentage' THEN pp.amount::text END) IS NULL`. The hybrid plan's configuration carries `"percentage": 0.01`, so the `COALESCE` is non-NULL and the row survives. The premise holds and this change has work to do.

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

This is a data change against production. Run a **read-only** query against the Render production database `dpg-ckq1i8o5vl2c73d61070-a` (registry-db):

```sql
SELECT pr.id, pr.status, t.slug AS provider_slug, u.username AS consumer
  FROM registry.pricing_relationships pr
  JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
  LEFT JOIN registry.tenants t ON t.id = pr.provider_id
  LEFT JOIN registry.users u   ON u.id = pr.consumer_id
 WHERE pp.plan_type = 'hybrid';
```

Join `provider_id` for the tenant, **not** `consumer_id`. `sql/deploy/consolidate-pricing-relationships.sql:10-20` declares `provider_id UUID NOT NULL REFERENCES registry.tenants(id)` and `consumer_id UUID NOT NULL REFERENCES registry.users(id)` — joining `tenants` on `consumer_id` matches nothing and returns `slug` NULL for every row, which reads as "no tenant is on this plan" no matter what is true.

Expected: zero rows with `status = 'active'` belonging to a real tenant. **If any tenant is actually on the plan, stop and report to perigrin before continuing** — suspending a plan someone is paying on is not a safe deletion.

- [ ] **Step 2: Add the change**

```bash
carton exec sqitch add retire-registry-plus-plan \
  --requires suspend-rateless-tenant-plans \
  -n 'Stop offering the seeded Registry Plus hybrid plan'
```

- [ ] **Step 3: Write the deploy script**

Overwrite `sql/deploy/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Stop offering the seeded Registry Plus hybrid plan.
-- ABOUTME: Nothing can price a hybrid plan, so an active offer is a plan that cannot bill.

-- Deploy registry:retire-registry-plus-plan to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

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
   AND pr.status = 'active';

COMMIT;
```

- [ ] **Step 4: Write the revert script**

Overwrite `sql/revert/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Re-activate only the relationships this change suspended.
-- ABOUTME: The migration stamp is the handle; rows suspended for other reasons stay suspended.

-- Revert registry:retire-registry-plus-plan from pg

BEGIN;

SET client_min_messages = 'warning';

UPDATE registry.pricing_relationships
   SET status     = 'active',
       metadata   = metadata - 'suspended_by_migration',
       updated_at = CURRENT_TIMESTAMP
 WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan';

COMMIT;
```

- [ ] **Step 5: Write the verify script**

Overwrite `sql/verify/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Verify no active pricing relationship offers a hybrid plan.
-- ABOUTME: True at this point in the plan and at the end of it.

-- Verify registry:retire-registry-plus-plan on pg

BEGIN;

DO $$
BEGIN
    IF EXISTS (
        SELECT 1
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
         WHERE pp.plan_type = 'hybrid'
           AND pr.status = 'active'
    ) THEN
        RAISE EXCEPTION 'a hybrid pricing plan is still offered by an active relationship';
    END IF;
END $$;

ROLLBACK;
```

- [ ] **Step 6: Write the data round-trip test**

`t/database/revert-round-trip.t` diffs `pg_dump --schema-only`, so it cannot see a data-only change. This change gets its own test rather than relying on a harness that is structurally blind to it.

Create `t/database/retire-registry-plus-plan.t`:

```perl
#!/usr/bin/env perl
# ABOUTME: The hybrid-plan retirement is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it suspends the seeded relationships and that reverting restores them.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' );

my $db = Mojo::Pg->new($uri)->db;

sub active_hybrid_count {
    return $db->query(
        q{SELECT count(*) FROM registry.pricing_relationships pr
            JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
           WHERE pp.plan_type = 'hybrid' AND pr.status = 'active'}
    )->array->[0];
}

sub stamped_count {
    return $db->query(
        q{SELECT count(*) FROM registry.pricing_relationships
           WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'}
    )->array->[0];
}

is active_hybrid_count(), 0, 'no active relationship offers a hybrid plan after deploy';
my $stamped = stamped_count();
ok $stamped > 0, "the change stamped $stamped relationship(s) as its own work";

$sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'drop-installment-schedules', '-y' );

is active_hybrid_count(), $stamped,
    'reverting re-activates exactly the relationships the change suspended';
is stamped_count(), 0, 'reverting removes the migration stamp';

done_testing;
```

- [ ] **Step 7: Run the new test and watch the assertion count**

Run: `carton exec prove -lv t/database/retire-registry-plus-plan.t`
Expected: PASS with `$stamped` greater than zero. **If `$stamped` is zero the test fails at "the change stamped ... as its own work"** — that is the intended behaviour: a migration that suspends nothing means the seed data changed and this plan's premise needs rechecking.

- [ ] **Step 8: Regenerate the test schema dump**

```bash
make test-schema
```

The seeded relationship rows live in the dump. Confirm they now carry the suspended status:

Run: `grep -n "suspended_by_migration" sql/test-schema.sql | head`
Expected: at least one match naming `retire-registry-plus-plan`.

- [ ] **Step 9: Run the database suite**

Run: `carton exec prove -lv t/database/`
Expected: PASS. `revert-round-trip.t` now reverts `retire-registry-plus-plan`; because the change is data-only, the schema dumps match trivially, and `retire-registry-plus-plan.t` is what actually grades it.

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

The schema revert harness diffs pg_dump --schema-only and is blind to a
data-only change, so this one carries its own round-trip test."
```

---

## Task Dependency Order

Strictly sequential. Each arrow is a real dependency, not a preference.

```
1 (harness) → 2 (installment code) → 6 (installment tables) → 7 (plan retirement)
                    └───────────→ 3 (Stripe client, PriceOps plan)

                    4 (discount surface, #296) ┐
                    5 (seti_test bypass)       ┘ independent of everything above
```

- Task 1 before Task 6: the migration must land under a harness that already exists and is already proven able to fail.
- Task 2 before Task 6: code that reads a table is deleted before the table is dropped, so no commit leaves a tree that cannot run its own tests.
- Task 6 before Task 7: Task 7's change is appended after Task 6's in `sql/sqitch.plan`, and its round-trip test reverts `--to drop-installment-schedules`.
- Task 2 before Task 3: this one is real, not conventional. Task 3 Step 1's grep is the gate that says both modules are unreferenced, and until Task 2 lands they are both still referenced — `InstallmentPayment.pm:12,78,95,178` names `Registry::PriceOps::PricingPlan`, and `PriceOps/ScheduledPayment.pm:12,18` and `PriceOps/PaymentSchedule.pm:12,19` name `Registry::Client::Stripe`. Run Task 3 first and its own gate fails.
- Tasks 4 and 5 touch files disjoint from every other task. They are ordered by convention, not necessity.

## Coverage Gaps This Leg Opens

Named here so they are found by reading, not by an incident.

1. **Webhook deduplication is untested** from Task 2 until Leg 0 restores it against the enrollment path. The subtest that covered it needed a payment schedule to exist.
2. **The `tenant-scoped-payments` schedule pre-flight guard is untested** from Task 6 onward. The guard remains deployed and correct; there is simply no longer a table whose rows could trip it. Nothing in the milestone re-creates one.

## Self-Review

**Spec coverage.** Every item in the spec's Leg 1 row (`:2964`) maps to a task: installments → 2; `Client::Stripe` and `PriceOps/PricingPlan.pm` → 3; `Family::sibling_discount_eligible`, misfiled tests, #296, discount form → 4; `seti_test` signup bypass → 5; the Registry Plus retirement → 7; the sqitch change dropping both tables with its verify and revert, the four stranded verify scripts, and `t/dao/tenant-payment-schema-isolation.t` → 6; the revert-test harness → 1. Three items the spec's row does not name are covered anyway: the three `seti_test` test consumers (Task 5), `review-activate.html.ep:163-185` (Task 4), and the four early-bird/sibling assertions in `t/dao/pricing-plan-workflow.t:216-222,242` (Task 4).

**Placeholders.** None. Every code step carries the actual Perl or SQL. Every line range was read before being cited.

**Type consistency.** The only cross-task interface is the sqitch change name `drop-installment-schedules`, used identically in Task 6 (creation, deploy header, revert header, verify header, commit) and Task 7 (`sqitch revert --to drop-installment-schedules`). `Test::Registry::DB::_find_pg_tool` is called with the same single-string signature the definition takes at `t/lib/Test/Registry/DB.pm:23`.
