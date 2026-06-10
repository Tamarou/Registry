# MVP Stripe Connect + Tenant-Scoped Payments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tenant parents can pay for enrollment; tuition settles into the tenant's own Stripe (Standard) connected account via destination charges with a 2.5% application fee, and payment data lives in the tenant schema.

**Architecture:** Move the tenant-scoped payment tables (`payments`, `payment_items`, `payment_schedules`, `scheduled_payments`) out of `registry.`-qualified SQL so the connection `search_path` governs (the PricingPlan fix generalized); add Connect account + readiness columns to `registry.tenants`; gate paid enrollment on readiness; create PaymentIntents as destination charges; rewrite the `payment_intent.succeeded` webhook to find/finalize on the tenant connection; refresh readiness from `account.updated`.

**Tech Stack:** Perl 5.42 + Object::Pad, Mojolicious, Mojo::Pg (schema-per-tenant), Sqitch migrations, Stripe API via `Registry::Service::Stripe` (form-encoded, bracket-notation params), Minion.

**Spec:** `docs/superpowers/specs/2026-06-09-mvp-connect-tenant-payments-design.md` (same branch). Read it first.

**Branch / worktree:** `fix/tenant-payment-routing` in `/home/perigrin/dev/Registry/.claude/worktrees/lifecycle` (already rebased onto main as of 2026-06-10).

---

## Project conventions you must follow

- Read `CLAUDE.md` (repo root) and follow it. Highlights: strict TDD (RED before GREEN, run the test and show it failing), 100% pass rate, pristine output, Object::Pad (`method` gets implicit `$self`; `field $x :param :reader`), never `--no-verify`, never a live `sk_live_` key in tests.
- Test commands: `carton exec prove -lv t/path/to/test.t` (single), `carton exec prove -lr t/dao/` (suite). Always `-l`.
- Workflow tests need `carton exec ./registry workflow import registry` first.
- Sqitch: plan file is `sql/sqitch.plan`; every change needs `sql/deploy/X.sql`, `sql/revert/X.sql`, `sql/verify/X.sql`. Validate with a scratch DB: `createdb registry_migtest && carton exec sqitch deploy db:pg:///registry_migtest && carton exec sqitch revert --to <prev> -y db:pg:///registry_migtest && carton exec sqitch deploy db:pg:///registry_migtest && dropdb registry_migtest`.
- `sql/test-schema.sql` is a **generated** dump that test databases deploy from. Never hand-edit it: after changing `sql/deploy/*.sql`, run `make test-schema` and commit the regenerated dump (see Makefile:3-11; it depends on the deploy scripts and regenerates from a sqitch deploy).
- The per-tenant migration loop pattern (with `quote_ident`) is in `sql/deploy/enrollment-payment-dedup.sql`.
- Multi-tenancy: `Registry::DAO->new(schema => $slug)` sets `search_path = $slug, public` (quoted, via `Mojo::Pg->search_path`, `lib/Registry/DAO.pm:37-39`); `$dao->connect_schema($slug)` returns a re-scoped DAO (`lib/Registry/DAO.pm:92`). `registry.tenants` is platform-scoped and stays `registry.`-qualified everywhere.
- Test DB harness: `t/lib/Test/Registry/DB.pm` (`my $t = Test::Registry::DB->new; my $dao = $t->db;`), fixtures in `t/lib/Test/Registry/Fixtures.pm`, tenant provisioning via `Registry::DAO::Tenant->provision($db, {...})` (copies users via `copy_user`). Reference tests: `t/dao/payment-workflow-step.t` (workflow-step pattern), `t/job/process-waitlist-tenant.t` (tenant-schema assertions), `t/controller/subscription-webhook-routing.t` (webhook controller with Test::MockObject app over a real DAO).
- Stripe param encoding: `Registry::Service::Stripe::_request_async` sends `form => $params` — Mojo does NOT serialize nested hashrefs into Stripe's bracket notation. Params must be pre-flattened: `'metadata[payment_id]' => $id`, `'transfer_data[destination]' => $acct`. See `lib/Registry/DAO/Subscription.pm:27-28,124,169` for the working convention.

## Decisions locked by the spec (do not re-litigate)

- Tenant-scoped DAOs to unqualify: `Payment`, `PaymentSchedule`, `ScheduledPayment` (+ the `payment_items` table they use). Platform-scoped, keep `registry.`-qualified: `PricingRelationship`, `PricingRelationshipEvent`, `BillingPeriod`, `webhook_events`, `tenants`.
- Standard connected accounts, manual SACP onboarding, 2.5% fee via `application_fee_amount` on destination charges, `on_behalf_of` set so the tenant bears Stripe's processing fee.
- Readiness gate: paid enrollment refused unless tenant has `stripe_connect_account_id` AND `stripe_charges_enabled` AND `stripe_details_submitted`. Free ($0) enrollment unaffected.
- Fee rounding (was an open question — decided here): `application_fee_amount = int($amount_cents * 2.5 / 100 + 0.5)` (round half-up, integer cents, same currency as the charge).
- Installments (was an open question — decided here): **MVP is one-time charges only.** Installment/subscription billing stays on the platform account, unchanged, and existing installment tests must stay green. SACP's afterschool launch takes one-time payments. Connect-routed installments are part of the deferred epic (#23/#76). Known dormant asymmetry after Task 4: the webhook's `_is_installment_payment_event` looks up payment schedules on the **registry** connection, so a schedule created on a tenant connection would be invisible to it — harmless today (`InstallmentPayment` is wired into no workflow), captured in Task 9's issue so tenant-installment work doesn't trip it silently.
- `PriceOps::PricingRelationships::_get_usage_data` keeps querying `registry.payments` (empty after the move). This is intentionally correct interim behavior: the 2.5% is now collected at charge time, so the usage computation returning 0 prevents double-collection. Task 9 documents it and files the redesign issue.

