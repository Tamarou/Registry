# Payment Settlement: a state machine, not a set of guards

**Status:** design, not yet implemented
**Supersedes:** the ad-hoc guards added across `631a645`, `040d717`, `ff32426`, `e318c0c`, `c2daea8`, `bb718c1`
**Context:** PriceOps Leg 0. Tasks 0, 1, 1b, 2, 3, 4, 5a, 5b are implemented; 6, 7a-c, 8, 9 are not.

## Why this document exists

Three adversarial review rounds against the implemented money path found 21 defects: 7, then 6, then 8. Every round, the fixes for the previous round's findings introduced new ones. Six of round 3's eight were introduced by round 2's remediation, and two of those were *worse* than the bugs they replaced — one converted a recorded double charge into an unrecorded one, the other converted a silent oversell into one that emails the family a confirmation.

The pattern is not carelessness at individual sites. It is that **the settlement path has no state machine**, and every fix has been a guard bolted onto one call site. Each guard is locally correct. Together they disagree.

This document specifies the machine, so that correctness is a property of the design rather than of ten call sites remembering the same rule.

---

## 1. What is actually there today

### 1.1 The vocabulary

`payments.status` is `character varying(50)` with **no CHECK constraint** (`sql/test-schema.sql:1144`). Seven values are written by code:

| Status | Written at | Meaning |
|---|---|---|
| `pending` | column default, at create | intent may not exist yet; no money moved |
| `processing` | `Payment.pm:434` | Stripe reports the intent in flight |
| `failed` | `Payment.pm:253`, `:306`, `:439` | intent creation or retrieval failed; no money moved |
| `completed` | `Payment.pm:712` (`mark_completed`) | captured |
| `refund_pending` | `Payment.pm:632` | captured, and an obligation to return some of it exists |
| `refunded` | `Payment.pm:791` | full amount returned |
| `partially_refunded` | `Payment.pm:791` | some returned; **the normal outcome of a per-child capacity refund on a family cart** |

Two classifiers read this vocabulary and **disagree**:

```
_money_has_moved   = completed | refunded | partially_refunded | refund_pending
_refundable_status = completed | refund_pending
```

A `partially_refunded` row is therefore settled but not refundable — so a second capacity obligation on the same cart can only be discharged because `_record_capacity_obligation` happens to flip the status back to `refund_pending` first. That works by side effect. Nothing records it, and nothing tests it.

The plan's Task 9 instructs operators to write an eighth value, `refund_failed`, which appears nowhere in `lib/` and is in **neither** classifier. Writing it locks the row out of every future refund *and* invites the next Stripe redelivery to re-complete it.

### 1.2 The writers

Ten paths write a payment row. Whether each is safe depends on the caller, not the method:

| Write | Method | Lock? | **May it write?** | Why / why not |
|---|---|---|---|---|
| `Payment.pm:235` | `_record_intent` | yes | guarded | explicit |
| `:254` | `_record_intent_failure` | yes | guarded | explicit |
| `:307` | `_record_retrieval_failure` | lock, return **discarded** | own check | |
| `:435`, `:441` | `_apply_intent` | lock at entry, return **discarded** | own check | |
| `:635` | `_record_capacity_obligation` | inherited from caller | **NOTHING** | **the only write with neither. Walks a terminal `partially_refunded` back to `refund_pending`.** |
| `:715` | `mark_completed` | inherited from caller | caller's | safe *only* because both callers check first |
| `:731` | `rotate_idempotency_token` | yes | guarded | explicit |
| `:802` | `_apply_refund_result` | **none** | **none** | **no caller locks either** |
| `WorkflowSteps/Payment.pm:197` | reuse branch | **none** | **none** | **bypasses `save()`; clobbers `amount_cents`, which bricks every later settlement** |

An earlier draft of this table had one column, "Lock held?", and recorded `:635` as *safe because the caller locked*. A reviewer found the blocker there. **Locking serialises writers; it does not decide whether a writer may write.** Conflating the two is why that site was missed by three review rounds.

