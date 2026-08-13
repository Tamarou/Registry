# PriceOps Leg 1: Safe Deletions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Delete every piece of dead pricing machinery that no later leg needs, and ship the revert-test harness that every later leg's migration will be graded by.

**Architecture:** Leg 1 is the first leg of the PriceOps alignment milestone (spec: `docs/superpowers/specs/2026-08-07-priceops-alignment-design.md`, leg row at `:2964`). It has no dependencies and every other leg depends on it, because it shrinks the surface the rest of the milestone has to reason about and it builds the migration safety net. The work is seven commits in a fixed order: harness first, then Perl deletion, then the database drop, then the data retirement. Code that reads a table is deleted before the table is dropped, so no commit in the sequence leaves a broken tree.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, Minion, PostgreSQL, Sqitch, `Test::PostgreSQL`, `prove`.

**Editing rule, from round 10 of review onward:** only defects that change what an executing worker *does* are corrected here — line numbers and ranges, step ordering, code, SQL, commands, gate patterns and their match counts, `git add` file lists, and safety constraints. Inaccuracies in explanatory prose are recorded in `2026-08-09-priceops-leg-1-deferred-findings.md` and deliberately left in place. Nine rounds of review established that rewriting argument introduces new defects at roughly the rate it removes them; the executable content is what this document is for.

## Global Constraints

Copied from the spec. Every task's requirements implicitly include this section.

- **A deployed change is retired by a new change, not by deleting a file.** Never `git rm` a file under `sql/deploy/`, `sql/revert/`, or `sql/verify/` that is named in `sql/sqitch.plan`, and never edit a deployed change's deploy script.
- **A leg that deletes a module greps `t/` for its name, not just `lib/`.** A `use` in `t/` is as load-bearing as a `use` in `lib/`. The whole file is the blast radius, not the line.
- **A leg that drops a database object greps `sql/verify/` for its name in the same commit.**
- The live sqitch plan is **`sql/sqitch.plan`** (67 lines). The root `./sqitch.plan` (44 lines) is stale — do not touch it. `sqitch.conf` sets `top_dir = ./sql` and leaves `plan_file` commented out.
- `sqitch.conf` sets `[deploy] verify = true` and `[rebase] verify = true`. Each change's verify runs **at its own point in the plan**. `t/database/migration-verification.t:24-27` additionally runs `sqitch verify` with **no change argument**, re-running every verify script against the **final** schema. A superseded verify must therefore be **true at both points** — strip the assertions that name dropped objects so the script goes vacuous. **Never invert an assertion**; an inverted assertion fails at its own deploy point.
- **Every line range in this plan is a line number in the file as it stands at HEAD, before any of this plan's edits, unless the step says otherwise.** Two places say otherwise and both flag it: Task 5's Interfaces block gives post-edit numbers, and Task 5's note before Step 6 gives per-step offsets. **Apply multiple edits to one file bottom-up — highest line number first.** This holds whether the edits are inside one step or spread across steps of the same task. Top-down invalidates every range below the first cut, and the failure is not always loud: in this plan it produces a file that does not compile (Task 2, Steps 2→3), a file that compiles and passes with one test running under another test's name (Task 3, Step 3), an edit that silently does nothing (Task 4, Step 3), and two edits off by 8 and 22 lines (Task 5, Steps 3→5). All four were measured by executing the steps in written order. Each of those tasks now states its own order; this constraint governs anywhere one is not stated.
- Findings this plan defers rather than fixes are marked "on the issue list". They are not tracked in this document — they go to the GitHub tracker as issues against the PriceOps milestone, cross-referenced to the spec decision they came from, each citing the file:line that proves it. Filing them is its own work item, not a step in any task here.
- Test command is `carton exec prove -lr <dirs>`. Always `-lr`, **never `-r` alone**. Do not pass a bare `t/` — see the next constraint; there is no `.proverc` to exclude anything.
- Single file: `carton exec prove -lv t/path/to/file.t`.
- 100% pass rate, pristine output. No new warnings, no unexpected diagnostics.
- Object::Pad methods take no explicit `$self`. Use the `isa` operator, not `ref eq`.
- Every file starts with two `# ABOUTME: ` comment lines.
- **`grep` exits 1 when it finds nothing — including `grep -c`, which prints `0` and still exits 1.** Several steps here expect `0` from a `grep -c`; that is a *pass*, and it also returns a non-zero status. Under `set -e`, or in a chained command, it aborts. Append `|| true` if you wrap these, and read the printed number rather than the exit code.
- Comments are evergreen — no "recently changed", no "was previously".
- **Never run `t/stripe-live/`** (hits real Stripe) or **`t/playwright/`** (the ambient `STRIPE_PUBLISHABLE_KEY` is a `pk_live_` key and must never reach a browser). Editing those files is fine; executing them is not. **A bare `prove -lr t/` runs all five of their `.t` files** — four under `t/stripe-live/` and `t/playwright/setup_registration_test_data.t` — so every wide run in this plan names its directories instead. The `t/stripe-live/` four are self-protecting (`plan skip_all` without an `sk_test_` key) and the one playwright `.t` is inert (`Test::Registry::DB`, ephemeral Postgres, no browser, no Stripe, no network — verified), but the rule is absolute and the command must not depend on either fact.
- Local test invocation uses a placeholder that must **not** start with `sk_test_`:
  `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/...`
- Do not touch the dev database. All schema work happens in ephemeral `Test::PostgreSQL` instances.
- **Production is read-only in this leg, and two steps read it.** Task 6 Step 1a and Task 7 Step 1 run counts against the Render production database `dpg-ckq1i8o5vl2c73d61070-a` (registry-db). Go through the Render MCP tool — `mcp__render__query_render_postgres` with `postgresId: dpg-ckq1i8o5vl2c73d61070-a` — never `psql "$DATABASE_URL"` and never the ephemeral instance. This matters because **the wrong database returns the answer the step expects**: a dev or test database has no installment rows either, so `0` looks like confirmation. Task 6 Step 1a's count and Task 7 Step 1's menu query each select `current_database()`, and Task 7 Step 1 opens with a standalone identity probe because its first query expects zero rows — where a column would prove nothing. Keep that output; it is the evidence of which database answered. No task deploys anything to production.
- Full suite is ~76 minutes. Run it once, at the end (Task 7), not per-task.

## Declared Deviations From The Spec

Five places where this plan does something other than what the spec says. All five are deliberate.

