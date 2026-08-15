# PriceOps Leg 0: The Money Path Becomes Atomic and Observable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make settlement atomic — one transaction on one connection — take the row and session locks that the #283 guards assume, re-check capacity at capture with a correct predicate, and give the resulting refund somewhere to go.

**Architecture:** Leg 0 is the second leg of the PriceOps alignment milestone (spec: `docs/superpowers/specs/2026-08-07-priceops-alignment-design.md`, Leg 0's row at spec `:2965`). Leg 1 shipped the deletions and the revert-test harness; this leg rewrites the live money path underneath. Every task after Task 1 is *inside the transaction Task 1 opens*, which is why the ordering here is stricter than Leg 1's.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, Minion, PostgreSQL, Sqitch, `Test::PostgreSQL`, `prove`.

**Editing rule, carried from Leg 1:** only defects that change what an executing worker *does* are corrected here — line numbers and ranges, step ordering, code, SQL, commands, gate patterns and their match counts, `git add` file lists, safety constraints. Prose inaccuracies are recorded in a companion file. Nine plan-review rounds on Leg 1 established that rewriting argument introduces defects at roughly the rate it removes them.

## Global Constraints

Copied from Leg 1, plus this leg's own.

- **A deployed change is retired by a new change, not by deleting a file.** Never `git rm` a file under `sql/deploy/`, `sql/revert/`, or `sql/verify/` named in `sql/sqitch.plan`, and never edit a deployed change's **deploy** script. Editing a **verify** script is safe — sqitch hashes the deploy script only.
- **A migration registers with the revert harness in the same commit that appends to `sql/sqitch.plan`** — append its change name to `@CHANGES` in `t/database/revert-round-trip.t`, in plan order. Skipping it is silent: the suite still prints `All tests successful` and only the test count moves. Read the count.
- **`@SLUGS` in that harness holds exactly five reserved-word slugs and three are used.** This leg's two migrations bring it to five — the ceiling. The next migration-bearing leg must extend the list, and the replacements must also be SQL reserved words; mixed case and hyphens were tried against live Postgres and break `clone_schema`, not the migrations.
- **`clone_schema` regenerates index and unique-constraint names.** `LIKE … INCLUDING ALL` means the tenant copy of `enrollments_session_student_type_unique` is called `enrollments_session_id_student_id_student_type_key`. Resolve existing objects out of `pg_index`/`pg_constraint` by table and column set, never by name. Creating a *new* object by name in the tenant loop is safe — the name does not exist yet.
- **Never `DROP CONSTRAINT IF EXISTS` in the tenant loop.** It converts the abort into a silent skip, leaving a status-blind constraint in force in exactly the schema that holds money.
- **`SET LOCAL` silently does nothing outside a transaction** and reverts at COMMIT. One `begin` at the top of the settlement path and no other transaction below it.
- **`_await` refuses to run under a live event loop** (`Service/Stripe.pm:246-249`). Both settlement paths run under the daemon's IOLoop, so every Stripe call this leg adds must use an `_async` variant.
- Test command is `make test` (a narrowed directory list; a bare `prove -lr t/` runs the forbidden suites).
- **Never run `t/stripe-live/`** (hits real Stripe) or **`t/playwright/`** (the ambient `STRIPE_PUBLISHABLE_KEY` is a `pk_live_` key). Editing them is fine; executing them is not.
- Local test invocation uses a placeholder that must **not** start with `sk_test_`:
  `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/...`
- Do not touch the dev database. All schema work happens in ephemeral `Test::PostgreSQL` instances.
- **Production is read-only in this leg.** Go through the Render MCP tool with `postgresId: dpg-ckq1i8o5vl2c73d61070-a`, never `psql "$DATABASE_URL"`. Carry `current_database()` in the same result set as any count — the wrong database returns the answer you are hoping for.
- `grep` exits 1 when it finds nothing, including `grep -c`, which prints `0` and still exits 1. `$` is a regex anchor — use `grep -F` for patterns containing `$`.
- Object::Pad methods take no explicit `$self`. Use the `isa` operator, not `ref eq`. Every file starts with two `# ABOUTME: ` lines. Comments are evergreen.
- Full suite is ~17 minutes with `-j8`. Run it once, at the end.

## Declared Deviations From The Spec

Eight places where this plan does something other than what the spec's Leg 0 row says. All eight are deliberate, and six exist because the row is wrong about the code. Each was verified by reading or running, not inferred.

1. **The capacity refund calls `refund_async`, not `Payment::refund`.** The spec names `Payment::refund` at `:4540`, `:4544`, `:4857` and in the row. That method reaches `create_refund` → `_await`, which dies with *"Synchronous Stripe call did not settle - it was likely made inside a running event loop"* (`Service/Stripe.pm:246-249`). Both settlement paths run under the IOLoop — the webhook is a controller action, and `_settle_callback` runs inside a `->then` (`WorkflowSteps/Payment.pm:251-252`). The spec knows this rule; it applies it to `publish_version` in Leg 6 at `:3154` and never back-propagates it. `refund_async` (`:571-601`) carries the identical guard at `:572` and the identical whole-payment default at `:575`.

2. **The capacity predicate is a new sub; `count_for_session` is left alone.** The row reads as an instruction to fix the primitive. It has four other callers — `MultiChildSessionSelection.pm:94`, `Enrollment.pm:301`, `SelectTargetSession.pm:19`, `ValidateTargetCapacity.pm:23,35` — none of which has a payment in hand, and the three transfer-path callers genuinely want the unfiltered count. Self-exclusion there is inert at best.

3. **Session locks are taken in sorted order.** The spec calls the lock "one statement in a block that is already open" (`:4524`), which is true only for a single-session cart. A multi-session cart takes one lock per item, iterating `keys %selections` (`MultiChildSessionSelection.pm:126`) — Perl's randomized hash order, fixed per process, differing between processes. Two concurrent two-session carts over the same pair deadlock. Lock the distinct session ids sorted, before the count.

4. **The predicate has a NULL branch.** `sessions.capacity` is nullable (`sql/test-schema.sql:920`, `:966`; `Session.pm:21` defaults to `undef`) and the existing check guards it (`MultiChildSessionSelection.pm:93`). The spec's stated comparison has no NULL handling; written literally, every uncapped session refunds at capture.

5. **Four of the row's items are already done.** The `payment_id` scalar refusal, the server-owned run-data keys, the `session_for_<id>` subset check, and `get_subscription_config` taking its run all shipped in the hardening PR (#314) because they are unauthenticated, live, and independent of this leg's transaction work. What remains of the reuse-guard item is the status **allow-list** (`WorkflowSteps/Payment.pm:166` is still `ne 'completed'`, a deny-list of one that admits `refunded` and `partially_refunded`) and the `workflow_run_id` ownership check, which `create_payment` writes and nothing reads.

6. **#247 is only half closed, and this plan says so.** The issue's own evidence is stale — it cites `Webhooks.pm:93-118` for a registry/tenant split that #237 already fixed. Its *second* half is `Payment.pm:355`'s `return unless @$items`: a payment with no `enrollment_items` is marked `completed`, returns 200, and enrolls nobody. Making the claim and the work atomic does not make a no-op loud. This leg does not close that half; it is recorded under Coverage Gaps.

7. **`mark_completed` is a behaviour change, not a refactor.** The spec says a literal swap "writes back the loaded `'pending'` and a NULL `completed_at`" (`:1643`). The webhook never writes `completed_at` today (`Webhooks.pm:132-135` writes two columns), while the callback path does (`Payment.pm:318-321`) — so webhook-settled payments currently have `completed_at IS NULL`, and this leg starts populating it. `save` also rewrites the whole metadata blob, a wider write than `update`'s patch.

8. **The demotion is an `UPDATE`-then-`INSERT`, not a fourth parameter on `create_for_payment`.** The sub hardcodes its arbiter (`Enrollment.pm:94-96`) and takes `($class, $db, $data)` — there is no slot for a conflict action, and `finalize_enrollment` is its only caller. The spec offers this alternative itself at `:4505` and it is the smaller diff.

## Spec Citations Corrected

Verified against the tree. The row and its supporting decisions cite these wrongly:

| Spec says | Actual | Cited at |
|---|---|---|
| `Webhooks.pm:142` (`finalize_enrollment`) | **`:138`** | row ×2, `:4473`, `:4501` |
| `Webhooks.pm:136` (the `update`) | **`:132-135`** | `:1635`, `:1641`, `:4302` |
| `Webhooks.pm:112` (`connect_schema`) | **`:108`** | `:1593` |
| `sql/test-schema.sql:3488` (dedup index) | **`:3394`** | `:4508` |
| `sql/test-schema.sql:2913` (the constraint) | **`:2835`** | `:2399` |
| `sql/test-schema.sql:1178-1191` (`payments.status`) | **`:1140-1153`**, status at `:1144` | `:2182` |

`sql/test-schema.sql` citations across the spec are stale by roughly 90-120 lines because Leg 1's `cda1f33` regenerated the dump. This leg regenerates it again.

---

### Task 1: One transaction, one connection

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm:44-49` (the claim), `:79-81` (the release), `:108-109` (the connection hop), `:131-138`
- Test: `t/controller/payment-intent-webhook.t`

**Interfaces:**
- Consumes: nothing.
- Produces: `stripe()` runs one `begin` at the top and no other transaction below it. Every later task's lock and re-check lives inside that block. Post-COMMIT work re-establishes the search path at **session** level, because `Payment::save` writes the unqualified `payments` and `registry.payments` is a real table (`sql/deploy/payments.sql:7`).

**The defect, restated — #247's body is stale.** The issue cites `Webhooks.pm:93-118` for a registry/tenant split that #237 already closed; both the `completed` write and `finalize_enrollment` already run on `$tdb`. What remains is that the **claim** (`:45-49`) and the **release** (`:81`) run on `$dao->db` while the work runs on a second pool from `connect_schema` (`:108`, `DAO.pm:104-106`). A crash between claim and work leaves a claimed event with nothing done, and the claim is not rolled back with it.

- [ ] **Step 1: Write the failing test** — a webhook delivery that dies mid-finalization must leave no claim in `registry.webhook_events` and no partial enrollment. Assert both.
- [ ] **Step 2: Run it and watch it fail.** `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-intent-webhook.t`. Expected: the claim survives the rollback.
- [ ] **Step 3: Resolve the slug to a tenant row before `begin`.** That lookup *is* the validation; a slug that resolves to no tenant never reaches `set_config`.
- [ ] **Step 4: Replace the `connect_schema` hop with `SELECT set_config('search_path', ?, true)`** inside the transaction, bound as a parameter so the slug never reaches SQL text. Set it to `<tenant>, public` — do not widen with `registry`.
- [ ] **Step 5: Move `Subscription::get_subscription` out of the block.** It is the only blocking Stripe call inside it (`Subscription.pm:319`, `:332`), and it runs on a user agent with no request timeout. Anything doable before `begin` happens before `begin`.
- [ ] **Step 6: Re-establish the path at session level for post-COMMIT work** — `set_config('search_path', ?, false)`.
- [ ] **Step 7: Run the test and the controller suite.** Expected: PASS.
- [ ] **Step 8: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] One `begin` on the settlement path and no other below it (`grep -c '\->begin' lib/Registry/Controller/Webhooks.pm` -- 1)
- [ ] `connect_schema` no longer appears in the webhook path (`grep -c connect_schema lib/Registry/Controller/Webhooks.pm` -- 0)
- [ ] The slug is bound, never interpolated (`grep -c "set_config('search_path', ?" lib/Registry/Controller/Webhooks.pm` -- at least 1)
- [ ] Webhook suite passes (`STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-intent-webhook.t`)

### Negative Scenarios
- [ ] **A nested `begin` below the top silently ends the transaction.** `SET LOCAL` reverts at COMMIT, so a `begin` anywhere below restores the search path mid-flight and the next unqualified write lands in `registry`. Assert there is exactly one.
- [ ] **A slug that resolves to no tenant must not reach `set_config`.** Deliver a webhook whose metadata names a nonexistent tenant; assert it is refused before the transaction opens, not inside it.
- [ ] **The claim must be released by the ROLLBACK, not by the catch block.** Assert that a die inside the block leaves no row in `webhook_events` even if the catch never runs.

---

### Task 2: `mark_completed`

**Files:**
- Create: `mark_completed` on `lib/Registry/DAO/Payment.pm` (near `save`, `:425-435`)
- Modify: `lib/Registry/Controller/Webhooks.pm:132-135`, `lib/Registry/DAO/Payment.pm:206-216`, `:218-226`

**Interfaces:**
- Consumes: Task 1's transaction.
- Produces: a mutating `mark_completed($db, $intent_id)`. Leg 9a extends the same field list for the quote stamp.

**Why not a literal swap.** All `Payment` fields are `:param :reader` with no writer (`:12-23`), so `save` writes back whatever was loaded. `update` (`Object.pm:38-49`) returns a *new* object and patches two columns; `save` (`:425-435`) writes six, including `metadata => { -json => ... }` unconditionally.

**Two behaviour changes to state, not hide.** The webhook does not write `completed_at` today; the callback path does (`Payment.pm:318-321`). After this task, webhook-settled payments get one — correct, and a data-shape change. And the webhook begins rewriting the metadata blob on every delivery, which is a new interleaving surface with `WorkflowSteps/Payment.pm:162-165`.

- [ ] **Step 1: Write the failing test** — after a webhook settlement, `completed_at` is set and `metadata` is unchanged from what the callback wrote.
- [ ] **Step 2: Run it.** Expected: `completed_at` is NULL.
- [ ] **Step 3: Add `mark_completed`** — mutate `status`, `stripe_payment_intent_id`, `completed_at`, then `save`.
- [ ] **Step 4: Swap the three call sites.**
- [ ] **Step 5: Run the payment and webhook suites.** Expected: PASS.
- [ ] **Step 6: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] `mark_completed` exists and is the webhook's write (`grep -c mark_completed lib/Registry/DAO/Payment.pm lib/Registry/Controller/Webhooks.pm`)
- [ ] Webhook-settled payments carry `completed_at` (asserted in the test above)

### Negative Scenarios
- [ ] **A literal `save` swap writes back the loaded `pending`.** Assert the status after settlement is `completed`, not the loaded value.
- [ ] **The metadata blob must survive.** Assert `enrollment_items` is intact after the webhook writes, since `save` rewrites the whole column.

---

### Task 3: `SELECT … FOR UPDATE` on the payment row

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm:123-136`, `lib/Registry/DAO/Payment.pm:266-343` (`_apply_intent`), `lib/Registry/DAO/WorkflowSteps/Payment.pm:164-166`

**Interfaces:**
- Consumes: Task 1's transaction. A lock outside one is released immediately.
- Produces: every read-decide-write on a payment row holds it.

**Two sites, not one.** The spec enumerates `_apply_intent`'s guards and never mentions that `Webhooks.pm:123-136` carries its **own** copy of the amount and completed checks rather than calling it. A lock on one leaves the other racing.

**The mechanism already exists.** `SQL::Abstract::Pg` supports `for`, and `Object::find` passes its 4th argument through as options (`Object.pm:16`). Verified: `Payment->find($db, {id=>$id}, { for => 'update' })` renders `SELECT * FROM payments WHERE id = ? FOR UPDATE`. No new SQL.

**Also here: the reuse guard's allow-list.** `WorkflowSteps/Payment.pm:166` is still `ne 'completed'` — a deny-list of one that admits `refunded` and `partially_refunded`, driving a refunded row back to `completed`. Replace with an allow-list of `pending`/`processing`, and reuse the row only when `$existing->metadata->{workflow_run_id}` equals `$run->id` — a linkage `create_payment` writes and nothing has ever read back.

- [ ] **Step 1: Write the failing test** — two concurrent settlements of the same payment; assert exactly one finalizes.
- [ ] **Step 2: Run it.** Expected: both proceed.
- [ ] **Step 3: Take the lock in `_apply_intent`** before the ownership check at `:274`.
- [ ] **Step 4: Take the lock in `Webhooks.pm`** before the amount check at `:123`.
- [ ] **Step 5: Rewrite the reuse guard** — allow-list plus the `workflow_run_id` ownership check.
- [ ] **Step 6: Run the payment, webhook and workflow suites.** Expected: PASS.
- [ ] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] Both sites take the lock (`grep -c "for => 'update'" lib/Registry/DAO/Payment.pm lib/Registry/Controller/Webhooks.pm`)
- [ ] The reuse guard is an allow-list (`grep -c "ne 'completed'" lib/Registry/DAO/WorkflowSteps/Payment.pm` -- 0)
- [ ] `workflow_run_id` is read, not only written (at least 2 occurrences in `WorkflowSteps/Payment.pm`)