`save()` writes six columns from the in-memory object. From a stale object that is not an update but a **whole-row restore**: the old status, a nulled `completed_at`, a superseded intent id. Every unlocked write above is therefore a potential silent revert of another settlement's work.

### 1.3 The obligation

A capacity obligation lives in three unschema'd jsonb keys:

| Key | Written | Cleared | Read by |
|---|---|---|---|
| `refund_owed_cents` | `:633`, accumulated | `_apply_refund_result:799` | 3 code sites |
| `refund_owed_children` | `:634`, sorted | `_apply_refund_result:800` | `capacity_refund_key` |
| `refund_manual_review` | `:561` | **never** | its own write-guard at `:624` |

No type, no constraint, no index on the amount. A runbook `jsonb_set` writing `"1500"` instead of `1500` corrupts the arithmetic silently. `refund_manual_review` being uncleared is the direct cause of round 3's finding #3.

### 1.4 The invariants that do not hold

1. A settled payment is never re-settled. *(Violated at `WorkflowSteps/Payment.pm:197`.)*
2. A discharged obligation is never re-owed. *(Violated: `already_seated_by` and `demote_to_waitlisted` disagree about `cancelled`.)*
3. A write to a payment is serialized against concurrent settlements. *(Violated at `:802` and `:197`; and the three `_guard_settled_write` sites take `FOR UPDATE` **outside any transaction**, so the lock is released at statement end.)*
4. A seat this cart holds is counted against its own capacity. *(Violated: the `already_seated_by` short-circuit `next`s before `$granted{$session_id}++`.)*
5. An obligation is discoverable by a status scan. *(Violated: `_apply_refund_result` leaves `refund_manual_review` behind with a non-`refund_pending` status.)*


### 1.5 The guards are duplicated, and only one copy is tested

A 68-mutation run against the implemented path scored **53 caught, 15 survived**. The score matters less than the shape of the survivors:

> Every survivor except two provably-equivalent mutants is a **controller-side or step-side copy of a guard whose DAO-side twin is well tested.**

| Survivor | The duplicated guard | DAO twin |
|---|---|---|
| `Webhooks.pm:274` — drop `_money_has_moved` before `mark_completed` | the settled check | graded by `payment-settled-state-machine.t` |
| `Webhooks.pm:249` — drop `{ for => 'update' }` | the row lock | graded by `payment-callback-atomicity.t` |
| `Webhooks.pm:290` — use the return value instead of re-reading the debt | the obligation read | graded by `payment-refund-debt-lifecycle.t` |
| `WorkflowSteps/Payment.pm:299-326` — the whole post-COMMIT refund block | the refund path | graded by `webhook-capacity-refund.t` |

The webhook suites only ever construct payments with `status => 'pending'`, so the webhook's copy of the settled check is never exercised. A bare `die` at `WorkflowSteps/Payment.pm:299` passes **all 65 files** — the step's refund path is dead to the suite, while its webhook twin has three assertions.

This is the same defect as §1.2 seen from the test side. The guards are duplicated because there is no single write path; the duplicates are untested because the tests were written against the DAO. **A design with one write path removes both problems at once** — there is no second copy to leave ungraded.

Three further survivors are ordinary test debt rather than duplication, and are listed in §5 as prerequisites: `payment_fits_session` ignoring `'pending'` seats belonging to *other* payments (an oversell at capture), `already_seated_by` without its `payment_id` predicate, and the deadlock ordering in `_lock_cart_sessions`, whose code comment claims a verification that exists nowhere in the suite.

One methodological caveat worth carrying forward: the same run found that **suite selection changes verdicts.** One mutation was green against a 26-file money-path selection and red only once a 39-file dependent set was added. Rounds 1 and 2 scored against narrower selections and may have over-reported survivors.

---

## 2. The design

### 2.1 States

**Five states, and the existing strings are kept.** An earlier draft proposed six and a rename of `completed`; both were wrong.

`refunding` is derived data promoted to a status: once §2.2 makes the obligation a typed column, `refunding` is exactly `completed AND refund_owed_cents > 0`. Two representations of one fact is the failure this document exists to eliminate — and there is already a live example of them disagreeing, a row reading `refund_pending` with `refund_owed_cents = 0`. Dropping it also removes the only backward edge in the graph, which is the only place a walk-back would be legal by construction.