1. **The `seti_test` replacement is an env guard, not a `t/lib/` move.** The spec says to "move what the tests need into `t/lib/`". That is unnecessary: `TenantPayment::process` already has an environment-guarded no-keys branch that produces a byte-identical result hash to the `seti_test` branch, and `t/controller/tenant-create-session.t` already passes through it today (verified: the payment template renders `<input type="hidden" name="setup_intent_id" value="">` at `templates/tenant-signup/payment.html.ep:91`, and `process_workflow` applies server-issued hidden values on top of caller data at `t/lib/Test/Registry/Helpers.pm:168`, so that test's `seti_test_123` never reaches the step). The replacement is therefore: delete both `seti_test` branches, add the one-line `BEGIN { delete @ENV{...} }` the codebase already uses, and drop the dead form keys. Smaller diff, same coverage, and it removes an unguarded production bypass rather than relocating it.

   One consequence to state rather than leave implicit: this makes the no-keys mock at `TenantPayment.pm:56-71` load-bearing. It was one of two paths to a fake subscription; after Task 5 it is the only one, and both alex journeys plus `t/controller/tenant-create-session.t` depend on it. **No leg in this milestone owns its removal** — the spec's Leg 1 row names only the `seti_test` bypass, and no later leg's row names the env-guarded branch. It is environment-guarded and so cannot fire in production, which is why keeping it is safe; but "a mock provisioning path with no owning leg" goes on the issue list rather than being discovered by whoever eventually wires real Stripe into tenant signup.

2. **Superseded verify scripts go vacuous, not corrected.** The spec says the old scripts are "edited to match the schema as of the end of the plan". Taken literally that means asserting the tables are absent, which **fails** at the script's own deploy point under `[deploy] verify = true`, where the tables are present. The correct edit is to remove every assertion naming a dropped object, leaving a comment that points at the retiring change. `sql/verify/drop-installment-schedules.sql` is where the absence gets asserted.

3. **`t/dao/pricing-plan-clean-architecture.t` is truncated, not deleted.** Spec `:2813` lists it under "Also deleted", and spec `:2869-2870` tells the Leg 9a implementer its `use Registry::DAO::PricingRelationship` at `:16` "needs no action: Leg 1 already deletes the file". Task 4 Step 1 keeps the file with its first subtest only. The reason is in that step and is not repeated here; what matters at this level is that **Leg 9a's stated premise is now false.** The file survives, so a Leg 9a worker looking for the sixth reader of `PricingRelationship` will find the file still on disk. The outcome is still safe — the truncated file's `use` list is `Test::More`, `Registry::DAO`, `Registry::DAO::PricingPlan` and nothing else, so there is no `PricingRelationship` reader left to fix — but Leg 9a must be told to re-check rather than trust the spec sentence.

   Leg 9a is not the only leg the survivor could reach. The retained subtest also asserted `plan_scope`, one of the three `pricing_plans` columns **Leg 9b** drops (spec `:3854-3855`), which would have handed Leg 9b a red assertion in a file this plan promises it need not touch. Task 4 Step 1 cuts that line too, so what survives depends on nothing any later leg removes. Both directions were checked against the truncated file's actual contents, not against its `use` list alone.

4. **The harness runs deploy-then-revert, the opposite of the direction the spec pins.** Spec `:3880-3881` says "deploy to the change, revert one, deploy again, compare the schema". That compares the schema *at* the change across a revert/redeploy cycle. Task 1 compares the schema at `change^` across a deploy/revert cycle instead. The argument is Task 1's first counter-intuitive note, and is load-bearing for Task 6: for a change whose deploy is a `DROP`, the spec's direction is vacuous. Named here because the spec sentence is pinned and a reader auditing plan-against-spec should not have to discover the difference in a task body.

5. **`@CHANGES` grades two already-deployed changes the spec never asked for.** Spec `:3455` requires a tested revert for every migration *this milestone adds*; `payments-amount-cents` (`sql/sqitch.plan:65`) and `refund-amounts-cents` (`:67`) were both deployed on 2026-08-06, well before it. Both are on the list anyway, as a scope decision perigrin has already made, because of the four already-deployed cents changes these are the two whose reverts are both broken and sitting on money tables this leg keeps — and Task 1 Steps 3 and 4 repair one revert each. These are the "two exceptions to never edit a deployed change" noted under File Structure. The Global Constraint itself is not relaxed: it governs a deployed change's **deploy** script, and revert scripts fall outside `script_hash` entirely. The full argument, including why the other two cents changes are *not* absorbed, is under Task 1's `@CHANGES` discussion. Named here so that plan-against-spec reads as a deliberate widening rather than as scope creep.

## Spec Gaps This Plan Closes

Four stranded callers the spec's Leg 1 row does not name, found by grep:

- **The `seti_test` test consumers.** `t/controller/tenant-create-session.t:66`, `t/user-journeys/alex/01-acquire-tenant.t:82-85,199-208,331-348`, `t/user-journeys/alex/03-platform-billing.t:77-78,164-172,214,216`. Exactly the shape the spec's own stranded-caller rule warns about.
- **`templates/pricing-plan-creation/review-activate.html.ep:163-186`** reads the seven discount keys the orphaned form writes. The spec names the form and the step class but not this reader.
- **`schemas/requirements-and-rules.json:76-100`** is the step's outcome definition — `workflows/pricing-plan-creation.yaml:27` binds it by name — and it declares a `discount_rules` group with three more discount fields. The spec names neither it nor the fact that outcome definitions are a second, independently-served description of every form.
- **`t/dao/pricing-plan-workflow.t:216-222,242`** posts the discount keys straight into `RequirementsRules->process` and asserts on what comes back. Deleting the step's discount blocks without touching this file leaves a failing assertion.

## File Structure

**Created:**

| Path | Responsibility |
|---|---|
| `t/database/revert-round-trip.t` | For each listed change: deploy to its parent → clone a tenant schema → dump → deploy the change → revert it → dump → diff. Fails when a revert script does not restore the schema. |
| `sql/deploy/drop-installment-schedules.sql` | Drops `payment_schedules` and `scheduled_payments` from `registry` and every tenant schema. |
| `sql/revert/drop-installment-schedules.sql` | Recreates both tables exactly as they stand at the plan tip, in `registry` and every tenant schema. |
| `sql/verify/drop-installment-schedules.sql` | Asserts both tables are absent everywhere. |
| `sql/deploy/retire-registry-plus-plan.sql` | Suspends the platform's active relationships that offer the seeded Registry Plus hybrid plan. The plan row itself is untouched — `pricing_plans` has no status column, which is why the revert is stamp-keyed. |
| `sql/revert/retire-registry-plus-plan.sql` | Un-suspends only the rows this change stamped. |
| `sql/verify/retire-registry-plus-plan.sql` | Asserts no active platform-offered relationship offers a tenant-scoped hybrid plan. |
| `t/database/retire-registry-plus-plan.t` | Asserts the data revert round-trips (the schema harness cannot see data changes). |

**Deleted:** 5 library modules, 2 more library modules, 9 test files — all nine in Task 2, named in its Files block and removed by the single `git rm` in its Step 1. (Self-references in this document are by task and step, not by line: a plan edits itself every round and its own line numbers do not survive that.) Tasks 3 and 4 delete no test file. `t/dao/pricing-plan-clean-architecture.t` is **truncated, not deleted**; it appears in the Modified list below and nowhere else.

**Modified:** `lib/Registry/Controller/Webhooks.pm`, `lib/Registry/DAO/Family.pm`, `lib/Registry/DAO/PricingPlan.pm` (comment only), `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm`, `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm`, two `templates/pricing-plan-creation/` templates, `schemas/requirements-and-rules.json`, `t/controller/payment-failures.t`, `t/dao/family.t`, `t/dao/pricing-plan-amount-cents.t`, `t/dao/pricing-plan-clean-architecture.t`, `t/dao/pricing-plan-workflow.t`, `t/dao/tenant-payment-schema-isolation.t`, `t/controller/tenant-create-session.t`, two `t/user-journeys/alex/` files, `t/stripe-live/service-version.t` (comment only — never executed), `t/database/migration-verification.t`, `docs/operations/sacp-stripe-connect-onboarding.md` (one table row, Task 6 Step 10), `sql/revert/payments-amount-cents.sql` and `sql/revert/refund-amounts-cents.sql` (the two bugs Task 1's harness finds), `sql/sqitch.plan`, four `sql/verify/` scripts, `sql/test-schema.sql`.

Note the two exceptions to "never edit a deployed change": `sql/revert/payments-amount-cents.sql` and `sql/revert/refund-amounts-cents.sql`. The Global Constraint forbids editing a deployed change's **deploy** script, and it stands. Revert scripts are outside `script_hash` (`App::Sqitch::Plan::Change.pm:164-169`), so editing one changes nothing about what is already deployed — see Task 1 Steps 3 and 4.

**Deliberately untouched:**

- `lib/Registry/DAO/PricingPlan.pm` keeps `installments_allowed` (`:19`), `installment_count` (`:20`), their validation (`:42-47`) and `installment_amount_cents` (`:199-201`). The columns survive Leg 1 — and, so far as the spec says, everything after it. **No leg owns their removal.** `grep -n 'installments_allowed\|installment_count\|installment_amount_cents'` over all 5312 lines of the spec returns nothing: Leg 9b's drop list is `plan_scope`/`plan_type`/`pricing_configuration` plus tables (spec `:3854-3855`), and the `pricing_plans` it drops is the **tenant-schema** copy only (spec `:2976`, `:361`) while Leg 4 *adds* columns to `registry.pricing_plans` (spec `:2969`), so that table outlives the milestone. `enhanced-pricing-model.sql:7` sets `search_path TO registry, public` and `:19-20` add these columns there; `:90-91` add the tenant copies, which do go with the tenant table. So the tenant copies have an owner and the `registry` ones plus these three DAO surfaces do not. On the issue list, same as the no-keys mock in Deviation 1.
- `lib/Registry/DAO/WorkflowSteps/PricingModel.pm:73-74` and `ReviewActivatePlan.pm:109-110,178-179` write those surviving columns. Leave them.
- `lib/Registry/DAO/WorkflowSteps/ResourceAllocation.pm:65,148` uses `installment_payments` as a resource-picker string. That is Leg 5's authoring rewrite.
- `.github/workflows/ci.yml:128`'s false comment about the stripe-e2e workflow belongs to Leg 3a, whose table row names it explicitly.

---

### Task 1: The revert-test harness

**Files:**
- Create: `t/database/revert-round-trip.t`
- Modify: `t/database/migration-verification.t:46-49`
- Modify: `sql/revert/payments-amount-cents.sql:11,16,31,38` — the harness fails on its first subject; see Step 3.
- Modify: `sql/revert/refund-amounts-cents.sql:43` — and on its second; see Step 4.

**Interfaces:**
- Consumes: `Test::Registry::DB::_find_pg_tool($tool)` (`t/lib/Test/Registry/DB.pm:23-33`) — returns an executable path for `pg_dump`/`psql`, searching `$tool`, `/usr/bin/$tool`, and `/usr/lib/postgresql/{17,16,15,14}/bin/$tool`.
- Produces: the `@CHANGES` list in `t/database/revert-round-trip.t`, which this task leaves holding two entries in this order:

  ```perl
  my @CHANGES = qw(
      payments-amount-cents
      refund-amounts-cents
  );
  ```

  **The list must stay ascending in `sql/sqitch.plan` order.** Each iteration deploys `--to "$change^"` and leaves the database sitting at that parent, so the next iteration's `--to` has to be a forward move. A descending list does not quietly grade the wrong thing — it is a **hard abort**: sqitch refuses with `Cannot deploy to an earlier change; use "revert" instead` and the file dies on the first out-of-order entry. That is the good failure mode, and it means a mis-ordered list is caught on the first CI run rather than living as a silent gap. `payments-amount-cents` is `sql/sqitch.plan:65` and `refund-amounts-cents` is `:67`, so appending is the natural operation and the order takes care of itself. Verified by running the two-entry list: iteration 2 printed `Deploying changes through schedule-amounts-cents`, a forward move.
- Produces: **Task 6 appends its change name** to that list in the same commit that adds the change to `sql/sqitch.plan`; that append is the whole registration mechanism. **Task 7 does not, and must not** — its change is data-only, so both `pg_dump --schema-only` dumps would match no matter what its deploy did. See Task 7 Step 6. Any future change that alters no schema object belongs off this list and needs its own data test.

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

**Both entries are already-deployed changes, and grading them is a scope decision perigrin has already made. It is Deviation 5.** The spec's requirement (`:3455`) is that every migration *this milestone adds* ships with a tested revert — it does not commission a retrospective audit of already-deployed reverts, and Leg 1's row does not list one. `payments-amount-cents` (`sql/sqitch.plan:65`) and `refund-amounts-cents` (`:67`) were both deployed on 2026-08-06, so both are outside the letter of the requirement and inside its intent: of the four already-deployed cents changes, these are the two whose reverts are both broken and sitting on money tables this leg keeps. Task 1 Steps 3 and 4 repair one revert each.

The four cents changes are not equivalent to each other, and the difference is what makes two of them worth absorbing and the other two not. All four sit consecutively at `sql/sqitch.plan:64-67`, so any of them is gradeable by adding its name:

| Change | What its revert restores | What the column was | Verdict |
| --- | --- | --- | --- |
| `pricing-plans-amount-cents` | `NOT NULL DEFAULT 0` (`:17,41`) — **then drops the default** (`:26,51`) | `amount DECIMAL(10,2) NOT NULL` (`unified-pricing-infrastructure.sql:23`) | round-trips clean; nothing to fix |
| `payments-amount-cents` | `NOT NULL DEFAULT 0` (`:11,16,31,38`), never dropped; and no index | bare `NOT NULL` (`payments.sql:10,33`), plus `idx_payments_amount` (`performance-optimization.sql:68`) | three defects, on money tables this leg **keeps** — **absorbed here** |
| `schedule-amounts-cents` | `NOT NULL DEFAULT 0` (`:11,12,26,44,45,63`), never dropped | bare `NOT NULL` (`installment-payment-schedules.sql:15,16,32`) | same defect, on tables **Task 6 drops** — issue list only |
| `refund-amounts-cents` | the `registry` comment (`:17-18`) but **not** the tenant loop's (`:31-54`) | `COMMENT ON COLUMN … refund_amount` (`drop-transfer-business-rules.sql:66`), which `clone_schema` copied into every tenant schema | one defect, on `enrollments` — a table this leg keeps — **absorbed here**, fixed by Task 1 Step 4 |

`pricing-plans-amount-cents` has no defect to find, and repairing `schedule-amounts-cents` would fix a revert script for `payment_schedules` and `scheduled_payments`, which Task 6 deletes at `sql/deploy/drop-installment-schedules.sql` — work with a lifetime of about four tasks. Both go on the issue list regardless.

**The `payments-amount-cents` revert has three defects, not the one that is visible by reading it.** The list below is what the harness actually reported; each was measured, not inferred.

1. **A default that outlives its purpose.** `ADD COLUMN ... NOT NULL` needs a value for the existing rows, so the script supplies `DEFAULT 0` — and then never removes it, on all four columns (`registry.payments`, `registry.payment_items`, and both tenant copies). `payments.sql:10,33` declared these bare `NOT NULL`. Post-revert, an `INSERT` that omits the amount books a zero payment instead of raising. The sibling `sql/revert/pricing-plans-amount-cents.sql:26,51` already carries the correct idiom — `ALTER TABLE ... ALTER COLUMN amount DROP DEFAULT` after the backfill — so the fix is to copy a pattern that exists three files over, not to invent one.

2. **A dropped index that is never rebuilt.** `performance-optimization.sql:68` created `idx_payments_amount ON registry.payments(amount)`. The deploy's `DROP COLUMN amount` (`sql/deploy/payments-amount-cents.sql:20`, and `:45` for tenants) took the index with it, and nothing creates an equivalent on `amount_cents`. The revert restores the column without the index, so the schema it claims to restore is short of one index per schema. **This one is not merely a revert defect — the index is missing from production right now**; `sql/test-schema.sql:3936-3957` shows the four surviving indexes on `registry.payments` and no `amount` among them. The revert fix here does not address production; that goes on the issue list.

3. **Column-order drift that the current comparison cannot absorb.** `amount` was declared mid-table (`payments.sql:10`, with `error_message` last at `:19`); Postgres cannot put a re-added column back in its original position, so it lands at the end and `error_message` acquires a trailing comma it did not have. The sorted comparison exists to tolerate exactly this drift and does not, because the comma is part of the line. `refund-amounts-cents` never exposed this: the columns its revert re-adds were appended by a later migration and were already last, so re-adding them at the end restores the original order. Step 1's `dump_schema` therefore normalizes the trailing comma away. Measured: with the first two defects repaired but the comma left in, the two dumps still disagreed on `error_message text`; with the comma normalized, the delta is zero.

**What it does not grade, stated up front so nobody reads a green tick as more than it is.** An adversarial pass injected nineteen defects into revert scripts and the harness caught fourteen, including every constraint, index, trigger, type, default, nullability and table-presence defect in both the `registry` schema and the cloned tenant schema. The nineteenth is worth naming because it is the one the slug choice buys: changing a `format('... %I ...', s)` to `%s` in `sql/revert/refund-amounts-cents.sql` is caught loudly — `ERROR: syntax error at or near "order"` — and is caught **only** because the fixture slug needs quoting. Under a slug like `rt_123_0` that mutation round-trips clean and the harness grades nothing about identifier quoting, in a codebase where `Tenant.pm:163-169` already carries a comment about `"user"` and `"order"` as tenant slugs. The five it misses fall into three kinds:

| Blind spot | Why | Bearing on this leg |
|---|---|---|
| Sequence / identity current value | `pg_dump --schema-only` emits the sequence definition but no `setval` — the position lives in the data section | None, for any of the three graded changes. `grep -n "SERIAL\|IDENTITY\|nextval" sql/deploy/installment-payment-schedules.sql sql/deploy/simplify-installment-schema-for-stripe.sql` returns nothing and Task 6's tables are UUID-keyed; the same grep over the deploy and revert of both absorbed changes — `payments-amount-cents` and `refund-amounts-cents` — also returns nothing. |
| `GRANT` / `REVOKE` | `--no-privileges` strips them, and it is there on purpose — role names differ between a `Test::PostgreSQL` instance and production, so leaving them in makes the dump machine-dependent | None. No migration in this milestone grants, and neither absorbed change does either — same grep, no `GRANT` or `REVOKE` in any of the four scripts. |
| An object relocated between two tables | The comparison is a sorted multiset of lines (see point 3 below), and `    x integer,` reads identically whichever `CREATE TABLE` it sits under | None, and the absorbed changes are immune for a second reason worth knowing. Task 6 drops and recreates whole tables and moves nothing between them. The two cents reverts do re-add columns, which is the shape that would exploit this hole — but each `ADD COLUMN` is paired with an `UPDATE %I.<table> SET amount = amount_cents…` against the same table, so a script that named the wrong table would fail at deploy time with `column amount_cents does not exist` rather than round-trip clean past a sorted diff. |

Sorting is what buys immunity to `attnum` drift, and relocation-blindness is the price. That trade is worth taking — drift is guaranteed and relocation is not in this milestone — but it is a real hole, and a later leg that moves a column between tables must not lean on this harness to grade it.

**Be precise about what a migration may print, because the obvious rule is not the true one.** `$sqitch->run` inherits the test's file handles and the test's stdout *is* the TAP stream, so it is tempting to say nothing may write to stdout at all. Two measurements say otherwise, and both matter to what the scripts below look like.

- **Only TAP-shaped stdout breaks the parse.** A psql-shaped result block on stdout — ` count `, `-------`, `     3`, `(1 row)` — parses clean; the same is true of sqitch's own `Adding registry tables to db:…`, which Step 2's transcript shows landing mid-subtest with no complaint. A line that reads `ok 1 - …` produces `Parse errors: Tests out of sequence.  Found (1) but expected (2)`. The hazard is a line that *looks* like TAP, not stdout as such. Measured with a two-subtest probe: the psql-shaped subtest passed, the TAP-shaped one raised the parse error.
- **`SET client_min_messages = 'warning'` is not what protects the parse.** `RAISE NOTICE` goes to **stderr**, never stdout. Measured: a script raising a notice sent ` answer / 42 / (1 row)` to stdout and `NOTICE:  A NOTICE LINE` to stderr. So the `SET` at the top of every deploy and revert script in this plan buys **stderr hygiene** — it keeps `NOTICE` chatter out of the run so the project's pristine-output rule holds — and buys nothing at all against TAP. It stays for that reason, which is a good enough one.

The operative rule for a migration is therefore: do not print a line that could be mistaken for TAP, and take a `RAISE NOTICE` added for debugging back out before commit because the output must be pristine, not because the parser would trip on it.

**Two requirements the spec pins, which drive the shape below.**

- **It runs against a schema built by `clone_schema`, not against `registry` alone** (spec `:872-874`: "a harness that only exercises `registry` cannot see this class of failure at all"). This is load-bearing for Task 6. A migration-only database has exactly two schemas — `sql/test-schema.sql:26` `CREATE SCHEMA registry;` and `:35` `CREATE SCHEMA sqitch;` — and `registry.tenants` holds two rows, `registry` and `registry-platform` (`sql/test-schema.sql:2513-2514`). `registry-platform` has no schema, so `to_regnamespace(...) IS NULL` skips it; `registry` is skipped by the `to_regclass` guards. Without a provisioned tenant the tenant half of Task 6's deploy *and* revert executes zero times and the harness grades none of it.
- **It grades every change this milestone adds, not just the tip** (spec `:3455`: "Every migration in this milestone ships with a revert that is tested by reverting it"). Pinning `@HEAD^` grades whichever change happens to be last. Task 7 appends a data-only change on top of Task 6, and a data-only change round-trips trivially under a schema dump — so a tip-only harness stops grading Task 6's hundred-line revert one commit after it is written.

**Three things about this harness are counter-intuitive. Each was established by running it, not by reasoning about it.**

1. **The direction is deploy-then-revert, not revert-then-redeploy.** The invariant worth testing is "the revert script undoes the deploy script", which is `schema(@HEAD^) == schema(deploy tip; revert tip)`. The obvious formulation — dump at `@HEAD`, revert, redeploy, dump again — tests the *opposite* implication, and for a change whose deploy is a `DROP` it is vacuous: both dumps have the tables absent no matter what the revert script contains. Task 6 ships exactly such a change, so the wrong direction would let a hand-written hundred-line revert script through ungraded.

2. **A trailing `^` works after a change name but not after `@`.** `App::Sqitch::Plan::ChangeList::_offset` (`local/lib/perl5/App/Sqitch/Plan/ChangeList.pm:33-38`) strips a trailing `^` only when it is **not** preceded by a punctuation character, and its `$punct` class at `:31` contains `@`. So in `@^` the caret is never recognised as an offset, the literal string `@^` is looked up as a change name, and nothing is found; `@HEAD^` works because the caret follows `D`. The same rule is what makes `drop-installment-schedules^` valid — the caret follows `s` — which is how the harness below addresses "the change before change X" by name instead of pinning the tip.

3. **The comparison is over sorted lines, not the raw dump.** `pg_dump` prints columns in `attnum` order, and a revert that re-adds a dropped column puts it at the end of the table rather than back in its original position — Postgres offers no way to place it. The tip's own revert does this today: `sql/revert/refund-amounts-cents.sql` restores `refund_amount_requested` and `refund_amount` after the columns that followed them, so a raw diff fails on the current tip before this leg changes anything. Sorting the filtered lines compares the *multiset* of schema statements: a missing or altered column, index, constraint, trigger or comment still fails; pure attnum drift does not. Verified: raw comparison fails on today's tip, sorted comparison passes.

   Sorting alone is not quite enough, and the second entry on `@CHANGES` is what exposes the gap. A column line ends in a comma unless it is the table's last column, so a re-added column landing at the end gives the previous last column a comma it did not have — attnum drift leaking straight through the sort as a pair of differences. `refund-amounts-cents` never showed this because the columns its revert re-adds were appended by a later migration and were already last. `payments-amount-cents` does: `payments.sql:10` declares `amount` third and `:19` makes `error_message` last. `dump_schema` therefore strips the optional trailing comma along with the newline before sorting. Verified: with that change the round trip is exact in both directions; without it the two dumps disagree on `error_message text`.

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

# Changes graded here.  A leg that ships a migration appends its change name in
# the same commit; that is the whole registration mechanism.  Pinning '@HEAD^'
# instead would grade only whichever change happens to be last, and Task 7's
# data-only change -- which round-trips trivially under a schema dump -- would
# then mask Task 6's hundred-line revert.
#
# ASCENDING IN sql/sqitch.plan ORDER, and that is load-bearing rather than
# tidy.  Each iteration deploys '--to $change^' and leaves the database at that
# parent, so the next iteration's '--to' must be a forward move.  A list out of
# plan order asks sqitch to deploy backwards and the run stops meaning what the
# assertions claim.  payments-amount-cents is sqitch.plan:65, refund is :67.
#
# Both are real subjects rather than placeholders.  payments-amount-cents sits
# on the money tables this milestone keeps and its revert is broken three ways
# (see the task notes).  refund-amounts-cents re-adds two dropped columns and so
# exercises the attnum tolerance the sorted comparison exists for.
my @CHANGES = qw(
    payments-amount-cents
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
#
# The trailing comma has to come off for that to hold.  A column line's comma
# means "not the last column in this table", so a re-added column landing at the
# end gives the previous last column a comma it did not have -- attnum drift
# leaking through the sort as a pair of phantom differences.  Strip the optional
# comma and the newline together so both forms normalize to the same string;
# stripping the comma alone would take the newline with it on comma lines only
# and reintroduce the same phantom from the other side.
sub dump_schema () {
    my @lines = qx{$pg_dump --schema-only --no-owner --no-privileges --restrict-key=rt --exclude-schema=sqitch '$uri'};
    $? == 0 or die 'pg_dump failed';
    # Drop comment lines and blanks: pg_dump emits version banners that vary.
    return [ sort map { s/,?\s*$//r } grep { !/^--/ && /\S/ } @lines ];
}

my $sqitch = App::Sqitch->new();

# One tenant schema per change, so entries after the first do not collide
# on tenants_slug_key (sql/test-schema.sql:3269-3273).  Earlier iterations'
# schemas stay behind and appear in both dumps, which is harmless -- the
# comparison is before-vs-after, not against a fixture.
#
# The slugs are SQL reserved words on purpose.  A slug like 'rt_123_0' needs no
# quoting anywhere, so a migration that interpolates the schema name with %s
# where it should use %I round-trips clean and the harness grades nothing about
# quoting.  Reserved words are the only quoting-hostile slugs clone_schema
# survives: fix-clone-schema-identifier-quoting.sql:314 runs
# PERFORM set_config('search_path', dest_schema, true) on the UNQUOTED name and
# then strips the 'registry.' prefix from FK, function, trigger and view definitions
# (:386,406,455,468) so that search_path re-resolves them.  A reserved word
# case-folds to itself, so the fold is the identity and only DDL syntax needs
# quoting, which quote_ident supplies.  A mixed-case slug does not fold to
# itself, and clone_schema dies partway with
#   relation "RT_Mixed_1234.pricing_relationship_events_sequence_number_seq"
#   does not exist
# Do not "improve" this list with mixed case or hyphens.  Both were tried
# against live Postgres; both break the harness rather than the migrations.
my @SLUGS = qw( order user group table check );
@CHANGES <= @SLUGS
    or die sprintf 'revert-round-trip needs one reserved-word slug per change: %d changes, %d slugs',
        scalar @CHANGES, scalar @SLUGS;

my $n = 0;

for my $change (@CHANGES) {
    my $slug = $SLUGS[ $n++ ];

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

        # Quoted, because pg_dump renders a reserved-word schema as
        # "order".enrollments -- an unquoted /\Qorder\E\./ matches nothing and
        # this assertion would fail on every run.  Verified by running both
        # forms against one dump in the same process.
        my $before = dump_schema();
        ok scalar( grep { /"\Q$slug\E"\./ } @$before ),
            qq{dump at $change^ includes the cloned tenant schema "$slug"};

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

The first assertion greps for the slug rather than asserting the dump is merely non-empty. A non-empty dump proves nothing: if `clone_schema` silently did nothing, the tenant half of every migration would go ungraded and this test would still be green — which is the failure mode the whole file exists to prevent. It greps for `"order".` and not `order.` because that is what `pg_dump` writes; the two forms were run against one dump in the same process and the unquoted one matched nothing.

The reserved-word slug is the single most load-bearing choice in this file, and it is cheap to undo by accident. `Registry::DAO::Tenant` already quotes tenant slugs as identifiers, and `Tenant.pm:163-169` names `"user"` and `"order"` in a comment as the reason — so a tenant slug that needs quoting is a supported case in production, not a contrivance. A migration that reaches for `%s` where it needs `%I` is therefore a real production bug, and it is invisible to a harness whose only tenant schema is `rt_123_0`. Every reserved word in `@SLUGS` was run through `clone_schema` against live Postgres and each produced 43 tables, identical to the `rt_*` control.

The tenant is created by direct `INSERT` plus `clone_schema` rather than by `Registry::DAO::Tenant->provision`, because `provision` also copies users and seed data (`Tenant.pm:171`) and needs a `Registry::DAO::User` to exist. None of that changes the schema, which is the only thing this test reads.

- [ ] **Step 2: Run it and watch both subtests fail — this is the red step**

Run: `carton exec prove -lv t/database/revert-round-trip.t`

Expected: **FAIL, twice**, and both failures are real rather than staged. `Files=1, Tests=2, 55 wallclock secs` on the run this transcript came from: each subtest deploys the plan up to its change's parent, deploys and reverts one change, and runs `pg_dump` twice.

**Do not stage a canary to prove the harness can fail.** It fails on both of its subjects, on bugs that have been deployed since the cents conversion — a better red step than any injected one, and it skips the risk of leaving a canary behind in a deployed script.

`is_deeply` prints only the *first* differing element, so each transcript below is thinner than the defect behind it. The full symmetric difference for each subtest was measured separately and is given underneath, because the fixes are graded against the whole of it and not against the one line `is_deeply` happens to name.

**Subtest 1, `payments-amount-cents`:**

```
# Subtest: payments-amount-cents reverts cleanly
Adding registry tables to db:postgresql://postgres@127.0.0.1:15440/test
    ok 1 - dump at payments-amount-cents^ includes the cloned tenant schema "order"
    not ok 2 - deploying payments-amount-cents and reverting it restores the schema exactly
    #     Structures begin differing at:
    #          $got->[974] = '    amount numeric(10,2) DEFAULT 0 NOT NULL'
    #     $expected->[974] = '    amount numeric(10,2) NOT NULL'
```

`Adding registry tables to db:...` is sqitch initialising its own registry on the ephemeral database, and it lands on stdout inside the subtest. `prove` reports no parse error for it — verified on this run — which is the concrete instance of the rule above: stdout is not the hazard, a TAP-shaped line on stdout is. Leave this line alone; it is expected on the first run against a fresh database.

Measured delta — four lines present after the revert that were not there before:

```
    amount numeric(10,2) DEFAULT 0 NOT NULL      (x4: registry.payments, registry.payment_items,
                                                  "order".payments, "order".payment_items)
```

and two lines lost:

```
CREATE INDEX idx_payments_amount ON registry.payments USING btree (amount);
CREATE INDEX payments_amount_idx ON "order".payments USING btree (amount);
```

The dump is two lines shorter after the revert than before: the four `DEFAULT 0` lines replace four bare `NOT NULL` lines one for one, and the two indexes are simply gone. The tenant index is named `payments_amount_idx` rather than `idx_payments_amount` because `performance-optimization.sql:68` named the registry one explicitly while `clone_schema`'s `LIKE ... INCLUDING ALL` let Postgres generate the tenant copy's name — which is the name the fix in Step 3 has to reproduce, and it reproduces it by creating the index unnamed rather than by spelling it out.

**Subtest 2, `refund-amounts-cents`:**

```
# Subtest: refund-amounts-cents reverts cleanly
    ok 1 - dump at refund-amounts-cents^ includes the cloned tenant schema "user"
    not ok 2 - deploying refund-amounts-cents and reverting it restores the schema exactly
    #     Structures begin differing at:
    #          $got->[3568] = 'COMMENT ON COLUMN "order".enrollments.refund_status IS 'Status of refund processing for dropped enrollment';'
    #     $expected->[3568] = 'COMMENT ON COLUMN "order".enrollments.refund_amount IS 'Amount refunded for dropped enrollment';'
```

Measured delta — nothing added, and **two** lines lost:

```
COMMENT ON COLUMN "order".enrollments.refund_amount IS 'Amount refunded for dropped enrollment';
COMMENT ON COLUMN "user".enrollments.refund_amount IS 'Amount refunded for dropped enrollment';
```

Two and not one because subtest 1's tenant schema is still standing when subtest 2 runs — the schemas accumulate, so every tenant schema created so far loses the comment. That is not a flaw in the fixture; it is a second sample of the same tenant loop, for free.

Do not match on the element indices — `974` and `3568` here. Each depends on how many lines sort ahead of the difference, so both move whenever a migration is added anywhere ahead of the change, and `3568` moved from `2411` the moment `payments-amount-cents` joined the list and left a second tenant schema standing. They are quoted so a reader can recognise the run, not so anyone can assert on them.

**The two bugs.**

*`payments-amount-cents`* — the three defects catalogued in the task notes above: a `DEFAULT 0` left behind on four columns, `idx_payments_amount` and its tenant twin never rebuilt, and the column-order drift that Step 1's comma normalization already absorbs. Step 3 fixes the first two; the third needs no script change, which is why it does not appear in the measured delta.

*`refund-amounts-cents`* — `sql/deploy/drop-transfer-business-rules.sql:66` put a comment on `registry.enrollments.refund_amount`. `clone_schema` copies tables with `CREATE TABLE ... (LIKE src INCLUDING ALL)` (`fix-clone-schema-identifier-quoting.sql:367`), and `INCLUDING ALL` includes `INCLUDING COMMENTS`, so every tenant schema carries that comment too. `sql/revert/refund-amounts-cents.sql` restores the comment for `registry` at `:17-18` but its tenant loop (`:31-54`) re-adds the column and stops. Revert a tenant schema and the comment is gone for good.

**Editing a revert script is safe in a way editing a deploy script is not**, and Steps 3 and 4 both rely on it. Sqitch's modification detection compares `script_hash`, which is the SHA-1 of the **deploy** script alone (`local/lib/perl5/App/Sqitch/Plan/Change.pm:164-169`, `builder => '_deploy_hash'`), so changing a revert script does not mark the change as modified and nothing needs redeploying anywhere. Neither of these reverts has run in production; the fixes only change what happens the first time they do.

**Both fixes land before the next run, in one green step.** The usual red/green/commit rhythm would put a commit between them, and that commit would be of a red suite — subtest 2 still fails while only subtest 1 is fixed. Two defects found by one new test is one unit of work.

- [ ] **Step 3: Fix the defaults and the index in the payments revert**

In `sql/revert/payments-amount-cents.sql`, the registry half currently reads:

```sql
ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payments SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payments DROP COLUMN amount_cents;

ALTER TABLE registry.payment_items
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payment_items SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payment_items DROP COLUMN amount_cents;
```

Replace it with:

```sql
-- DEFAULT 0 is scaffolding: ADD COLUMN ... NOT NULL needs a value for the
-- existing rows.  payments.sql:10,33 declared these columns bare NOT NULL, so
-- the default is dropped once the backfill has run -- otherwise an INSERT that
-- omits the amount books a zero payment instead of raising.
ALTER TABLE registry.payments
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payments SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payments ALTER COLUMN amount DROP DEFAULT;
ALTER TABLE registry.payments DROP COLUMN amount_cents;

-- performance-optimization.sql:68 indexed this column, and DROP COLUMN in the
-- deploy took the index with it.  Restoring the column without the index leaves
-- the schema short of what the revert claims to restore.
CREATE INDEX IF NOT EXISTS idx_payments_amount ON registry.payments(amount);

ALTER TABLE registry.payment_items
    ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0;
UPDATE registry.payment_items SET amount = amount_cents::DECIMAL / 100;
ALTER TABLE registry.payment_items ALTER COLUMN amount DROP DEFAULT;
ALTER TABLE registry.payment_items DROP COLUMN amount_cents;
```

`ALTER COLUMN ... DROP DEFAULT` after the backfill is the idiom `sql/revert/pricing-plans-amount-cents.sql:26,51` already uses; this is copying it, not inventing it.

In the same file's tenant loop, add a `DROP DEFAULT` for each table and recreate the tenant index, so the block becomes:

```sql
        EXECUTE format(
            'ALTER TABLE %I.payments
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payments SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.payments ALTER COLUMN amount DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.payments DROP COLUMN amount_cents', s);

        -- Unnamed, so Postgres generates payments_amount_idx -- the same name
        -- clone_schema's LIKE ... INCLUDING ALL gave the tenant copy.
        EXECUTE format('CREATE INDEX ON %I.payments (amount)', s);

        EXECUTE format(
            'ALTER TABLE %I.payment_items
                ADD COLUMN IF NOT EXISTS amount DECIMAL(10,2) NOT NULL DEFAULT 0', s);
        EXECUTE format(
            'UPDATE %I.payment_items SET amount = amount_cents::DECIMAL / 100', s);
        EXECUTE format('ALTER TABLE %I.payment_items ALTER COLUMN amount DROP DEFAULT', s);
        EXECUTE format('ALTER TABLE %I.payment_items DROP COLUMN amount_cents', s);
```

The tenant index is created **unnamed**. Naming it `idx_payments_amount` would collide with nothing — index names are per-schema — but it would not match what the tenant schema actually had, because that copy was made by `LIKE ... INCLUDING ALL`, which generates `payments_amount_idx` from the table and column names. Spelling out the generated name would work too and would be one more thing to keep in step with Postgres; letting Postgres generate it is the same rule that produced the original.

Fix only the revert. The **deploy** dropped `idx_payments_amount` in production and nothing has rebuilt it on `amount_cents` — a live missing index, not a revert defect — but repairing that means editing a deployed deploy script, which the Global Constraints forbid. It goes on the issue list.

- [ ] **Step 4: Fix the tenant loop in the refund revert**

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

- [ ] **Step 5: Run it again and confirm it passes**

Run: `carton exec prove -lv t/database/revert-round-trip.t`
Expected: PASS, two subtests, two assertions each. **Both transcripts in this task are filtered to the assertion lines — this one and Step 2's — and the two subtests are lopsided in a way worth knowing before you see it.** sqitch prints one progress line per change it touches: `App::Sqitch::Engine.pm:1037` and `:1084` call `info_literal("  + $name ..")` / `"  - $name .."` for every deploy and revert step, and `App/Sqitch.pm:45-50` defaults `verbosity` to 1 with no `core.verbosity` in `sqitch.conf` to turn it down.

Measured: **subtest 1 carries about 67 lines of that, subtest 2 about 7.** `sql/sqitch.plan` holds 64 changes and `pricing-plans-amount-cents` is number 61, so subtest 1 walks 61 of the plan's 64 changes to reach `payments-amount-cents^`. Subtest 2 then moves only two changes forward, because the harness deliberately leaves the database at the parent — that is what the "Leave the database at the parent" comment buys. A real subtest 1 looks like:

```
Adding registry tables to db:postgresql://postgres@127.0.0.1:15442/test
Deploying changes through pricing-plans-amount-cents to db:postgresql://…
  + users ...................................... ok
  + workflows .................................. ok
  ... 58 more ...
  + pricing-plans-amount-cents ................. ok
    ok 1 - dump at payments-amount-cents^ includes the cloned tenant schema "order"
```

None of it is a symptom. Do not read its presence as a difference from the blocks below, and do not go looking for a way to silence it — the assertion lines are what this step grades.

```
# Subtest: payments-amount-cents reverts cleanly
    ok 1 - dump at payments-amount-cents^ includes the cloned tenant schema "order"
    ok 2 - deploying payments-amount-cents and reverting it restores the schema exactly
ok 1 - payments-amount-cents reverts cleanly
# Subtest: refund-amounts-cents reverts cleanly
    ok 1 - dump at refund-amounts-cents^ includes the cloned tenant schema "user"
    ok 2 - deploying refund-amounts-cents and reverting it restores the schema exactly
ok 2 - refund-amounts-cents reverts cleanly
1..2
All tests successful.
Files=1, Tests=2, 61 wallclock secs
Result: PASS
```

That is a transcript, not a prediction. The file exactly as Step 1 writes it was run against live Postgres with the reserved-word fixture: red on both subtests before the Step 3 and Step 4 edits, green on both after them, and the symmetric difference in each direction is zero for each change. Both edits were then reverted so the red step still reproduces for whoever executes this plan.

- [ ] **Step 6: Replace the fake rollback subtest**

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

- [ ] **Step 7: Run both database tests**

Run: `carton exec prove -lv t/database/`
Expected: PASS, and `migration-verification.t` now reports one fewer subtest.

- [ ] **Step 8: Commit**

```bash
git add t/database/revert-round-trip.t t/database/migration-verification.t \
        sql/revert/payments-amount-cents.sql sql/revert/refund-amounts-cents.sql
git commit -m "Add a revert-test harness and fix the two bugs it found

The rollback subtest passed by calling pass(). The new harness takes a list of
sqitch changes and, for each one, deploys an ephemeral database to that
change's parent, provisions a tenant schema with clone_schema, deploys the
change, reverts it, and diffs the schema dumps -- so a revert script that does
not restore the schema fails here rather than in production. A leg that ships a
migration adds its change name to the list in the same commit.

It failed on both of its subjects, immediately.

payments-amount-cents re-added amount as NOT NULL DEFAULT 0 where the column
was declared bare NOT NULL and never dropped the default, so a post-revert
INSERT that omitted the amount would book a zero payment instead of raising;
and it restored the column without idx_payments_amount, which the deploy's
DROP COLUMN had taken with it. The revert now drops the default after the
backfill and recreates the index in both the registry and tenant schemas.

refund-amounts-cents restores the refund_amount column comment for registry but
not for tenant schemas, which get the comment from clone_schema's
LIKE ... INCLUDING ALL, so reverting a tenant schema dropped it permanently.
The revert's tenant loop now restores it.

Both fixes are to revert scripts. sqitch's script_hash covers the deploy script
alone, so neither change is marked modified and nothing needs redeploying."
```

---

### Task 2: Delete the installment machinery

**Files:**
- Delete: `lib/Registry/DAO/PaymentSchedule.pm`, `lib/Registry/DAO/ScheduledPayment.pm`, `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm`, `lib/Registry/PriceOps/PaymentSchedule.pm`, `lib/Registry/PriceOps/ScheduledPayment.pm`
- Delete: `t/controller/admin-installment-payment-dashboard.t`, `t/controller/installment-payment-webhooks.t`, `t/controller/subscription-webhook-routing.t`, `t/dao/payment-schedule-race-condition.t`, `t/dao/payment-schedule.t`, `t/dao/scheduled-payment.t`, `t/e2e/installment-payment-enrollment.t`, `t/integration/installment-webhook-processing.t`, `t/unit/installment-breakdown.t`
- Modify: `lib/Registry/Controller/Webhooks.pm:8,69-72,204-289`
- Modify: `t/controller/payment-failures.t:2,3,13,16,22-24,26-30,34-36,71-79,92-272,274`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `Registry::Controller::Webhooks::stripe` keeps exactly three dispatch arms after this task — `payment_intent.succeeded` → `_process_payment_intent_succeeded` (`:61-63`), `account.updated` → `_process_account_updated` (`:66-68`), and the `else` that hands everything remaining to `Registry::DAO::Subscription::process_webhook_event` (`:72-80`). Only the installment `elsif` goes. Task 6 relies on no Perl code naming `payment_schedules` or `scheduled_payments`.

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

**Steps 2 and 3 both cut `lib/Registry/Controller/Webhooks.pm`, and both use pre-edit line numbers. Do Step 3 first, then Step 2.** They touch disjoint regions, so that is the only reordering needed. In written order Step 2 removes 4 lines above Step 3's range — `:8` (one line) and `:69-72` replaced by one line (three) — and Step 3's literal `:204-289` then takes original `:208-290`: it strands the first method's header and eats the class's closing `}`. Measured by executing both steps in written order:

```
Missing right curly or square bracket at lib/Registry/Controller/Webhooks.pm line 203, at end of line
syntax error at lib/Registry/Controller/Webhooks.pm line 203, at EOF
```

(The reported line is 203 or 202 depending on whether your editor keeps the trailing blank line; both were observed. The number is not the point — the missing `}` is.)

Step 2's blocks are quoted verbatim, so a text-matching editor survives either order; Step 3 is a bare range with nothing to match on, which is why it goes first.

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

**Delete `lib/Registry/Controller/Webhooks.pm:204-289` as one contiguous cut.** Four orphaned methods live in that range, and the four ranges below are an inventory of what the block contains — not a set of separate deletions. Taking them one at a time leaves the blank separators at `:228`, `:256` and `:276` behind: three dangling blank lines where the methods used to be. The single cut takes them with it.

Every comment these methods carry sits inside a method body, so there is nothing above `:204` to sweep up — `:203` is blank and `:202` closes the preceding method. After the cut that blank at `:203` sits directly above the class's closing `}` at `:290`, one separator, which is how the rest of the file separates members.

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

**Work bottom-up.** Every range below is a line number in the file as it stands now; deleting from the top first shifts the ones underneath. **Item 1 is the banner renumber at `:274` and it must be done first** — it is the only edit below the big cut, and items 2-9 remove 203 lines ahead of it (181+9+3+5+3+1+1), taking the file from 355 lines to 152 and putting `:274` past EOF. Left last, it silently does nothing and the survivor keeps a `4.4` banner with no 4.1-4.3; nothing greps for `4.4`, so no later gate catches it.

1. Renumber the surviving banner. `4.1` through `4.3` no longer exist, so `:274` becomes:
   ```perl
   # Refund Processing (DAO level - no webhook handler for refunds)
   ```

2. `:92-272` — one contiguous block: the `# Helper to create a payment schedule with 3 installments` comment, `create_test_schedule`, the `post_webhook` helper and its four-line comment, and all three webhook subtests (`4.1 Card Decline` `:135-165`, `4.2 Duplicate Webhook` `:170-215`, `4.3 Failed Installment` `:220-271`), through the blank line at `:272`. The refund subtest's own banner starts at `:273`.
3. `:71-79` — the `$pricing` plan and its trailing blank. Its only reader was `create_test_schedule` at `:96`.
4. `:34-36` — the Mojo app and its trailing blank:
   ```perl
   my $t = Test::Registry::Mojo->new('Registry');
   $t->app->helper(dao => sub { $dao });
   ```
   `$t` was referenced only inside `post_webhook` (`:125,129`). Nothing left in the file makes an HTTP request.
5. `:26-30` — the fake-key block and its trailing blank:
   ```perl
   # Fake Stripe key so PriceOps::ScheduledPayment constructor doesn't die.
   # No actual Stripe calls are made in these tests.
   local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_webhook_tests';
   local $ENV{STRIPE_WEBHOOK_SECRET} = 'whsec_test_fake_for_webhook_tests';
   ```
6. `:22-24` — three now-unused imports:
   ```perl
   use Registry::DAO::PricingPlan;
   use Registry::DAO::PaymentSchedule;
   use Registry::DAO::ScheduledPayment;
   ```
7. `:16` — `use Digest::SHA qw(hmac_sha256_hex);`. Its only caller was `post_webhook` at `:123`. **Keep `:17` `use Mojo::JSON qw(encode_json);`** — the refund subtest calls `encode_json` at `:291,337`.
8. `:13` — `use Test::Registry::Mojo;`, unused once `$t` is gone.
9. `:3` — rewrite the second ABOUTME line from:
   ```perl
   # ABOUTME: Tests card decline, duplicate webhook, failed installment, and refund at HTTP and DAO layers.
   ```
   to:
   ```perl
   # ABOUTME: Tests that a refund updates the payment row and the enrollment it paid for.
   ```

Leave `use Test::Registry::Fixtures;` (`:15`) alone. It is unused today and was unused before this leg — an unrelated cleanup.

- [ ] **Step 6: Run the affected tests**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-failures.t t/controller/webhooks.t t/controller/payment-intent-webhook.t`
Expected: PASS, pristine.

Then re-run Step 4's grep, which could not gate anything when it ran:

```bash
grep -rn "PaymentSchedule\|ScheduledPayment\|InstallmentPayment\|_is_installment_payment_event\|_process_installment_payment_event" lib/ t/ templates/ workflows/
```

Expected now: **no matches at all.** At Step 4 it still tolerated hits in `payment-failures.t` ("fixed in the next step"), so nothing ever confirmed Step 5 finished the job — a skipped item there leaves a comment naming a deleted module and two dead `local $ENV{STRIPE_*}` lines, and every other gate in this leg stays silent about it.

`payment-intent-webhook.t` is in that list because Step 2 rewrites the `if`/`elsif`/`else` chain it drives; it is the fastest check that the surviving two branches still dispatch.

- [ ] **Step 7: Run the wider controller and DAO suites**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/controller/ t/dao/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
# Step 1's `git rm` already staged all fourteen deletions. Naming them again
# here is a pathspec error -- `git add` is all-or-nothing, so it would exit 128
# and stage NOTHING, and the `git commit` below would then record the deletions
# without the two edits, leaving a tree whose Webhooks.pm still says
# `use Registry::DAO::PaymentSchedule;`.  Stage only what Steps 2-5 modified.
git add lib/Registry/Controller/Webhooks.pm t/controller/payment-failures.t
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
- Modify: `t/dao/pricing-plan-amount-cents.t:11,146-167`
- Modify: `t/stripe-live/service-version.t:16-18` (comment only — edit it, never run it)
- Modify: `lib/Registry/DAO/PricingPlan.pm:196-198`

**Interfaces:**
- Consumes: Task 2 must be complete. `InstallmentPayment.pm`, `PriceOps/ScheduledPayment.pm` and `PriceOps/PaymentSchedule.pm` are the bulk of both modules' callers, and Task 2 is what deletes them.
- Produces: `Registry::Service::Stripe` becomes the only Stripe client under `lib/Registry/Service`. It is **not** the only one in the tree: `lib/Registry/DAO/Subscription.pm` builds its own `Mojo::UserAgent` (`:6,17`) against `https://api.stripe.com/v1` (`:19`, calls at `:82,84,86`) and survives this leg — spec `:2397` says Leg 0 "covers all three clients". Later legs add methods to `Service::Stripe`, not to a fourth.

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

**Both edits are pre-edit line numbers. Cut `:146-167` FIRST, then delete `:11`.** Written order is the trap here, and it is the worst of the four in this plan because it fails *silently*: deleting `:11` shifts everything below up by one, so a later `:146-167` cut takes original `:147-168` — the dollar subtest's **body** plus the percentage subtest's **header**. What survives is `subtest 'a dollar-denominated discount is scaled before it meets a cents price'` at `:146` wrapped around the percentage subtest's body. The file compiles, `prove` reports PASS with one fewer subtest exactly as Step 5 predicts, Step 1's `PriceOps::PricingPlan` grep is silent because `:158` went with the body, and one test now runs under another test's name for good. Measured by executing the step in written order.

Delete the whole subtest at `:146-166`, `'a dollar-denominated discount is scaled before it meets a cents price'`, **and the blank line at `:167` with it — cut `:146-167`.** It is the only user of `my $ops = Registry::PriceOps::PricingPlan->new;` (`:158`, used at `:160,162,164`).

The blank line is not a nicety. `:145` and `:167` are both blank — they are the separators on either side of the subtest — so cutting only `:146-166` leaves two consecutive blanks where one belongs. This was measured, not reasoned: a worker who followed the earlier `:146-166` range produced exactly that artifact.

Keep the final subtest at `:168-182` — it calls `$plan->calculate_price`, which lives on the surviving DAO.

**What goes with it:** `calculate_plan_price` (`PriceOps/PricingPlan.pm:87-121`) is the only code in the tree that scales a `sibling_discount` from dollars to cents (`:112`), and this subtest is its only test. Both disappear together. That is not a coverage gap — Task 4 deletes the rest of the sibling-discount surface for the same reason, that nothing reaches it. `Registry::DAO::PricingPlan::calculate_price` (`:136-149`) handles `percentage_discount` only and is unaffected.

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
    # installments today; no leg drops these registry.pricing_plans columns.
```

- [ ] **Step 5: Run the tests**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/pricing-plan-amount-cents.t`
Expected: PASS, seven subtests, **the last one named `'a percentage discount cannot leave a fractional cent behind'`**. Check that name. "PASS with one fewer subtest" is also what the top-down mutation Step 3 warns about produces — it leaves the percentage subtest's body running under the dollar subtest's name, and every other gate in this task stays silent.

- [ ] **Step 6: Commit**

```bash
# Step 2's `git rm` already staged both deletions; naming them again makes this
# a pathspec error that stages nothing (see Task 2 Step 8).
git add lib/Registry/DAO/PricingPlan.pm t/dao/pricing-plan-amount-cents.t \
        t/stripe-live/service-version.t
git commit -m "Delete Client::Stripe and PriceOps::PricingPlan

Neither had a caller outside one subtest. Service::Stripe is now the only
Stripe client under lib/Registry/Service, which is where later legs add
methods. DAO::Subscription still calls api.stripe.com through its own user
agent; retiring that one is Leg 0's."
```

---

### Task 4: Delete the orphaned discount surface and the silent-pass test

**Files:**
- Modify: `t/dao/pricing-plan-clean-architecture.t` (cut `:11-13`, `:16-19`, `:20-21`, `:46` and `:50-209`; **do not delete the file** — Step 1, whose printed listing is the specification)
- Modify: `lib/Registry/DAO/Family.pm:66-82` (delete `sibling_discount_eligible`)
- Modify: `t/dao/family.t:219-252`
- Modify: `lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm:2,11,45-94,163-167`
- Modify: `t/dao/pricing-plan-workflow.t:211,216-222,242,292-294,411`
- Modify: `templates/pricing-plan-creation/requirements-rules.html.ep:9,77-171,344-355`
- Modify: `templates/pricing-plan-creation/review-activate.html.ep:163-186`
- Modify: `schemas/requirements-and-rules.json:75-100` (Step 5b)

**Interfaces:**
- Consumes: **Task 3 must have landed.** Step 6's grep is this task's gate, and six lines match its pattern until Task 3 removes them — **all of Task 3, not just Step 2**: `lib/Registry/PriceOps/PricingPlan.pm:100,112,114,130` (Step 2 deletes the file) and `t/dao/pricing-plan-amount-cents.t:147,155` (Step 3 cuts the `:146-167` subtest). Run Task 4 first and the gate reports six matches that are not on its table, which reads as a miss.
- Produces: the `requirements-rules` workflow step keeps every non-discount field it has today. Leg 5's authoring rewrite starts from that reduced form.

**Why these three go together:** all three are code that produces or asserts values nothing reads. `sibling_discount_eligible` has only test callers. The discount form writes `early_bird_enabled`, `early_bird_discount`, `early_bird_cutoff_date`, `family_discount_enabled`, `family_discount_type`, `family_discount_amount`, `min_children`, `volume_discount_enabled`, `volume_tiers` — and the calculators read different keys entirely (`percentage_discount` at `lib/Registry/DAO/PricingPlan.pm:143`, `sibling_discount` at the now-deleted `PriceOps/PricingPlan.pm:112`). `volume_discount_enabled` and `volume_tiers` have zero readers anywhere. The step's **outcome definition** describes the same form a second time and names three further discount fields — `early_bird_discount`, `bulk_discount_threshold`, `bulk_discount_percentage` — that not even the form ever wrote; Step 5b takes those. `pricing-plan-clean-architecture.t` is issue #296: the file has four subtests (`:24,50,90,145`), and three of them wrap their work in an `eval` and fall through to a bare `pass(...)`. There are four such `pass` sites — `:61,83,129,198` — because the second subtest has two, and returns at the first.

- [ ] **Step 1: Cut the three silent-pass subtests, keep the one that runs**

**Do not delete the file.** Run it first and the reason is on the screen:

```
$ STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/pricing-plan-clean-architecture.t
ok 1 - PricingPlan should not have relationship fields    # 7 assertions, all real
ok 2 - Create PricingPlan without relationship fields     # 1 - Skipping test due to database issue
ok 3 - Relationships handled by PricingRelationship       # 1 - Skipping test due to database issue
ok 4 - Platform plans without embedded relationships      # 1 - Skipping test due to database issue
All tests successful.
```

They skip because `:21` is `my $db = Test::Registry::DB->new->db;` — the `Test::Registry::DB` object is discarded on that line, the ephemeral server is reaped, and every subsequent query dies with *terminating connection due to administrator command*. That is why the first subtest survives: `:23-48` constructs a `Registry::DAO::PricingPlan` **in memory** and checks with `->can` that `target_tenant_id` and `offering_tenant_id` are absent while `plan_name`, `amount_cents`, `plan_scope` and `requirements` are present (`:37,40,41,44,45,46,47` — of which `:46` is the one line inside this subtest that the step below also cuts). It never touches the database, so the dead handle cannot reach it.

**Be precise about what is kept and what is lost, because they are not the same guard.** Spec `:4102-4104` says *"that test is the guard for the relationship-agnostic-plans invariant, and the invariant was violated by a later migration while the guard sat dead."* A migration cannot violate a `->can` check on a Perl class — the assertion that a migration could break is `:87`, `is($result->rows, 0, 'Database should not have target_tenant_id or offering_tenant_id columns')`, and it is inside the range this step cuts. It is also one of the three that never runs. So this step keeps the only assertions that execute and cuts the one the spec sentence is actually about.

That is not a coverage gap, and the reason belongs here rather than on the Coverage Gaps list: the migration-level invariant is guarded at the migration. `sql/verify/remove-pricing-plan-relationship-fields.sql:11-19` raises if either column exists, and `t/database/migration-verification.t:24-27` re-runs every verify script against the final schema, so a later migration re-adding either column fails the suite whether or not `:87` exists.

Cut `:50-209` — the three `eval`-and-`pass` subtests — and with them the `use` lines and the `$db` handle that existed only to feed them. `:210` is `done_testing();` and stays.

**Cut `:46` as well, from inside the subtest that is being kept.** It is `ok($plan->can('plan_scope'), 'PricingPlan should have plan_scope field');`, and `plan_scope` is one of the three `pricing_plans` columns Leg 9b drops (spec `:3854-3855`). The field it checks is `Registry::DAO::PricingPlan.pm:13`, `field $plan_scope :param :reader = 'customer';` — which goes when the column does, at which point this assertion turns red and Leg 9b has to come back to a file that Deviation 3 promises it will not have to touch. The other six assertions are about fields nothing in this milestone removes. One line out now is cheaper than a cross-leg obligation, and it costs no coverage: `plan_scope`'s existence is not what this test is for.

**Write the file exactly as below — the listing, not the ranges, is the specification.** The `use` cuts are `:11-13` (`Test::Exception`, `Test::Registry::DB`, `Test::Registry::Fixtures`), `:16-19` (`PricingRelationship`, `Tenant`, `User`, `Mojo::JSON`) and `:20-21` (the blank and `my $db = …`). `:14 use Registry::DAO;` **stays** even though the surviving subtest never calls it — there is no rule here to derive, only the listing. Getting this wrong is silent: the file still compiles, still passes, and Step 1's own grep gate is satisfied by a leftover `t/` match. It also breaks two of this plan's promises — Deviation 3 tells Leg 9a the truncated file's `use` list is `Test::More`, `Registry::DAO`, `Registry::DAO::PricingPlan` and nothing else, and a surviving `:16` hands Leg 9a the exact `PricingRelationship` reader that deviation says does not exist.

The result is the whole file:

```perl
#!/usr/bin/env perl
# ABOUTME: Test that PricingPlan is relationship-agnostic and focuses on plan definition
# ABOUTME: Verifies clean separation between pricing plans and pricing relationships

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Registry::DAO;
use Registry::DAO::PricingPlan;

# Test that PricingPlan doesn't have obsolete relationship fields
subtest 'PricingPlan should not have relationship fields' => sub {
    # Create a plan instance for testing
    my $plan = eval {
        Registry::DAO::PricingPlan->new(
            id => '123e4567-e89b-12d3-a456-426614174000',
            session_id => '223e4567-e89b-12d3-a456-426614174000',
            plan_name => 'Test Plan',
            amount_cents => 10000,
            created_at => '2024-01-01T00:00:00Z',
            updated_at => '2024-01-01T00:00:00Z',
        );
    };

    ok($plan, 'Created plan instance') or diag("Error: $@");

    # These fields should NOT exist
    ok(!$plan->can('target_tenant_id'), 'PricingPlan should not have target_tenant_id field');
    ok(!$plan->can('offering_tenant_id'), 'PricingPlan should not have offering_tenant_id field');

    # These fields SHOULD exist (core plan definition)
    ok($plan->can('plan_name'), 'PricingPlan should have plan_name field');
    ok($plan->can('amount_cents'), 'PricingPlan should have amount_cents field');
    ok($plan->can('requirements'), 'PricingPlan should have requirements field');
};

done_testing();
```

Dropping `use Test::Registry::DB;` takes the `Test::PostgreSQL` spin-up with it — verified, the reduced file runs in 4-6 wallclock seconds against no database, `Result: PASS` — measured twice on different machines, and it also passes with `DATABASE_URL` and `TEST_DATABASE_URL` unset, spawning no `Test::PostgreSQL` at all. That run was of the seven-assertion form, before the `plan_scope` line came out; the file above reports `1..6` inside its one subtest.

The deleted `:16` is one of nine live `use Registry::DAO::PricingRelationship;` lines in the tree, and the only one this task removes. That is not enough to strand the module — three of the nine are under `lib/` — but confirm it rather than assume it:

Run: `grep -rn "PricingRelationship" lib/ t/`
Expected: matches under `lib/` remain. Then check the cut mechanically rather than by eye — that grep prints 80-odd `t/` lines and the discriminating one is buried mid-list:

```bash
grep -c PricingRelationship t/dao/pricing-plan-clean-architecture.t
```

Expected: `0` (and exit 1, which is a pass — see the Global Constraints). Non-zero means `:16` survived the cut and the `use` list above is wrong — if it does, `:16` survived the cut and the `use` list above is wrong. If no `lib/` matches remain, stop and report: the module would then be dead too, which is out of this task's scope.

- [ ] **Step 2: Delete `sibling_discount_eligible` and its two test callers**

In `lib/Registry/DAO/Family.pm`, delete `:66-82` — the separator line, the sub, and the comment that introduces it:

```perl
    # Get sibling discount eligibility
    sub sibling_discount_eligible ($class, $db, $family_id, $session_id) {
```

`:67` is the comment, `:68` the `sub` line, `:82` its closing brace. Take the comment too: it describes only this sub, and `:83` is the class's own closing `}`, so leaving the comment behind strands it against the end of the file.

Take `:66` as well, and note what it is: **not an empty line but four spaces.** It is the separator between `has_multiple_children` (which ends at `:65`) and the sub being deleted. Cut `:67-82` alone and that whitespace-only line is left dangling directly against the class's closing `}` — a trailing-whitespace artifact where nothing separates any more. This was measured on a worker who followed the earlier `:67-82` range. The result of `:66-82` is `    }` at what was `:65` followed immediately by `}`, which is how a class ends when its last member is its last member.

In `t/dao/family.t`, delete the whole `'Sibling discount eligibility'` subtest, `:219-251`. The two `sibling_discount_eligible` calls at `:237` and `:249` are the subtest's **only** assertions — deleting just those two lines leaves a subtest whose body creates a session and two enrollments and then asserts nothing, which `Test::More` reports as `No tests run for subtest`, a failure. The whole block goes, including its setup and the two `Registry::DAO::Enrollment->create` calls that exist to make the second assertion true.

`:217` closes the preceding subtest and `:253` opens the next one, so `:219-251` plus the blank line at `:252` is a clean cut; take `:219-252`.

**That cut breaks the next subtest, and the grep gate in Step 6 will not tell you.** Those two `Enrollment->create` calls are the only enrollments created for any of `$parent1`'s family members *before* `'Family member relations'` runs. The file has two more at `:276` and `:306`, but both are in `'Flexible enrollment architecture'` (`:267`), which runs afterwards and cannot help the subtest above it. `'Family member relations'` — the subtest immediately below, at `:253` before the cut — calls `$child->enrollments($db)` on `$children->[0]`, which is `Registry::DAO::Enrollment->find($db, { family_member_id => $id })` (`lib/Registry/DAO/FamilyMember.pm:108-110`). `Registry::DAO::Object::find` returns `wantarray ? $c->to_array->@* : $c->first` (`lib/Registry/DAO/Object.pm:18`), and `$c->first` on no rows is `undef`. Verified by running the cut: `not ok 2 - Can retrieve enrollments` and `not ok 3 - 'Enrollments is array' isa 'ARRAY'`, `Failed test 'Family member relations'`.

So the surviving subtest has to seed its own enrollment. In `'Family member relations'`, insert this between the `is($family->id, ...)` assertion and the `my $enrollments = ...` line:

```perl
    # Enroll the child so the relation has a row to return
    my $relation_session = Test::Registry::Fixtures::create_session($db, {
        name => "Family Member Relations Session " . time(),
    });
    Registry::DAO::Enrollment->create($db, {
        session_id       => $relation_session->id,
        family_member_id => $child->id,
        student_type     => 'family_member',
        status           => 'active',
    });
```

Verified: with the cut plus this insertion, `t/dao/family.t` reports 10 subtests and `Result: PASS`.

Run: `grep -rn "sibling_discount_eligible" lib/ t/ templates/`
Expected: no matches.

- [ ] **Step 3: Delete the discount blocks from the step class**

**Four edits to one file, all pre-edit line numbers. Apply them bottom-up: `:163-167`, then `:45-94`, then `:11`, then `:2`.** In the written order the first two edits remove 51 lines above `:163-167`, and that range then falls past the end of a 139-line file — the edit silently does nothing and `discount_types` survives at `:113`. Measured, not reasoned: a worker who followed the written order produced exactly that, with `113:            discount_types => [` still in the file. Step 6's gate does catch it, because `discount_types` is in its pattern — but a step that relies on a later gate to notice it did nothing is a step that does not work.

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

3. `:9` — the standfirst still promises what the page no longer offers:
   ```
           <p class="text-gray-600 mb-6">Set eligibility requirements, discounts, and renewal policies.</p>
   ```
   Replace with:
   ```
           <p class="text-gray-600 mb-6">Set eligibility requirements, trial terms, and renewal policies.</p>
   ```
   This is user-facing copy, not a comment: after the `:77-171` cut the form has no discount field on it at all, and the sentence tells the admin to look for one. Same correction as the `RequirementsRules.pm:2` ABOUTME in Step 3, one layer up.

- [ ] **Step 5: Delete the stranded reader in the review template**

In `templates/pricing-plan-creation/review-activate.html.ep`, delete `:163-186` — the whole `<% if ($summary->{requirements}) { %>` block that displays `$reqs->{early_bird_enabled}`, `early_bird_discount`, `early_bird_cutoff_date`, `family_discount_enabled`, `family_discount_amount`, `family_discount_type`, and `min_children`, plus the blank line that followed it. Once the form stops writing those keys, this block is a reader for data that no longer exists.

The whole block, not just the two `<% if %>` bodies: `:163` opens the guard, `:164` binds `my $reqs`, `:165` opens the `<dl>`, `:184` closes it and `:185` closes the guard. Deleting only `:166-183` leaves an empty `<dl>` inside a guard whose only remaining statement is an unused `my $reqs`. `:187` starts the `$summary->{rules}` block, which stays.

Take `:186` too. `:162` and `:186` are both blank — the separators either side of the block — so a `:163-185` cut leaves two consecutive blanks between the `<h3>` at `:161` and the `$summary->{rules}` guard. Measured on a worker who followed the earlier range, not inferred.

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

- [ ] **Step 5b: Delete the discount group from the outcome definition**

The form template is not the only description of this form. `schemas/requirements-and-rules.json` is the step's **outcome definition**, and it is bound to the very step this task is editing — `workflows/pricing-plan-creation.yaml:27` reads `outcome-definition: Requirements and Rules`, and `schemas/requirements-and-rules.json:2` reads `"name": "Requirements and Rules"`. Leave it alone and the form's authoritative field list still declares three discount fields after every other trace of them is gone.

That list is live, not documentation. `lib/Registry/Command/schema.pm:73-88` globs `schemas/*.json` and calls `Registry::DAO::OutcomeDefinition::import_from_file` on each; that sub **updates** an existing row by name (`lib/Registry/DAO/OutcomeDefinition.pm:67-83`) rather than skipping it, so an edited file does reach the database on the next `registry schema load`. The stored schema is then served by `GET /outcome/definition/:id` (`lib/Registry.pm:740`) and consumed by `public/js/form-builder.js`, which renders fields from it.

Delete `:76-100` — the whole `discount_rules` group object:

```json
    {
      "id": "discount_rules",
      "type": "object",
      "label": "Discount Rules",
      "required": false,
      "properties": {
        "early_bird_discount": { ... },
        "bulk_discount_threshold": { ... },
        "bulk_discount_percentage": { ... }
      }
    }
```

**Then fix `:75`.** `discount_rules` is the last element of the `fields` array (`:101` is `  ]`), so the group that precedes it, which closes at `:75` with `    },`, becomes the last element and its trailing comma becomes a syntax error. Change `:75` from `    },` to `    }`. Deleting `:76-100` on its own leaves the file invalid JSON and `import_from_file` swallows the failure into a `carp` (`:92-95`), returning undef — the import prints `Failed to import schema from 'requirements-and-rules.json'` and keeps going, so a broken file does not fail the command.

Note the field names: `bulk_discount_threshold` and `bulk_discount_percentage` are not among the nine keys the form wrote, and `early_bird_discount` here is a **flat** field inside `discount_rules`, not the `requirements->{early_bird_discount}` the step class stored. This group is a third, independent statement of the same dead idea. Nothing reads any of the three — `grep -rn "discount_rules\|bulk_discount" lib/ t/ templates/ workflows/` returns nothing.

Run: `perl -MJSON::PP -e 'JSON::PP->new->decode(do { local (@ARGV, $/) = "schemas/requirements-and-rules.json"; <> }); print "valid JSON\n"'`
Expected: `valid JSON`

No `registry schema load`. That command takes its DAO from `$self->app->dao` and writes the **dev** database, which this plan's Global Constraints forbid. The file is the source of truth; the row is refreshed by whoever next runs the importer against a database they own.

- [ ] **Step 6: Confirm no discount key survives without both a writer and a reader**

Run:

```bash
grep -rn "early_bird_\|family_discount_\|min_children\|volume_discount_enabled\|volume_tiers\|discount_types\|discount_rules\|bulk_discount_\|sibling_discount" lib/ t/ templates/ workflows/ schemas/
```

**`schemas/` is in the directory list on purpose**, and so are `discount_rules`, `bulk_discount_` and `sibling_discount` in the pattern. Without `schemas/` the gate cannot see the outcome definition Step 5b edits, and `bulk_discount_threshold` / `bulk_discount_percentage` match none of the other alternations — so a gate scoped to the nine form keys would report all-clear over a live schema still declaring three discount fields. `sibling_discount` is in for the opposite reason: it has a survivor, and the gate should show it rather than leave the reader wondering whether it was missed.

**Run this gate only after Task 3 has landed — all of it, not just Step 2.** Six lines match the pattern and are not survivors: `lib/Registry/PriceOps/PricingPlan.pm:100,112,114,130`, which Task 3 **Step 2** deletes with the file, and `t/dao/pricing-plan-amount-cents.t:147,155`, which Task 3 **Step 3** cuts with the `:146-167` subtest. Running the gate before Task 3 produces six matches that are not on the table below and the check reads as a miss.

Expected: **matches remain, and every one must be on this list.** The nine keys this task removes are the ones the orphaned *form* wrote. `early_bird_cutoff_date` and `min_children` are also named by two surviving `PricingPlan` methods that key on `plan_type`, not on the form:

| Survivor | Why it stays |
|---|---|
| `lib/Registry/DAO/PricingPlan.pm:154,155,170,172` | `requirements_met`, which **is** live: `calculate_price` calls it at `:138`. Its two `plan_type` branches (`'early_bird'` at `:154`, `'family'` at `:170`) read `early_bird_cutoff_date` and `min_children` off `requirements`. Reached through `plan_type`, which the enhanced-pricing-model migration backfills, not through the deleted form. Out of scope for Leg 1. |
| `lib/Registry/DAO/PricingPlan.pm:181,183,186` | `is_early_bird_available`. **This method has zero callers and zero tests** — `grep -rn "is_early_bird_available" lib/ t/ templates/ workflows/ schemas/` returns exactly one line, its own declaration at `:181`. It is dead, and it stays dead in Leg 1 anyway: the spec assigns the early-bird surface to a later leg, and deleting a public method on a live DAO is not a safe deletion in the sense this task means. Note what the spec actually says about it — `:2698-2700` singles this method out as the reader that "parses the string to an epoch and **gets it right**"; the epoch-vs-string bug it is being contrasted against is in `requirements_met`, the row above. Removal is on the issue backlog and no leg currently owns it. `:181` shows up in the grep only because `early_bird_` matches inside the method name. |
| `t/dao/pricing-plans.t:69,76,86,92,139,155,172,198,206` | fixtures and assertions for `requirements_met`, reached through `calculate_price` (`:159,163,175,178`). It never names `is_early_bird_available` — that method has no test at all, which is a fact for whichever leg removes it, not a reason to keep it here. |
| `t/dao/tenant-summer-camp.t:172,173,183,184` | an **inert** fixture, not a live path. `:168` of that file is `plan_type => 'standard'`, so neither `requirements_met` branch can fire and `:172`'s `early_bird_cutoff_date` is never read. `:173` writes `sibling_discount => 15.00` and `:183-184` reads it back. After Task 3 deletes `PriceOps/PricingPlan.pm:112` nothing in production reads that key either — but the assertion is not thereby worthless: it round-trips a `requirements` JSONB value through create-and-reload, which is live behaviour. Leave the file alone. Filing the inert `early_bird_cutoff_date` key as cleanup is enough. |

Twenty matching lines, no more — seven, nine and four, exactly as the table enumerates them. Anything **not** on that list is a miss — in particular any match under `templates/`, under `workflows/`, under `schemas/`, or in `RequirementsRules.pm`, all of which must be gone.

`t/e2e/admin-program-management.t` does **not** appear, despite writing `pricing => { standard => 180.00, early_bird => 150.00 }` at `:138,148`. Its key is `early_bird`, with no trailing underscore, so the pattern `early_bird_` never matches it. It is named here only so nobody adds it to the table on sight of the file.

`sql/` is excluded from the grep on purpose: `enhanced-pricing-model.sql`, `summer-camp-module.sql` and their revert and verify scripts all name these columns, and they are deployed changes that must not be edited.

- [ ] **Step 7: Run the affected tests**

No workflow re-import. `workflows/pricing-plan-creation.yaml:25-28` stores the step's **class name**, not its code, and the class name has not changed — so the stored definition is still correct. `carton exec ./registry workflow import registry` would also write the **dev** database (`lib/Registry/Command/workflow.pm` takes its DAO from `$self->app->dao`), which this plan's Global Constraints forbid.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/family.t t/dao/pricing-plan-workflow.t t/dao/pricing-plans.t`
Expected: PASS. `family.t` reports one fewer subtest, ten rather than eleven.

**One warning here is pre-existing and is not yours.** `t/dao/pricing-plan-workflow.t` prints `Use of uninitialized value in string eq at lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm line 71.` — `$form_data->{requires_approval} eq 'yes'` with the key absent. Confirmed by running the file at HEAD before any of this task's edits. The Global Constraints demand pristine output, so this looks like a regression and is not one; it is on the issue list. Do not fix it here — it is outside this task's blast radius and a fix would be an unrelated change. Any *other* new warning is yours.

(`t/dao/pricing-plan.t` does not exist — the singular-named files are `pricing-plans.t`, `pricing-plan-workflow.t` and `pricing-plan-amount-cents.t`.)

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/dao/ t/controller/`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/Registry/DAO/Family.pm lib/Registry/DAO/WorkflowSteps/RequirementsRules.pm \
        t/dao/family.t t/dao/pricing-plan-clean-architecture.t t/dao/pricing-plan-workflow.t \
        templates/pricing-plan-creation/requirements-rules.html.ep \
        templates/pricing-plan-creation/review-activate.html.ep \
        schemas/requirements-and-rules.json
git commit -m "Delete the orphaned discount surface and the subtests that passed by skipping (#296)

The requirements-rules form wrote nine discount keys. The calculators read
different keys; volume_discount_enabled and volume_tiers had no reader at all.
The review template displayed the orphaned keys, so it goes with the form, and
the step's outcome definition declared three more that nothing ever wrote.
Family::sibling_discount_eligible had only test callers.

Three of pricing-plan-clean-architecture.t's four subtests shut down their own
Postgres on line 21, then fell through to pass() with an explanation instead of
asserting anything. Those three go; the file stays, keeping the one subtest
that actually runs. Closes #296."
```

---

### Task 5: Delete the `seti_test` signup bypass

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:40-47,294-307,308,373`
- Modify: `t/controller/tenant-create-session.t:65-67`
- Modify: `t/user-journeys/alex/01-acquire-tenant.t:5,82-85,199-208,331-348`
- Modify: `t/user-journeys/alex/03-platform-billing.t:5,77-78,164-172,214,216`

**Interfaces:**
- Consumes: nothing.
- Produces: `TenantPayment::process` keeps four terminal outcomes after the cut, and later legs need all four by name: a real `setup_intent_id` → `handle_setup_completion` (`:41-43`); `collect_payment_method` with **no** Stripe keys configured → the direct-provision branch returning `{ next_step => 'complete', tenant_created => 1, ... }` (`:50-63`, the return at `:62`); `collect_payment_method` with keys present → `return $self->create_setup_intent($db, $run, $form_data);` (`:65`) — **this is the live production path to Stripe and the only one that reaches it**; and the bare page load (`:68-72`). Only the `seti_test` arm goes. No branch keys on the value of a client-supplied string.

  Those four ranges are **post-edit** line numbers, and they were measured on a worktree that had actually executed Steps 3 and 4 — not computed by subtracting deleted lines from the pre-edit file. An earlier draft of this block did compute them, and all four were wrong. If you are reading this before running the steps, the pre-edit locations are `:43` and `:295` (the two `seti_test` branches) and `TenantPayment.pm:369-373` (the `_provision_tenant` comment block).

**The defect:** `TenantPayment.pm:43` and `:295` both branch on `$form_data->{setup_intent_id} =~ /^seti_test/` — a client-supplied string with no environment guard. In production, where both Stripe keys are set, a POST carrying `setup_intent_id=seti_test_anything` provisions a tenant with a fake subscription. The no-keys branch immediately below produces a byte-identical result hash and **is** environment-guarded, so it can never fire in production.

**Verified before writing this task:**
- The two branches produce the same hash: both build `{ stripe_subscription_id => 'sub_test_' . time(), trial_ends_at => time() + (30*24*60*60), status => 'trialing' }`, call `$run->update_data`, call `_provision_tenant`, and return `{ next_step => 'complete', tenant_created => 1, %$result }`. `TenantPayment.pm:372-373` says so itself: "This is the single provisioning path for all completion scenarios".
- `t/controller/tenant-create-session.t` already exercises the no-keys branch today. Its `BEGIN { delete @ENV{qw(STRIPE_SECRET_KEY STRIPE_PUBLISHABLE_KEY)} }` is at `:7`, and its `setup_intent_id => 'seti_test_123'` at `:66` never reaches the step: `templates/tenant-signup/payment.html.ep:91` renders `<input type="hidden" name="setup_intent_id" value="">`, and `t/lib/Test/Registry/Helpers.pm:168` builds the submission as `my %submit = ( $data->%{@$fields}, %$hidden );` — server-issued hidden values win. The test passes (117 tests, verified).
- The two alex journeys post directly with `Test::Mojo`, bypassing the template, so they are the only genuine consumers.
- `handle_setup_completion` constructs `Registry::DAO::Subscription->new(db => $db)` at `:291`, **before** the `seti_test` check, and `lib/Registry/DAO/Subscription.pm:18` dies without `STRIPE_SECRET_KEY`. Removing the bypass means the alex journeys stop reaching that constructor entirely, which is why deleting the key is safe.

**Named risk and its fallback:** if an alex journey turns out to need a `Subscription` object after all, the in-repo pattern is `local *Registry::Service::Stripe::create_payment_intent_async = sub {...}` — 15 sites across 7 files, including `t/user-journeys/alex/02-activate-and-collect.t:421`, `t/integration/tenant-paid-enrollment.t:237` and eight in `t/dao/payment-idempotency.t` alone. It works on Object::Pad methods. Put such a helper in `t/lib/`, not in a production class.

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

**Add the three lines directly against the existing `BEGIN`, with no blank line between them.** The offset table below is +3, and a blank separator makes it +4 — which throws every range in Steps 6, 7 and 8 off by one. Measured: with the separator the files come out at 352 and 312 lines; without it, 351 and 311, which is what the table assumes.

- [ ] **Step 2: Run them and watch them fail**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/user-journeys/alex/01-acquire-tenant.t t/user-journeys/alex/03-platform-billing.t`
Expected: FAIL, both files. The POST still carries `setup_intent_id=seti_test_acquire_$$`, so dispatch reaches `handle_setup_completion`, which constructs `Registry::DAO::Subscription` and dies with `STRIPE_SECRET_KEY not set`.

This is the red step: it demonstrates that the `seti_test` branch, not the no-keys branch, is what those tests exercise today.

**Step 1 has now shifted both journey files, and Steps 6, 7 and 8 cite HEAD numbers.** Every later range sits below `:5`, so Step 1's three inserted lines move all of them — but Steps 6 and 7 are themselves net deletions above Step 8, so the offset is not uniform. Measured by executing the sequence:

| Step | File | Cited | When that step runs |
| --- | --- | --- | --- |
| 6 | `01-acquire-tenant.t` | `:199-208` | `:202-211` (+3) |
| 7 | `01-acquire-tenant.t` | `:82-85` | `:85-88` (+3) |
| 8 | `01-acquire-tenant.t` | `:331-348` | **`:331-348` — its HEAD numbers** |
| 6 | `03-platform-billing.t` | `:164-172` | `:167-175` (+3), `:171`→`:174` |
| 7 | `03-platform-billing.t` | `:77-78` | `:80-81` (+3) |
| 8 | `03-platform-billing.t` | `:214,216` | **`:215,217`** |

Step 6 replaces 10 lines with 8 and Step 7 replaces 4 with 3, so by the time Step 8 runs, `01` is back where it started (+3−2−1 = 0) and `03` is one ahead (+3−2−0 = +1, its Step 7 rewrite being 2-for-2). Confirmed by `wc -l`: `01` goes 351 → 351, `03` goes 310 → 311.

**Bottom-up does not rescue this the way the Global Constraint usually does**, because Step 1 must precede Step 2 — the red step needs the `seti_test` POST that Step 6 removes — so Step 1 cannot be deferred. Within Steps 6, 7 and 8 the order *is* free, and doing **8 first** would make all three ranges a flat +3; the table above is written for the plan's own order instead. All three steps quote their blocks verbatim, so a text-matching editor lands correctly regardless; the table is the fallback.

**Steps 3, 4 and 5 all cut `TenantPayment.pm`, and every range in them is a line number in the file as it stands now. Apply them bottom-up.** Step 3 removes 8 lines and Step 4 a further 14, so running them in written order leaves Step 4 stale by 8 and Step 5 stale by 22 — the same hazard the Global Constraint names, here spread across three steps. The order to edit in is: Step 5 item 1 (`:373`), Step 5 item 2 (`:308`), Step 4 (`:294-307`), then Step 3 (`:40-47`). Both Step 5 edits replace one line with one line, so neither shifts anything below it, and the two deletions then come off in descending order. Read all three steps before touching the file.

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

Delete `:294-307` — the block below is `:294-306`, plus the blank at `:307`, on the same reasoning: `:293` is already blank and `:308` is `# For non-test modes, validate the setup_intent_id matches what was stored`. Stop at `:308`; **Step 5 rewrites that comment**, which this deletion makes false.

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

- [ ] **Step 5: Correct the two comments the deletion makes false**

Two comments in this file describe a test mode that Steps 3 and 4 remove. Both go, **bottom-up**:

1. `:373` currently reads:

   ```perl
       # scenarios (no-Stripe mock, seti_test mock, real-Stripe).
   ```

   Replace with:

   ```perl
       # scenarios (no-Stripe mock, real-Stripe).
   ```

2. `:308` — the line Step 4 deliberately stops just short of — currently reads:

   ```perl
           # For non-test modes, validate the setup_intent_id matches what was stored
   ```

   Replace with:

   ```perl
           # Validate the setup_intent_id matches what was stored
   ```

   The qualifier is the whole point: after Step 4 this file has no test mode, so "for non-test modes" describes a distinction that no longer exists and implies a branch a reader will go looking for. `grep -n "test mode\|test_mode\|non-test" lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` should return nothing once both edits land. Do not delete the comment outright — the validation it introduces is still real and still needs saying.

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

Make the matching edit at `t/user-journeys/alex/03-platform-billing.t:164-172`. That block's five comment lines carry no `# Expected:` line, unlike `01`'s six — so do not add one. Replace the whole range with exactly:

```perl
# -- Step: payment (POST, no Stripe keys configured) ----------------------
# collect_payment_method=1 with no Stripe keys in the environment provisions
# directly (TenantPayment.pm, the !STRIPE_PUBLISHABLE_KEY && !STRIPE_SECRET_KEY
# branch).  The BEGIN block at the top of this file guarantees the condition.
$t->post_ok($payment_url => form => {
    collect_payment_method => 1,
})->status_is(302);
```

Note the trailing semicolon — `03`'s original `:172` has one and `01`'s `:208` does not. Four comment lines out of five, which is the arithmetic the offset table above depends on.

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
git add lib/Registry/DAO/WorkflowSteps/TenantPayment.pm t/controller/tenant-create-session.t \
        t/user-journeys/alex/01-acquire-tenant.t t/user-journeys/alex/03-platform-billing.t
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
- Modify: `t/dao/tenant-payment-schema-isolation.t:3,7,11,39-40,43,93-223`
- Modify: `t/database/revert-round-trip.t` (Step 1 appends this change to `@CHANGES`)
- Modify: `docs/operations/sacp-stripe-connect-onboarding.md:87,92` (Step 10)
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: `t/database/revert-round-trip.t` from Task 1 — this change lands at the tip, so the harness grades its revert. Task 2 must be complete: no Perl may name the dropped tables.
- Produces: sqitch change `drop-installment-schedules`, which becomes the **plan predecessor** of Task 7's change. Not its *required dependency* — "requires" is sqitch's term of art for `--requires`, and Task 7 Step 2 declares `--requires suspend-rateless-tenant-plans` only. Plan position is what orders these two; there is no dependency edge between them and adding one has been proposed and rejected twice.

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
  --note 'Drop the installment schedule tables from registry and every tenant schema'
```

**`--note`, spelled out — not `-n`.** `carton` parses its own arguments with `Getopt::Long` in `pass_through` mode and declares `"verbose!"` (`Carton/CLI.pm:38-45`); `auto_abbrev` is on, so `-n` abbreviates to `--noverbose` and `carton` eats it before `sqitch` ever sees it. Demonstrated: `carton exec perl -e 'print "@ARGV"' -n foo` prints `foo`. The note would silently vanish and `sqitch add` would open an editor prompting for one.

Confirm `sql/sqitch.plan` gained exactly one line at the end and that the three stub files appeared under `sql/deploy/`, `sql/revert/`, `sql/verify/`.

Then register the change with Task 1's harness, in this same commit. In `t/database/revert-round-trip.t`, extend `@CHANGES`:

```perl
my @CHANGES = qw(
    payments-amount-cents
    refund-amounts-cents
    drop-installment-schedules
);
```

Append, do not insert. The list is ascending in `sql/sqitch.plan` order because each iteration leaves the database at its change's parent and the next one has to move forward; this change is added at the plan's end, so the end of the list is also the correct position. Task 1's Produces block states the rule.

The harness grades only what is on that list. Skipping this append is the failure mode Task 1's list exists to prevent, and it is silent — the suite stays green and the hundred-line revert script below is never run.

- [ ] **Step 1a: Check what the drop would destroy in production**

`DROP TABLE` is not reversible for rows. The revert below recreates both tables empty. Before merging, count what is there. Run this **read-only** against the Render production database `dpg-ckq1i8o5vl2c73d61070-a` (registry-db), the same target Task 7 Step 1 uses:

**Count every schema, not just `registry`.** The deploy below drops `%I.payment_schedules` and `%I.scheduled_payments` in every tenant schema too, and `registry` is the one schema where an app-created row *cannot* be: every DAO wrote the table name unqualified — **before Task 2 deleted these files**, `DAO/PaymentSchedule.pm:21` `sub table { 'payment_schedules' }`, `:68` `$db->update('scheduled_payments', …)`, `DAO/ScheduledPayment.pm:22`, and `PriceOps/ScheduledPayment.pm:92,113,122` (`FROM payment_schedules`, `FROM scheduled_payments`, `UPDATE payment_schedules`) — so on a tenant-scoped connection they all resolved through `search_path` into the tenant schema. Those paths are gone by the time this step runs; the line numbers are at HEAD, for anyone checking the argument against history. `tenant-scoped-payments.sql:255-284` creates those copies with `LIKE … INCLUDING ALL` (empty) and `:144-169` explicitly refuses to move schedule rows into them. A tenant schema is therefore the only place a row could have come from, and a `registry`-only count would return `0, 0` while saying nothing about it.

```sql
SELECT current_database() AS db,
       n.nspname AS schema, c.relname AS tbl,
       (xpath('/row/c/text()', query_to_xml(
           format('SELECT count(*) AS c FROM %I.%I', n.nspname, c.relname),
           false, true, '')))[1]::text::bigint AS rows
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE c.relkind = 'r'
   AND c.relname IN ('payment_schedules', 'scheduled_payments')
 ORDER BY 2, 3;
```

`query_to_xml` runs each count as a read-only subquery, which is what lets one statement cover a schema list that is not known until it runs.

Expected: every row `0`. Issue #295 says installments are unreachable, and Task 2 has already established that no code path creates a schedule — but "unreachable now" and "never reached" are different claims, and only the count settles it. **Non-zero means stop and report to perigrin**; this leg's premise is that these tables hold nothing, and dropping rows a customer paid against is not a decision this plan gets to make.

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

Also fix `:8`, which the same edit falsifies: `-- For each tenant schema: verify the four payment tables exist and that` becomes `-- For each tenant schema: verify the payment tables exist and that`. Two names go with the array elements, so "four" stops being true, and the Global Constraints require evergreen comments. It does not disturb Step 10's grep — `:8` names no table.

Leave everything else — the FK-schema check (`:32-57`) and the leftover-registry-rows check (`:64-70`) are still true at both points.

- [ ] **Step 9: Rewrite `t/dao/tenant-payment-schema-isolation.t`**

It seeds both dropped tables and must change in this same commit. Five edits, **bottom-up**.

1. **`:93-223` — delete the entire migration-replay section.** This is the edit that is easy to get wrong, so here is why it is all-or-nothing. The section reads the `DO` block out of `sql/deploy/tenant-scoped-payments.sql` at `:107-114` and replays it against the live test database. Both subtests below it run that block: `'migration move-logic: rows land in tenant schema'` at `:150` and `'migration schedule-guard: ...'` at `:204,214`. The extracted block names `registry.scheduled_payments` (`tenant-scoped-payments.sql:150`) and does `CREATE TABLE %I.payment_schedules (LIKE registry.payment_schedules INCLUDING ALL)` (`:255-284`). Once this task drops those tables, **every** `$db->query($do_block)` raises *relation does not exist*. Deleting only the schedule-guard subtest leaves the move-logic subtest replaying the same block and the file fails hard — not "PASS with one fewer subtest".

   The cut runs from the `# ---- migration move-logic tests ---` banner at `:93` through `};` at `:222` and the blank at `:223`. `:92` is blank and `:224` is `# ---- behavioral block (#237 repro) ---`, which stays, as do the structural subtests above `:93` and everything from `:224` down.

2. **`:43` — narrow the table list.** In `subtest 'payment tables exist in tenant schema'`, at `:43` replace:

   ```perl
       for my $tbl (qw(payments payment_items payment_schedules scheduled_payments)) {
   ```

   with:

   ```perl
       for my $tbl (qw(payments payment_items)) {
   ```

3. **`:39-40` — fix the comment that names the dropped tables.** The block runs `:37-40`; `:38` is *"These must be green both before AND after the migration is written because"* and stays. Replace:

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

Expected exactly **twelve files**, and `sql/verify/drop-installment-schedules.sql` must be one of them. **Check for that name; the count alone is not a signal.** It is twelve only here, at Step 10's own position — re-run this grep after Step 11 and the correct answer becomes eleven, because the regenerated `sql/test-schema.sql` no longer names the tables. Eleven is also what a skipped Step 4 gives you *here*. The name is what discriminates. A stub verify left in place by skipping Step 4 passes at its own deploy point AND under `migration-verification.t:26`'s bare `sqitch verify`, so the change ships with no verify at all and the suite stays green; the only signal is this list coming back with eleven entries instead of twelve. The twelve are: the three `sql/deploy/` scripts in the original chain, `sql/deploy/tenant-scoped-payments.sql`, the three `sql/revert/` scripts in the original chain, the three new `drop-installment-schedules` scripts, `sql/verify/simplify-installment-schema-for-stripe.sql`, and `sql/test-schema.sql` (regenerated next). **No `lib/`, no `t/`.**

`sql/verify/simplify-installment-schema-for-stripe.sql` is on the list because Step 6 leaves the table names in its explanatory comment, not in an assertion. That is the only `sql/verify/` match besides the new one; the other three superseded scripts (Steps 5, 7, 8) no longer name the tables at all. If a *third* verify script appears, or if that file matches on a line that is not a comment, the supersession is incomplete.

The grep above does not cover `docs/`, and one document there goes stale with this step. `docs/operations/sacp-stripe-connect-onboarding.md:92` is a live operator runbook whose pre-flight table tells the operator that `tenant-scoped-payments` aborts when *"`registry.scheduled_payments` rows reference payments tagged to a tenant"*. After this task there is no such table and that row can never fire. Delete that one table row and leave the payer-residency row, which is unaffected — the guard itself stays deployed and correct (see Coverage Gaps), but the runbook must stop telling an operator to expect an error that cannot happen. It is committed with the rest of this task in Step 14.

**Fix the sentence above the table in the same edit.** `:87` reads `per-tenant payment tables and will abort loudly on two pre-flight conditions:`. Once the schedule-guard row is gone the table has one row, and a runbook that promises two conditions and lists one reads as a truncated document. Change `two pre-flight conditions` to `a pre-flight condition`.

- [ ] **Step 11: Regenerate the test schema dump**

```bash
make test-schema
```

**Expect about 157 changed lines you did not cause.** `Test::Registry::DB::generate_dump` shells `pg_dump` with no `--restrict-key` and no seed pinning, so every run re-rolls the `\restrict` token and every seeded UUID and timestamp. Measured at HEAD with no source change: `157 insertions(+), 157 deletions(-)`. That churn is inherent to the target, it is committed along with the real diff, and it is not something to strip or investigate. The real diff is the dropped tables.

`sql/test-schema.sql` is a build product of `sql/deploy/*.sql` and `sql/sqitch.plan` (see the `Makefile` rule). Confirm the two tables are gone from it:

Run: `grep -c "payment_schedules" sql/test-schema.sql`
Expected: `0`.

Then confirm the dump is a dump and not an empty file: `grep -c "CREATE TABLE registry.payments" sql/test-schema.sql`, expected `1`. `generate_dump` truncates the target before `pg_dump` writes to it, so a failed dump leaves zero bytes — on which the first grep also returns `0`. Without the second check the gate cannot tell "tables dropped" from "dump destroyed", and committing an empty `test-schema.sql` silently moves every later test onto the slow sqitch-deploy path.

- [ ] **Step 12: Run the migration tests, including the harness**

Run: `carton exec prove -lv t/database/`
Expected: **`Files=2, Tests=6`**, and `revert-round-trip.t` must print `ok 3 - drop-installment-schedules reverts cleanly`. **If it prints `Tests=5`, Step 1's `@CHANGES` append was missed** — and "All tests successful" is what you get either way, so read the count, not the verdict.

That one line is load-bearing. Measured: a deploy that drops from `registry` and omits the tenant loop — a plausible slip on a 26-line script — leaves both tables standing in every tenant schema, and `migration-verification.t` stays green because a migration-only database has no tenant schema to look at. `revert-round-trip.t` is the only thing in the tree that catches it, and it catches nothing at all if the append was skipped.

What it catches: a missing column, a wrong type or default, a missing index, a constraint whose `pg_get_constraintdef` text differs, a missing trigger, a missing comment. Column *order* it does not — the comparison is over sorted lines. The tenant half is graded too: the harness provisions a `clone_schema` tenant before the first dump (Task 1 Step 1), so a tenant schema left without its copies, left without the two `updated_at` triggers, or given its copies twice all fail here rather than in production. Three of them, in fact — this is the third entry on `@CHANGES` and each earlier iteration's schema is still standing, so the tenant loop below is exercised against `"order"`, `"user"` and `"group"` in the same run.

- [ ] **Step 13: Run the isolation test and the DAO suite**

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/dao/tenant-payment-schema-isolation.t`
Expected: PASS with **two** fewer subtests — both migration-replay subtests go, not just the schedule-guard one. The file has four `subtest` blocks before the cut (`:42,52,125,170`); the two structural ones (`:42,52`) and the `#237` behavioural block at the end all still run.

Run: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/dao/ t/integration/`
Expected: PASS.

- [ ] **Step 14: Commit**

```bash
git add sql/deploy/drop-installment-schedules.sql sql/revert/drop-installment-schedules.sql \
        sql/verify/drop-installment-schedules.sql sql/sqitch.plan sql/test-schema.sql \
        sql/verify/installment-payment-schedules.sql sql/verify/simplify-installment-schema-for-stripe.sql \
        sql/verify/schedule-amounts-cents.sql sql/verify/tenant-scoped-payments.sql \
        t/database/revert-round-trip.t t/dao/tenant-payment-schema-isolation.t \
        docs/operations/sacp-stripe-connect-onboarding.md
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
against the live test database, so both of its migration subtests died with the
tables. Opens a coverage gap: that migration's row-move path is now untested.

The change is added to revert-round-trip.t's list, so its revert is graded --
including the tenant half, against a clone_schema-provisioned schema."
```

- [ ] **Step 15: Close the two installment issues as won't-do**

Spec `:2802-2803`: *"Close #295 and #279 as won't-do."* Both are installment issues, and this is the commit that finishes removing installments — the code went in Task 2, the tables here. Do it now rather than at the end of the leg, while the evidence is in the commit you just wrote.

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
- Produces: no active **platform-offered** `pricing_relationships` row offers a *tenant-scoped* `hybrid` plan — the platform signup menu has no hybrid entry. A reseller-offered tenant-scoped hybrid stays active on purpose; Step 3 is the argument, and the `provider_id` condition is what keeps it. Customer-scoped hybrid plans, which tenants author for their own programs, are out of scope here — and not because a later leg resolves them: spec `:1070` marks hybrid *collection* deferred for the whole milestone, and spec `:609-611` says "**Authoring a hybrid is therefore refused at publish**, by the same CHECK that owns the kind rules, until the handler exists". Leg 4 migrates such a plan to a v1 that Leg 6's publish CHECK then refuses (spec `:625-630`). Nothing in this leg or any later one makes one collectable. This change is not on Task 1's `@CHANGES`; it carries `t/database/retire-registry-plus-plan.t` instead.

**Every `sql/test-schema.sql` line number in this task is a HEAD number, and Task 6 already moved them.** Task 6 Step 11 regenerates the dump after dropping both installment tables, which removes the `payment_schedules` TABLE block (`:1136-1173`, 38 lines), the `scheduled_payments` TABLE block (`:1358-1388`, 31), and two 8-line `COPY` blocks. By the time this task runs, `:1204`/`:1215` are `:1166`/`:1177` (−38) and `:2388`/`:2407-2409` are `:2311`/`:2330-2332` (−77). Nothing here reads the dump by line — Step 8 checks it with `grep -c` — so no instruction breaks; the numbers are for confirming the fixture's premise against HEAD, not for navigating the regenerated file.

**What is being retired:** `sql/deploy/unified-pricing-infrastructure.sql:128-140` seeds a plan named `'Registry Plus - $100/month + 1%'` (`:133`) with `plan_type` and `pricing_model_type` both `'hybrid'` — the column is `pricing_model_type` (`:21-22`), not `pricing_model` — `amount` `100.00`, and `pricing_configuration` (`:138`) `{"monthly_base": 100.00, "percentage": 0.01, "applies_to": "customer_payments"}`. Note `amount` is how the *seed migration* wrote it; by this point in the plan `pricing-plans-amount-cents` has replaced the column with `amount_cents` and the row reads `10000` (`sql/test-schema.sql:2388`). That row is `plan_scope = 'tenant'`; its single `pricing_relationships` row, `status = 'active'`, is at `:2408`. It is the only tenant-scoped hybrid row in the seed — the other two relationships (`:2407`, `:2409`) are Revenue Share and the already-suspended Standard.

**Why it has to go, stated accurately.** It is tempting to say nothing can price a hybrid plan. That is false, and the truth is worse. `revenue_share_fraction_for_tenant` (`lib/Registry/PriceOps/RevenueShare.pm:31-41`) resolves a tenant's rate from `p.pricing_configuration->>'percentage'` alone — it never reads `plan_type` or `pricing_model_type` — so a tenant subscribed to Plus would have the `0.01` picked up and 1% charged on every customer payment, through `Payment.pm:91`. What no code collects is the other half: `"monthly_base": 100.00` / `amount_cents = 10000`. Nothing in the tree bills a recurring platform base fee off a `pricing_plans` row. So an active Plus offer is not a plan that cannot bill; it is a plan that bills *half* — Registry would silently under-collect $100/month for every tenant that picked it. That is the defect this change closes.

Nothing reads `plan_type = 'hybrid'` on the billing path either, which is why the fix is retirement rather than implementation: the live branches key on `pricing_model_type` (`PriceOps/PricingRelationships.pm:254,282`, `PriceOps/UnifiedPricingEngine.pm:170,177,187`), and the only `plan_type` readers that **branch** on it are `PriceOps/PricingPlan.pm:99,110,129,171` (deleted by Task 3) and `DAO/PricingPlan.pm:154,170,182`, which **this leg** leaves alone — spec `:431-434` names `:154,170` as "the branch that goes" when `plan_type` is dropped, so they do not outlive the milestone either. `PricingPlanSelection.pm:99` passes the value through without testing it. None of them compares against `'hybrid'`, which is what this argument needs.

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

**Run this first, and keep its output with the rest.** The query below expects *zero rows*, so a `current_database()` column in it would prove nothing — no rows, no evidence. This one always returns a row:

```sql
SELECT current_database() AS db, count(*) AS tenants FROM registry.tenants;
```

Expected: `db` is the production database name, and `tenants` is non-zero. If `db` is a local or ephemeral name, stop — everything below is being asked of the wrong database, and both of the counts below return the answer you are hoping for whichever database answers them.

```sql
SELECT t.slug, t.name, pp.plan_name, pp.plan_scope,
       EXISTS (
           SELECT 1
             FROM registry.pricing_relationships pr
            WHERE pr.pricing_plan_id = pp.id
              AND pr.provider_id     = '00000000-0000-0000-0000-000000000000'
              AND pr.status          = 'active'
       ) AS platform_offered
  FROM registry.tenants t
  JOIN registry.pricing_plans pp ON pp.id = t.platform_pricing_plan_id
 WHERE pp.plan_type = 'hybrid';
```

Expected: zero rows. Filter on `plan_type` only and select the other two, so this stays broader than the migration's own guard and you see everything the guard would hide. Read the result by the two selected columns:

| `plan_scope` | `platform_offered` | What it means |
| --- | --- | --- |
| `tenant` | `t` | A tenant is subscribed to Plus. **Stop and report to perigrin before continuing** — the Step 3 pre-flight will abort the deploy on exactly this row, and Leg 1 has no migration path off it. |
| `tenant` | `f` | A tenant bought Registry through a reseller. Outside the predicate; the deploy proceeds. Report it anyway — the billing path collects the reseller's percentage and none of the base fee. |
| `customer` | either | A tenant has been sold a hybrid plan for its own programs. Outside the predicate; does not block. Worth reporting: the billing path cannot price it. |

Then, for context on what the `UPDATE` will touch, list the menu rows:

```sql
SELECT current_database() AS db,
       pr.id, pr.status, pr.provider_id, pp.plan_name, pp.plan_scope
  FROM registry.pricing_relationships pr
  JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
 WHERE pp.plan_type = 'hybrid';
```

Expected: one `active` row, `plan_name = 'Registry Plus - $100/month + 1%'`, `plan_scope = 'tenant'`, `provider_id = 00000000-0000-0000-0000-000000000000`. Only rows matching all three go into the `UPDATE`. A row with `plan_scope = 'customer'`, or with any other `provider_id`, is a tenant's own plan and must **not** be suspended — see Step 3.

Read-only queries only. Do not deploy anything to production from this task.

- [ ] **Step 2: Add the change**

```bash
carton exec sqitch add retire-registry-plus-plan \
  --requires suspend-rateless-tenant-plans \
  --note 'Stop offering the seeded Registry Plus hybrid plan'
```

`--note`, not `-n`, for the reason given under Task 6 Step 1: `carton` swallows `-n` as an abbreviation of its own `--noverbose`.

- [ ] **Step 3: Write the deploy script**

**`plan_type = 'hybrid'` alone is not a safe predicate — it must be paired with `plan_scope = 'tenant'`,** exactly as `suspend-rateless-tenant-plans.sql:29` pairs them. `plan_scope` defaults to `'customer'` (`sql/deploy/unified-pricing-infrastructure.sql:17-18`), and a tenant authoring a plan through the pricing workflow picks both fields: `lib/Registry/DAO/WorkflowSteps/PricingPlanBasics.pm:76-81` offers `hybrid` in the plan-type list and `:88-92` lets the same author set any `plan_scope`. So a customer-scoped hybrid plan is a thing a tenant can create in the product, today, and it is not what this change retires — the seeded Plus row is `plan_scope = 'tenant'` (`sql/deploy/unified-pricing-infrastructure.sql:128-140`). Without the guard this migration reaches into a tenant's own pricing and suspends it.

**`plan_scope = 'tenant'` is still not enough, and this is the subtler half.** A *tenant*-scoped hybrid plan is equally a thing a tenant can create — `PricingPlanBasics.pm:88-92` offers `tenant` to every plan author with the description *"For other organizations using your platform"*, and `ReviewActivatePlan.pm:102` persists the choice verbatim. That is the reseller case, and it lands squarely inside the two-column predicate. What the change actually means to retire is one entry on **the platform's own signup menu**, and that menu is defined by three filters, not two: `PricingPlanSelection.pm:85-86,93` selects relationships with `provider_id => PLATFORM_UUID` and `status => 'active'`, then keeps only plans whose `plan_scope eq 'tenant'`. `PLATFORM_UUID` is `'00000000-0000-0000-0000-000000000000'` (`:14`), and it is private to that file — `PriceOps::PricingRelationships::create` passes `provider_id => $provider` straight through (`:76-77`) from a free parameter, so a reseller's B2B relationship carries the reseller's id.

Hence the third condition, `pr.provider_id = '00000000-0000-0000-0000-000000000000'`, in all three places that carry the predicate: the deploy's pre-flight `DO` block, the deploy's `UPDATE`, and the verify. Three, not two — a pre-flight that stays broad while the `UPDATE` narrows is a check that aborts the deploy over a row the change never touches, and the operator has no way to satisfy it. This was reproduced, not reasoned: with only the two guards, a planted B2B relationship whose provider is an ordinary tenant comes back `status = 'suspended'` stamped `suspended_by_migration` after `sqitch deploy`, and the verify then fails permanently red — the exact failure mode the `plan_scope` guard was added to prevent, on the axis it did not cover.

Note this narrows the predicate; it does not widen it. Switching to `pricing_model_type = 'hybrid'` was considered and rejected in an earlier round because Registry's own Studio and Empire tiers are `plan_type => 'standard', pricing_model_type => 'hybrid', plan_scope => 'tenant'` (`t/controller/tenant-pricing-display.t:80-84,109-113`) and would be suspended by it. Adding `provider_id` leaves them untouched — they are `plan_type = 'standard'` and never enter the predicate at all.

Overwrite `sql/deploy/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Stop offering the seeded Registry Plus hybrid plan.
-- ABOUTME: Its 1% is charged but its $100/month base is collected by nothing.

-- Deploy registry:retire-registry-plus-plan to pg
-- requires: suspend-rateless-tenant-plans

BEGIN;

SET client_min_messages = 'warning';

-- Step 1's production count is a pre-flight, and a pre-flight is a time-of-check
-- window: signup is open, and a tenant can subscribe between running the query
-- and running this migration.  Re-assert it inside the transaction that does the
-- work, the way tenant-scoped-payments.sql:116-124 does.  Suspending the offer a
-- tenant is actively billed on is not a safe deletion.
--
-- The EXISTS narrows this to plans the UPDATE below will actually suspend.  A
-- pre-flight wider than the statement it guards aborts the deploy over a row the
-- change never touches: a tenant buying Registry through a reseller has a
-- tenant-scoped hybrid plan as its platform plan, that plan's offer belongs to
-- the reseller, and no edit to this file short of deleting the check would let
-- the deploy through.  Guard what you are about to change, not what it resembles.
DO $$
DECLARE
    subscribed text;
BEGIN
    SELECT string_agg(t.slug, ', ')
      INTO subscribed
      FROM registry.tenants t
      JOIN registry.pricing_plans pp ON pp.id = t.platform_pricing_plan_id
     WHERE pp.plan_type  = 'hybrid'
       AND pp.plan_scope = 'tenant'
       AND EXISTS (
           SELECT 1
             FROM registry.pricing_relationships pr
            WHERE pr.pricing_plan_id = pp.id
              AND pr.provider_id     = '00000000-0000-0000-0000-000000000000'
              AND pr.status          = 'active'
       );

    IF subscribed IS NOT NULL THEN
        RAISE EXCEPTION
            'retire-registry-plus-plan pre-flight FAILED: tenants [%] are '
            'subscribed to a tenant-scoped hybrid plan.  '
            'Migrate them off it before retiring the offer.', subscribed
        USING ERRCODE = 'integrity_constraint_violation';
    END IF;
END $$;

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
   AND pr.provider_id = '00000000-0000-0000-0000-000000000000'
   AND pr.status = 'active';

COMMIT;
```

- [ ] **Step 4: Write the revert script**

**The stamp is a handle, not a licence.** `metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'` says *this change is the one that suspended the row* — it does not say the row is still suspended. An operator who cancels a suspended relationship afterwards leaves the stamp in place, and an unconditional `SET status = 'active'` would resurrect it into the signup menu on the next revert. Add `AND status = 'suspended'`: revert what this change did, to rows still in the state it left them.

The cost of that narrowing is a stamp with no owner: a row cancelled after suspension keeps `suspended_by_migration` forever, because the revert now skips it and nothing else ever strips the key. That is deliberate, not an oversight to fix later. The stamp is inert — the deploy only writes rows at `status = 'active'`, so a cancelled row is never re-stamped and never double-counted, and the key is descriptive history rather than live state. Do not add a cleanup pass; a second `UPDATE` that strips the stamp from non-suspended rows would erase the only record of why they were suspended in the first place.

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

**It must not strand at Leg 9b.** Spec `:3856-3861` enumerates nine verify scripts that read `pricing_relationships`, `plan_scope` or `plan_type` and are all superseded when Leg 9b drops them; `:3863` puts the total at sixteen files. A verify written here that reads all three joins that list as a tenth. Guard the body and it goes vacuous rather than red when they are gone, which is what the ABOUTME already claims.

**The table guard alone is not enough.** Spec `:3854-3855` says Leg 9b drops *"`plan_scope`/`plan_type`/`pricing_configuration`, `pricing_relationships`, `billing_periods`…"* — three columns of `pricing_plans` as well as the table. `to_regclass('registry.pricing_relationships')` only covers the table. If Leg 9b drops the columns in a different change from the table, there is a plan point where `pricing_relationships` still exists and `pp.plan_type` does not, and this verify fails with `column pp.plan_type does not exist` at exactly the moment it is supposed to be going quiet. Leg 9b's internal change ordering is not this plan's to fix, so guard against both and stop caring what order it picks.

Overwrite `sql/verify/retire-registry-plus-plan.sql`:

```sql
-- ABOUTME: Verify no active platform-offered relationship offers a tenant-scoped hybrid plan.
-- ABOUTME: True at this point in the plan and at the end of it, including after Leg 9b.

-- Verify registry:retire-registry-plus-plan on pg

BEGIN;

DO $$
BEGIN
    -- Leg 9b drops pricing_relationships AND pricing_plans.plan_type/plan_scope
    -- (spec :3854-3855).  Every verify runs again against the final schema
    -- (t/database/migration-verification.t:26), so this one goes vacuous instead
    -- of erroring.  Check the columns as well as the table: if Leg 9b drops them
    -- in separate changes, there is a point where the table is still here and the
    -- columns are not, and a table-only guard fails there.
    IF to_regclass('registry.pricing_relationships') IS NULL
       OR NOT EXISTS (
           SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'registry'
              AND table_name   = 'pricing_plans'
              AND column_name IN ('plan_type', 'plan_scope')
            HAVING count(*) = 2
       )
    THEN
        RETURN;
    END IF;

    -- All three conditions match the deploy, and all three are load-bearing.
    -- Drop plan_scope and this asserts no tenant ever authors a customer-scoped
    -- hybrid plan; drop provider_id and it asserts no tenant ever resells a
    -- tenant-scoped one.  Either is an assertion a tenant can falsify from the
    -- product, turning CI permanently red with no code change that fixes it.
    IF EXISTS (
        SELECT 1
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
         WHERE pp.plan_type   = 'hybrid'
           AND pp.plan_scope  = 'tenant'
           AND pr.provider_id = '00000000-0000-0000-0000-000000000000'
           AND pr.status      = 'active'
    ) THEN
        RAISE EXCEPTION 'the platform still offers a tenant-scoped hybrid pricing plan on an active relationship';
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
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

# Deploy up to this change's parent so fixtures can be planted before it runs.
# 'NAME^' is sqitch's one-before offset.  Naming the change under test rather
# than whichever change happens to precede it keeps this correct when a later
# leg appends to the plan.  lives_ok, not a bare run: App::Sqitch->run dies on
# a non-zero exit, and an unwrapped die reports as 'test exited with 2' rather
# than naming the step that broke.  t/database/migration-verification.t:40 uses
# the same wrapper for the same reason.
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan^' ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

# Every fixture below exists to kill a specific mutation of the three scripts.
# The table in the prose above says which.  Do not drop one without checking it.

# A customer-scoped hybrid plan is something a tenant can author through
# PricingPlanBasics.  The migration must leave it alone.
my $customer_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type)
      VALUES ('Tenant-authored hybrid', 'hybrid', 'hybrid')
      RETURNING id}
)->hash->{id};

# A tenant-scoped hybrid plan, but offered by a reseller rather than by the
# platform.  PricingPlanBasics.pm:88-92 lets any author pick 'tenant', and
# PriceOps::PricingRelationships::create passes provider_id straight through,
# so this row is reachable from the product.  It is outside the platform's
# signup menu and must survive.
my $b2b_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type, plan_scope)
      VALUES ('Reseller tenant-scoped hybrid', 'hybrid', 'hybrid', 'tenant')
      RETURNING id}
)->hash->{id};

# The Studio/Empire shape: plan_type 'standard', pricing_model_type 'hybrid'.
# If the predicate ever drifts to pricing_model_type, this row goes dark.
my $standard_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type, plan_scope)
      VALUES ('Studio-shaped tier', 'standard', 'hybrid', 'tenant')
      RETURNING id}
)->hash->{id};

# The seeded Plus plan -- the one thing this change exists to retire.  Find it
# by the migration's own predicate rather than by name or by hard-coded id.
my $plus_plan_id = $db->query(
    q{SELECT pp.id FROM registry.pricing_plans pp
        JOIN registry.pricing_relationships pr ON pr.pricing_plan_id = pp.id
       WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = 'tenant'
         AND pr.provider_id = ? AND pr.status = 'active'
       LIMIT 1}, PLATFORM_UUID
)->hash->{id};
ok $plus_plan_id, 'the seed still contains a platform-offered tenant-scoped hybrid plan';

# A reseller tenant, so a relationship can carry a provider that is not the
# platform.  Created outright rather than found, so the fixture does not depend
# on which other tenants the seed happens to contain.
my $reseller_id = $db->query(
    q{INSERT INTO registry.tenants (name, slug) VALUES ('Reseller Fixture', 'reseller_fixture')
      RETURNING id}
)->hash->{id};

# provider_id references tenants(id) and consumer_id references users(id)
# (consolidate-pricing-relationships.sql:12-13), so consumer_id is copied off a
# seeded row rather than inventing a user.  provider defaults to the platform.
sub plant_relationship ($plan_id, %opt) {
    # exists, not //: `metadata => undef` is the whole point of one caller below,
    # and `$opt{metadata} // '{}'` would silently turn that NULL into '{}' and
    # leave the COALESCE mutation alive.  Defaulting an explicit undef away is
    # the bug this fixture exists to catch.
    my $metadata = exists $opt{metadata} ? $opt{metadata} : '{}';
    return $db->query(
        q{INSERT INTO registry.pricing_relationships
              (provider_id, consumer_id, pricing_plan_id, status, metadata)
          SELECT ?, consumer_id, ?, 'active', ?::jsonb
            FROM registry.pricing_relationships
           ORDER BY id LIMIT 1
          RETURNING id},
        $opt{provider} // PLATFORM_UUID, $plan_id, $metadata
    )->hash->{id};
}

my $customer_rel_id = plant_relationship($customer_plan_id);
my $standard_rel_id = plant_relationship($standard_plan_id);
my $b2b_rel_id      = plant_relationship( $b2b_plan_id, provider => $reseller_id );

# Squarely inside the predicate, but with metadata explicitly NULL.  Without
# COALESCE in the deploy, `NULL || '{...}'::jsonb` is NULL, so this row would be
# suspended without a stamp and the revert could never find it again.
my $null_meta_rel_id = plant_relationship( $plus_plan_id, metadata => undef );

# A platform offer on the retired plan that an operator has already cancelled.
# `AND pr.status = 'active'` in the deploy is the only thing keeping it out, and
# without this fixture nothing tests that: every other relationship inside the
# three-column predicate is already active at this point in the plan, so deleting
# the condition changes nothing observable.  With it, the deploy suspends and
# stamps a cancelled row and the revert then resurrects it as active.
my $cancelled_rel_id = plant_relationship($plus_plan_id);
$db->query( q{UPDATE registry.pricing_relationships SET status = 'cancelled' WHERE id = ?},
    $cancelled_rel_id );

sub rel_status ($id) {
    return $db->query( q{SELECT status FROM registry.pricing_relationships WHERE id = ?}, $id )
        ->hash->{status};
}

sub retired_ids {
    return $db->query(
        q{SELECT pr.id FROM registry.pricing_relationships pr
            JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
           WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = 'tenant'
             AND pr.provider_id = ? AND pr.status = 'active'
           ORDER BY pr.id}, PLATFORM_UUID
    )->arrays->flatten->to_array;
}

sub stamped_ids {
    return $db->query(
        q{SELECT id FROM registry.pricing_relationships
           WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
           ORDER BY id}
    )->arrays->flatten->to_array;
}

my $before = retired_ids();
ok scalar @$before >= 2,
    'the platform offers the seeded tenant-scoped hybrid plan plus the NULL-metadata fixture';

# --- the in-transaction pre-flight -------------------------------------------
# Subscribe a tenant to the plan about to be retired.  The deploy must refuse,
# and must leave no trace: no suspended rows, no sqitch.changes entry.
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = 'registry'},
    $plus_plan_id );

dies_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' ) }
    'the deploy refuses to run while a tenant is subscribed to the plan';
is_deeply retired_ids(), $before,
    'the refused deploy suspended nothing';
is $db->query( q{SELECT count(*) FROM sqitch.changes WHERE change = 'retire-registry-plus-plan'} )
      ->array->[0], 0,
    'the refused deploy recorded no change';

$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = 'registry'} );

# A tenant buying Registry through a reseller: its platform plan is a
# tenant-scoped hybrid plan, so it matches the pre-flight's first two conditions
# and only the EXISTS keeps it out.  Left set for the rest of the run -- the
# deploy below has to succeed with this row in place.
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE id = ?},
    $b2b_plan_id, $reseller_id );