### Negative Scenarios
- [ ] **A refunded row must not be reusable.** Set a row to `refunded`, plant its id, assert reuse is refused.
- [ ] **Another run's payment row must not be reusable** even when its status is `pending` — the ownership check, not the status check, is what refuses it.
- [ ] **A lock taken outside the transaction is not a lock.** Assert the lock statement is inside the block Task 1 opened, not before it.

---

### Task 4: Refund plumbing

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:449` and `:572` (the guards), `lib/Registry/Service/Stripe.pm:173-175` and `:267-269`
- Create: a per-child share resolver on `Payment`

**Interfaces:**
- Consumes: nothing from 1-3, but must precede Task 5.
- Produces: `refund_async` accepts `refund_pending`; `create_refund_async` accepts `_idempotency_key`; a resolver taking `(child_id, session_id)` that Leg 3 reuses with a per-enrollment argument.

**Why this precedes the capacity branch.** Task 5 writes `payments.status = 'refund_pending'` and then calls the method whose first line is `die … unless $status eq 'completed'`. The refund never reaches Stripe. The guard rewrite and the key must be in the same commit as the first `refund_pending` write.

**The refund share.** `refund_async:575` defaults to the whole payment, and a payment is a family cart — refunding "the payment" for one child returns every sibling's money. Resolve through `payment_items.metadata->{child_id, session_id}`, which `calculate_enrollment_total:531-538` already writes on every row. **Not** `payment_items.enrollment_id`: line items are written before the charge and enrollments after settlement, so the column cannot be populated at the natural write point — it would need a second write inside `finalize_enrollment`, a backfill migration, and a third `@SLUGS` entry this leg does not have.

**Use `_idempotency_key` extract-and-delete**, copying `create_payment_intent_async:72-76`. Stripe rejects unknown form parameters, so it must be deleted before the POST. A positional argument would break `t/dao/refund-application-fee.t`, which monkey-patches both methods with two-argument signatures at `:264,311,339,368,404`.

- [ ] **Step 1: Write the failing tests** — a `refund_pending` payment can be refunded; a refund carries an idempotency key; a per-child refund returns one child's share, not the cart.
- [ ] **Step 2: Run them.** Expected: the guard rejects, no key is sent, the whole cart is refunded.
- [ ] **Step 3: Rewrite both guards as allow-lists** of `completed`/`refund_pending`. Both entry points move together.
- [ ] **Step 4: Thread `_idempotency_key`** through `create_refund_async` and `create_refund`.
- [ ] **Step 5: Add the share resolver.**
- [ ] **Step 6: Run the refund suite.** Expected: PASS.
- [ ] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] Both guards accept `refund_pending` (`grep -c "unless \$status eq 'completed'" lib/Registry/DAO/Payment.pm` -- 0)
- [ ] `create_refund_async` threads a key (`grep -c _idempotency_key lib/Registry/Service/Stripe.pm` -- at least 3)
- [ ] `t/dao/refund-application-fee.t` still passes unchanged

### Negative Scenarios
- [ ] **`_idempotency_key` must not reach Stripe as a form parameter** — Stripe 400s on unknown params. Assert it is deleted from the payload.
- [ ] **A `pending` payment must still be refusable.** The allow-list must not become "anything".
- [ ] **The share resolver must not fall back to the cart total silently** when metadata is missing; assert it refuses.

---

### Task 5: The capacity gate

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:350-385` (`finalize_enrollment`), `lib/Registry/DAO/Enrollment.pm`
- Modify: `lib/Registry/DAO/WorkflowSteps/Payment.pm:267`, `lib/Registry/Controller/Webhooks.pm:138`