Renaming `completed` buys nothing. The defects came from **two classifiers**, not from the word, and a rename touches every fixture, the runbook, the schema dump, and anything already emitted into Stripe metadata.

| State | Money moved? | Refundable? | Settled? |
|---|---|---|---|
| `pending` | no | no | no |
| `processing` | no | no | no |
| `failed` | no | no | no |
| `completed` | yes | yes | yes |
| `refunded` | yes | no | yes |

`partially_refunded` disappears — a partial return is `completed` with a non-zero `refunded_cents`, which is what it actually is. **One classifier**, `is_settled`, derived from this table. No second list to fall out of sync.

**There are now three classifiers to collapse, not two.** Round 4 added `_money_returned` (`refunded|partially_refunded`) to gate `finalize_enrollment`, because neither existing predicate asks the right question: `_money_has_moved` includes `completed`, and `mark_completed` runs immediately above `finalize_enrollment` in the same transaction, so using it refuses every first settlement — measured, not reasoned. `_refundable_status` also includes `completed`. It is named rather than inlined precisely so this section can find it.

And the cheapest mechanism in this document, which an earlier draft noted the absence of and then failed to propose:

```sql
ALTER TABLE registry.payments
  ADD CONSTRAINT payments_status_check
  CHECK (status IN ('pending','processing','failed','completed','refunded'));
```

One line, same migration, same per-tenant loop. It is what stops an operator following the current runbook from writing `refund_failed` — a value in neither classifier, which today both locks the row out of every future refund and invites the next redelivery to re-complete it.

### 2.2 The obligation becomes a column

```sql
ALTER TABLE registry.payments
  ADD COLUMN refund_owed_cents integer NOT NULL DEFAULT 0
    CHECK (refund_owed_cents >= 0 AND refund_owed_cents <= amount_cents),
  ADD COLUMN refunded_cents    integer NOT NULL DEFAULT 0
    CHECK (refunded_cents >= 0 AND refunded_cents <= amount_cents);

CREATE INDEX idx_payments_refund_owed
  ON registry.payments (refund_owed_cents) WHERE refund_owed_cents > 0;
```

`sql/deploy/payments-amount-cents.sql:18` is the precedent, including the per-tenant-schema loop. This buys: a typed integer an operator cannot corrupt with a quoted string; the invariant that a debt cannot exceed the cart; an index Leg 3's `ProcessRefunds` can drive; and a cumulative refunded total that survives a second refund, which today is recoverable only from Stripe's list endpoint.

**Two confirmed defects this section must fix, found in review round 4 and deferred here by decision.** Both come from one root cause: the obligation is a mutable accumulator with no version, and both the Stripe idempotency key and the discharge assume it is stable across a network round trip. Neither is fixed by §2.3's conditional UPDATE — the arithmetic is wrong under any locking discipline.

- **The key changes as the debt grows — double refund.** `capacity_refund_key` derives from `refund_owed_children`, and `_record_capacity_obligation` unions that list while accumulating the cents. Both callers then refund the accumulated *total*, not the delta (`Webhooks.pm:219`, `WorkflowSteps/Payment.pm:313`). Debt 5000 for child A goes out under `refund:capacity:P:A`; if the local discharge fails, a later pass adds child B and 8000 goes out under `refund:capacity:P:A,B` — a key Stripe has never seen. **13000 sent against an 8000 obligation**, with the platform's application fee returned twice alongside it. Confirmed independently by two review lenses. The comment above the method claims the key is "Stable for one debt"; it is not.
- **The discharge deletes instead of subtracting — lost refund.** `$refund_cents` is captured at `Payment.pm:957`, *before* the Stripe call, and `_apply_refund_result` deletes `refund_owed_cents` outright. A debt that grew during the round trip is erased down to zero — the increment gone, with no row, no status and nothing for the runbook to find. Related: `refund_async`'s `->catch` sits below the `->then`, so a local database throw from `_apply_refund_result` is reported as `"Refund failed: ..."`, indistinguishable from Stripe refusing. The caller cannot tell "no money moved, safe to retry" from "money moved, do not retry".

