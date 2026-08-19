# PriceOps Leg 0: The Money Path Becomes Atomic and Observable

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

> ## STATUS — read before following any step below
>
> **Implemented and merged:** Tasks 0, 1, 1b, 2, 3, 4, 5a, 5b.
> **Not implemented:** Tasks 6, 7a, 7b, 7c, 8, 9.
>
> **The guards this plan specifies in Tasks 2 through 5b are superseded.** Three
> adversarial review rounds found 21 defects in them; 16 are fixed and **five
> remain open by decision**. Read
> [`docs/superpowers/specs/2026-08-18-payment-settlement-state-machine.md`](../specs/2026-08-18-payment-settlement-state-machine.md)
> **first** — it lists the open defects and the design that closes them.
>
> Steps in implemented tasks are ticked. An unticked box in Tasks 0-5b means the
> step was deliberately not done and the task body says why. Line numbers in
> unimplemented tasks have drifted; re-derive them by searching for the text.
>
> **No live card goes through this path** until the state-machine spec's status
> CHECK constraint and conditional-UPDATE write path land.


**Goal:** Make settlement atomic — one transaction on one connection — take the row and session locks that the #283 guards assume, re-check capacity at capture with a correct predicate, and give the resulting refund somewhere to go.

**Architecture:** Leg 0 is the second leg of the PriceOps alignment milestone (spec: `docs/superpowers/specs/2026-08-07-priceops-alignment-design.md`, Leg 0's row at spec `:2965`). Leg 1 shipped the deletions and the revert-test harness; this leg rewrites the live money path underneath. Every task after Task 1 is *inside the transaction Task 1 opens*, which is why the ordering here is stricter than Leg 1's.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, Minion, PostgreSQL, Sqitch, `Test::PostgreSQL`, `prove`.

**Base commit — read this before touching any cited line.** Every `file:line` in this document resolves against **`main` with PR #314 merged**, and against nothing else. #314 (`24d2cb9`, `91cdeeb`, `9527c85`, `c64a5cb`) inserts twelve lines into `lib/Registry/DAO/WorkflowSteps/Payment.pm` after old line 100, so every citation into that file past `:100` shifts by **+12** between the two trees: the spec's `:152-154` reuse guard is this document's `:166`, its `:251-252` is `:263-264`, `:267` is `:279`, `:372` is `:384`. Both numbers are correct for their own tree, which is exactly what makes the mix dangerous. **Do not start this leg until #314 is merged and the branch is rebased onto it.** Declared Deviation 5 depends on it too — the four items it calls "already done" exist only post-#314.

**Editing rule, carried from Leg 1:** only defects that change what an executing worker *does* are corrected here — line numbers and ranges, step ordering, code, SQL, commands, gate patterns and their match counts, `git add` file lists, safety constraints. Prose inaccuracies are recorded in a companion file. Nine plan-review rounds on Leg 1 established that rewriting argument introduces defects at roughly the rate it removes them.

## Global Constraints

Copied from Leg 1, plus this leg's own.

- **A deployed change is retired by a new change, not by deleting a file.** Never `git rm` a file under `sql/deploy/`, `sql/revert/`, or `sql/verify/` named in `sql/sqitch.plan`, and never edit a deployed change's **deploy** script. Editing a **verify** script is safe — sqitch hashes the deploy script only.
- **A migration registers with the revert harness in the same commit that appends to `sql/sqitch.plan`** — append its change name to `@CHANGES` in `t/database/revert-round-trip.t`, in plan order. Skipping it is silent: the suite still prints `All tests successful` and only the test count moves. Read the count.
- **`@SLUGS` in that harness holds five reserved-word slugs and three are used; this leg takes it to six.** Task 0 appends a sixth (`default`, verified to clone — 41 tables — and to render quoted in `pg_dump`), and this leg's **three** migrations then consume all six. The harness asserts `@CHANGES <= @SLUGS` at `:87` and pairs them positionally at `:94`. The next migration-bearing leg must extend the list again, and the replacements must also be SQL reserved words; mixed case and hyphens were tried against live Postgres and break `clone_schema`, not the migrations. (`limit` is a verified fallback if a seventh is ever wanted.)
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
- **`grep` exits 1 when it finds nothing, including `grep -c`, which prints `0` and still exits 1.** Every `-- 0` criterion in this document therefore carries `|| true`; without it a *satisfied* gate reports failure to any harness reading `$?`. A criterion naming a file the task has yet to create exits **2**, not 1.
- **Always `grep -F` for patterns containing `$`, and never trust a bare `grep`.** The two greps on this machine disagree: `/usr/bin/grep` (GNU) treats a mid-pattern `$` as a literal, while the `grep` on `PATH` in an agent shell is **ugrep 7.5.0**, which treats it as an anchor anywhere. `grep -c "unless \$status eq 'completed'"` returns 2 under one and 0 under the other. `-F` makes both agree. This is not style: two gates in the first draft of this plan were silently inert because of it.
- `grep -c` over multiple files prints one line per file and **no total**; ugrep also reorders them. State a per-file expectation, never a combined number.
- Use `carton exec -- <cmd>`, with the `--`. Without it carton swallows arguments: `carton exec sqitch add zzz -n 'probe'` reports `Unknown argument "probe"`, and `carton exec sqitch --version` prints carton's own version.
- Object::Pad methods take no explicit `$self`. Use the `isa` operator, not `ref eq`. Every file starts with two `# ABOUTME: ` lines. Comments are evergreen.
- Full suite is ~17 minutes with `-j8`. Run it once, at the end.

## Declared Deviations From The Spec

Thirteen places where this plan does something other than what the spec's Leg 0 row says. All thirteen are deliberate, and six exist because the row is wrong about the code. Each was verified by reading or running, not inferred. Items 9-13 were argued in task bodies for two rounds without being listed here, which is exactly the failure this section exists to prevent.

1. **The capacity refund calls `refund_async`, not `Payment::refund`.** The spec names `Payment::refund` at `:4540`, `:4544`, `:4857` and in the row. That method reaches `create_refund` → `_await`, which dies with *"Synchronous Stripe call did not settle - it was likely made inside a running event loop"* (`Service/Stripe.pm:246-249`). Both settlement paths run under the IOLoop — the webhook is a controller action, and `_settle_callback` runs inside a `->then` (`WorkflowSteps/Payment.pm:263-264`). The spec knows this rule; it applies it to `publish_version` in Leg 6 at `:3154` and never back-propagates it. `refund_async` (`:571-601`) carries the identical guard at `:572` and the identical whole-payment default at `:575`.

2. **The capacity predicate is a new sub; `count_for_session` is left alone.** The row reads as an instruction to fix the primitive. It has other callers in four files, at five call sites — `MultiChildSessionSelection.pm:103`, `Enrollment.pm:301`, `SelectTargetSession.pm:19`, `ValidateTargetCapacity.pm:23` and `:35` — none of which has a payment in hand, and the transfer-path callers genuinely want the unfiltered count. Self-exclusion there is inert at best.

3. **Session locks are taken in sorted order.** The spec calls the lock "one statement in a block that is already open" (`:4525`), which is true only for a single-session cart. A multi-session cart takes one lock per item, iterating `keys %selections` (`MultiChildSessionSelection.pm:135`) — Perl's randomized hash order, fixed per process, differing between processes. Two concurrent two-session carts over the same pair deadlock; reproduced, then fixed by sorting. Lock the distinct session ids sorted, before the count.

4. **The predicate has a NULL branch — and a zero branch.** `sessions.capacity` is nullable (`sql/test-schema.sql:1366`; `Session.pm:21` defaults to `undef`) and the existing check guards it (`MultiChildSessionSelection.pm:102`). The spec's stated comparison has no NULL handling; written literally, every uncapped session refunds at capture. Zero needs the same treatment for a different reason: no CHECK constraint forbids it, and nine live sites read `0` as unlimited. See Task 5a Step 4.

5. **Four of the row's items are already done.** The `payment_id` scalar refusal, the server-owned run-data keys, the `session_for_<id>` subset check, and `get_subscription_config` taking its run all shipped in the hardening PR (#314) because they are unauthenticated, live, and independent of this leg's transaction work. What remained of the reuse-guard item — the status allow-list and the `workflow_run_id` ownership check — **is now done**: Task 3 replaced the `ne 'completed'` deny-list-of-one with `_reusable_payment_row`, an allow-list of `pending`/`processing` plus run ownership.

6. **#247 is only half closed, and this plan says so.** The issue's own evidence is stale — it cites `Webhooks.pm:93-118` for a registry/tenant split that #237 already fixed. Its *second* half is `Payment.pm:355`'s `return unless @$items`: a payment with no `enrollment_items` is marked `completed`, returns 200, and enrolls nobody. Making the claim and the work atomic does not make a no-op loud. This leg does not close that half; it is recorded under Coverage Gaps.

7. **`mark_completed` is a behaviour change, not a refactor.** The spec says a literal swap "writes back the loaded `'pending'` and a NULL `completed_at`" (`:1643`). The webhook never writes `completed_at` today (`Webhooks.pm:132-135` writes two columns), while the callback path does (`Payment.pm:318-321`) — so webhook-settled payments currently have `completed_at IS NULL`, and this leg starts populating it. `save` also rewrites the whole metadata blob, a wider write than `update`'s patch.

8. **The demotion is an `UPDATE`-then-`INSERT`, not a fourth parameter on `create_for_payment`.** The sub hardcodes its arbiter (`Enrollment.pm:94-96`) and takes `($class, $db, $data)` — there is no slot for a conflict action, and `finalize_enrollment` is its only caller. The spec offers this alternative itself at `:4505` and it is the smaller diff.

9. **Task 1 erases the subscription-event failure marker, and this leg accepts that only if it is compensated.** `Subscription::process_webhook_event` writes `processing_status = 'failed'` to `registry.subscription_events` and *then* dies (`Subscription.pm:250-258`). Today that marker survives because there is no transaction; under Task 1 the ROLLBACK takes it with the claim. Task 1's last negative scenario requires the write to be moved outside the transaction or re-issued after rollback. Same weight as Deviation 7 and it was undeclared for two rounds.

10. **Post-COMMIT work uses a tenant-scoped DAO, not the spec's session-level `set_config`.** The spec mandates `set_config('search_path', $1, false)` at `:1618-1628`, reasoning correctly that `Payment::save` writes unqualified `payments` and `registry.payments` is a real table, so a wrong-path write matches nothing and returns quietly. Both of the spec's own options fail here: session-level poisons the connection pool (Mojo::Pg re-applies `search_path` only on new handles), and a caller-owned second transaction cannot span `refund_async`'s internal `->then`. `$dao->connect_schema($slug)->db` is neither — Mojo::Pg sets the path at handle open. The spec's compensating assertion is retained in full: assert against `<tenant>.payments` **by qualified name**.

11. **Task 1b is new structural work the row does not contain.** The row and spec `:1584-1628` scope atomicity to the webhook. A transaction on the callback path is this leg's second-largest change. It is required — `->begin` is 0 across all four money-path files, and spec `:4497-4500` does demand the capacity gate on both callers, which cannot be honoured without a container on both — but it is scope the row does not name.

12. **The idempotency token keeps its shipped name.** The row says `metadata[registry_idempotency_token]`; the live key is `idempotency_token` (`Payment.pm:129`, flattened to Stripe by `_stripe_metadata_params:51-62`). It predates #314 and is already on live Stripe objects, so renaming is a live-data change. Adopting the shipped name is the smaller diff.

13. **Task 7b passes the tenant id through from `TenantPayment.pm:318-322`.** The row asks only that the tenant write join the transaction, read `trial_end` defensively, and cancel what it cannot record. The pass-through comes from a different spec bullet (`:2708-2711`) that names no leg. Without it the row's own item is dead code, since `Subscription.pm:131` and `:144` both sit under `if ($tenant_id)`.

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

`sql/test-schema.sql` citations across the spec are stale because Leg 1's `cda1f33` regenerated the dump — but **no single offset generalizes**, so do not adjust an uncited line by a rule of thumb. The three measured deltas are **−94** (3488→3394), **−78** (2913→2835) and **−38** (1178→1140): `cda1f33` was `+161/−337` on that file, distributed unevenly, and the drift shrinks toward the top. Re-derive any line not in the table above by searching for the text. This leg regenerates the dump again. (`sql/test-schema.sql:1178-1191` is cited twice in the spec — `:2182` and `:5078`; the table lists the first.)

---

### Task 0: `processed_at` on `registry.webhook_events`

**Files:**
- Create: `sql/{deploy,revert,verify}/webhook-events-processed-at.sql`
- Modify: `sql/sqitch.plan`, `t/database/revert-round-trip.t` (`@CHANGES` **and** `@SLUGS`)

**Interfaces:**
- Consumes: nothing. First task in the leg.
- Produces: `registry.webhook_events.processed_at`, which Task 1 stamps at COMMIT. `@SLUGS` gains a sixth entry, which Task 6 then consumes.

**Why this is first.** The spec requires it in the same paragraph as the atomicity work (`:1584-1590`: "Add `processed_at` to `registry.webhook_events`"), and Task 1 cannot stamp a column that does not exist. Verified against the tree: `registry.webhook_events` has exactly four columns — `id`, `stripe_event_id`, `event_type`, `received_at`. There is no `processed_at`.

**This is a registry-only table.** `clone_schema` does not mention `webhook_events`, and the only references in `lib/` are schema-qualified `registry.webhook_events` (`Controller/Webhooks.pm`, 2 hits). The tenant loop has nothing to do here — but the change still registers with the harness, because the harness grades the round-trip, not the tenancy.

**`@SLUGS` must grow before `@CHANGES` does.** The harness pairs them positionally (`:94`, `my $slug = $SLUGS[ $n++ ]`) and asserts `@CHANGES <= @SLUGS` at `:87`. `@SLUGS` currently holds five (`order user group table check`) and this leg adds three changes in total, so the list must reach six. The replacement must be a SQL reserved word in lowercase with no hyphens — mixed case and hyphens were tried against live Postgres and break `clone_schema`.

- [x] **Step 1: Extend `@SLUGS` to six** by appending `default`, and verify the new slug actually clones before relying on it: create a schema of that name through `registry.clone_schema('default')` against an ephemeral `Test::PostgreSQL` and assert it succeeds. If it does not, pick another reserved word and repeat — do not proceed on an unverified slug.
- [x] **Step 2: `carton exec -- sqitch add webhook-events-processed-at --note '…'`.**
- [x] **Step 3: Write the deploy** — `ALTER TABLE registry.webhook_events ADD COLUMN processed_at timestamptz;`
      **Be honest about what this column is for.** An earlier draft justified it as state tracking — "rows claimed but not yet finished have no value, and that is the state Task 9's runbook looks for." Both halves are false. Task 1 makes that state unreachable: with the claim inside the transaction, the release deleted and the stamp before COMMIT, `processed_at IS NOT NULL` is equivalent to the row existing, and nothing else writes the table (2 references, both in `Webhooks.pm`). And Task 9's runbook queries `payments` for `refund_pending` per tenant schema; it never reads `webhook_events`. The column's real value is **received→processed latency** — the leg is titled "Observable" and `received_at` alone cannot give you that. Keep it for that reason or drop this task; do not keep it for a reason that is not true. Contrast `registry.subscription_events` (`sql/test-schema.sql:1377-1386`), which carries `processed_at` *and* `processing_status`, and is load-bearing precisely because its claim survives a failure.
- [x] **Step 4: Write the revert and verify.**
- [x] **Step 5: Append the change to `@CHANGES` in the same commit** that appends to `sql/sqitch.plan`. Skipping this is silent — the suite still prints `All tests successful` and only the count moves.
- [x] **Step 6: Run `t/database/`.** Baseline is `Files=3, Tests=24, PASS`; expected **`Tests=25`**. One change adds **+1**, not +2: `prove` counts one test point per `subtest`, and `revert-round-trip.t:96` wraps each change in exactly one, with its two assertions inside. Measured by appending a real fourth entry and reading `Tests=4`. A count of 24 means the `@CHANGES` append was skipped.
- [x] **Step 7: Regenerate the test schema — `make test-schema`.** Without this the migration exists and `sql/test-schema.sql` does not know it, so every suite built from the dump still has the old table. Task 1 writes `processed_at` and dies with `column "processed_at" of relation "webhook_events" does not exist`, taking the whole webhook suite down with it. Found by executing Task 1: the plan's only `make test-schema` was in Task 6, six tasks too late for the column Task 1 depends on. Confirm the column reached the dump — `awk '/^CREATE TABLE registry.webhook_events/,/^\);/' sql/test-schema.sql` must show `processed_at`. **Do not** grade this with Task 6's DDL-churn expression: measured here, it reads **0** for this change, because a bare `ADD COLUMN` renders as an indented column line and nothing at line start.
- [x] **Step 8: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] The column exists (`grep -cF 'processed_at' sql/deploy/webhook-events-processed-at.sql || true` -- at least 1)
- [x] The harness grades it — `t/database/` goes **`Tests=24` → `Tests=25`**
- [x] `@CHANGES` is at 4 and `@SLUGS` is at 6:
      `carton exec perl -0777 -ne 'while(/my \@(CHANGES|SLUGS)\s*=\s*qw\(([^)]*)\)/gs){my@w=split " ",$2; print "$1 = ",scalar(@w),"\n"}' t/database/revert-round-trip.t`
      Reads `CHANGES = 3 / SLUGS = 5` now, must read `CHANGES = 4 / SLUGS = 6`.