**Interfaces:**
- Consumes: Tasks 1, 3, 4.
- Produces: capacity is re-checked at capture on both settlement paths, and the capacity-gone branch demotes and refunds.

**Order within this task is strict.** Sorted locks → predicate → demotion → wiring. The predicate before the branch, or the branch fires on a false positive. The demotion *with* the branch, because a branch that inserts is silently a no-op.

- [ ] **Step 1: Write the failing test** — a session at capacity, a payment captured for the last seat by someone else first; assert the loser is waitlisted and refunded, not enrolled.
- [ ] **Step 2: Run it.** Expected: both enroll; the session oversells.
- [ ] **Step 3: Take session locks, sorted.** `SELECT id FROM sessions WHERE id = ANY(?) ORDER BY id FOR UPDATE`, over the **distinct** session ids in the cart. Sorted is load-bearing: `keys %selections` is randomized per process, and two concurrent multi-session carts otherwise deadlock.
- [ ] **Step 4: Add the predicate as a new sub** — count `active`/`pending` rows for the session **excluding those whose `payment_id` is this payment**, and compare `count + (this payment's items for this session)` against capacity. Leave `count_for_session` alone; its four other callers want the unfiltered count. **A NULL capacity is unlimited** — return early, do not compare.
- [ ] **Step 5: Run the gate before `finalize_enrollment`**, not after. `finalize_enrollment` writes this payment's rows as `active`, so a re-check after it counts itself.
- [ ] **Step 6: Write the capacity-gone branch** — `UPDATE` the enrollment to `waitlisted`, then `INSERT` only on zero rows; set `payments.status = 'refund_pending'`; commit; **then** call `refund_async` with `Idempotency-Key: refund:capacity:<payment_id>` and the per-child share from Task 4.
- [ ] **Step 7: Wire both callers** — `WorkflowSteps/Payment.pm:267` and `Webhooks.pm:138`. The second short-circuits when this payment already holds `active` rows for the session.
- [ ] **Step 8: Run the payment, webhook and integration suites.** Expected: PASS.
- [ ] **Step 9: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] The loser of a last-seat race is waitlisted and refunded (the test above)
- [ ] Locks are sorted (`grep -c 'ORDER BY id' lib/Registry/DAO/Payment.pm` -- at least 1)
- [ ] `count_for_session` is unchanged (`git diff ce35f0d -- lib/Registry/DAO/Enrollment.pm | grep -c 'count_for_session'` -- 0 changed lines within it)
- [ ] Both callers run the gate