# --- the deploy proper -------------------------------------------------------
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' ) }
    'the deploy runs once no tenant is subscribed to a platform-offered one';

is_deeply retired_ids(), [],
    'no active platform relationship offers a tenant-scoped hybrid plan';
is_deeply stamped_ids(), $before,
    'the change stamped exactly the rows it suspended';
is rel_status($customer_rel_id), 'active',
    'a tenant-authored customer-scoped hybrid plan is left active';
is rel_status($b2b_rel_id), 'active',
    "a reseller's own tenant-scoped hybrid offer is left active";
is rel_status($standard_rel_id), 'active',
    'a standard plan with pricing_model_type hybrid is left active';
ok scalar( grep { $_ eq $null_meta_rel_id } @{ stamped_ids() } ),
    'a row whose metadata was NULL comes back stamped, not NULL';
is rel_status($cancelled_rel_id), 'cancelled',
    'a relationship already cancelled on the retired plan is left cancelled';

# --- the revert --------------------------------------------------------------
# A row this change suspended, then cancelled by a human afterwards.  The
# revert's status guard must leave it cancelled: the stamp is a handle for
# finding the row, not a licence to overwrite whatever it says now.
$db->query( q{UPDATE registry.pricing_relationships SET status = 'cancelled' WHERE id = ?},
    $before->[0] );

lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'retire-registry-plus-plan^', '-y' ) }
    'the revert runs';

is rel_status( $before->[0] ), 'cancelled',
    'the revert does not resurrect a row cancelled after suspension';
is_deeply retired_ids(), [ grep { $_ ne $before->[0] } @$before ],
    'reverting re-activates every row the change suspended and no other';
# Not [] -- the cancelled row keeps its stamp, because the revert's status guard
# skips it and nothing else strips the key.  Step 4 says why that is deliberate.
# Asserting [] here would quietly re-introduce the resurrection bug: the only way
# to make it true is to drop the guard.
is_deeply stamped_ids(), [ $before->[0] ],
    'reverting strips the stamp from every row it re-activated, and only those';

done_testing;
```

**`$cancelled_rel_id` is the one fixture that was added by mutation-testing this table rather than the scripts.** An earlier draft claimed the `AND pr.status = 'active'` row was killed because "the stamp set is compared by id, not by count". That was wrong, and it was measured: with the deploy's `AND pr.status = 'active'` removed, the whole file still passed. Every relationship inside the three-column predicate is already `active` at this point in the plan — the only seeded suspended relationship is `sql/test-schema.sql:2409`, whose plan is `Registry Standard - $200/month`, `plan_type = subscription` (`:2387`), which never enters the predicate — so the condition had nothing to exclude and deleting it changed nothing observable. That left Step 4's whole argument ("the deploy only writes rows at `status = 'active'`, so a cancelled row is never re-stamped") resting on the one guard the suite did not grade. With the fixture, the same mutation fails assertions 9, 14 and 17, and 17 is the resurrection the guard exists to prevent.

**Why the fixture block is this long.** Every one of these rows kills a mutation that the shorter version left alive. Mutation-testing the three scripts against the earlier six-assertion test caught 3 of 10; the two guards this task argues hardest for — the pre-flight `DO` block and the revert's `AND status = 'suspended'` — could both be deleted outright with the suite still green. That is the #296 shape again, one level up: the test passed, so the guards read as covered.

| Mutation | Old test | Fixture that now kills it |
| --- | --- | --- |
| deploy's whole pre-flight `DO` block deleted | green | the `platform_pricing_plan_id` subscriber + `dies_ok` |
| pre-flight drops its `EXISTS` narrowing | n/a | the reseller tenant left on `$b2b_plan_id` across the successful deploy |
| revert drops `AND status = 'suspended'` | green | `$before->[0]` cancelled after suspension |
| deploy drops `COALESCE(pr.metadata, ...)` | green | `$null_meta_rel_id` |
| deploy drops `AND pr.status = 'active'` | green | `$cancelled_rel_id` — **and nothing else does** |
| deploy's `plan_type` → `pricing_model_type` | green | `$standard_rel_id` (Studio shape) |
| deploy drops `AND pr.provider_id = ...` | n/a | `$b2b_rel_id` |
| deploy drops `AND pp.plan_scope = 'tenant'` | caught | `$customer_rel_id` |
| verify drops `AND pp.plan_scope = 'tenant'` | caught | `$customer_rel_id` |
| revert drops the `metadata - 'suspended_by_migration'` | caught | `stamped_ids()` after revert |

The `deploy made a no-op` sanity mutation fails the first assertion, which confirms the harness can fail at all — a mutation table is worthless without that control.

- [ ] **Step 7: Run the new test and watch the first assertion**

**This test writes four diagnostics to stderr on a green run — five lines with the blank — and they are expected.** The `dies_ok` pre-flight probe makes sqitch fail a deploy on purpose, so psql reports the `RAISE EXCEPTION` on stderr while stdout stays clean TAP:

```
psql:sql/deploy/retire-registry-plus-plan.sql:48: ERROR:  retire-registry-plus-plan pre-flight FAILED: tenants [registry] are subscribed to a tenant-scoped hybrid plan.  Migrate them off it before retiring the offer.
CONTEXT:  PL/pgSQL function inline_code_block line 20 at RAISE
"psql" unexpectedly returned exit value 3