### Negative Scenarios
- [x] **An unverified slug breaks `clone_schema`, not the migration.** Assert the sixth slug clones before it is committed. The failure surfaces in a later leg's migration, far from the change that caused it.
- [x] **A change that is not on `@CHANGES` is ungraded and silent.** Assert the test count moved; the verdict line says `All tests successful` either way.

---

### Task 1: One transaction, one connection — the webhook path

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm:44-49` (the claim), `:79-81` (the release — **deleted**, see Step 7), `:102` (the slug read, hoisted by Step 3), `:108-109` (the connection hop), `:131-138`
- Modify: `lib/Registry/DAO/Subscription.pm` (Step 6 hoists `get_subscription` out of the block; it is reached from `process_webhook_event`, not from `Webhooks.pm` directly)
- Test: `t/controller/payment-intent-webhook.t`
- Test (**breaks, and must be re-pointed**): `t/controller/webhook-tenant-payment-finalization.t`. Moving the tenant routing out of `_process_payment_intent_succeeded` changes that method's contract, and this file calls it **directly** six times with a registry-scoped DAO. Its first subtest is the *only* coverage of tenant routing, so re-point that one at a real signed POST through `stripe()` — handing the handler a pre-scoped connection makes the subtest pass while asserting nothing about which schema was chosen, which is the coverage the task is supposed to preserve. The other five call the handlers to test handler behaviour and only need the registry handle. **Grep for direct callers of any method whose signature this leg changes before starting a task** — a Files list that names only the source file has omitted a test whose assumptions the change invalidates three times now in this milestone.

**Interfaces:**
- Consumes: Task 0's `processed_at`.
- Produces: `stripe()` runs one `begin` at the top with the claim inside it, and no other transaction below. Every later task's lock and re-check on this path lives inside that block. Task 1b does the same for the callback path.

**The defect, restated — #247's body is stale.** The issue cites `Webhooks.pm:93-118` for a registry/tenant split that #237 already closed; both the `completed` write and `finalize_enrollment` already run on `$tdb`. What remains is that the **claim** (`:45-49`) and the **release** (`:81`) run on `$dao->db` while the work runs on a second pool from `connect_schema` (`:108`, `DAO.pm:104-106`). A crash between claim and work leaves a claimed event with nothing done, and the claim is not rolled back with it.

**One connection is guaranteed, and that is load-bearing.** `$dao->db` is a single field computed once (`DAO.pm:46-58`) — verified: three statements, one `pg_backend_pid`. Anything that acquires its own handle is a different backend and **cannot see the open transaction**: a second DAO reading `acme.payments` mid-transaction returns 0 rows. Note `$c->dao` is uncached by design (`Registry.pm:274-283`), so `Workflows.pm:407` and `:427` are already two different connections — which is why Task 1b has to be explicit about where its transaction lives.

- [x] **Step 1: Write the failing test** — a webhook delivery that dies mid-finalization must leave no claim in `registry.webhook_events` and no partial enrollment. Assert both.
- [x] **Step 2: Run it and watch it fail.** `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lv t/controller/payment-intent-webhook.t`. Baseline: `Files=1, Tests=4, PASS` — so the new assertion takes it to `Tests=5`. Expected: the claim survives the rollback.
- [x] **Step 3: Hoist the slug extraction into `stripe()`, above the `begin`.** This step exists because Steps 3 and 4 were mutually impossible in an earlier draft: `$slug` is read from `$event->{data}{object}{metadata}{tenant_slug}` at `:102`, inside `_process_payment_intent_succeeded`, which does not run until `:61`. Read it from the already-decoded event in `stripe()` instead, then resolve it to a tenant row — that lookup *is* the validation, and a slug resolving to no tenant never reaches `set_config`. Verified: `set_config` accepts a nonexistent schema silently and only fails later, at the first unqualified table reference. **Only `payment_intent.succeeded` carries a slug**; `account.updated` and the subscription branch have none, and for those the path stays `registry` with no `set_config` at all.
- [x] **Step 4: Open the transaction, and move the claim inside it.** This is the leg's headline act and it is a code change, not a consequence of the other steps: `my $tx = $db->begin;` in `stripe()` after Step 3's extraction, with the `INSERT … ON CONFLICT DO NOTHING` claim from `:45-49` now inside the block, on the same `$db`. Without this step the remaining steps produce a handler with `set_config` and no transaction — at which point `SET LOCAL` silently does nothing, per the Global Constraint.
- [x] **Step 5: Replace the `connect_schema` hop with `SELECT set_config('search_path', ?, true)`** inside the transaction, bound as a parameter so the slug never reaches SQL text, and pass the resulting `$tdb` down to `_process_payment_intent_succeeded`. Set it to `<tenant>, public` — do not widen with `registry`. Binding is genuinely safe, not merely conventional: Postgres validates the GUC rather than splicing it, and `'acme, public; DROP TABLE registry.payments'` is rejected with `invalid value for parameter "search_path"`.
- [x] **Step 6: Move `Subscription::get_subscription` out of the block** — this edits `lib/Registry/DAO/Subscription.pm`, which is why that file is on the Files list. It is the only blocking Stripe call inside the transaction (`Subscription.pm:319`, `:332`), it runs on a user agent with no request timeout, and it is reached five handlers deep from `process_webhook_event` (`:226-240`) with the id read from `$event->{data}`. Pre-fetch it before `begin` and pass it in. Anything doable before `begin` happens before `begin`.
- [x] **Step 7: Delete the catch-block release at `:81`.** With the claim inside the transaction the ROLLBACK removes it, and the old release now runs on a poisoned handle: reproduced, the catch-block `DELETE` dies with `current transaction is aborted, commands ignored until end of transaction block`. Proven that the rollback is sufficient *and* that redelivery still works — after a mid-flight die the claim count is 0 and the redelivery re-claims with `rows=1`, so the claim is genuinely rolled back, not merely invisible. Deleting this is required, not tidying.
- [x] **Step 8: Stamp `processed_at` and COMMIT.**
- [x] **Step 9: Do post-COMMIT work on a tenant-scoped DAO, not under a search-path override.** `$dao->connect_schema($slug)->db` returns a handle whose `search_path` Mojo::Pg set at open (`DAO.pm:39`), which is the one mechanism that is neither pool-poisoning nor transaction-bound. Do **not** use a session-level `set_config(…, false)`: it survives back into the pool, because Mojo::Pg's queue-reuse `return $dbh if $dbh->ping` precedes its `SET search_path` block — reproduced, the same pid comes back out with `search_path=acme` and unqualified `payments` resolving to the wrong tenant. And do **not** use a second short transaction: Task 5b's `refund_async` writes inside its own `->then` after a Stripe round-trip, so a caller-owned transaction either closes too early (the write lands on `registry` and affects 0 rows, silently) or is held across the network, which the Global Constraint forbids.
- [x] **Step 10: Add `$self->render_later` before returning.** `stripe()` does not call it today; the render only survives because `Mojolicious::Routes::_render` finds no `webhooks/stripe` template and `mojo.routed` suppresses the croak. Once this action returns a promise that is one added default template away from a silent double-render.
- [x] **Step 11: Run the test and the controller suite.** Expected: PASS.
- [x] **Step 12: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] One `begin` on this path (`grep -c -- '->begin' lib/Registry/Controller/Webhooks.pm || true` -- **0 now**, 1 after). The pattern is live, not dead: it returns 1 against `lib/Registry/DAO/Message.pm`.
- [x] `connect_schema` is gone from this path (`grep -cF connect_schema lib/Registry/Controller/Webhooks.pm || true` -- **1 now, 0 after**), and returns in Task 5b as **0 → 1**.
      **This gate spans two tasks and both earlier versions of it were wrong.** Round 1 wrote `1 → 0`, correct here but failing once 5b lands. Round 2 "corrected" it to `1 → 1` on the reasoning that Step 9 needs the call — but Step 9 describes *how post-COMMIT work must be done*, and **Task 1 has no post-COMMIT work**: the refund that needs a tenant-scoped handle is Task 5b's. Executing Task 1 reads 0. Grade Task 1 at 0 and Task 5b at 1; when 5b lands, grade the surviving call by position — after the COMMIT, never before the work.
- [x] The slug is bound, never interpolated (`grep -cF "set_config('search_path', ?" lib/Registry/Controller/Webhooks.pm || true` -- **0 now, exactly 1 after**). One, not two: Step 9 no longer uses `set_config` at all.
- [x] The catch-block release is gone (`grep -cF 'webhook_events' lib/Registry/Controller/Webhooks.pm || true` -- **2 now**; after, the remaining hits must not include a `DELETE` in a catch)
- [x] Webhook suite passes and grows (`Tests=4` → `Tests=5`)

### Negative Scenarios
- [x] **A `begin` on a second handle is the real hazard, not a nested one.** A nested `begin` on the *same* handle is loud — it dies with `Already in a transaction at Mojo/Pg/Transaction.pm line 20`. What is silent is a `begin` on a **different** handle: a separate transaction that sees neither the uncommitted rows nor the search path. `Waitlist.pm:195` and `:234` are the live examples of that shape. Assert one transaction on one handle.
- [x] **A slug that resolves to no tenant must not reach `set_config`.** Deliver a webhook whose metadata names a nonexistent tenant; assert it is refused before the transaction opens, not inside it.
- [x] **The claim must be released by the ROLLBACK, not by the catch block.** Assert that a die inside the block leaves no row in `webhook_events` even if the catch never runs.
- [x] **A session-level search path must not survive into the pool.** Assert that after the request, a fresh handle from the same pool resolves unqualified `payments` to `registry`, not to the tenant. (Control, measured: with a session-level `false` the reused handle comes back on `acme, public` and counts 1; with the transaction-local form it comes back on `registry, public` and counts 0.)
- [x] **The subscription branch's failure marker must not vanish with the rollback.** `Subscription.pm:250-258` writes `processing_status = 'failed'` to `registry.subscription_events` and *then* dies. Under this task that die unwinds a transaction wrapping the branch, so the ROLLBACK erases the marker along with the claim — a behaviour change from today, where it survives because there is no transaction. Assert the marker is still written, by moving that write outside the transaction or re-writing it after rollback. See Declared Deviation 9.

---

### Task 1b: The callback path gets a transaction

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/Payment.pm:263-264` (the `->then`), `:267-378` (`_settle_callback` — the whole method; an earlier draft cited `:267-284`, which stops 94 lines short and hides the decline branch)