## File structure (what changes where)

| File | Responsibility / change |
| --- | --- |
| `sql/deploy|revert|verify/tenant-stripe-connect.sql` (new) | Connect columns on `registry.tenants` |
| `sql/deploy|revert|verify/tenant-scoped-payments.sql` (new) | Backfill payment tables into existing tenant schemas; repoint `enrollments.payment_id` FK tenant-local; move existing tenant payment rows |
| `sql/test-schema.sql` | Lockstep: tenants columns + FK change |
| `lib/Registry/DAO/Tenant.pm` | New fields + `stripe_connect_ready` |
| `lib/Registry/DAO/Payment.pm` | Flatten Stripe metadata; unqualify `payments`/`payment_items`; `REVENUE_SHARE_PERCENT`; Connect params derived inside `create_payment_intent` |
| `lib/Registry/DAO/PaymentSchedule.pm`, `lib/Registry/DAO/ScheduledPayment.pm`, `lib/Registry/PriceOps/ScheduledPayment.pm`, `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm` | Unqualify the four `registry.`-qualified payment-table references |
| `lib/Registry/DAO/WorkflowSteps/Payment.pm` | Readiness gate (Connect params are NOT passed by the step — Task 6 derives them inside `create_payment_intent`) |
| `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` | Use the shared `REVENUE_SHARE_PERCENT` from Payment.pm |
| `lib/Registry/Controller/Webhooks.pm` | Tenant-first `payment_intent.succeeded`; `account.updated` handler |
| `docs/operations/sacp-stripe-connect-onboarding.md` (new) | Manual onboarding runbook |
| Tests | One new test file per task, named below |

---

### Task 1: Fix Stripe param flattening in `Payment::create_payment_intent` (pre-req bug)

The webhook safety net and §4 of the spec depend on `metadata.payment_id` / `metadata.tenant_slug` arriving on the PaymentIntent. Today `create_payment_intent` passes `metadata => { ... }` (a nested hashref) into `form =>` encoding, which Mojo turns into a multipart request with metadata as a file part — the metadata never reaches Stripe. (Verified empirically; the working callers in `Subscription.pm` flatten to `'metadata[key]'`.)

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm` (`create_payment_intent`, ~line 84)
- Test: `t/dao/payment-intent-stripe-params.t` (new)

- [ ] **Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
# ABOUTME: Tests that create_payment_intent sends Stripe params flattened in
# ABOUTME: bracket notation (form encoding cannot serialize nested hashrefs).
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Payment;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

my $user = Test::Registry::Fixtures::create_user($db, {
    username => 'stripe_params_user', user_type => 'parent',
});

my $payment = Registry::DAO::Payment->create($db, {
    user_id  => $user->id,
    amount   => 100.00,
    metadata => { tenant_slug => 'some_tenant', enrollment_items => [] },
});

# Capture exactly what reaches the Stripe client.
my $captured;
{
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent = sub ($self, $params) {
        $captured = $params;
        return { id => 'pi_test_123', client_secret => 'cs_test' };
    };
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
    $payment->create_payment_intent($db, { description => 'Test', receipt_email => 'a@b.c' });
}

ok $captured, 'stripe client received params';
is ref($_), '', "param '$_' is a flat scalar (no nested refs)" for sort keys %$captured;
is $captured->{'metadata[payment_id]'}, $payment->id,
    'payment_id arrives as metadata[payment_id] bracket key';
is $captured->{'metadata[tenant_slug]'}, 'some_tenant',
    'tenant_slug arrives as metadata[tenant_slug] bracket key';
ok !exists $captured->{metadata}, 'no nested metadata hashref remains';

$t->cleanup_test_database;
done_testing;
```

Note: complex metadata values that are themselves refs (e.g. `enrollment_items`, an arrayref) must NOT be sent to Stripe at all — Stripe metadata values are strings. Only flatten scalar values; skip refs. The DB `metadata` column keeps the full structure (that part already works).

- [ ] **Step 2: Run it, confirm RED**

Run: `carton exec prove -lv t/dao/payment-intent-stripe-params.t`
Expected: FAIL — `metadata` key exists as a nested hashref; bracket keys absent.

- [ ] **Step 3: Implement the flattening**

In `lib/Registry/DAO/Payment.pm` `create_payment_intent`, replace the `metadata => {...}` block in the `create_payment_intent` call:

```perl
            # Stripe's API is form-encoded; nested hashes must be flattened to
            # bracket notation (metadata[key]=value). Mojo's form generator
            # would otherwise turn a nested hashref into a bogus multipart
            # upload and the metadata would never reach Stripe. Metadata
            # values must be strings, so refs (e.g. enrollment_items) are
            # snapshotted only in the DB metadata column, not sent to Stripe.
            my %stripe_metadata = (
                user_id    => $user_id,
                payment_id => $self->id,
                ( ref $metadata eq 'HASH'
                    ? ( map { $_ => $metadata->{$_} }
                        grep { defined $metadata->{$_} && !ref $metadata->{$_} }
                        keys %$metadata )
                    : () ),
            );
            $intent = $self->stripe_client->create_payment_intent({
                amount        => _to_cents($amount),
                currency      => $currency,
                description   => $description,
                receipt_email => $receipt_email,
                map { ( "metadata[$_]" => $stripe_metadata{$_} ) } sort keys %stripe_metadata,
            });
```