The typed columns alone fix neither. The design needs a **per-debt sequence**: increment a counter on each `_record_capacity_obligation` write, key each refund `refund:capacity:$id:$n`, and send that increment's own delta rather than the balance. Each attempt then carries a key stable for exactly the money it covers, and the discharge becomes `refund_owed_cents = refund_owed_cents - ?` rather than a delete.

`refund_owed_children` stays in jsonb — nothing filters on it, and once the sequence above owns the key it no longer derives one. `refund_manual_review` becomes a **fourth state on the obligation**, not a stray flag: `owed`, `discharged`, `unresolvable`, `none`.

### 2.3 One write path: a conditional UPDATE

*This section is a reviewer's design, not mine. It gets more of the 21 defects for a smaller diff than the `transition()` method an earlier draft proposed, and I am recording why it won.*

Every mutation of a payment row becomes an UPDATE that names **only the fields it changes** and carries its own legality in the WHERE clause:

```sql
UPDATE payments SET status = 'completed', completed_at = now()
 WHERE id = ? AND status IN ('pending','processing')
```

Then check `->rows`. Zero means refused — unambiguously, by construction, not by a return shape a caller can misread.

What this subsumes, without any lock at all:

- **The three `FOR UPDATE`-outside-a-transaction sites.** No lock is needed: the predicate is evaluated inside the UPDATE's own row lock, atomically. This removes the requirement rather than enforcing it.
- **`_apply_refund_result` unlocked and unguarded** — the predicate moves into the WHERE.
- **`WorkflowSteps/Payment.pm:197`** — same, and it stops clobbering `amount_cents` and `metadata` because it names neither.
- **`_record_intent`'s refusal shaped like success** — `rows == 0` is not a shape.
- **The terminal-status walk-back** — `AND status = 'completed'`.
- **The whole-row-restore hazard of §1.2**, and with it most of `_lock_and_refresh`'s reason to exist.
- **Accumulation**, once §2.2 makes it a column: `SET refund_owed_cents = refund_owed_cents + ? WHERE id = ? AND status = 'completed'` is atomic, with no read-modify-write.

§2.1's state table survives as a **pure predicate that builds the WHERE clause** — that is the part carrying the value ("one place to add a state"), without a god-method, an untyped `$changes` bag, or an `AutoCommit` check to get right.

**Why the `transition()` method lost.** It required an open transaction at three call sites that have none — and at one, `_apply_refund_result`, which runs post-COMMIT *on purpose*, because a refund inside the settlement transaction is not undone by the ROLLBACK the rest of the leg depends on. "Requires an open transaction" would have been exactly wrong there. Its `$to = undef` escape for same-state writes disabled the legality check for the majority of writes on this path, which is the very set the defects came from. Its `$changes` bag was an unvalidated `column => value` map through which `{status => 'completed'}` bypasses the machine. And its sketch called `$db->dbh` before the `$db = $db->db if $db isa Registry::DAO` coercion every other method performs — `Registry::DAO` has no `dbh`, so it would have died method-not-found on first use.

**What still needs a transaction and a lock:** `finalize_enrollment`. It is multi-row work — session locks, enrollment writes, the obligation — and genuinely needs both. The conditional UPDATE replaces the *single-row* guards, not the settlement transaction.

### 2.4 The seat predicate has one owner

`already_seated_by`, `demote_to_waitlisted` and `payment_fits_session` currently encode three overlapping opinions about which enrollment statuses matter. Round 3's findings #1, #2 and #7 are all disagreements between them.

One sub answers "what does this cart hold in this session", returning counts by category, and the three consumers read from it. The short-circuit, the demotion predicate and the capacity arithmetic then cannot diverge, because there is one source.

---

## 3. What this fixes