**Interfaces:**
- Consumes: nothing from Task 1; the two paths are independent containers.
- Produces: `_settle_callback` returns a **promise**, and the work inside it runs in one transaction on one handle. Tasks 3, 5a and 5b install locks and re-checks on this path and require it.

**Why this task exists.** Measured across the money path, `grep -c -- '->begin'` is **0** in `Controller/Webhooks.pm`, `Controller/Workflows.pm`, `DAO/Payment.pm` and `DAO/WorkflowSteps/Payment.pm`. Task 1 builds a container on the webhook path only, but `_apply_intent` (Task 3) and `finalize_enrollment` (Task 5b) are reached from **both**. Without this task, those two tasks ship statements on this path that read like locks and are not — reproduced: two concurrent settlements under AutoCommit both act, the same code inside a transaction yields exactly one.

**This whole shape has been prototyped end to end and it works.** Implemented in the real file and driven over HTTP through `_process_step` with a genuinely deferred Stripe response, the ordering is exactly settle → COMMIT → post-COMMIT → render, and the six callback-path suites stay green at an unchanged `Files=6, Tests=30`.

**One correction to the worry that motivated this task.** `_settle_callback` is *mostly* synchronous — four of its five branches return a hashref (`:279-284`) — but the declined-card branch at `:341` **already returns a promise** (`return $cancel->then(...)`). So Mojo::Promise adoption through `handle_payment_callback`'s `->then` at `:264` is already proven in the shipped tree; the work is making the success branch match, not introducing a new mechanism. Note the consequence for the gate below: "assert the return value is a promise" passes today on the decline path, so it must be asserted on the **success** path specifically.

**The transaction must open inside the `->then`,** not before `process_payment_async`: opening it earlier holds a payment row lock across a Stripe network round-trip (`Payment.pm:563-569`) under the IOLoop.

- [x] **Step 1: Write the failing test** — two concurrent settlements of the same payment on the callback path; assert exactly one finalizes.
- [x] **Step 2: Run it.** Expected: both proceed.
- [x] **Step 3: Make `_settle_callback` return a promise** instead of a hashref.
- [x] **Step 4: Open one transaction spanning *both* money writes.** There are two, in two promise stages: `_apply_intent` sets `status = 'completed'` and saves (`Payment.pm:318-321`), then `_settle_callback` enrolls. A transaction in `_settle_callback` alone — which this task's Files list implied — leaves the completed-write outside it and Task 3's row lock inert on this path, and a failure between the stages still strands a row marked paid with no enrollment. Verified by execution: with the transaction in the second stage the payment reads `completed` with zero enrollments, the identical defect Task 1 closed on the webhook side.
      The fix is to give `process_payment_async` an optional settlement callback and run it inside the transaction it opens around its own completed-write. Called without one it behaves exactly as before, so its other callers are untouched. The transaction cannot open earlier — `retrieve_payment_intent_async` is a network round trip, and holding a payment row locked across it is what the Global Constraint forbids — and opening it later is what left the two writes apart. Between the two is the only place it fits.
      **Re-point the mocks in the same commit.** `t/dao/payment-failure-recovery.t` (×2), `t/controller/payment-return-callback.t` and `t/dao/payment-intent-destination-charge.t` all stub `process_payment_async`, three of them with `set_always`, which ignores arguments and silently drops the callback — the step then gets a raw Stripe result and never reaches `_settle_callback`.