Deploy failed
```

That is the probe working. This leg introduces it, so it is not on the known-pristine-output exception list, and Step 10's full-suite run must not read it as a violation — the rule is about *unexpected* diagnostics, and this one is asserted on.

Run: `carton exec prove -lv t/database/retire-registry-plus-plan.t`
Expected: PASS, eighteen assertions. **The load-bearing ones are the two preconditions — `ok $plus_plan_id` and `ok scalar @$before >= 2` — and they sit ahead of every assertion about the change itself for that reason.** `ok $plus_plan_id` fails if the seed no longer contains a platform-offered tenant-scoped hybrid plan, and every fixture below it is planted against that id, so nothing after it means anything once it goes. `ok scalar @$before >= 2` then fails if the seeded row and the NULL-metadata fixture are not both inside the predicate. Either failure means the seed data changed and this plan's premise needs rechecking, not that the test needs loosening — an empty `$before` would let every later assertion pass vacuously against an empty set, which is why both are asserted rather than assumed.

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

This is the end of Leg 1, so the whole tree gets checked once.

**Not `prove -lr t/`.** That would run `t/stripe-live/` and `t/playwright/`, which the Global Constraints forbid, and there is no `.proverc` to exclude them. Name the directories:

Run:
```bash
STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr -j8 \
  t/auth t/controller t/css t/dao t/database t/e2e t/frontend t/integration \
  t/job t/priceops t/robustness t/security t/seed t/service t/unit \
  t/user-journeys t/workflow