| Round | Finding | Fixed by |
|---|---|---|
| 1 | refunded rows re-completed | §2.3 legal transitions |
| 1 | uncleared debt marker | §2.2 obligation state |
| 1 | constant key, recomputed amount | **fixed only for the populated case.** `capacity_refund_key`'s empty-children branch still returns the constant `refund:capacity:$id`, and the terminal-status walk-back produces exactly the row that reaches it. §2.3's predicate closes the walk-back; the branch should die rather than mint a shared key |
| 2 | debt assigned not accumulated | §2.2 typed column + §2.3 single write path |
| 2 | manual-review invisible to runbook | §2.2 obligation state is queryable |
| 2 | three unguarded whole-row saves | §2.3 |
| 2 | retrieval branch without a transaction | §2.3 enforces it |
| 3 | `cancelled` disagreement → double refund | §2.4 |
| 3 | short-circuit bypasses `$granted` → oversell | §2.4 |
| 3 | `refund_manual_review` never cleared | §2.2 |
| 3 | guard refusal returns success shape | §2.3's `rows == 0`, **plus a caller change**. Raising alone is not enough: the chain would reject and render "Payment processing error" to a parent who has already paid. The caller must route to completion, the decision `_settle_callback` already makes for `already_completed` |
| 3 | `_apply_refund_result` unguarded | §2.3 |
| 3 | fourth unguarded write at `:197` | §2.3 |
| 3 | promotion path silent no-op | **NOT fixed by §2.4.** The cause is `create_for_payment`'s `ON CONFLICT (session_id, student_id, payment_id) DO NOTHING` meeting an existing `waitlisted` row. A shared *read* predicate does not make an INSERT promote. Needs `DO UPDATE SET status='active' WHERE enrollments.status='waitlisted'`, or the UPDATE-then-INSERT shape `demote_to_waitlisted` already uses |
| 3 | guard locks outside a transaction | §2.3 `AutoCommit` check |

## 4. What this does not fix

Stated so the next review does not have to find them:

- **`Enrollment::enroll_children` and `Waitlist::accept_offer` still take no session lock.** The capacity gate is correct against concurrent *payments* and remains racy against those two writers. Plan Coverage Gap 2 already records this; it is Leg 8's.
- **Two settlements serializing is proven only by a held lock, not by a concurrency test.** The suite has no two-process test. Lens A's probes did this by hand and found the current locks correct.
- **A `refunded` row is not evidence money moved.** `_apply_refund_result` never reads `$refund->{status}`; Stripe can hold a Connect refund `pending`. The spec assigns this to Leg 3.
- **Three call sites have no transaction and one must not have one.** `_apply_refund_result` runs post-COMMIT deliberately. §2.3's conditional UPDATE is what makes this a non-issue — but any future move back toward a transaction-scoped guard has to account for it.
- **`save()` never checks `->rows`, and `_apply_intent` discards `_lock_and_refresh`'s return.** Both are silent-no-op paths that survive this design unless fixed alongside it.
- **`demote_to_waitlisted`'s fallback INSERT can abort a captured settlement.** Its three lookups scope on `payment_id`; `enrollments_session_student_type_unique` does not. A child holding a row in this session from another payment is invisible to the SELECT and fatal to the INSERT, inside the settlement transaction, after capture. Filed as [#315](https://github.com/Tamarou/Registry/issues/315).
- **`_reusable_payment_row` refuses unstamped rows.** A pre-linkage `pending` row is orphaned rather than reused. Not a money defect; litter no process reaps. Filed as [#316](https://github.com/Tamarou/Registry/issues/316).

## 5. Sequencing

0. ~~**Fix the runbook line that bricks a row.**~~ **DONE** (`9776f6a`). Task 9 Step 2 in `docs/superpowers/plans/2026-08-15-priceops-leg-0-atomic-money-path.md` (search for `refund_failed`) instructed an operator to write it. That is not documentation debt of the same kind as the deviations owed — it is a live instruction that puts a money row into a status in neither classifier. One-line edit.
1. ~~**The rest of the documentation debt, separately.**~~ **DONE.** Three deliverables, all landed:
   - **Task 9's runbook** — `docs/operations/sacp-stripe-connect-onboarding.md` now carries *Clearing a stranded `refund_pending` payment*: why redelivery does not heal the state, the per-tenant finding query, list-before-issue, the stable idempotency key with its 24-hour expiry warning, the settle-the-row UPDATE, and why a failed refund must never be written as `refund_failed`. All four of Task 9's acceptance gates measured: `24 hours` 0→2, `refund_pending` 0→7, `registry.payments` 4→4 (the finding query is tenant-scoped, not `registry`), and the listing step precedes the issuing step in document order.
   - **The deviations owed** — a new *Deviations From This Plan* section in the plan, recording code-vs-plan rather than the existing plan-vs-spec. **Eight entries, not six.** The "six" here was unsourced and never enumerated anywhere in the repo, so the list was re-derived from `git diff origin/main...HEAD` and verified against the tree. The biggest one nobody had written down: the synchronous `Payment::refund` was **deleted**, not merely bypassed as Declared Deviation 1 says.
   - **The blocking plan edits** — the STATUS header's line-number caveat scoped the staleness warning to *unimplemented* tasks. It is wrong in the more dangerous direction: `Payment.pm` grew ~500 lines and `Webhooks.pm` ~230, so Coverage Gap 1's `Payment.pm:355` is now `:495` and the row's `Webhooks.pm:138` is now `:247` — where `:138` today is unrelated tenant-billing logging. The caveat now covers the whole document.
2. **Write the failing tests for round 3's eight defects.** The earlier claim here — *"all 21 known defects have regression tests already"* — was **false**. The suite is green with all eight present, so a machine landed against it would be unfalsifiable, on a branch whose history is that each round's fixes introduced the next round's. Each test is roughly sixty lines against the existing `payment-capacity-obligation.t` fixture.
   Then fix, in the current code, the three whose fix is two lines: the `cancelled` vocabulary, `$granted`, and clearing `refund_manual_review`. The machine then lands against a suite that has already gone red and green once.
   Five gaps must be closed first, or the machine ships with the same blind spots the guards had: a webhook delivered onto a `refunded`/`refund_pending` row (the webhook suites only ever build `pending` ones); a `pending` seat held by *another* payment counting against capacity; `already_seated_by` without its `payment_id` predicate; the workflow step's post-COMMIT refund path, which a bare `die` proves is dead to all 65 files; and two concurrent carts over the same session pair, which no test takes.
3. **§2.4 — the seat predicate — before §2.2's CHECK constraint, not after.** This ordering is load-bearing. `CHECK (refund_owed_cents <= amount_cents)` turns the unfixed `cancelled` bug from an overpayment into a *hard failure*: the re-owed debt accumulates on each redelivery until a later one violates the constraint, throws inside the settlement transaction, and rolls back `mark_completed` and the enrollments with it — 500 to Stripe, retry into the same wall, family gets nothing.
4. **The columns**, with the per-tenant loop and a revert-harness entry.
5. **Only then Task 6.** Its partial unique index encodes the enrollment status vocabulary, and §2.4 changes who owns that.

## 6. The honest caveat

I designed the guards this document replaces, and three review rounds found 21 defects in them. Asking for a reader was the right call, and the reader earned it:

- It found a **blocker at the one site this document certified as safe** (§1.2's `:635` row). The table had a single column, "Lock held?", and I had reasoned that locking implied authority to write. It does not.
- It found that **§5's acceptance criteria did not exist** — I claimed all 21 defects had regression tests; round 3's eight do not, and the suite is green with all of them present.
- It replaced §2.3 with a **materially better mechanism**. The conditional UPDATE removes the need for the lock rather than enforcing it, and gets more of the 21 for a smaller diff. My `transition()` would have died method-not-found on first use, and its `$to = undef` escape disabled the check for the majority of writes on this path.
- It found that **§3's promotion-no-op mapping was wrong** — a shared read predicate cannot make an INSERT promote.

That is four substantive corrections to a document whose thesis is that I keep fixing the site rather than the property. The thesis survives; my execution of it needed the same scrutiny as the code did.

This revision has not itself been reviewed.