### Negative Scenarios
- [ ] **An uncapped session must not refund.** `sessions.capacity` is nullable; assert a NULL-capacity session enrolls normally.
- [ ] **A plain `waitlisted` insert is discarded in silence.** The arbiter at `Enrollment.pm:94-96` is `DO NOTHING` on exactly the three columns `finalize_enrollment` already wrote. Assert the row's status actually changed.
- [ ] **The refund must be issued after COMMIT.** A refund inside the transaction is not undone by the ROLLBACK the leg's correctness rests on, and the redelivered webhook then refunds a partial twice. Assert ordering.
- [ ] **A two-sibling cart must not pass `9 >= 10`.** The comparison is `count + this payment's items`, not `count` alone.
- [ ] **Two concurrent multi-session carts must not deadlock.** Assert the lock order is deterministic.

---

### Task 6: The two migrations

**Files:**
- Create: `sql/{deploy,revert,verify}/payment-intent-unique.sql`, `sql/{deploy,revert,verify}/enrollment-status-aware-unique.sql`
- Modify: `sql/sqitch.plan`, `t/database/revert-round-trip.t` (`@CHANGES`), `sql/verify/flexible-enrollment-architecture.sql:8-18`, `sql/verify/fix-multi-child-enrollments.sql:21-31`, `t/dao/payment-finalization-idempotency.t:75-102`, `lib/Registry/DAO/Enrollment.pm:77`
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: Task 5 (the partial index encodes the status vocabulary the gate uses).
- Produces: two graded migrations. Both go on `@CHANGES` — neither is data-only.