- [x] **Step 5: Chain post-COMMIT work off the promise,** so Task 5b's refund resolves before the render. Verified ordering: settle-and-commit → refund resolves → render.
- [x] **Step 6: Run the workflow and payment suites.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] One `begin` on the callback path (`grep -c -- '->begin' lib/Registry/DAO/WorkflowSteps/Payment.pm || true` -- **0 now**, 1 after)
- [x] `_settle_callback` returns a promise (asserted in the test above)
- [x] Two concurrent settlements produce exactly one finalization

### Negative Scenarios
- [x] **A transaction opened before the Stripe call holds a row lock across the network.** Assert the `begin` follows the `->then`, not precedes `process_payment_async`.
- [x] **A synchronous return breaks the post-COMMIT chain.** If `_settle_callback` returns a hashref, Task 5b's refund cannot be sequenced after COMMIT. Assert the return value is a promise **on the success branch** — the decline branch at `:341` already returns one, so an unqualified assertion passes before any work is done.
- [x] **A `begin` on a handle other than the one doing the work is invisible.** `$c->dao` is uncached, so `Workflows.pm:407` and `:427` already hold two different connections. Assert the transaction and the work share a handle.

---

### Task 2: `mark_completed`

**Files:**
- Create: `mark_completed` on `lib/Registry/DAO/Payment.pm` (near `save`, `:425-435`)
- Modify (the two completed-writes): `lib/Registry/Controller/Webhooks.pm:132-135`, `lib/Registry/DAO/Payment.pm:316-321`
- Modify (`update` → `save` only, **not** `mark_completed`): `lib/Registry/DAO/Payment.pm:206-216`, `:218-226`

**Interfaces:**
- Consumes: Task 1's transaction.
- Produces: a mutating `mark_completed($db, $intent_id)`. Leg 9a extends the same field list for the quote stamp.

**Why not a literal swap.** All `Payment` fields are `:param :reader` with no writer (`:12-23`), so `save` writes back whatever was loaded. `update` (`Object.pm:38-49`) returns a *new* object and patches two columns; `save` (`:425-435`) writes six, including `metadata => { -json => ... }` unconditionally.

**There are exactly two completed-writes on the money path, and only they take `mark_completed`.** `Webhooks.pm:133` and `Payment.pm:318`. Verified across `lib/`: nothing else writes `status = 'completed'` on this path (`AdminDashboard.pm:37` is a query filter; the `transfer_status => 'completed'` hits are unrelated).

**The other two cited sites must NOT become `mark_completed`.** `Payment.pm:206-216` is `_record_intent`, which stamps an intent id on a still-**pending** row; `:218-226` is `_record_intent_failure`, which sets `status = 'failed'` and dies. Neither writes `completed`. Pointing them at `mark_completed` would mark a payment completed at intent-creation time, and again on failure — a money bug inside the task whose purpose is to make settlement honest. They are on the Files list for the spec's separate `update` → `save` instruction (`:1630-1633`) and nothing more.

**Two behaviour changes to state, not hide.** The webhook does not write `completed_at` today; the callback path does (`Payment.pm:318-321`). After this task, webhook-settled payments get one — correct, and a data-shape change. And the webhook begins rewriting the metadata blob on every delivery, which is a new interleaving surface with the competing metadata write at `WorkflowSteps/Payment.pm:169-177` (`$updated_meta` → `$raw_db->update('payments', { … metadata => { -json => … } })`).

- [x] **Step 1: Write the failing test** — after a webhook settlement, `completed_at` is set and `metadata` is unchanged from what the callback wrote.
- [x] **Step 2: Run it.** Expected: `completed_at` is NULL.
- [x] **Step 3: Add `mark_completed`** — mutate `status`, `stripe_payment_intent_id`, `completed_at`, then `save`.
- [x] **Step 4: Swap the two completed-writes** — `Webhooks.pm:132-135` and `Payment.pm:316-321` — to `mark_completed`.
- [x] **Step 5: Separately, convert `_record_intent` and `_record_intent_failure` from `update` to `save`,** leaving their status semantics exactly as they are. This is the spec's `update` → `save` item, not the `mark_completed` item.
- [x] **Step 6: Run the payment and webhook suites.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] `mark_completed` exists and is the webhook's write (`grep -cF mark_completed lib/Registry/DAO/Payment.pm lib/Registry/Controller/Webhooks.pm` -- **0 for each now**; after, `Payment.pm` ≥ 1 and `Webhooks.pm` ≥ 1. This prints one line per file and **no total** — a single combined number is not available from `grep -c`, so read both lines.)
- [x] Webhook-settled payments carry `completed_at` (asserted in the test above)

### Negative Scenarios
- [x] **A literal `save` swap writes back the loaded `pending`.** Assert the status after settlement is `completed`, not the loaded value.
- [x] **The metadata blob must survive.** Assert `enrollment_items` is intact after the webhook writes, since `save` rewrites the whole column.
- [x] **`mark_completed` must not reach the intent-recording sites.** Assert that creating a payment intent leaves `status = 'pending'` and `completed_at IS NULL`, and that a failed intent leaves `status = 'failed'`. This is the scenario that catches "swap the three call sites" being read literally.

---

### Task 3: `SELECT … FOR UPDATE` on the payment row

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm:112` (the `Payment->find` that must take the lock; the checks it feeds are at `:123-136`), `lib/Registry/DAO/Payment.pm:266-343` (`_apply_intent`), `lib/Registry/DAO/WorkflowSteps/Payment.pm:164-166`

**Interfaces:**
- Consumes: Task 1's transaction **and Task 1b's**. A lock outside one is released immediately.
- Produces: every read-decide-write on a payment row holds it.

**Two sites, not one.** The spec enumerates `_apply_intent`'s guards and never mentions that `Webhooks.pm:123-136` carries its **own** copy of the amount and completed checks rather than calling it. A lock on one leaves the other racing.

**`_apply_intent` is reached from the callback path, which is why Task 1b exists.** Measured: `grep -c -- '->begin'` is **0** in `Controller/Webhooks.pm`, `Controller/Workflows.pm`, `DAO/Payment.pm` and `DAO/WorkflowSteps/Payment.pm` — the entire money path opens no transaction today. Task 1 builds one on the webhook path only. Reproduced against live Postgres, two concurrent settlements of the same row: with `FOR UPDATE` under AutoCommit both act (**2 settlements**); with `FOR UPDATE` inside a transaction, one acts (**1 settlement**). Installing this lock before both paths have a transaction ships a statement that reads like a lock and is not one.

**The mechanism already exists.** `SQL::Abstract::Pg` supports `for`, and `Object::find` passes its 4th argument through as options (`Object.pm:16`). Verified by execution against a real DBI prepare callback: `Payment->find($db, {id=>$id}, { for => 'update' })` renders `SELECT * FROM "payments" WHERE "id" = ? FOR UPDATE`. No new SQL.

**One footgun in that 4th argument.** It is the `$order` parameter and it defaults to `{ -desc => 'created_at' }` (`Object.pm:14`; `:16` is the pass-through line). Passing `{ for => 'update' }` **silently drops the `ORDER BY`**. Harmless for a find-by-id, which is what both sites do. Do not copy the pattern to a non-unique filter without restoring the sort — `find` returns `->first` in scalar context, so the row you lock becomes arbitrary.

**Also here: the reuse guard's allow-list.** `WorkflowSteps/Payment.pm:166` is still `ne 'completed'` — a deny-list of one that admits `refunded` and `partially_refunded`, driving a refunded row back to `completed`. Replace with an allow-list of `pending`/`processing`, and reuse the row only when `$existing->metadata->{workflow_run_id}` equals `$run->id` — a linkage `create_payment` writes and nothing has ever read back.

- [x] **Step 1: Write the failing test** — two concurrent settlements of the same payment; assert exactly one finalizes.
- [x] **Step 2: Run it.** Expected: both proceed.
- [x] **Step 3: Take the lock in `_apply_intent`** before the ownership check at `:274`.
- [x] **Step 4: Take the lock in `Webhooks.pm`** before the amount check at `:123`.
- [x] **Step 5: Rewrite the reuse guard** — allow-list plus the `workflow_run_id` ownership check.
- [x] **Step 6: Run the payment, webhook and workflow suites.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] Both sites take the lock (`grep -cF "for => 'update'" lib/Registry/DAO/Payment.pm lib/Registry/Controller/Webhooks.pm` -- **0 for each now**, at least 1 for each after. This prints one line per file and no total; read the per-file lines. Note ugrep reorders the file list.)
- [x] The reuse guard is an allow-list (`grep -cF "ne 'completed'" lib/Registry/DAO/WorkflowSteps/Payment.pm || true` -- **1 now** (`:166`), 0 after)
- [x] `workflow_run_id` is read, not only written (`grep -cF workflow_run_id lib/Registry/DAO/WorkflowSteps/Payment.pm || true` -- **1 now** (`:210`, the write), at least 2 after)

### Negative Scenarios
- [x] **A refunded row must not be reusable.** Set a row to `refunded`, plant its id, assert reuse is refused.
- [x] **Another run's payment row must not be reusable** even when its status is `pending` — the ownership check, not the status check, is what refuses it.
- [x] **A lock taken outside the transaction is not a lock.** Assert the lock statement is inside the block Task 1 opened, not before it.

---

### Task 4: Refund plumbing

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:449` and `:572` (the guards), `lib/Registry/Service/Stripe.pm:173-175` and `:267-269`
- Create: a per-child share resolver on `Payment`

**Interfaces:**
- Consumes: nothing from 1-3, but must precede Task 5b.
- Produces: `refund_async` accepts `refund_pending`; `create_refund_async` accepts `_idempotency_key`; a resolver taking `(child_id, session_id)` that Leg 3 reuses with a per-enrollment argument.

**Why this precedes the capacity branch.** Task 5 writes `payments.status = 'refund_pending'` and then calls the method whose first line is `die … unless $status eq 'completed'`. The refund never reaches Stripe. The guard rewrite and the key must be in the same commit as the first `refund_pending` write.