```

That is every directory under `t/` except the two forbidden ones and `t/lib` and `t/fixtures`, which hold no `.t` files. Measured: `Files=252, Tests=2249, 1011 wallclock secs, Result: PASS` on 24 cores with `-j8`. Serially it is closer to 100 minutes than the 76 an earlier draft claimed — the estimate was never measured and `-j` is what makes this step reasonable.

Expected: 100% pass, pristine output.

Known pre-existing pristine-output violations that are **not** this leg's to fix (do not silence them, and do not let them be mistaken for regressions), measured on a green run of the command above and reproduced at HEAD in an untouched worktree: `Wide character in print at .../Test2/Formatter/TAP.pm line 156` ×6 (`t/integration/utf8-workflows.t`); `Use of uninitialized value in concatenation (.) or string at lib/Registry/DAO/Payment.pm line 536` ×2 (`t/dao/payment-free-by-total.t`, `t/dao/payment-idempotency.t` — a file no task here touches); `Error creating Registry::DAO::User: … duplicate key value violates unique constraint "users_username_key"` ×2 (`t/robustness/db-constraints.t:36`, `t/controller/camp-registration-errors.t`); the `MOJO_SECRET not set` warning, an SMTP failure diagnostic, and an uninitialized-value warning from `lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm:71`.

- [ ] **Step 11: Commit**

```bash
git add sql/deploy/retire-registry-plus-plan.sql sql/revert/retire-registry-plus-plan.sql \
        sql/verify/retire-registry-plus-plan.sql sql/sqitch.plan sql/test-schema.sql \
        t/database/retire-registry-plus-plan.t