(Keep the surrounding try/catch and the post-create `stripe_payment_intent_id` update unchanged. `$metadata` is the Object::Pad field — check its accessor/JSON decoding; `$self->metadata` returns the decoded hashref, use whichever the class already uses internally.)

- [ ] **Step 4: Run test, confirm GREEN.** `carton exec prove -lv t/dao/payment-intent-stripe-params.t`
- [ ] **Step 5: Regression:** `carton exec prove -lr t/dao/payments.t t/dao/payment-workflow-step.t t/dao/payment-finalization-idempotency.t` — all pass, pristine.
- [ ] **Step 6: Commit:** `git add -A && git commit -m "Flatten Stripe PaymentIntent params to bracket notation so metadata actually reaches Stripe"`

---

### Task 2: Connect columns on `registry.tenants` + Tenant DAO fields

**Files:**
- Create: `sql/deploy/tenant-stripe-connect.sql`, `sql/revert/tenant-stripe-connect.sql`, `sql/verify/tenant-stripe-connect.sql`
- Modify: `sql/sqitch.plan` (append), `sql/test-schema.sql` (lockstep), `lib/Registry/DAO/Tenant.pm`
- Test: `t/dao/tenant-stripe-connect.t` (new)

- [ ] **Step 1: Write the failing test**

```perl
#!/usr/bin/env perl
# ABOUTME: Tests the tenant Stripe Connect fields and the readiness predicate
# ABOUTME: used to gate paid enrollment on a usable connected account.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Tenant;

my $t   = Test::Registry::DB->new;
my $dao = $t->db;
my $db  = $dao->db;

my $tenant = Registry::DAO::Tenant->create($db, { name => 'Connect Test Org' });

is $tenant->stripe_connect_account_id, undef, 'connected account defaults to undef';
ok !$tenant->stripe_connect_ready, 'not ready with no connected account';

$tenant->update($db, {
    stripe_connect_account_id => 'acct_test123',
    stripe_charges_enabled    => 1,
    stripe_details_submitted  => 0,
});
my $reloaded = Registry::DAO::Tenant->find($db, { id => $tenant->id });
ok !$reloaded->stripe_connect_ready, 'not ready until details_submitted';

$reloaded->update($db, { stripe_details_submitted => 1 });
$reloaded = Registry::DAO::Tenant->find($db, { id => $tenant->id });
ok $reloaded->stripe_connect_ready, 'ready with account + charges_enabled + details_submitted';

$t->cleanup_test_database;
done_testing;
```

- [ ] **Step 2: Run it, confirm RED** (unknown column / no such method).
- [ ] **Step 3: Write the migration**

`sql/deploy/tenant-stripe-connect.sql`:
```sql
-- Deploy registry:tenant-stripe-connect to pg
-- requires: stripe-subscription-integration

BEGIN;
SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Per-tenant Stripe Connect (Standard) account and readiness flags. The
-- booleans mirror the connected account's charges_enabled/details_submitted
-- and are refreshed by the account.updated webhook. Paid enrollment is gated
-- on all three being present/true.
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_connect_account_id TEXT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_charges_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_details_submitted BOOLEAN NOT NULL DEFAULT FALSE;

COMMIT;
```