**The refund share.** `refund_async:575` defaults to the whole payment, and a payment is a family cart — refunding "the payment" for one child returns every sibling's money. Resolve through `payment_items.metadata->{child_id, session_id}`, which `calculate_enrollment_total:531-538` already writes on every row. **Not** `payment_items.enrollment_id`: line items are written before the charge and enrollments after settlement, so the column cannot be populated at the natural write point — it would need a second write inside `finalize_enrollment`, a backfill migration, and a third `@SLUGS` entry this leg does not have.

**Use `_idempotency_key` extract-and-delete**, copying `create_payment_intent_async:72-76`. Stripe rejects unknown form parameters, so it must be deleted before the POST. A positional argument would break `t/dao/refund-application-fee.t`, which monkey-patches both methods with two-argument signatures at `:264,311,339,368,404`.

- [x] **Step 1: Write the failing tests** — a `refund_pending` payment can be refunded; a refund carries an idempotency key; a per-child refund returns one child's share, not the cart.
- [x] **Step 2: Run them.** Expected: the guard rejects, no key is sent, the whole cart is refunded.
- [x] **Step 3: Rewrite both guards as allow-lists** of `completed`/`refund_pending`. Both entry points move together.
- [x] **Step 4: Thread `_idempotency_key`** through `create_refund_async` and `create_refund`.
- [x] **Step 5: Add the share resolver.**
- [x] **Step 6: Run the refund suite.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] Both guards accept `refund_pending` (`grep -cF "unless \$status eq 'completed'" lib/Registry/DAO/Payment.pm || true` -- **2 now** (`:449`, `:572`), 0 after). `-F` is load-bearing and this criterion is the reason the Global Constraint exists: without it `$status` is read as an anchor, the count is 0 before any work, and the gate can never fail.
- [x] `create_refund_async` threads a key (`grep -cF _idempotency_key lib/Registry/Service/Stripe.pm || true` -- **1 now** (`:74`), **exactly 2 after**). Two, not "at least 3": `create_refund` delegates to `create_refund_async` (`return $self->_await($self->create_refund_async($params))`), so the params — key included — reach the one extraction that exists. A second extraction in the sync method would be dead code. Assert the sync path carries the key by exercising it, not by counting greps; "needs no extraction" and "has no key" look identical from outside.
- [x] `t/dao/refund-application-fee.t` still passes unchanged (baseline measured: `Files=1, Tests=15, PASS`)

### Negative Scenarios
- [x] **`_idempotency_key` must not reach Stripe as a form parameter** — Stripe 400s on unknown params. Assert it is deleted from the payload.
- [x] **A `pending` payment must still be refusable.** The allow-list must not become "anything".
- [x] **The share resolver must not fall back to the cart total silently** when metadata is missing; assert it refuses.

---

### Task 5a: Sorted session locks and the capacity predicate

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:350-385` (`finalize_enrollment`)
- Create: a capacity predicate sub on `lib/Registry/DAO/Enrollment.pm`

**Interfaces:**
- Consumes: Tasks 1 and 1b (the transaction on **both** paths) and Task 3.
- Produces: a predicate `(payment, session_id)` returning whether this payment's items still fit, with the session row locked. Task 5b consumes it. `count_for_session` is untouched.

**Order within this pair is strict.** Sorted locks → predicate (5a) → demotion → wiring (5b). The predicate must land before the branch, or the branch fires on a false positive.

- [x] **Step 1: Write the failing test** — a session at capacity, a payment captured for the last seat by someone else first; assert the predicate says it does not fit.
- [x] **Step 2: Run it.** Expected: the predicate does not exist; the count includes this payment's own rows.
- [x] **Step 3: Take session locks, sorted, inside `finalize_enrollment`.** `SELECT id FROM sessions WHERE id = ANY(?) ORDER BY id FOR UPDATE`, over the **distinct** session ids in the cart, derived from `$metadata->{enrollment_items}` (`Payment.pm:351-354`; `$item->{session_id}` at `:360`) — that is the cart, in the one method both settlement paths call. Verified against live Postgres: `EXPLAIN` puts `LockRows` **above** `Sort (Sort Key: id)`, so rows are locked in sorted order; run concurrently, the unsorted form deadlocks and the sorted form does not. If cart ids are also sorted in Perl anywhere, plain `sort` matches Postgres `uuid` ordering, because canonical lowercase hex sorts identically to the 16-byte comparison and Postgres always emits lowercase. **Do not** try to reuse `MultiChildSessionSelection.pm:87`'s `@unique_sessions`: it is a lexical inside the sibling-rule branch (`:85-92`) of a pre-checkout workflow-step class, does not exist on the ordinary path, and has no `%selections` in scope here.
- [x] **Step 4: Add the predicate as a new sub** — count `active`/`pending` rows for the session **excluding those whose `payment_id` is this payment**, and compare `count + (this payment's items for this session)` against capacity. Leave `count_for_session` alone; the transfer-path callers want the unfiltered count. **A NULL *or zero* capacity is unlimited** — return early, do not compare. Zero is not hypothetical: there is **no CHECK constraint on `sessions.capacity`**, so `0` is storable, and nine live sites already read it as unlimited — `ValidateTargetCapacity.pm:22`, `SelectTargetSession.pm:20`, `Enrollment.pm:302`, `MultiChildSessionSelection.pm:102`, `:106`, `:213`, `:236`, `:303`, `:309`. A predicate written `return unless defined $capacity` refunds every capacity-0 session at capture while all nine pre-checks wave the enrollment through. This is the same `defined`-versus-truthy distinction Task 8 turns the other way, and the two must not be conflated: an undefined **price** is a refusal, an undefined **capacity** is permission.
- [x] **Step 5: Run the gate ahead of the enrollment writes, inside the same method.** `finalize_enrollment` writes this payment's rows as `active` in the loop at `:360` onward, so a re-check after that loop counts itself. Gate first, then write. The two call sites (`Webhooks.pm:138`, `WorkflowSteps/Payment.pm:279`) are unchanged by this task.
- [x] **Step 6: Run the payment suite.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] Locks are sorted (`grep -cF 'ORDER BY id' lib/Registry/DAO/Payment.pm || true` -- 0 now, at least 1 after)
- [x] `count_for_session`'s body is unchanged. Two grep forms both fail here and neither should be used. Counting all diff lines matches unchanged **context** and gives a false positive (demonstrated by touching a line three away from the call site at `:301`, which this task and Task 6 both edit). Counting only changed lines fixes that but is **blind in the other direction**: the sub is `Enrollment.pm:214-223` and its body (`215-222`) never contains the string `count_for_session`, so editing the body while leaving the signature alone scores 0 and passes. Diff the sub itself:
      `diff <(git show origin/main:lib/Registry/DAO/Enrollment.pm | sed -n '/sub count_for_session/,/^    }/p') <(sed -n '/sub count_for_session/,/^    }/p' lib/Registry/DAO/Enrollment.pm) | wc -l`
      -- **0 now, 0 after.**
- [x] The predicate excludes this payment's own rows (the test above)

### Negative Scenarios
- [x] **An uncapped session must not refund.** Assert **both** a NULL-capacity and a **zero**-capacity session enroll normally. Zero is the one a `defined` check gets wrong.
- [x] **A two-sibling cart must not pass `9 >= 10`.** The comparison is `count + this payment's items`, not `count` alone.
- [x] **Two concurrent multi-session carts must not deadlock.** Assert the lock order is deterministic.
- [x] **A lock taken outside a transaction is not a lock.** Assert this runs inside the block Tasks 1/1b opened, on the path under test.

---

