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

| Write | Method | Lock held? | Why / why not |
|---|---|---|---|
| `Payment.pm:235` | `_record_intent` | guard + lock | explicit |
| `:254` | `_record_intent_failure` | guard + lock | explicit |
| `:307` | `_record_retrieval_failure` | lock, return **discarded** | own status check |
| `:435`, `:441` | `_apply_intent` | lock at method entry | explicit |
| `:635` | `_record_capacity_obligation` | none of its own | safe *only* because `finalize_enrollment` locked |
| `:715` | `mark_completed` | none of its own | safe *only* because both callers lock first |
| `:731` | `rotate_idempotency_token` | guard | explicit |
| `:802` | `_apply_refund_result` | **none** | **and no caller locks — this is a live defect** |
| `WorkflowSteps/Payment.pm:197` | reuse branch | **none** | **bypasses `save()` entirely; no status predicate in the WHERE** |

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

Six states. `refund_pending` is removed as a *status* and re-expressed as an obligation on a settled row — the conflation of "money moved" with "money is owed back" is what makes the two classifiers disagree.

```
                   create
                     |
                     v
                 [pending] ---- intent in flight ----> [processing]
                     |                                      |
      intent/retrieval failure                         capture
                     |                                      |
                     v                                      v
                  [failed]                             [captured] <--.
                                                            |         |
                                              obligation discharged   |
                                                            |         |
                                       obligation recorded  |         |
                                                            v         |
                                                      [refunding] ----'
                                                            |
                                              fully returned|
                                                            v
                                                       [refunded]
```

| State | Money moved? | Refundable? | Settled? |
|---|---|---|---|
| `pending` | no | no | no |
| `processing` | no | no | no |
| `failed` | no | no | no |
| `captured` | yes | yes | yes |
| `refunding` | yes | yes | yes |
| `refunded` | yes | no | yes |

`captured` replaces `completed`; `refunding` replaces `refund_pending`; `partially_refunded` disappears — a partial return is `captured` with a non-zero `refunded_cents`, which is what it actually is. **One classifier, `is_settled`, derived from the table above.** No second list to fall out of sync.

*(Renaming `completed` is a data migration on a live column. If that is judged too expensive, keep the string `completed` and rename only in the predicate layer — the design holds either way. The point is one classifier, not the spelling.)*

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

`refund_owed_children` stays in jsonb — nothing filters on it, and it exists only to derive the idempotency key. `refund_manual_review` becomes a **fourth state on the obligation**, not a stray flag: `owed`, `discharged`, `unresolvable`, `none`.

### 2.3 One write path

Every mutation of a payment row goes through a single method that takes the lock, re-reads under it, checks the transition is legal, applies it, and saves:

```perl
# The only way a payment row changes.
#
# $to is a target state or undef for a same-state field write. The lock is real
# because this method requires an open transaction and refuses without one --
# a FOR UPDATE outside a transaction is released at statement end and is not a
# lock, which is a mistake this path has made three times.
method transition ($db, $to, $changes = {}) {
    die "transition: requires an open transaction"
        if $db->dbh->{AutoCommit};

    $self->_lock_and_refresh($db)
        or die "transition: payment $id no longer exists";

    die "transition: $status -> $to is not a legal transition"
        unless __CLASS__->_may_transition($status, $to);

    # apply $changes, set $status = $to, save
}
```

Three properties follow that do not hold today:

- **The transaction requirement is enforced, not assumed.** `AutoCommit` is checked. The three current guard sites would fail loudly rather than silently holding no lock.
- **Illegal transitions are impossible, not merely unwritten.** `refunded -> captured` is rejected by the table, so the four "walked back a settled row" defects cannot recur at *any* call site, including ones added later.
- **There is one place to add a state.** Today adding `refund_pending` required finding three classifiers and ten writers; two were missed both times.

### 2.4 The seat predicate has one owner

`already_seated_by`, `demote_to_waitlisted` and `payment_fits_session` currently encode three overlapping opinions about which enrollment statuses matter. Round 3's findings #1, #2 and #7 are all disagreements between them.

One sub answers "what does this cart hold in this session", returning counts by category, and the three consumers read from it. The short-circuit, the demotion predicate and the capacity arithmetic then cannot diverge, because there is one source.

---

## 3. What this fixes

| Round | Finding | Fixed by |
|---|---|---|
| 1 | refunded rows re-completed | §2.3 legal transitions |
| 1 | uncleared debt marker | §2.2 obligation state |
| 1 | constant key, recomputed amount | already fixed; §2.2 keeps key and amount on one source |
| 2 | debt assigned not accumulated | §2.2 typed column + §2.3 single write path |
| 2 | manual-review invisible to runbook | §2.2 obligation state is queryable |
| 2 | three unguarded whole-row saves | §2.3 |
| 2 | retrieval branch without a transaction | §2.3 enforces it |
| 3 | `cancelled` disagreement → double refund | §2.4 |
| 3 | short-circuit bypasses `$granted` → oversell | §2.4 |
| 3 | `refund_manual_review` never cleared | §2.2 |
| 3 | guard refusal returns success shape | §2.3 — a refused transition raises; it cannot be mistaken for success |
| 3 | `_apply_refund_result` unguarded | §2.3 |
| 3 | fourth unguarded write at `:197` | §2.3 |
| 3 | promotion path silent no-op | §2.4 |
| 3 | guard locks outside a transaction | §2.3 `AutoCommit` check |

## 4. What this does not fix

Stated so the next review does not have to find them:

- **`Enrollment::enroll_children` and `Waitlist::accept_offer` still take no session lock.** The capacity gate is correct against concurrent *payments* and remains racy against those two writers. Plan Coverage Gap 2 already records this; it is Leg 8's.
- **Two settlements serializing is proven only by a held lock, not by a concurrency test.** The suite has no two-process test. Lens A's probes did this by hand and found the current locks correct.
- **A `refunded` row is not evidence money moved.** `_apply_refund_result` never reads `$refund->{status}`; Stripe can hold a Connect refund `pending`. The spec assigns this to Leg 3.
- **The renaming of `completed` is a live-data migration** and may be judged not worth it. See §2.1.

## 5. Sequencing

1. **Documentation debt first, separately.** Six Declared Deviations owed, eight blocking plan edits, Task 9's runbook. None of it depends on this design, and the plan currently instructs operators into a status that breaks the row.
2. **The state machine, behind the existing tests.** All 21 known defects have regression tests already; they are the acceptance criteria.
   Five gaps must be closed first, or the machine ships with the same blind spots the guards had: a webhook delivered onto a `refunded`/`refund_pending` row (the webhook suites only ever build `pending` ones); a `pending` seat held by *another* payment counting against capacity; `already_seated_by` without its `payment_id` predicate; the workflow step's post-COMMIT refund path, which a bare `die` proves is dead to all 65 files; and two concurrent carts over the same session pair, which no test takes.
3. **The columns**, with the per-tenant loop and a revert-harness entry.
4. **Only then Task 6.** Its partial unique index encodes the enrollment status vocabulary, and §2.4 changes who owns that.

## 6. The honest caveat

I designed the guards this document replaces, and three review rounds found 21 defects in them. The argument for this design is structural — one write path, one classifier, one seat predicate, illegal transitions rejected by construction — but I am not the right person to be the only reader of it. It should be reviewed before it is built.