**Resolve by column set, never by name.** Reproduced against ephemeral Postgres: `registry` holds `enrollments_session_student_type_unique`, the tenant copy is `enrollments_session_id_student_id_student_type_key`. Resolve through `pg_constraint` on `(conrelid, contype='u', conkey)` and `ALTER TABLE … DROP CONSTRAINT <resolved>`. Never `IF EXISTS` — it turns the abort into a silent skip in the schema that holds money.

**Two deployed verify scripts break.** A partial unique **index** does not appear in `information_schema.table_constraints`, so `flexible-enrollment-architecture.sql:8-18` and `fix-multi-child-enrollments.sql:21-31` both `RAISE EXCEPTION` against the final schema — and `flexible-enrollment-architecture.sql:37-48` already asserts the other name in that `IN` list is gone, so there is no fallback. Strip both following Leg 1's precedent (`cda1f33`): remove the assertions, leave a comment pointing at the retiring change. Keep `:37-48`; it stays true.

**One test is semantically inverted, not just renamed.** `t/dao/payment-finalization-idempotency.t:97` asserts the error names the constraint, and the subtest asserts a re-registering parent *raises* — which is exactly what the partial index is meant to permit. Re-cut it. `Enrollment.pm:77`'s comment names the same constraint and becomes false.

- [ ] **Step 1: `sqitch add` both changes** with `--note` spelled in full (`carton` swallows `-n`), and append both to `@CHANGES` in the same commit.
- [ ] **Step 2: Write the unique index on `payments.stripe_payment_intent_id`** with the tenant loop. A new name is safe. Do **not** drop the redundant `idx_payments_stripe_intent` — dropping it invokes the naming hazard for no benefit.
- [ ] **Step 3: Write the status-aware partial index**, resolving the old constraint by column set. Active statuses are `('active','pending')`, matching `enrollments_status_check` (`sql/test-schema.sql:839`).
- [ ] **Step 4: Write both reverts to drop by resolved identity**, not by name — the harness cannot catch a name-based revert for objects the change created.
- [ ] **Step 5: Strip the two verify scripts.**
- [ ] **Step 6: Re-cut `payment-finalization-idempotency.t:75-102` and fix `Enrollment.pm:77`.**
- [ ] **Step 7: `make test-schema`.** Expect ~157 lines of inherent churn; commit it.
- [ ] **Step 8: Run `t/database/`.** Expected: `Files=3` and the harness must print `ok N - payment-intent-unique reverts cleanly` and one for the other. A missing line means the `@CHANGES` append was skipped — read the count, not the verdict.
- [ ] **Step 9: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] Both changes are on `@CHANGES` and the harness grades them (test count rises by 2)
- [ ] Neither migration names a constraint it did not create (`grep -c 'DROP CONSTRAINT IF EXISTS' sql/deploy/enrollment-status-aware-unique.sql` -- 0)
- [ ] `@CHANGES` is at 5 and `@SLUGS` is at 5 (the ceiling; the next leg must extend it)
- [ ] `make test` passes