Revert drops the three columns; verify checks them via `information_schema.columns` (copy the style of `sql/verify/tenant-stripe-connect`'s nearest neighbor, e.g. `sql/verify/stripe-subscription-integration.sql`). Append to `sql/sqitch.plan` following its exact line format. Then regenerate the test dump: `make test-schema` (never hand-edit `sql/test-schema.sql`) and commit it.

- [ ] **Step 4: Add the DAO fields + predicate** in `lib/Registry/DAO/Tenant.pm`:

```perl
    field $stripe_connect_account_id :param :reader = undef;
    field $stripe_charges_enabled    :param :reader = 0;
    field $stripe_details_submitted  :param :reader = 0;

    # A tenant can take paid enrollment only when its connected account exists
    # and Stripe reports it ready to take charges with onboarding complete.
    method stripe_connect_ready {
        return $stripe_connect_account_id
            && $stripe_charges_enabled
            && $stripe_details_submitted ? 1 : 0;
    }
```

- [ ] **Step 5: Run test, confirm GREEN.**
- [ ] **Step 6: Validate the migration on a scratch DB** (deploy → revert → re-deploy, commands in the conventions section). Paste the output.
- [ ] **Step 7: Regression:** `carton exec prove -lr t/dao/tenants.t` (or the existing tenant test file — find it with `ls t/dao/ | grep -i tenant`) plus `t/dao/`.
- [ ] **Step 8: Commit.**

---

### Task 3: Migration — payment tables into tenant schemas, FK repoint, row move

**Files:**
- Create: `sql/deploy/tenant-scoped-payments.sql`, `sql/revert/tenant-scoped-payments.sql`, `sql/verify/tenant-scoped-payments.sql`
- Modify: `sql/sqitch.plan`; regenerate `sql/test-schema.sql` via `make test-schema`
- Test: `t/dao/tenant-payment-schema-isolation.t` (new — written in this task with the Task-4 assertions TODO-marked, fully green at the end of Task 4)

This is the riskiest task. Read `sql/deploy/enrollment-payment-dedup.sql` (per-tenant loop), `sql/deploy/fix-clone-schema-identifier-quoting.sql` (quote_ident discipline), and `sql/deploy/payments.sql` (table shapes) first.

What the deploy script must do, in order:

1. **Backfill tables into every existing tenant schema** (newly provisioned tenants get them via `clone_schema`). For each tenant slug, for each of `payments`, `payment_items`, `payment_schedules`, `scheduled_payments`: if the table does not exist in the tenant schema, `CREATE TABLE <slug>.<table> (LIKE registry.<table> INCLUDING ALL)`, then add the FKs rewritten tenant-local:
   - `payments.user_id REFERENCES users(id)` (tenant-local users — this is the fix for #237's `payments_user_id_fkey`)
   - `payment_items.payment_id REFERENCES payments(id) ON DELETE CASCADE`
   - `scheduled_payments.payment_schedule_id REFERENCES payment_schedules(id)` and any FK to `payments` — **read `sql/deploy/payments.sql` + the installment migrations for the authoritative FK list** (`grep -rn 'REFERENCES registry\.\(payments\|payment_schedules\)' sql/deploy/`) and mirror every one tenant-locally.
   - `payment_schedules`' FKs likewise (check what it references; anything platform-scoped like `pricing_plans` needs a decision: pricing_plans is cloned per-tenant already — reference the tenant-local one).
   `LIKE ... INCLUDING ALL` copies indexes/defaults/constraints EXCEPT foreign keys, which is exactly what we want (we re-add them rewritten).
2. **Repoint `enrollments.payment_id` in every TENANT schema — drop-FK / move-rows / add-FK, in that order.** Postgres binds an FK to a table OID at DDL time (no per-query search_path resolution), and `ADD CONSTRAINT ... FOREIGN KEY` **validates existing rows immediately** — so the new tenant-local FK can only be added AFTER the referenced payment rows are in the tenant's `payments` table. Per tenant:
   1. If `enrollments.payment_id`'s FK references `registry.payments` (check `pg_constraint.confrelid`; discover the constraint name from `pg_constraint`, it may vary), DROP it.
   2. Move that tenant's rows (step 3 below).
   3. ADD the tenant-local FK: `EXECUTE format('ALTER TABLE %I.enrollments ADD CONSTRAINT enrollments_payment_id_fkey FOREIGN KEY (payment_id) REFERENCES %I.payments(id)', s, s)`.
   `clone_schema` strips schema qualifiers when cloning FK *definitions* (binding them to the dest schema's tables at clone time), so tenants cloned after `payments.sql` may already point tenant-locally — the confrelid conditional makes the migration idempotent across both states (already-tenant-local: skip drop/add, still move any registry-resident rows). **The registry template's own FK is left untouched**: `registry.enrollments → registry.payments` is schema-local and correct. (The spec says "registry template AND every tenant"; in the registry schema an unqualified re-add binds to the identical table, so leaving it alone satisfies the spec's intent — note this in a migration comment.) **A scratch-DB run has zero tenants/rows and cannot exercise the ordering — the migration test in Step 4 must seed a tenant enrollment with a non-null `payment_id` referencing a registry payment row before deploying, to prove the three-phase order validates.**
3. **Move existing tenant payment rows** (executed per tenant between FK drop and FK add): for each row of `registry.payments` whose `metadata->>'tenant_slug'` names this tenant, `INSERT INTO <slug>.payments ... SELECT` (same id), move its `registry.payment_items` rows alongside, then delete the originals. Rows without a tenant slug stay in registry (platform/test data). Pre-alpha: expect near-zero rows; the loop must still be correct. Log a NOTICE with the moved count per tenant.
4. Everything in one transaction, `quote_ident`/`format('%I')` for every schema/identifier interpolation, `CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL` guard per the dedup-migration pattern.

The revert script uses the same three-phase order mirrored: per tenant, DROP the tenant-local `enrollments.payment_id` FK, move the tenant's payment/payment_items rows back into `registry.payments`/`registry.payment_items`, THEN re-add the FK referencing `registry.payments` (adding it before the rows are back in registry would fail validation for any enrollment with a non-null `payment_id`). Leave the per-tenant empty tables in place (document in a comment — dropping tenant tables on revert risks data loss). **Revert limitation (state it in a script comment):** `registry.payments.user_id` is `NOT NULL REFERENCES registry.users(id)`, so moving back a payment whose payer exists only in the tenant schema (the very case Task 4 enables) fails FK validation — the transaction aborts loudly, no corruption. Revert is clean only while moved rows reference dual-resident (`copy_user`'d) users; tenant-only-payer rows need manual handling before revert.

The verify script asserts, for each tenant schema: the four payment tables exist, and `enrollments.payment_id`'s FK references the tenant's own `payments` table — `pg_constraint.confrelid = format('%I.payments', s)::regclass` — not `registry.payments`. (Do not assert anything about the registry template's FK; it is intentionally unchanged.)

- [ ] **Step 1: Write the isolation test** (`t/dao/tenant-payment-schema-isolation.t`) with two parts:
  - **Structural assertions (green at the end of THIS task):** after provisioning a tenant, the four payment tables exist in the tenant schema, and `enrollments.payment_id`'s FK there has `pg_confrelid` = the tenant's own `payments` table (query `pg_constraint` joined to `pg_class`/`pg_namespace`).
  - **Behavioral block (the #237 repro — TODO-wrapped until Task 4):** create the parent **directly on the tenant connection** so the user exists ONLY in the tenant schema. (Do NOT use `provision`'s `users` arg for this user — `copy_user` preserves ids, so a provision-copied parent also exists in `registry.users` and the FK would not trip.) Then `Registry::DAO::Payment->create($tenant_db, { user_id => $parent->id, amount => 50.00 })` inside `try/catch`, asserting: the create succeeds, the row exists in `<slug>.payments`, and `registry.payments` has no such row. Until Task 4 unqualifies the DAO this whole block fails (the DAO still writes `registry.payments`, whose `user_id` FK targets `registry.users`), so wrap the entire block in `TODO: { local $TODO = 'Task 4 unqualifies the Payment DAO'; ... }` (CLAUDE.md: every commit is 100% green; expected failures must be TODO). Task 4 removes the wrapper.
- [ ] **Step 2: Run it BEFORE writing the migration.** Expect the structural assertions GREEN even now: a freshly cloned tenant already has the four payment tables and a tenant-local `enrollments.payment_id` FK, because `clone_schema` clones every registry table and re-binds FK definitions to the dest schema (verified empirically). They are a clone-path invariant the test locks in — the migration's backfill/repoint loops exist for OLDER prod tenants that predate the payment migrations, a state the test DB cannot contain (it deploys all migrations before any tenant exists). The migration's own RED→GREEN evidence lives in Step 4(c)'s seeded legacy-state run. The behavioral block reports the `payments_user_id_fkey` violation under TODO — paste that FK error: it is the verified #237 repro.
- [ ] **Step 3: Write the three migration files + plan entry, then `make test-schema` to regenerate the dump.**
- [ ] **Step 4: Migration validation.** (a) Scratch-DB cycle: full deploy → revert this change → re-deploy (commands above). (b) Provision-path check: after deploy, `clone_schema` a fresh schema and confirm it contains `payments` with tenant-local `users` and `enrollments.payment_id` FKs. (c) **Ordering proof against recreated legacy state.** A scratch DB has no tenants, and a freshly cloned tenant is already tenant-local — neither exercises the drop/move/add order. In a seeded DB (the test harness DB works): provision a tenant, then **recreate the legacy state by hand** — drop the tenant's `enrollments_payment_id_fkey` and re-add it as `REFERENCES registry.payments(id)` (optionally also drop the tenant's four payment tables to exercise the backfill branch) — then seed a registry payment row whose metadata names the tenant plus a tenant enrollment row with that `payment_id`, run the migration's DO block, and confirm: the row moved, the tenant-local FK was re-added and validated, and the enrollment still references the payment. Paste the output.
- [ ] **Step 5: Run the full `t/dao/` suite** — existing payment tests still pass because the DAOs are still `registry.`-qualified (tables unchanged in registry); the isolation test is green (structural assertions pass; behavioral block is TODO).
- [ ] **Step 6: Commit.**

---

### Task 4: Unqualify the tenant-scoped payment DAOs

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm` (`sub table` line 37; `payment_items` at lines 216, 221; the `registry.payments` reference near line 270), `lib/Registry/DAO/PaymentSchedule.pm` (lines 21, 68), `lib/Registry/DAO/ScheduledPayment.pm` (line 22), `lib/Registry/PriceOps/ScheduledPayment.pm` (lines 92, 113, 122), `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm` (line 368)
- Test: `t/dao/tenant-payment-schema-isolation.t` (from Task 3, goes fully green)

- [ ] **Step 1: Re-grep for the authoritative list** — `grep -rn 'registry\.\(payments\|payment_items\|payment_schedules\|scheduled_payments\)' lib/` — and change every hit EXCEPT `lib/Registry/PriceOps/PricingRelationships.pm` (platform revenue aggregation, handled in Task 9) to the unqualified table name. Line numbers above are as of 2026-06-10; trust the grep.
- [ ] **Step 2: Remove the TODO wrapper from the Task 3 isolation test and run it — fully GREEN now** (create succeeds, row in tenant schema, registry empty).
- [ ] **Step 3: Run the money-path suites:** `carton exec prove -lr t/dao/ t/controller/ t/integration/` and specifically `t/dao/payment-schedule.t t/dao/scheduled-payment.t t/dao/payment-schedule-race-condition.t t/integration/installment-webhook-processing.t t/controller/installment-payment-webhooks.t`. These run against the registry schema in tests, where unqualified names resolve to `registry.*` via search_path — they must all stay green. The platform-subscription/tenant-signup path (`t/dao/tenant-payment-workflow.t`, anything matching `tenant-signup`) must stay green per the spec's regression callout.
- [ ] **Step 4: Commit.**

---

### Task 5: Readiness gate in the enrollment Payment step

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/Payment.pm` (`create_payment`, line ~84)
- Test: `t/dao/payment-step-readiness-gate.t` (new; pattern: `t/dao/payment-workflow-step.t`)

Behavior: in `create_payment`, after computing `$payment_info` and before `Registry::DAO::Payment->create`, when `$payment_info->{total} > 0` resolve the tenant and require readiness:

```perl
    # Paid enrollment requires a ready Stripe Connect account: tuition must
    # settle into the tenant's own account (Registry is not the merchant of
    # record). Free enrollment has no charge and is exempt.
    #
    # Tenant rows are platform data living ONLY in registry.tenants. $db here
    # is tenant-scoped, and clone_schema gives every tenant schema an empty
    # shadow `tenants` table, so an unqualified Tenant->find would always
    # return undef -- the lookup must be registry-qualified (same convention
    # as Tenant::slug_exists, lib/Registry/DAO/Tenant.pm:96).
    my $tenant_slug = $run->data->{__tenant_slug};
    if ($payment_info->{total} > 0) {
        my $row = $tenant_slug
            ? $db->query('SELECT * FROM registry.tenants WHERE slug = ?', $tenant_slug)
                  ->expand->hash
            : undef;
        my $tenant = $row ? Registry::DAO::Tenant->new(%$row) : undef;
        unless ($tenant && $tenant->stripe_connect_ready) {
            return {
                next_step => $self->id,
                errors    => ['Online payment is not yet available for this organization. '
                            . 'Please contact the program organizer to complete enrollment.'],
                data      => $self->prepare_payment_data($db, $run),
            };
        }
    }
```

(`$db` in a workflow step may arrive as a raw handle or a `Registry::DAO` — check how `create_payment` already uses it and coerce the same way the surrounding code does. The test must drive this from a tenant-scoped connection to prove the shadow-table trap is avoided.)

- [ ] **Step 1: Write the failing test** — three cases driven through `Registry::DAO::WorkflowSteps::Payment->create_payment` (or `process`) with a tenant-scoped `$db` and a run whose data carries `__tenant_slug`: (a) paid total + tenant NOT ready → result has `errors` mentioning unavailability and no payment row is created; (b) paid total + ready tenant (set the three columns) → proceeds to payment creation (intercept `Registry::Service::Stripe::create_payment_intent` as in Task 1's test so no network); (c) `total == 0` + not-ready tenant → no gate error (free path exempt; check how `create_payment` currently handles zero-total/free — if free enrollment short-circuits before `create_payment`, assert at the `process` level instead; read the step's `process` first and pick the right seam).
- [ ] **Step 2: RED**, **Step 3: implement**, **Step 4: GREEN**, **Step 5: regression** `carton exec prove -lr t/dao/payment-workflow-step.t t/dao/` , **Step 6: commit.**

---

### Task 6: Destination charge with application fee

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm` (`REVENUE_SHARE_PERCENT` constant + Connect params derived inside `create_payment_intent`), `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` (use the shared constant)
- Test: `t/dao/payment-intent-destination-charge.t` (new)

Design — **Connect params are derived inside `create_payment_intent` from the payment's own `metadata.tenant_slug`, not passed by callers.** This matters because the step has TWO intent-creation call sites: `create_payment` (line ~123) and the failure-retry path in `handle_payment_callback` (line ~188). If callers had to pass `connect_account`, a forgotten retry call site would silently settle tuition into the **platform** account — the exact merchant-of-record violation this spec exists to prevent. Deriving from the payment row makes every present and future intent for a tenant payment a destination charge.

- Move the 2.5 constant to the money class: in `Payment.pm`, `use constant REVENUE_SHARE_PERCENT => 2.5;` and a class helper:
  ```perl
  # Platform revenue share, collected at charge time as a Stripe application
  # fee on the destination charge. Integer cents, rounded half-up.
  sub application_fee_cents ($amount_cents) {
      return int($amount_cents * REVENUE_SHARE_PERCENT / 100 + 0.5);
  }
  ```
  In `TenantPayment.pm`, replace its local constant with `Registry::DAO::Payment::REVENUE_SHARE_PERCENT` (keep its existing tests green — they assert the value and the prose derive from one source).
- In `create_payment_intent`, before building the Stripe params, resolve the tenant from the payment's own metadata (registry-qualified, same shadow-table reasoning as Task 5):
  ```perl
        # Tenant payments are destination charges: tuition settles into the
        # tenant's connected account, the platform keeps the application fee,
        # and on_behalf_of makes the tenant the settlement merchant (bearer of
        # Stripe's processing fee). Derived from the payment's own metadata so
        # every intent for this payment -- including retries -- routes the
        # same way. Platform/registry payments (no tenant_slug) are unchanged.
        my $meta = ref $metadata eq 'HASH' ? $metadata : {};
        my $slug = $meta->{tenant_slug};
        my %connect_params;
        if ($slug && $slug ne 'registry') {
            my $row = $db->query(
                'SELECT stripe_connect_account_id, stripe_charges_enabled,
                        stripe_details_submitted
                 FROM registry.tenants WHERE slug = ?', $slug)->hash;
            if (my $acct = $row && $row->{stripe_connect_account_id}) {
                %connect_params = (
                    'transfer_data[destination]' => $acct,
                    on_behalf_of                 => $acct,
                    application_fee_amount       => application_fee_cents(_to_cents($amount)),
                );
            }
        }
  ```
  and merge `%connect_params` into the flattened param hash from Task 1. (Add `$db = $db->db if $db isa Registry::DAO;` at the top of the derive block — the standard `Registry::DAO::Object` idiom; `create_payment_intent` does no coercion today because it only forwards `$db` to `update`, but this new code queries `$db` directly and callers pass either form. `$metadata` is the field — use the same accessor Task 1 used. The Task 5 gate guarantees readiness before any tenant intent is created, so absence of an account here for a tenant payment means the gate was bypassed — that's gate territory, not this method's; routing on account presence keeps this method total.)
- The step's call sites need NO changes — verify both produce Connect params via the tests.

- [ ] **Step 1: Write the failing test** — using the Task 1 interception seam: (a) a payment whose metadata carries `tenant_slug` for a tenant with `stripe_connect_account_id = 'acct_test123'` produces params containing `transfer_data[destination] = acct_test123`, `on_behalf_of = acct_test123`, and `application_fee_amount == 250` for a $100.00 charge; (b) a payment with no `tenant_slug` contains none of the three keys (platform charge unchanged); (c) **the retry path**: drive `handle_payment_callback`'s failure branch (mock `retrieve_payment_intent` returning a failed status, capture the retry `create_payment_intent`) and assert the retry intent carries the SAME Connect params; (d) unit-test `application_fee_cents` rounding: 10000→250, 999→25 (24.975 rounds up), 1→0, 100→3 (2.5 rounds up).

  Note on rounding: document in the test that for amounts under $0.40 the fee rounds to 0 — acceptable; Stripe forbids `application_fee_amount` exceeding the charge, never an issue at 2.5%.
- [ ] **Step 2: RED → Step 3: implement → Step 4: GREEN.**
- [ ] **Step 5: Regression:** `carton exec prove -lr t/dao/tenant-payment-workflow.t t/dao/payments.t t/dao/payment-step-readiness-gate.t t/dao/payment-intent-stripe-params.t`.
- [ ] **Step 6: Commit.**

---

### Task 7: Webhook — tenant-first finalization + `account.updated` readiness refresh

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm` (`_process_payment_intent_succeeded` ~lines 93-118; the `stripe()` dispatch ~lines 58-76)
- Test: `t/controller/webhook-tenant-payment-finalization.t` (new; pattern: `t/controller/subscription-webhook-routing.t` — Test::MockObject app over a real DAO, call the handler methods directly rather than through HTTP signature verification)

Rewrite `_process_payment_intent_succeeded` per spec §4 — after Task 4 the payment row lives in the tenant schema, so the current registry-connection `find` would return undef and silently skip finalization:

```perl
    method _process_payment_intent_succeeded ($dao, $event) {
        my $intent     = $event->{data}{object} // {};
        my $payment_id = $intent->{metadata}{payment_id};
        return unless $payment_id;    # not a Registry one-time payment -- ignore

        # The tenant is resolved from our own snapshotted metadata. The spec
        # suggests corroborating with the Connect `account` field, but
        # destination-charge payment_intent events are PLATFORM events and
        # typically carry no `account` field -- so metadata is the source of
        # truth and there is usually nothing to corroborate against. (If an
        # `account` field IS present and a tenant lookup by it disagrees with
        # the slug, that would be worth a warn -- optional, not required.)
        my $slug = $intent->{metadata}{tenant_slug};

        # The payment row lives in the schema the registration ran under. A
        # one-time payment without a tenant slug is a registry-schema payment
        # (platform/test); anything else must resolve, or we fail loudly so
        # Stripe retries rather than silently dropping a paid enrollment.
        my $tdao = ($slug && $slug ne 'registry') ? $dao->connect_schema($slug) : $dao;
        my $tdb  = $tdao->db;

        require Registry::DAO::Payment;
        my $payment = Registry::DAO::Payment->find($tdb, { id => $payment_id });
        die "payment_intent.succeeded: payment $payment_id not found"
          . ($slug ? " in tenant schema '$slug'" : ' in registry schema') . "\n"
            unless $payment;

        unless (($payment->status // '') eq 'completed') {
            $payment->update($tdb, {
                status                   => 'completed',
                stripe_payment_intent_id => $intent->{id},
            });
        }

        $payment->finalize_enrollment($tdb);
    }
```

The `die` propagates to `stripe()`'s existing catch: claim released, 500 returned, Stripe retries — exactly the spec's fail-loud requirement. Update the now-stale comment at the old line 102 ("payments live in registry.payments").

Add the `account.updated` branch in `stripe()` BEFORE the installment/tenant-billing classification:

```perl
            elsif ($event->{type} eq 'account.updated') {
                $self->_process_account_updated($dao, $event);
            }
```

```perl
    # Connect sends account.updated when a connected account's capabilities
    # change. Mirror charges_enabled/details_submitted onto the tenant so the
    # paid-enrollment readiness gate reflects Stripe's current view.
    method _process_account_updated ($dao, $event) {
        my $account = $event->{data}{object} // {};
        my $acct_id = $account->{id} or return;

        my $updated = $dao->db->query(
            q{UPDATE registry.tenants
              SET stripe_charges_enabled = ?, stripe_details_submitted = ?
              WHERE stripe_connect_account_id = ?},
            ($account->{charges_enabled}   ? 1 : 0),
            ($account->{details_submitted} ? 1 : 0),
            $acct_id,
        )->rows;
        $self->app->log->info("account.updated for unknown connected account $acct_id")
            unless $updated;
    }
```

- [ ] **Step 1: Write the failing test.** Cases:
  1. `payment_intent.succeeded` whose metadata carries `payment_id` + `tenant_slug` for a payment row created in a provisioned tenant schema (use the now-unqualified DAO on a tenant connection) with `metadata.enrollment_items` → handler completes the payment IN the tenant schema and `finalize_enrollment` creates the enrollment there (assert via tenant-schema query). RED before the rewrite: the registry-connection `find` returns undef and the handler returns silently — assert the enrollment does NOT get created under the old code, then flip the assertion.
  2. Same event but the payment row deleted → handler dies (assert with `dies_ok`/`try`) — Stripe-retry semantics.
  3. No `metadata.payment_id` → returns silently (foreign intents ignored), no die.
  4. `account.updated` for a tenant's `stripe_connect_account_id` flips the readiness booleans (assert via `registry.tenants` query); unknown account id → logged, no error.
- [ ] **Step 2: RED → Step 3: implement → Step 4: GREEN.**
- [ ] **Step 5: Regression:** `carton exec prove -lr t/controller/webhooks.t t/controller/stripe-webhooks.t t/controller/payment-intent-webhook.t t/controller/subscription-webhook-routing.t t/controller/installment-payment-webhooks.t t/integration/installment-webhook-processing.t t/dao/payment-finalization-idempotency.t`. `t/controller/payment-intent-webhook.t` is the most affected existing test — it drives `_process_payment_intent_succeeded` end-to-end with a registry-schema payment (no tenant_slug), which must keep working on the registry connection. The Connect docs note destination-charge `payment_intent.succeeded` events arrive on the platform webhook with metadata preserved — confirm no test assumed otherwise.
- [ ] **Step 6: Commit.**

---

### Task 8: End-to-end paid-enrollment integration test

**Files:**
- Test: `t/integration/tenant-paid-enrollment.t` (new)

One test that strings the whole MVP together against a real test DB (Stripe intercepted at the `Registry::Service::Stripe` seam — no network, no keys; the spec's "Stripe test mode + test connected account" live validation is the manual checklist in Task 10):

- Provision a tenant; copy in a parent; create session/pricing so `calculate_enrollment_total` yields a paid total (crib fixture setup from `t/dao/payment-workflow-step.t`).
- Not-ready tenant → step refuses (gate), no payment row anywhere.
- Mark tenant ready (`stripe_connect_account_id='acct_e2e'`, both booleans) → step creates the payment **in the tenant schema**, and the captured intent params carry `transfer_data[destination]='acct_e2e'`, `on_behalf_of`, the correct `application_fee_amount`, and `metadata[payment_id]`/`metadata[tenant_slug]` bracket keys.
- Synthesize the `payment_intent.succeeded` event from those captured params and drive `_process_payment_intent_succeeded` → payment `completed` and enrollment created, both in the tenant schema; registry schema has neither row.
- Run `finalize` twice → idempotent (one enrollment; the dedup index from `enrollment-payment-dedup` holds in the tenant schema).

- [ ] **Step 1: Write it** (it should be GREEN already if Tasks 1–7 are correct — it's the integration safety net; if anything is RED, that's a real integration gap to fix in the offending task's code, not in the test).
- [ ] **Step 2: Run the FULL suite:** `carton exec prove -lr t/` — 100% pass, pristine. Run `carton exec ./registry workflow import registry` first.
- [ ] **Step 3: Commit.**

---

### Task 9: Revenue-share aggregation — document the interim, file the issue

**Files:**
- Modify: `lib/Registry/PriceOps/PricingRelationships.pm` (comment only, at the two `FROM registry.payments` queries, lines ~232/248)

- [ ] **Step 1: Add the comment** above `_get_usage_data`'s queries:

```perl
        # Tenant enrollment payments now live in per-tenant schemas;
        # registry.payments holds only platform-scoped rows, so this
        # aggregation no longer sees tenant revenue. That is deliberate for
        # now: the 2.5% share is collected at charge time via the Stripe
        # application fee on destination charges, so computing it here as
        # well would double-collect. Redesign as reporting driven from
        # Stripe application-fee records is tracked in the Connect epic.
```

- [ ] **Step 2: File the GitHub issue** (`gh issue create`) titled "Redesign _get_usage_data revenue reporting around Connect application fees" — body explains the above, labels `payments,backend,enhancement,medium`. Reference the spec. Include a second bullet in the body: when tenant installments come into scope, `_is_installment_payment_event` (`lib/Registry/Controller/Webhooks.pm`) looks up payment schedules on the registry connection only — tenant-schema schedules would be invisible and their events misrouted to the Subscription handler; the lookup must become tenant-aware alongside Connect-routed installments.
- [ ] **Step 3: Run `carton exec prove -lr t/dao/pricing-relationships.t`** (or whichever tests cover PriceOps::PricingRelationships — `grep -rl PricingRelationships t/`) — green.
- [ ] **Step 4: Commit** (mention the issue number).

---

### Task 10: SACP onboarding runbook + deploy checklist

**Files:**
- Create: `docs/operations/sacp-stripe-connect-onboarding.md`

- [ ] **Step 1: Write the runbook.** Contents:
  1. In the Stripe dashboard (platform `acct_1NBjkkLMFKfcYAvR`, Connect → Accounts), create/locate SACP's **Standard** connected account; complete onboarding until `charges_enabled` and `details_submitted` are both true (visible on the account page).
  2. Record the `acct_…` id on the tenant row:
     ```sql
     UPDATE registry.tenants
     SET stripe_connect_account_id = 'acct_XXXX',
         stripe_charges_enabled    = true,
         stripe_details_submitted  = true
     WHERE slug = '<sacp-slug>';
     ```
     (Booleans self-heal afterwards via `account.updated`.)
  3. Webhook config: the existing platform endpoint must also receive **Connect** events — in Stripe dashboard → Webhooks, ensure the endpoint is set to "Listen to events on Connected accounts" for `account.updated`, alongside the existing platform events. `payment_intent.succeeded` for destination charges arrives on the platform account (verify once in test mode).
  4. Deploy checklist: `carton exec sqitch deploy` runs `tenant-stripe-connect` + `tenant-scoped-payments`; confirm prod row counts before/after the row-move (expected ~0 — confirm with perigrin per the spec risk table); post-deploy smoke = one test-mode paid enrollment on a test tenant + `/health`.
  5. Live validation (test mode): one end-to-end paid enrollment against Stripe test keys with a test connected account, confirming the charge shows `transfer_data.destination`, the application fee, and that the webhook finalized the enrollment.
- [ ] **Step 2: Commit.**

---

## Verification (whole feature)

1. `carton exec ./registry workflow import registry && carton exec prove -lr t/` — 100%, pristine.
2. Migration cycle on a scratch DB: full `sqitch deploy`, `revert --to fix-clone-schema-identifier-quoting`, re-`deploy` — clean three ways.
3. The #237 repro (tenant parent, paid enrollment) — `t/dao/tenant-payment-schema-isolation.t` proves the FK resolves and data isolates.
4. Grep gates: `grep -rn 'registry\.payments\|registry\.payment_items\|registry\.payment_schedules\|registry\.scheduled_payments' lib/` returns ONLY `PriceOps/PricingRelationships.pm` (commented) — nothing else.
5. Platform-subscription regression: tenant-signup workflow tests green (the three platform DAOs untouched).
6. Manual test-mode validation per the Task 10 runbook before SACP goes live.