### Task 5b: The capacity-gone branch — demote, then refund after COMMIT

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm:350-385` (`finalize_enrollment`), `lib/Registry/DAO/Enrollment.pm`
- Modify: `lib/Registry/Controller/Webhooks.pm` (the post-COMMIT refund call site only — **not** `:138`, which does not change)

**Interfaces:**
- Consumes: Task 5a's predicate, Task 4's `refund_pending` guard and per-child share.
- Produces: capacity is re-checked at capture on both settlement paths, and the loser is demoted and refunded.

**The gate lives inside `finalize_enrollment`, and the two call sites do not change.** `Webhooks.pm:138` and `WorkflowSteps/Payment.pm:279` are identical one-line `$payment->finalize_enrollment($db)` calls, and `finalize_enrollment` already derives the cart from `$metadata->{enrollment_items}` at `:351-354` and reads `$item->{session_id}` at `:360`. It is the only place holding the session ids, and both paths route through it. An earlier draft put the lock inside and the gate at the callers, which runs the count **unlocked** — the exact race the lock exists to close.

**The demotion must land *with* the branch,** because a branch that inserts is silently a no-op: the arbiter at `Enrollment.pm:94-96` is `DO NOTHING` on exactly the three columns `finalize_enrollment` already wrote.

**The refund must be issued on a tenant-scoped handle, not under a search-path override.** `refund_async` does its own write — `$self->save($db)` at `:596`, **inside its own `->then`**, after the Stripe round-trip — so the caller cannot wrap it in a transaction. Proved against live Postgres: with the post-COMMIT handle back on `registry, public`, that save runs `UPDATE payments` and affects **0 rows**, silently, because `save` discards `->rows`. Stripe refunds the customer, the row stays `refund_pending` forever, and `metadata.refund_id` is never recorded. Pass a `$dao->connect_schema($slug)->db` instead: that DAO's Mojo::Pg sets `search_path` at handle open (`DAO.pm:39`), so the write lands in the tenant with no transaction and no `set_config`. This is why the callback path never had the bug — `$self->dao->db` is already tenant-scoped there.

- [x] **Step 1: Write the failing test** — the loser of a last-seat race is waitlisted and refunded, not enrolled. Assert the refund bookkeeping by its **qualified** name (`<tenant>.payments`); an assertion that reads whatever unqualified `payments` resolves to is one this bug passes.
- [x] **Step 2: Run it.** Expected: both enroll; the session oversells.
- [x] **Step 3: Write the capacity-gone branch inside `finalize_enrollment`** — `UPDATE` the enrollment to `waitlisted`, then `INSERT` only on zero rows; set `payments.status = 'refund_pending'`. (`enrollments_status_check` at `sql/test-schema.sql:839` permits `waitlisted`, and `payments.status` carries no CHECK constraint, so both writes are legal.)
- [x] **Step 4: Commit the transaction, then refund on a tenant-scoped handle.** Call `refund_async($tenant_db, …)` with `Idempotency-Key: refund:capacity:<payment_id>` and the per-child share from Task 4 — after COMMIT, never inside, and never on the post-COMMIT `registry`-scoped handle.
- [x] **Step 5: Put a `->catch` on the post-COMMIT chain that logs and still renders success.** Without it a *failed* refund turns a fully-settled delivery into a 500 — measured on both paths. On the webhook that means Stripe retries a delivery whose claim is already committed, gets `200 (duplicate)`, never retries the refund, and counts a 500 against an endpoint it will eventually disable. On the callback path `_persist_step_result` sits downstream of the promise (`WorkflowRun::process:99-101`), so the run pointer never advances: the parent is charged, enrolled, demoted, and left on "Workflow error". Process death is the rare case; refund *failure* is the common one.
- [x] **Step 6: Run the payment, webhook and integration suites.** Expected: PASS.
- [x] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [x] The loser of a last-seat race is waitlisted and refunded (the test above)
- [x] The refund's own status write lands in the tenant schema — assert `<tenant>.payments.status = 'refunded'` **by qualified name**, and assert `registry.payments` gained no row
- [x] The tenant-scoped handle for the post-COMMIT refund exists. Match the **call**, not the word — a bare `grep -cF connect_schema` also counts the comment that explains why the call is there, and reads 2 for a correct implementation:
      `grep -c -- '->connect_schema(' lib/Registry/Controller/Webhooks.pm || true` -- **0 entering this task, exactly 1 after** (Task 1 removed the transaction-path call; this task reintroduces one after the COMMIT).
      Third gate in this leg to grade a string that appears in prose as well as code. Anchor on syntax whenever the token is something the surrounding comments would naturally name.
- [x] Both paths reach the gate without either call site changing

### Negative Scenarios
- [x] **A plain `waitlisted` insert is discarded in silence.** Assert the row's status actually changed, not that a statement ran.
- [x] **The refund must be issued after COMMIT.** A refund inside the transaction is not undone by the ROLLBACK the leg's correctness rests on, and the redelivered webhook then refunds a partial twice. Assert ordering.
- [x] **A 0-row UPDATE is the failure mode, not an exception.** `save` discards `->rows`. Assert the row actually changed rather than that the call returned.
- [x] **A failed refund must not fail the delivery.** Assert a rejecting `refund_async` still renders 2xx on the webhook path and still advances the run on the callback path.
- [x] **A process death between COMMIT and refund strands a `refund_pending` row.** This is accepted and handled by Task 9's runbook, not by code. Assert the row is findable, not that it cannot happen.

---

### Task 6: The two migrations

**Files:**
- Create: `sql/{deploy,revert,verify}/payment-intent-unique.sql`, `sql/{deploy,revert,verify}/enrollment-status-aware-unique.sql`
- Modify: `sql/sqitch.plan`, `t/database/revert-round-trip.t` (`@CHANGES`), `sql/verify/flexible-enrollment-architecture.sql:8-18`, `sql/verify/fix-multi-child-enrollments.sql:21-31`, `t/dao/payment-finalization-idempotency.t:75-102`, `lib/Registry/DAO/Enrollment.pm:77`
- Regenerate: `sql/test-schema.sql`

**Interfaces:**
- Consumes: Task 0 (which extended `@SLUGS` to six and already appended one change) and Tasks 5a/5b (the partial index encodes the status vocabulary the gate uses).
- Produces: two graded migrations. Both go on `@CHANGES` — neither is data-only.

**Resolve by column set, never by name.** Reproduced against ephemeral Postgres: `registry` holds `enrollments_session_student_type_unique`, the tenant copy is `enrollments_session_id_student_id_student_type_key`. Resolve through `pg_constraint` on `(conrelid, contype='u', conkey)` and `ALTER TABLE … DROP CONSTRAINT <resolved>`. Never `IF EXISTS` — it turns the abort into a silent skip in the schema that holds money.

**Three traps inside that resolution, all reproduced.** Getting "resolve by column set" wrong fails as a `NO MATCH`, which under the no-`IF EXISTS` rule aborts the deploy:

1. **Compute the attnums per schema; never hardcode the array.** Attnums are identical across today's tenants (`{2,3,11}` in all three), but `clone_schema`'s `LIKE … INCLUDING ALL` **compacts dropped columns**. Once the source table has a dropped column, source `{3,4,5}` becomes tenant `{2,3,4}` — a hardcoded array matches in `registry` and nowhere else. Look the attnums up from each schema's own `pg_attribute`.
2. **`conkey` is declared order, not sorted order.** A constraint declared `(student_type, session_id, student_id)` stores `{4,2,3}`, and `array_agg(attnum ORDER BY attnum)` finds nothing. The live constraint happens to be ascending, so an order-sensitive comparison passes here **by luck**. Compare set-wise (`@>` and `<@`) plus cardinality.
3. **`pg_index.indkey` will not compare to an array.** Step 4's revert must resolve the *partial unique index* (`enrollments_payment_dedup`, tenant copy `enrollments_session_id_student_id_payment_id_idx`), and `indkey` is an `int2vector`: it casts to `[0:2]={2,3,9}`, and `'[0:2]={2,3,9}'::int2[] = '{2,3,9}'::int2[]` is **false**. A direct cast silently finds nothing. Use `string_to_array(indkey::text, ' ')` or `unnest`.

**Two deployed verify scripts break.** A partial unique **index** does not appear in `information_schema.table_constraints`, so `flexible-enrollment-architecture.sql:8-18` and `fix-multi-child-enrollments.sql:21-31` both `RAISE EXCEPTION` against the final schema — and `flexible-enrollment-architecture.sql:37-48` already asserts the other name in that `IN` list is gone, so there is no fallback. Strip both following Leg 1's precedent (`cda1f33`): remove the assertions, leave a comment pointing at the retiring change. Keep `:37-48`; it stays true.

**One test is semantically inverted, not just renamed.** `t/dao/payment-finalization-idempotency.t:97` asserts the error names the constraint, and the subtest asserts a re-registering parent *raises* — which is exactly what the partial index is meant to permit. Re-cut it. `Enrollment.pm:77`'s comment names the same constraint and becomes false.

- [ ] **Step 1: `sqitch add` both changes** with `--note` spelled in full, and append both to `@CHANGES` in the same commit. Use `carton exec -- sqitch …`: `carton` swallows more than `-n` — `carton exec sqitch add zzz -n 'probe'` reports `Unknown argument "probe"`, `carton exec sqitch --version` prints carton's version, and `carton exec sqitch add --help` prints `Carton::Doc::Exec`. The `--` is what makes the invocation mean what it says.
- [ ] **Step 2: Write the unique index on `payments.stripe_payment_intent_id`** with the tenant loop. A new name is safe. Do **not** drop the redundant `idx_payments_stripe_intent` — dropping it invokes the naming hazard for no benefit.
- [ ] **Step 3: Write the status-aware partial index**, resolving the old constraint by column set. Active statuses are `('active','pending')`, matching `enrollments_status_check` (`sql/test-schema.sql:839`).
- [ ] **Step 4: Write both reverts to drop by resolved identity**, not by name — the harness cannot catch a name-based revert for objects the change created.
- [ ] **Step 5: Strip the two verify scripts.**
- [ ] **Step 6: Re-cut `payment-finalization-idempotency.t:75-102` and fix `Enrollment.pm:77`.**
- [ ] **Step 7: `make test-schema`.** Do **not** grade this by line count. Measured on an unchanged tree, regeneration rewrites **322 lines** (not the ~157 an earlier draft claimed) and is **non-deterministic** — two consecutive runs differ in every seed row, because each carries fresh UUIDs, fresh timestamps and a new `\restrict` token. DDL churn on an unchanged tree is exactly **0**, so that is the signal: `git diff -- sql/test-schema.sql | grep '^[+-][^+-]' | grep -cE '^[+-](CREATE|ALTER|DROP|COMMENT)'` -- **0 before this task, non-zero after**. Commit the whole regenerated file.
      **Know what this gate cannot see.** It detects index, constraint and table churn, because those render at line start. A bare `ALTER TABLE … ADD COLUMN` is **invisible to it** — measured, its entire contribution to the dump is an indented column line inside `CREATE TABLE` plus a `COPY` header, neither of which starts with `CREATE|ALTER|DROP|COMMENT`. It fires correctly for *this* task (two `CREATE UNIQUE INDEX`es, and dropping the constraint removes an `ALTER TABLE ONLY registry.enrollments` line at `sql/test-schema.sql:2834-2835`), but it cannot confirm Task 0's column reached the dump. Do not reuse it as a general rule.
- [ ] **Step 8: Run `t/database/`.** **`prove` counts one test point per `subtest`, not per assertion** — `revert-round-trip.t:96` wraps each change in one subtest, so a change adds **+1**, measured by appending a real fourth entry and reading `Tests=4`. Baseline entering this task is therefore **`Tests=25`** (24 originally, plus Task 0's one), and two changes take it to **`Tests=27`**. The harness must also print `ok N - payment-intent-unique reverts cleanly` and one for the other. `Files` stays 3 either way — it is 3 today, so it grades nothing. A missing `ok` line means the `@CHANGES` append was skipped; read the count, not the verdict.
- [ ] **Step 9: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] Both changes are on `@CHANGES` and the harness grades them — `t/database/` goes **`Tests=25` → `Tests=27`** (one prove-counted test per change; the two assertions live inside the subtest)
- [ ] Neither migration names a constraint it did not create (`grep -cF 'DROP CONSTRAINT IF EXISTS' sql/deploy/enrollment-status-aware-unique.sql || true` -- 0. Without `|| true` this exits **2** before the file exists, not 0 — the file is created by this very task.)
- [ ] `@CHANGES` is at 6 and `@SLUGS` is at 6. A line grep cannot count these — the lists span lines. Runnable form:
      `carton exec perl -0777 -ne 'while(/my \@(CHANGES|SLUGS)\s*=\s*qw\(([^)]*)\)/gs){my@w=split " ",$2; print "$1 = ",scalar(@w),"\n"}' t/database/revert-round-trip.t`
      Reads `CHANGES = 4 / SLUGS = 6` entering this task (Task 0 appended one and extended the list), must read `CHANGES = 6 / SLUGS = 6` leaving it. The harness asserts `@CHANGES <= @SLUGS` at `:87`, so this is the ceiling again — the next migration-bearing leg extends the list.
- [ ] `make test` passes. Baseline measured: **`Files=254, Tests=2258, PASS`** in 1071s. Expect the file count to rise with the tests this leg adds and the test count to exceed 2258; a *drop* means something was silently skipped.

### Negative Scenarios
- [ ] **A name-based `DROP CONSTRAINT` aborts on a real tenant.** Assert the deploy survives a `clone_schema`d tenant carrying the regenerated name.
- [ ] **`IF EXISTS` turns that abort into a silent skip.** Assert the constraint is actually gone in the tenant, not just in `registry`.
- [ ] **A revert that drops by name is a no-op for later-cloned tenants** — the shape already latent in `sql/revert/enrollment-payment-dedup.sql:17`. Assert the revert drops by resolved identity.

---

### Task 7a: Both Stripe clients keep their response, and get timeouts

**Files:**
- Modify: `lib/Registry/DAO/Subscription.pm:16-20` (the `ADJUST` block), `:98-99` (the `warn`-and-return), `:102`; `lib/Registry/Service/Stripe.pm:25-69`, `:67`
- Modify (logging callers): `lib/Registry/DAO/Payment.pm`, `lib/Registry/Service/Stripe.pm`, `lib/Registry/DAO/Subscription.pm`

**Interfaces:**
- Consumes: nothing. Disjoint from Tasks 1-6.
- Produces: `_stripe_request` and `Stripe.pm`'s request helper both return `($body, $request_id)`; all three modules on the logging triple emit a structured line carrying it. Tasks 7b and 7c consume the two-value return.

**There are two HTTP clients, not three.** Leg 1 deleted `Client::Stripe`. The spec's "all three clients" (`:2397`) predates that. Its "three modules" (spec `:2613`) is a *logging* triple in which `DAO/Payment.pm` is a caller, not a client — `grep -c 'log->'` returns 0 for all three, which is why `DAO/Payment.pm` is on the Files list above even though it opens no socket.

**`request_id` needs a client change first.** Both clients discard the response: `Stripe.pm:67` returns `decode_json($res->body)`, `Subscription.pm:102` returns `$tx->result->json`. There is no way to log a request id from a caller today.

**`Subscription.pm:98-99` warns and returns undef on a non-2xx.** Every caller then treats a failed API call as an empty result. Whatever this task does about logging, that path must become distinguishable from success — a caller cannot tell "Stripe said no" from "Stripe said nothing". (The spec cites this as `:96` at `:2616`; `:96` is the third fallback in the message chain at `:94-97`, and the `warn`/`return` pair is `:98-99`, inside the guard block `:89-100`. Add this to the Spec Citations Corrected table's shape when reading that section.)

- [ ] **Step 1: Write the failing tests** — a timeout is configured; a non-2xx is distinguishable from an empty success; a request id reaches the log.
- [ ] **Step 2: Run them.** Expected: no timeout, `undef` for both failure modes, silence.
- [ ] **Step 3: Set `request_timeout`, `connect_timeout`, `max_redirects` on `Subscription.pm`'s user agent,** matching `Stripe.pm:19-23`.
- [ ] **Step 4: Return the `Request-Id` header alongside the body** from both clients.
- [ ] **Step 5: Make `:96` fail distinguishably** rather than `warn`-and-return-undef.
- [ ] **Step 6: Log one structured line per Stripe call** in all three modules of the triple, carrying the request id.
- [ ] **Step 7: Run the affected suites.** Expected: PASS.
- [ ] **Step 8: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] `Subscription.pm` sets a request timeout (`grep -cF request_timeout lib/Registry/DAO/Subscription.pm || true` -- 0 now, at least 1 after)
- [ ] All three modules of the logging triple log (`grep -cF 'log->' lib/Registry/DAO/Payment.pm lib/Registry/Service/Stripe.pm lib/Registry/DAO/Subscription.pm` -- **0 for each now**, at least 1 for each after; read the per-file lines, there is no total)

### Negative Scenarios
- [ ] **A non-2xx must not look like an empty success.** Assert the two are distinguishable at the caller.
- [ ] **A logged request id must come from the response, not be invented.** Assert the logged value matches the header the client received.

---

### Task 7b: Subscriptions carry `metadata[tenant_id]` — and survive a null `trial_end`

**Files:**
- Modify: `lib/Registry/DAO/Subscription.pm:129-147`, `:263`, `:280`, `:296`, `:314`, `:327`; `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:318-322`

**Interfaces:**
- Consumes: Task 7a's two-value return.
- Produces: `create_subscription_with_config` receives a tenant id and records the subscription without dying on a trial-less plan.

**Read this before touching `:131`.** `metadata[tenant_id]` is never set on any Subscription, because `:131-133` sits inside `if ($tenant_id)` and the sole production caller (`TenantPayment.pm:318-322`) passes three arguments to a four-parameter signature. That disables **five** webhook handlers (`_handle_subscription_updated` `:263`, `_handle_subscription_deleted` `:280`, `_handle_trial_ending` `:296`, `_handle_payment_failed` `:314`, `_handle_payment_succeeded` `:327`). It is **five, not eight** — `grep -cF 'return unless $tenant_id' lib/Registry/DAO/Subscription.pm || true` returns 8 because three of those hits are UUID-format guards *inside* handlers already counted (`:270`, `:287`, `:303`). Count `method _handle`, not grep hits. (The `-F` is required here too: this pattern contains `$tenant_id`, so written bare it reads **0** under ugrep and 8 under GNU grep. The sentence explaining why a count misleads was itself miscounted for two rounds.)

**Passing the tenant id through, alone, arms a live bug.** The *same* `if ($tenant_id)` guards the metadata at `:131` **and** the tenant write at `:144`. That block calls `DateTime->from_epoch(epoch => $subscription->{trial_end})` at `:145`. Solo passes `trial_days => 0` (`TenantPayment.pm:116`), Stripe returns `trial_end: null`, and `from_epoch` dies on undef — **after** the POST at `:140` has already created a live subscription, with no `stripe_subscription_id` recorded anywhere. The `// 30` at **`TenantPayment.pm:139`** cannot rescue it; it defaults an *undefined* `trial_days`, and Solo's is a defined zero. (Note the file change mid-sentence: `:140`, `:144` and `:145` above are `Subscription.pm`; `:116` and `:139` are `TenantPayment.pm`.) Today the bug is unreachable only because the metadata is never set. Enabling one enables the other.