# NOTE: this message contains `$100`, and `git commit -m "..."` in double quotes
# lets the shell expand `$1` -- which is unset, so the message silently becomes
# "00/month". Measured. Write it to a file and use -F, or single-quote it.
git commit -F - <<'MSG'
Retire the seeded Registry Plus hybrid plan

Its 1% is charged on every customer payment through RevenueShare; nothing
collects the $100/month base. An active relationship offering one is a plan
a tenant can select and Registry bills half of. The change stamps every row it
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
customer-scoped fixture is untouched.
MSG
```

---

## Task Dependency Order

Execute in numeric order. Each arrow is a real dependency, not a preference; where no arrow joins two tasks, the numbering between them is convention.

```
1 (harness) ─────────────────┐
                             ↓
2 (installment code) → 6 (installment tables) → 7 (plan retirement)
        └───────────→ 3 (Stripe client, PriceOps plan) → 4 (discount surface, #296)

5 (seti_test bypass) — independent of everything above
```

There is deliberately no `1 → 2` arrow. Task 1 gates Task 6, the task that ships a migration — not Task 2, which touches no SQL. Task 2's own Interfaces block says it: *"Consumes: nothing from Task 1."*

- Task 1 before Task 6: the migration must land under a harness that already exists and is already proven able to fail.
- Task 2 before Task 6: code that reads a table is deleted before the table is dropped, so no commit leaves a tree that cannot run its own tests.
- Task 6 before Task 7: Task 7's change is appended after Task 6's in `sql/sqitch.plan`.
- Task 2 before Task 3: this one is real, not conventional. Task 3 Step 1's grep is the gate that says both modules are unreferenced, and until Task 2 lands they are both still referenced — `InstallmentPayment.pm:12,78,95,178` names `Registry::PriceOps::PricingPlan`, and `PriceOps/ScheduledPayment.pm:12,18` and `PriceOps/PaymentSchedule.pm:12,19` name `Registry::Client::Stripe`. Run Task 3 first and its own gate fails.
- Task 3 before Task 4: also real. Task 4 Step 6's grep is the gate that says no discount key survives without both a writer and a reader, and six lines match its pattern until Task 3 removes them — `lib/Registry/PriceOps/PricingPlan.pm:100,112,114,130` (Task 3 **Step 2** deletes the file) and `t/dao/pricing-plan-amount-cents.t:147,155` (Task 3 **Step 3** cuts the `:146-167` subtest holding them). Both steps, not one. Run Task 4 first and the gate reports six matches that are not on its table, which reads as a miss.
- Task 5 touches files disjoint from every other task. Its position is convention, not necessity.

## Coverage Gaps This Leg Opens

Named here so they are found by reading, not by an incident. Two are Task 6's and one is Task 5's.

**Webhook deduplication is deliberately not on this list.** An earlier draft had it, and it was wrong. The dedup subtest Task 2 deletes graded the *installment* path, which goes away entirely; dedup on the surviving path is covered today by `t/controller/payment-intent-webhook.t:97` and `:103`. The full argument is in Task 2 — do not re-add it here or write a replacement test for it.

1. **The `tenant-scoped-payments` schedule pre-flight guard is untested** from Task 6 onward. The guard remains deployed and correct; there is simply no longer a table whose rows could trip it. Nothing in the milestone re-creates one.
2. **The `tenant-scoped-payments` row-move path is untested** from Task 6 onward. Task 6 Step 9 deletes the whole migration-replay section of `t/dao/tenant-payment-schema-isolation.t` (`:93-223`) because both of its subtests re-run a `DO` block that names the dropped tables. That block also moved existing rows into the tenant schemas, and nothing else in the tree exercises it. The migration stays deployed; it is the only test of it that goes. This is on the issue list rather than being fixed here — restoring it means writing a fixture for a migration whose tables no longer exist.
3. **`handle_setup_completion` loses its last test entry** from Task 5 onward. `grep -rn handle_setup_completion lib/ t/` finds exactly two call sites — `TenantPayment.pm:44` (the `seti_test` arm Step 3 deletes) and `:50` (the real-setup-intent arm) — the declaration at `:290`, and three comments in the alex journeys. No test calls the method directly. Today the journeys reach it through the `seti_test` POST; after Step 6 they post `collect_payment_method` alone and route to the no-keys branch at `:56-71`. After this leg **nothing enters the method at all**, and it is the first of the four terminal outcomes Task 5's own Interfaces block says later legs need by name. The body below `:308` was already untested; what this leg removes is the last entry to the method. Not fixed here — a test for it needs a real `setup_intent_id`, which means a Stripe object, which is Leg 8's ground. On the issue list.

## Self-Review

**Spec coverage.** Every item in the spec's Leg 1 row (`:2964`) maps to a task: installments → 2; `Client::Stripe` and `PriceOps/PricingPlan.pm` → 3; misfiled tests → 2 (spec `:2813-2816` names two — `t/e2e/installment-payment-enrollment.t` and `t/controller/admin-installment-payment-dashboard.t`, "both DAO CRUD misfiled under names" — installment tests, so they go with the installment deletion, not with the discount surface); `Family::sibling_discount_eligible`, #296, discount form → 4; `seti_test` signup bypass → 5; the Registry Plus retirement → 7; the sqitch change dropping both tables with its verify and revert, the four stranded verify scripts, and `t/dao/tenant-payment-schema-isolation.t` → 6; the revert-test harness → 1. Four items the spec's row does not name are covered anyway: the three `seti_test` test consumers (Task 5), `review-activate.html.ep:163-186` (Task 4), `schemas/requirements-and-rules.json:76-100` (Task 4 Step 5b — the outcome definition bound to the edited step, which the spec never considers as a surface), and `t/dao/pricing-plan-workflow.t:216-222,242` (Task 4) — where `:216-222` are seven discount keys posted *into* `RequirementsRules->process`, not assertions, and `:242` is the single assertion that reads one back (`early_bird_discount`). The word `sibling` does not appear in that file at all.

**Placeholders.** None. Every code step carries the actual Perl or SQL. Every line range was read before being cited.

**Type consistency.** The sqitch change name `drop-installment-schedules` is used identically everywhere it appears: Task 6's creation, deploy header, revert header, verify header, `@CHANGES` append and commit. Task 7 names it only in its Interfaces prose, never in a script or test — its test addresses the change under test as `retire-registry-plus-plan^`, so appending a change later cannot silently retarget it. `Test::Registry::DB::_find_pg_tool` is called with the same single-string signature the definition takes at `t/lib/Test/Registry/DB.pm:23`. The `suspended_by_migration` metadata key is spelled the same in Task 7's deploy, revert, verify and test, and matches the deployed `suspend-rateless-tenant-plans` (`:24`) it deliberately shares a namespace with.