### Negative Scenarios
- [ ] **A name-based `DROP CONSTRAINT` aborts on a real tenant.** Assert the deploy survives a `clone_schema`d tenant carrying the regenerated name.
- [ ] **`IF EXISTS` turns that abort into a silent skip.** Assert the constraint is actually gone in the tenant, not just in `registry`.
- [ ] **A revert that drops by name is a no-op for later-cloned tenants** — the shape already latent in `sql/revert/enrollment-payment-dedup.sql:17`. Assert the revert drops by resolved identity.

---

### Task 7: Stripe client hardening

**Files:**
- Modify: `lib/Registry/DAO/Subscription.pm:16-20`, `:71-103`, `:118-158`; `lib/Registry/Service/Stripe.pm:25-69`; `lib/Registry/DAO/WorkflowSteps/Payment.pm:180-186`, `:324-327`

**Interfaces:**
- Consumes: nothing. Disjoint from Tasks 1-6.
- Produces: both clients keep response headers; every Stripe object Registry creates carries the idempotency token in metadata.

**There are two HTTP clients, not three.** Leg 1 deleted `Client::Stripe`. The spec's "all three clients" (`:2397`) predates that; its "three modules" (`:2612`) is a *logging* triple in which `DAO/Payment.pm` is a caller, not a client. The un-stamped object kinds are **Refund, Customer, Subscription, SetupIntent**.