So the order is: **fix `:145` first, then pass the id through.** Both in this task, `:145` in the earlier commit.

- [ ] **Step 1: Write the failing test** — `create_subscription_with_config` with `trial_days => 0` and a tenant id must record the subscription, not die.
- [ ] **Step 2: Run it.** Expected: dies in `from_epoch` on an undefined epoch, with a live subscription already created at Stripe.
- [ ] **Step 3: Make the trial window defensive** — a null `trial_end` means no trial, not an error. Separate the metadata guard at `:131` from the tenant-write guard at `:144` so the two stop sharing a condition.
- [ ] **Step 4: Record the subscription in the same transaction as the tenant row,** so a partial write cannot leave a live subscription unrecorded.
- [ ] **Step 5: Cancel what cannot be recorded.** If the tenant write fails after the POST succeeded, cancel the subscription rather than orphan it.
- [ ] **Step 6: Pass the tenant id through from `TenantPayment.pm:318-322`.**
- [ ] **Step 7: Run the tenant-payment and subscription suites.** Expected: PASS.
- [ ] **Step 8: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] A Solo signup (`trial_days => 0`) records its subscription (the test above)
- [ ] A created Subscription carries `metadata[tenant_id]` (the test above)
- [ ] The five handlers can now fire (`grep -c 'method _handle' lib/Registry/DAO/Subscription.pm` -- 5; assert at least one processes an event it previously dropped)

### Negative Scenarios
- [ ] **`trial_end: null` must not die.** Assert a trial-less plan records cleanly. This is the whole reason the task exists.
- [ ] **A POST that succeeds and a write that fails must not orphan.** Assert the subscription is cancelled or the id is recorded — never neither.
- [ ] **Enabling the metadata must not enable the crash.** Assert `:131` and `:144` no longer share a guard.

---

### Task 7c: Idempotency tokens on created objects, and the two silent catches

**Files:**
- Modify: `lib/Registry/Service/Stripe.pm:91` (SetupIntent), `:104` (Customer), `:121` (PaymentMethod), `:147` (Subscription), `:173` (Refund), `:182` (Price), `:195` (Product)
- Modify: `lib/Registry/DAO/Subscription.pm:59` (Customer), `:140` (Subscription), `:181` (SetupIntent), and `_stripe_request` at `:71`
- Modify: `lib/Registry/DAO/WorkflowSteps/Payment.pm:197`, `:338`

**Interfaces:**
- Consumes: Task 4's `_idempotency_key` threading, Task 7a's return shape.
- Produces: every Stripe object Registry creates — **through either client** — carries the token in metadata under one key name, and every creating POST carries an `Idempotency-Key` header.

**Ten creators across two clients, not seven across one.** `Service/Stripe.pm` has seven unstamped (`:91`, `:104`, `:121`, `:147`, `:173`, `:182`, `:195`); only `create_payment_intent_async:72` extracts `_idempotency_key` today. **`DAO/Subscription.pm` has three more** — `:59` a Customer, `:140` a Subscription, `:181` a SetupIntent — and `grep -c 'Idempotency-Key'` on that file returns **0**: `_stripe_request` (`:71`) has no key parameter at all.

The spec is explicit that this is not optional (`:2624-2632`): *"With no timeout and no key, a dropped connection on `:140` leaves Registry with no subscription id and Stripe with a live subscription… **Leg 0 covers all three clients or the guarantee it is named for is not a guarantee.**"* An earlier draft of this task recounted the creators inside one client and never asked whether the client set was complete — which left this task's own third Negative Scenario grading work no step performed.

**Use the key name that shipped.** The spec calls it `registry_idempotency_token`; the live name is `idempotency_token` (`Payment.pm:129`, reaching Stripe via `_stripe_metadata_params:51-62`, which flattens every scalar metadata key to `metadata[...]`). Note this **predates #314** — that PR did not touch `DAO/Payment.pm` — so the key is already live on Stripe objects today and renaming it is a live-data change. Adopt the shipped name.

**The two silent catches are not in the three named files** — they are `WorkflowSteps/Payment.pm:197` and `:338`, and both sit immediately before a replacement-intent mint, so what they swallow is a double-charge window, not just telemetry.