**`metadata[tenant_id]` is never set on any Subscription**, because `:131-133` sits inside `if ($tenant_id)` and the sole production caller (`TenantPayment.pm:318-322`) passes three arguments. That silently disables **eight** webhook handlers guarded by `return unless $tenant_id`. This is the same shape as the token item, on the same object, and belongs here.

**`request_id` needs a client change first.** Both clients discard the response: `Stripe.pm:67` returns `decode_json($res->body)`, `Subscription.pm:102` returns `$tx->result->json`. There is no way to log a request id from a caller today.

**The two silent catches are not in the three named files** — they are `WorkflowSteps/Payment.pm:185` and `:326`, and both sit immediately before a replacement-intent mint, so what they swallow is a double-charge window, not just telemetry.

- [ ] **Step 1: Write the failing tests** — a Subscription carries `metadata[tenant_id]`; a timeout is set; a failed cancel is logged rather than swallowed.
- [ ] **Step 2: Run them.** Expected: no metadata, no timeout, silence.
- [ ] **Step 3: Set `request_timeout`, `connect_timeout`, `max_redirects` on `Subscription.pm`'s user agent,** matching `Stripe.pm:19-23`. Note `Subscription.pm:18` has no `sk_live_` guard while `Payment.pm:150` does — add one while in the `ADJUST` block.
- [ ] **Step 4: Pass the tenant id through to `create_subscription_with_config`** so `metadata[tenant_id]` is actually set.
- [ ] **Step 5: Return the `Request-Id` header alongside the body** from both clients, and log it.
- [ ] **Step 6: Close the two catches** — log the failure and re-raise or record it; do not proceed silently to mint a replacement.
- [ ] **Step 7: Stamp the token on Refund, Customer, Subscription and SetupIntent.**
- [ ] **Step 8: Run the affected suites.** Expected: PASS.
- [ ] **Step 9: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] `Subscription.pm` sets a request timeout (`grep -c request_timeout lib/Registry/DAO/Subscription.pm` -- at least 1)
- [ ] A created Subscription carries `metadata[tenant_id]` (the test above)
- [ ] Neither catch is empty (`grep -c 'catch(sub ($cancel_err) { })' lib/Registry/DAO/WorkflowSteps/Payment.pm` -- 0)

### Negative Scenarios
- [ ] **A swallowed cancel is a double-charge window.** Assert a failed cancel prevents the replacement mint, or records it loudly.
- [ ] **A dropped connection must not leave an orphan subscription.** With no key and no timeout, a retry creates a second live Subscription; assert the id is recorded or the subscription is cancelled.
- [ ] **The eight `return unless $tenant_id` handlers must now fire.** Assert at least one processes an event it previously dropped.

---

### Task 8: `calculate_enrollment_total` refuses an undefined price

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:517-539`

**Interfaces:**
- Consumes: nothing. Disjoint.
- Produces: an undefined price is a refusal, not a free child.

`:528`'s `if (defined $price_cents)` has no `else` — an undefined price contributes nothing to the total and adds no line item, so the child is enrolled free with nothing recording it. The upstream cause is `requirements_met`'s epoch-vs-string comparison (`PricingPlan.pm:152-166`), which `:524` feeds `date => time()`; that bug gets an issue and dies with the module in Leg 8. **Leg 0 takes the refusal half only** — a genuinely free program returns `0`, which must keep working.

- [ ] **Step 1: Write the failing test** — a plan whose `calculate_price` returns undef must refuse, and one returning `0` must still enroll free.
- [ ] **Step 2: Run it.** Expected: the undef child is silently skipped.
- [ ] **Step 3: Refuse on undefined; keep `0`.**
- [ ] **Step 4: Run the payment suite.** Expected: PASS.
- [ ] **Step 5: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] An undefined price raises (the test above)
- [ ] A zero price still enrolls (`0` is a price, not an absence)

### Negative Scenarios
- [ ] **`defined` and truthiness are different tests.** Assert the guard is `defined`, so a genuinely free program is not refused.

---

### Task 9: The manual `refund_pending` clearance procedure

**Files:**
- Modify: `docs/operations/sacp-stripe-connect-onboarding.md` (after `:204`)

**Interfaces:**
- Consumes: Task 4.
- Produces: a runbook section. There is no automated reader until Leg 3, so this leg writes the procedure rather than implying one exists.

- [ ] **Step 1: Add `### Clearing a stranded refund_pending payment`** after the refund-policy subsection, stating: the state arises only from a post-COMMIT failure; Stripe's redelivery does **not** heal it, because the dedup claim committed in the same transaction dedups the retry away by design; and there is no automated reader until Leg 3.
- [ ] **Step 2: Write the procedure — list before re-issuing.** `GET /v1/refunds?payment_intent=<id>` under `Stripe-Account` first. A `succeeded` Refund settles the row; a `failed` one writes `refund_failed`; a `pending` one is left alone; only an **empty list** justifies re-issuing. Re-POSTing under the stable key is a double refund waiting on a clock — Stripe prunes idempotency keys after 24 hours.
- [ ] **Step 3: Give the finding query, per tenant schema** — `payments` is tenant-scoped.
- [ ] **Step 4: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] The section exists and names the 24-hour pruning (`grep -c '24 hours' docs/operations/sacp-stripe-connect-onboarding.md` -- at least 1)
- [ ] The finding query is per-tenant, not against `registry` (`grep -c 'refund_pending' docs/operations/sacp-stripe-connect-onboarding.md` -- at least 1)

### Negative Scenarios
- [ ] **A procedure that re-issues before listing is a double refund.** Assert the listing step comes first in the document order.

---

## Task Dependency Order

Execute in numeric order. Every arrow is a real dependency.

```
1 (one txn, one connection) ─── the container; nothing else can be "inside the block" until it exists
      ↓
2 (mark_completed) → 3 (FOR UPDATE on the payment row, TWO sites)
      ↓
4 (refund plumbing: guard rewrite + async key + per-child share)
      ↓
5 (the capacity gate: sorted session locks → predicate → demotion → both callers)
      ↓
6 (the two migrations)

7 (Stripe client hardening)  ── independent of 1-6
8 (calculate_enrollment_total refuses undefined) ── independent
9 (runbook: manual refund_pending clearance) ── requires 4
```

- **1 before everything**: a lock outside a transaction is released immediately.
- **4 before 5**: Task 5 writes `payments.status = 'refund_pending'` and then calls the method that rejects any status but `completed`. The guard rewrite and the idempotency key must be in the same commit as the first `refund_pending` write.
- **Within 5, strictly**: sorted locks → predicate → demotion → wiring both callers. The predicate must land before the branch, or the branch fires on a false positive; the demotion must land *with* the branch, because a branch that inserts is silently a no-op.
- **7 and 8 are disjoint** from the transaction work and can be worked in parallel by a second worker.

## Coverage Gaps This Leg Opens

1. **#247's empty-items half stays open.** `Payment.pm:355`'s `return unless @$items` still marks a payment `completed` with zero enrollments and returns 200. Atomicity does not make a no-op loud. Filed rather than fixed here.
2. **The oversell window narrows but does not close.** `Enrollment::enroll_children` (`:103-121`, the live free path, called at `WorkflowSteps/Payment.pm:372`) and `Waitlist::accept_offer` (`:187-226`, its own transaction, inserts `pending` with no capacity read) take no session lock. An admin lowering `sessions.capacity` is likewise unserialized. The spec names both at `:4521-4522` and then does not put them in the leg.
3. **`refund_pending` has no automated reader until Leg 3.** `Job::ProcessRefunds` claims `enrollments.refund_status`, a different column on a different table; `Job::ReconcilePayments` scans statuses that do not include it. Task 9 writes the manual clearance procedure instead of implying automation exists.
4. **`sql/revert/enrollment-payment-dedup.sql:17` is already a silent no-op** for tenants cloned after that change — it drops `enrollments_payment_dedup` by name, and the tenant copy is `enrollments_session_id_student_id_payment_id_idx`. Pre-existing, found while mapping this leg, not introduced here. It is invisible because that change is not on `@CHANGES`.