- [ ] **Step 1: Write the failing tests** — each created object carries the token; a Subscription-client POST carries an `Idempotency-Key`; a failed cancel is recorded rather than swallowed.
- [ ] **Step 2: Run them.** Expected: no token on nine of ten, no header at all from the second client, silence on both catches.
- [ ] **Step 3: Stamp the token on all seven `Service/Stripe.pm` creators,** deleting `_idempotency_key` from the payload before the POST exactly as `create_payment_intent_async:72-76` does — Stripe 400s on unknown form parameters.
- [ ] **Step 4: Give `_stripe_request` a key parameter** and thread it through `Subscription.pm`'s three creating POSTs (`:59`, `:140`, `:181`), stamping the same token in metadata.
- [ ] **Step 5: Close the two catches** — log the failure and re-raise or record it; do not proceed silently to mint a replacement.
- [ ] **Step 6: Run the affected suites.** Expected: PASS.
- [ ] **Step 7: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] The token reaches every creator in the first client (`grep -cF _idempotency_key lib/Registry/Service/Stripe.pm || true` -- **1 now** (`:74`), at least 8 after)
- [ ] The second client sends the header at all (`grep -cF 'Idempotency-Key' lib/Registry/DAO/Subscription.pm || true` -- **0 now**, at least 1 after). This is the whole of finding B-F1; without it the task's third Negative Scenario grades nothing.
- [ ] One key name across the codebase. **`grep -F idempotency_token` cannot grade this** — it matches `registry_idempotency_token` as a substring, so the wrong spelling passes the gate that exists to catch it. Use:
      `grep -rhoE '[a-z_]*idempotency_token' lib/ | sort -u`
      -- reads exactly `idempotency_token` and `rotate_idempotency_token` now; must read the same two after, and **never** `registry_idempotency_token`.
- [ ] Neither catch is empty (`grep -cF 'catch(sub ($cancel_err) { })' lib/Registry/DAO/WorkflowSteps/Payment.pm || true` -- **2 now**, 0 after. `-F` is load-bearing: `$c` is read as an anchor by ugrep and the criterion silently reads 0 before any work.)

### Negative Scenarios
- [ ] **`_idempotency_key` must not reach Stripe as a form parameter.** Assert it is deleted from every one of the ten payloads.
- [ ] **A swallowed cancel is a double-charge window.** Assert a failed cancel prevents the replacement mint, or records it loudly.
- [ ] **A dropped connection must not leave an orphan subscription.** With no key and no timeout, a retry creates a second live Subscription. Assert the second client sends a key — 7b's cancel-on-failure does **not** cover this case, because a dropped connection leaves no id to cancel with.

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
- Consumes: Task 5b — it is 5b that writes the `refund_pending` state this runbook clears. (Task 4 supplies the guard that lets a `refund_pending` row be refunded at all, but the stranded row itself comes from 5b.)
- Produces: a runbook section. There is no automated reader until Leg 3, so this leg writes the procedure rather than implying one exists.

- [ ] **Step 1: Add `### Clearing a stranded refund_pending payment`** after the refund-policy subsection, stating: the state arises only from a post-COMMIT failure; Stripe's redelivery does **not** heal it, because the dedup claim committed in the same transaction dedups the retry away by design; and there is no automated reader until Leg 3.
- [ ] **Step 2: Write the procedure — list before re-issuing.** `GET /v1/refunds?payment_intent=<id>` under `Stripe-Account` first. A `succeeded` Refund settles the row; a `pending` one is left alone; only an **empty list** justifies re-issuing.
      **A `failed` Refund must NOT be written as `refund_failed`.** That string appears nowhere in `lib/` and is in neither status classifier: `_money_has_moved` (`completed|refunded|partially_refunded|refund_pending`) and `_refundable_status` (`completed|refund_pending`). Writing it does both bad things at once — the row is locked out of every future refund, *and* the next Stripe redelivery sees an unsettled payment and re-completes it. Leave a failed refund as `refund_pending` with the obligation intact, and record the failure outside the status column (a note on the ticket, not the row) until a status is added to both classifiers. Re-POSTing under the stable key is a double refund waiting on a clock — Stripe prunes idempotency keys after 24 hours.
- [ ] **Step 3: Give the finding query, per tenant schema** — `payments` is tenant-scoped.
- [ ] **Step 4: Commit.**

**Acceptance Criteria**

### Positive Scenarios
- [ ] The section exists and names the 24-hour pruning (`grep -cF '24 hours' docs/operations/sacp-stripe-connect-onboarding.md || true` -- 0 now, at least 1 after)
- [ ] The finding query is per-tenant, not against `registry`. Two counts, because `refund_pending` alone cannot detect a `registry`-scoped query:
      `grep -cF 'refund_pending' docs/operations/sacp-stripe-connect-onboarding.md || true` -- 0 now, at least 1 after
      `grep -cF 'registry.payments' docs/operations/sacp-stripe-connect-onboarding.md || true` -- **4 now, still 4 after** (the doc already carries four legitimate uses; a fifth means the finding query was written against `registry`)

### Negative Scenarios
- [ ] **A procedure that re-issues before listing is a double refund.** Assert the listing step comes first in the document order.

---

## Task Dependency Order

Fourteen tasks. Execute in the order listed. Every arrow is a real dependency.

```
0 (processed_at migration) ─── Task 1 stamps a column that must exist first
      ↓
1 (webhook path: one txn, one connection)   1b (callback path: one txn)
      └───────────────┬───────────────────────┘
                      ↓   BOTH containers must exist before any lock is installed
      2 (mark_completed) → 3 (FOR UPDATE on the payment row, TWO sites)
                      ↓
      4 (refund plumbing: guard rewrite + async key + per-child share)
                      ↓
      5a (sorted session locks + capacity predicate)
                      ↓
      5b (capacity-gone branch: demote, COMMIT, then refund)
                      ↓
      6 (the two migrations)

7a (clients keep their response, get timeouts) ── independent of 0-6
      ↓
7b (metadata[tenant_id] + the trial_end fix)   ── MUST follow 7a
      ↓
7c (idempotency stamping + the two catches)    ── requires 4
8 (calculate_enrollment_total refuses undefined) ── independent
9 (runbook: manual refund_pending clearance)     ── requires 4
```

- **0 before 1**: Task 1 stamps `processed_at` at COMMIT and the column does not exist yet.
- **1 and 1b before 3, 5a and 5b**: a lock outside a transaction is released immediately, and the money path has **two** settlement paths. Task 1 alone leaves the callback path without a container, which would make Task 3's lock and Task 5's gate inert there — verified by execution, not argued.
- **4 before 5b**: Task 5b writes `payments.status = 'refund_pending'` and then calls the method that rejects any status but `completed`. The guard rewrite and the idempotency key must be in the same commit as the first `refund_pending` write.
- **5a before 5b**: the predicate must land before the branch, or the branch fires on a false positive. The demotion must land *with* the branch, because a branch that inserts is silently a no-op.
- **7a before 7b**: 7b's failure handling needs a client that can report a failure.
- **7b's internal order is not negotiable**: fix the `trial_end` crash *before* passing the tenant id through. Passing it through first arms a live bug that takes money and orphans the subscription — see the task body.
- **7a/7b/7c and 8 are disjoint** from the transaction work and can be worked in parallel by a second worker; 7c and 9 need Task 4 first.

## Coverage Gaps This Leg Opens
1. **#247's empty-items half stays open.** `Payment.pm:355`'s `return unless @$items` still marks a payment `completed` with zero enrollments and returns 200. Atomicity does not make a no-op loud. Filed rather than fixed here.
2. **The oversell window narrows but does not close.** `Enrollment::enroll_children` (`:103-121`, the live free path, called at `WorkflowSteps/Payment.pm:384`) and `Waitlist::accept_offer` (`:187-226`, its own transaction, inserts `pending` with no capacity read) take no session lock. An admin lowering `sessions.capacity` is likewise unserialized. The spec names both at `:4521-4522` and then does not put them in the leg.
3. **`refund_pending` has no automated reader until Leg 3 — and the two jobs the spec names do not exist.** `grep -rln 'ProcessRefunds\|ReconcilePayments'` matches only the spec and this plan; `lib/Registry/Job/` holds `WorkflowExecutor`, `DomainVerification`, `AttendanceCheck`, `ProcessWaitlist`, `WaitlistExpiration`. The string `refund_pending` appears nowhere under `lib/ t/ sql/`. Both jobs are Leg 3 deliverables (spec `:2968`). Task 9 writes the manual clearance procedure instead of implying automation exists.
4. **`sql/revert/enrollment-payment-dedup.sql:17` is already a silent no-op** for tenants cloned after that change — it drops `enrollments_payment_dedup` by name, and the tenant copy is `enrollments_session_id_student_id_payment_id_idx`. Pre-existing, found while mapping this leg, not introduced here. It is invisible because that change is not on `@CHANGES`.
5. **`Subscription.pm` has no live-key guard.** `Payment.pm:147-151` refuses an `sk_live_` key unless `MOJO_MODE=production`; `Subscription.pm:18` takes `$ENV{STRIPE_SECRET_KEY}` with no such check. An earlier draft of Task 7a added the guard, which is a real safety gap but is nowhere in the spec's Leg 0 row — adding it would have been undeclared scope. Filed rather than smuggled in.
6. **The reuse guard's `workflow_run_id` ownership check has no migration behind it.** Task 3 reads `$existing->metadata->{workflow_run_id}`, a key `create_payment` writes into a JSON blob. Nothing constrains it, so a row written before this leg has no such key and will simply fail the ownership check — the safe direction, but it means the guard is advisory on historical rows.
7. **~~`stripe()` never calls `render_later`.~~ FIXED in Task 1 — `Webhooks.pm` calls it.** The gap as originally found: the post-COMMIT render reached the client only by accident, `Mojolicious::Routes::_render` finds no `webhooks/stripe` template, and `mojo.routed` (`Routes.pm:161`) suppresses the croak that would otherwise fire. Verified by rendering `202` from a promise callback and observing it at the test. Task 1 should add an explicit `$self->render_later` before returning the promise — the current behaviour is one added default template away from silently double-rendering. Recorded here because it is pre-existing, but it becomes load-bearing the moment Task 1 returns a promise from that action.
8. **`t/database/revert-round-trip.t:67-68`'s comment cites `sql/test-schema.sql:3269-3273` for `tenants_slug_key`;** those lines are now `workflow_runs_pkey`. Stale comment in a file Tasks 0 and 6 both edit. Not worth a step; noted so a worker does not trust it.
