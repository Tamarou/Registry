# After-School and Camp on PriceOps Implementation Plan

> **Approved by perigrin, 2026-11-27** ("Seems right", https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5). Read as approving the plan as written, including: (A) Task 1 moves Solo v2 holders to v3 on identical price, fee and policies, adding the new workflows; (F) a drop under a refund policy that refuses is refused and instalments keep billing; no new refund kind.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sell camp and after-school as PriceOps offers (child-held entitlements, instalment plans, approval, transfers, waitlist, make-ups, sibling and early-bird versions), rewire every screen onto entitlements, and delete the old path.

**Architecture:** A session is one finite resource whose days are its events. Checkout is a new public `session-checkout` workflow built from the in-studio pieces (hold, one charge, complete), carrying one cart line per child and one Stripe schedule per instalment child. Every lifecycle rule is read from the stamped offer version; admin approval parks a run and `ContinueWorkflowRun` resumes it. The old tables, DAOs, workflows, jobs and tests are retired last, after every reader has moved.

**Tech Stack:** Perl 5.42, Object::Pad, Mojolicious, Mojo::Pg, PostgreSQL, Sqitch, Minion, HTMX, Stripe (direct charges and subscription schedules on the studio's account), carton.

**Spec:** `docs/superpowers/specs/2026-11-27-after-school-and-camp-on-priceops-design.md` (approved by perigrin). Parent spec: `git show origin/docs/priceops-model-design:docs/superpowers/specs/2026-11-21-priceops-model-design.md`, step 8. Executors read both.

## Global Constraints

- `use 5.42.0; use utf8; use Object::Pad;` classes as in `lib/Registry/DAO/Entitlement.pm`. Every new file starts with two `ABOUTME:` lines (`#`, `--` or `%#` as the file type takes).
- SQL lives only under `lib/Registry/DAO/` (workflow step classes count). `t/unit/no-sql-outside-dao.t`'s allowlist only shrinks: a task that deletes an allowlisted file deletes its entry.
- Schema changes are Sqitch changes (`sql/deploy`, `sql/revert`, `sql/verify`, a line in `sql/sqitch.plan`) that loop over `registry` and every tenant schema as `sql/deploy/priceops-offer-policies.sql` does. The same commit runs `make test-schema` and commits `sql/test-schema.sql`.
- Workflows are YAML under `workflows/`, each declaring `roles:` or `public: true`. A changed step list in a shipped workflow gets a migration that clears the stored copy in every schema (the `offer-publishing-adds-*` pattern) so import rebuilds it.
- Templates use only design-system classes and CSS custom properties (`docs/design-system.md`); no utility classes.
- No mocks. Stripe is called only from `t/stripe-live/` files gated on an `sk_test_` key (`Test::Registry::StripeConnect::available()`). Every other test reaches the money path through stored webhook events (`Test::Registry::StripeWebhook`) and never calls Stripe.
- Test-only helpers live in `t/lib/Test/Registry/`. Never add test infrastructure to production classes.
- 100% pass, no new warnings, no `skip`/`TODO`. An old-model test is deleted or rewritten by the task named in the Test Retirement Register, never skipped.
- Money is integer cents. Fractions have at most 4 decimal places. `application_fee_amount` is omitted at 0. Any change to a live Stripe schedule sends `proration_behavior: 'none'`.
- Every pricing and lifecycle rule is configuration on the stamped offer version (or, for the waitlist, the session resource). No built-in sibling, early-bird, transfer or missed-payment rule in code.
- Absence is not zero: refuse, never charge or grant by default.
- Camp checkout stays refused in production (`camp_checkout_refusal`) until Task 48 removes it, so nothing sells before the whole milestone lands.
- Each PR runs `make test` and CI green before review. perigrin merges.
- Commit messages end with the attribution trailer the executing session is given.

## Review Focus

1. **A cart where one child's seat is lost while the parent pays** (hold lapsed, session filled meanwhile): the other children are booked, that child's line alone is refunded its share, and no Stripe schedule is made for it. Pinned in Task 19.
2. **Stripe's final failed retry delivered twice, or after the invoice was paid:** the `missed_payment` policy applies once, and a paid invoice is never followed by an end. Pinned in Task 21.
3. **Two admins deciding one request at once, or a decision on a run whose entitlement already ended:** one decision wins, the second is refused with a reason, and the run moves once. Pinned in Task 26.
4. **A seat freeing while children are waiting:** a public visitor cannot take it before the queue's offer, and only the payer can open the offer's run. Pinned in Tasks 31 and 32.
5. **An early-bird `before {at}` deadline crossed between choosing and holding:** the version is refused at the hold, with a sentence, and the parent chooses again. Comparison is of instants, never local dates. Pinned in Task 17.

---

## Planner's calls (the design's "Left to the builder", decided)

1. **The session resource is the session.** `events.session_resource_id` links a session's days to its resource; `resources.waitlist` holds the waitlist setting. A session's dates are its days' events. The `sessions`, `session_events` and `session_teachers` tables retire with the old path.
2. **Instalment plan fields** are columns on `offer_version_payment_plans`: `count` (2 to 52), `cadence` (`weekly`, `monthly`, `quarterly`) and `surcharge_pct` (0 to 100, two places, NULL for none). The kind CHECK gains `instalments`.
3. **Weekly cadence over a short session: refuse, never clamp.** Due dates are the checkout date plus n-1 cadences (weekly is 7 days; monthly and quarterly use the month arithmetic with end-of-month clamping from `PricingPlan::_add_months`). Publishing refuses a plan whose last instalment would fall after the last day of a covered session if bought today. At checkout, a plan that no longer fits is not offered, and the page says why.
4. **The waitlist queue** is a `waitlist_entries` table: resource, child, payer, `joined_at`, state (`waiting`, `offered`, `accepted`, `lapsed`, `left`) and the offer's hold and run. Order is `joined_at, id`. While any child waits, a public hold on that session is refused, so a freed seat goes to the queue first.
5. **The waitlist offer** is a `session-checkout` run created for the payer (so only the payer can open it), with a hold placed for that run for `offer_hold_hours`. The hold's recorded `lifetime` is 15 minutes, so the payment step's extension (never past `placed_at + 2 × lifetime`) adds nothing to a 48-hour hold. Offers and lapses are handled by a recurring sweep every 5 minutes.
6. **The absent mark.** `entitlement_uses` gains `event_id` (the day), `mark` (`present`/`absent`) and `credit_entitlement_id` (the make-up credit the absence earned). Its key becomes `(entitlement_id, event_id)`. `occurrence_id` stays as the resource whose unit the entitlement holds.
7. **The make-up credit's link to its absence** is `entitlement_uses.credit_entitlement_id`. `max_per_term` counts credits per session entitlement (one session bought whole is one term). Correcting an absence to present ends an unused credit; changing an absence whose credit was booked is refused.
8. **Past due is two columns, not a state:** `past_due_since` and `past_due_invoice_id`. The state stays `active`, so the seat is kept and siblings still qualify. The ended states gain `unpaid` (ended for a missed payment) and `transferred` (moved to another offer).
9. **Instalment money links.** The checkout charge carries no instalment columns. Instalments 2..N are `payments` rows with `instalment_seq`, `instalment_count`, `stripe_schedule_id` and a new `entitlement_id`. "Paid so far" for an entitlement is its `payment_share_cents` plus its completed instalment and change payments, plus its predecessors' when it was transferred.
10. **The cart payment.** `payments.offer_version_id` is left NULL on a session cart's charge. Each line's version is stamped on its entitlement, and `payment_share_cents` ties it to the charge (see the contradictions section).
11. **Version choice.** The cheapest choosable version is preselected: lowest `price_cents`, then offer name, then version id. Conditions are evaluated in the cart and re-asked when the seats are held. The hold's moment is the purchase moment; completion does not re-ask, so a deadline that passes mid-payment does not refuse a paid booking.
12. **`approval` is optional on the refund and change policies, and absent reads as `none`.** In-studio versions are immutable and cannot gain the field. The publishing steps always write it. `price_difference` likewise reads as `same_price_only` when absent.
13. **Approval storage.** An `entitlement_requests` row is written only when approval is required. Only `admin` may decide (not staff). The decision is its own `entitlement-decision` run. It enqueues `continue_workflow_run` for the parked run and tells the payer.
14. **Cross-offer transfers** end the old entitlement as `transferred` and grant a new one stamped with the target's cheapest choosable version. The new one carries `transferred_from_entitlement_id`, and pending instalment rows move to it. A same-offer move stays in place, as today. The target must offer the entitlement's plan kind, and for instalments the same `count` and `cadence`, or the target is not listed.
15. **Instalment price difference** is spread over the unpaid instalments (remainder on the last) by updating the Stripe schedule. If a refund owed exceeds what is left, the remaining instalments go to 0 and the excess is refunded from the latest paid payments (`charge_and_refund`) or kept (`charge_only`).
16. **Teacher attendance:** the teacher dashboard is rewired, and the in-studio day view is left as it is. Teachers (`staff`) mark session days at `/teacher/attendance/:event_id`.
17. **Time zones:** every time and date is shown in its location's zone. Admin totals sum cents per currency and bucket dates by each row's own location zone. No tenant-wide zone is invented.
18. **Seeds:** the SACP seed drops its two draft projects (Summer Camp 2026 is past; Victoria creates programs in `session-setup`) and the program-type keys nothing reads (`enrollment_rules`, `default_price`). The registry storefront's "Get Started Today" session, its event and the `tiny-art-empire` project are deleted. The registry landing links to `tenant-signup`, which already lists Solo.
19. **Solo versions:** Task 1 publishes Solo v3 listing the four new workflows, and Task 43 publishes Solo v4 without the retired ones. Each moves the current holders of its predecessor onto it at identical price, fee and policies (see the contradictions section: this needs perigrin's yes).
20. **Retirement order:** (1) every reader is rewired, in PRs 2 to 8; (2) old workflows are removed (YAML, stored rows, Solo v4); (3) steps, controllers, routes, templates and jobs go; (4) DAOs and Payment.pm's enrollment code go; (5) tables are dropped; (6) seeds. The register at the end gives each old test file's owner and fate.
21. **Notifications** use the existing types (`general`, `waitlist_offer`, `waitlist_expiration`, `waitlist_joined`, `enrollment_confirmation`). No enum migration.
22. **Grace sweep** is a recurring `missed_payment_grace` job every hour. A grace end and an `end` both cancel the remaining Stripe schedule, so nothing bills for an ended entitlement.

## Design contradictions and gaps (for perigrin)

- **A. Existing Solo holders never receive new workflows.** The run right comes from the Solo version's stored set, and a stamped entitlement never changes. Any tenant holding Solo v2 when this lands (SACP, if the in-studio launch signs it up first) could not run `session-checkout`. Task 1 moves v2 holders to v3 at identical terms, refusing unless price, fee and policies are equal. That contradicts "later versions change only what later buyers get" for the platform's own offer, and needs perigrin's yes before PR 1 merges.
- **B. "Every charge stamps the offer version it was sold under" (parent spec) against one shared payment for several children on different versions.** One `payments.offer_version_id` cannot hold several versions. The stamp is kept per entitlement; the cart's charge leaves the column NULL (call 10).
- **C. The database fixes an entitlement's stamp, yet a transfer may change its price and offer.** A cross-offer transfer cannot happen in place, so it is an end plus a new entitlement (call 14).
- **D. `family_holds_entitlement` is "already stored" as `{offer_id}` (singular, required), but the design gives `{offer_ids?}`.** Task 4 replaces the shape. Its migration refuses to run if any published version carries the old one.
- **E. "Past due" and "restores the entitlement to active" read like a state, but the database forbids leaving an ended state.** Past due is a flag on an active entitlement (call 8).
- **F. A drop on an instalment plan whose refund policy refuses** (`none`, or past the cutoff). Drops are refund requests, so such a drop is refused and the instalments keep billing ("sales are final"). The design's "an approved drop cancels the remaining instalments" covers only drops the policy allows. If perigrin wants a no-refund drop that stops future instalments, that is a new refund kind.
- **G. Prior-art defect:** `Payment::instalment_schedule_params` hard-codes `recurring[interval] = month`, so a quarterly plan would bill monthly. Task 15 fixes it while reusing the code.

---

## File Structure

New:
- `lib/Registry/PriceOps/Instalments.pm`: pure functions. Due dates, parts and fit for an instalment plan. No SQL.
- `lib/Registry/DAO/WaitlistEntry.pm`: the per-session queue.
- `lib/Registry/DAO/EntitlementRequest.pm`: the approval queue.
- `lib/Registry/DAO/WorkflowSteps/`: `SessionProgram.pm`, `SessionDays.pm`, `InstalmentPaymentPlan.pm`, `MissedPaymentPolicy.pm`, `OfferConditions.pm`, `SessionCart.pm`, `HoldSessionSeats.pm`, `SessionCartPayment.pm`, `CompleteSessionCheckout.pm`, `DecideRefund.pm`, `AwaitApproval.pm`, `ChooseChangeDestination.pm`, `DecideChange.pm`, `PayChangeDifference.pm`, `DecideRequest.pm`, `ChooseMakeupCredit.pm`, `BookMakeup.pm`.
- `lib/Registry/Job/WaitlistOffers.pm`, `lib/Registry/Job/MissedPaymentGrace.pm`.
- `workflows/session-setup.yml`, `workflows/session-checkout.yml`, `workflows/entitlement-decision.yml`, `workflows/makeup-booking.yml`, with templates under `templates/<slug>/`.
- `t/lib/Test/Registry/Sessions.pm`: builds programs, sessions and published session offers for tests.

Modified (main ones): `DAO/OfferVersion.pm` (vocabulary, instalment plans, condition evaluation), `DAO/Entitlement.pm` (past due, transfer, day marks, make-ups, paid so far), `DAO/Resource.pm` (sessions), `DAO/Payment.pm` (schedule per entitlement), `Controller/Webhooks.pm` (final retry, schedule cancel), `Job/InstalmentSchedule.pm`, `Job/InstalmentReconcile.pm`, the refund/change steps, the dashboards, `DAO/Message.pm`, `DAO/Notification.pm`, `DAO/WorkflowSteps/ProgramListing.pm`, `DAO/WorkflowSteps/GenerateEvents.pm`, `Controller/TeacherDashboard.pm`, `Controller/Waitlist.pm`, the attendance-check steps, `Job/Recurring.pm`, `docs/operations/sacp-stripe-connect-onboarding.md`, `sql/seed/sacp-tenant.sql`.

Deleted in PR 9: see Tasks 43 to 47.

## PR steps

| PR | Step | Tasks |
|---|---|---|
| 1 | 8.1 The model | 1 to 9 |
| 2 | 8.2 Session product design | 10 to 14 |
| 3 | 8.3 Checkout | 15 to 20 |
| 4 | 8.4 Missed payments | 21 to 23 |
| 5 | 8.5 Drops and transfers | 24 to 30 |
| 6 | 8.6 Waitlist | 31 to 33 |
| 7 | 8.7 Attendance and make-ups | 34 to 37 |
| 8 | 8.8 Screens | 38 to 42 |
| 9 | 8.9 Retire the old path | 43 to 47 |
| 10 | 8.10 Acceptance | 48 to 49 |

---

## PR 1 — Step 8.1: The model

### Task 1: Solo v3 grants the milestone's workflows (TIER_2)

**Files:**
- Create: `sql/deploy/solo-grants-session-workflows.sql`, `sql/revert/…`, `sql/verify/…`. Modify: `sql/sqitch.plan`, `sql/test-schema.sql`.
- Test: `t/database/solo-grants-session-workflows.t`

**Interfaces:**
- Consumes: Solo v2 id `md5('solo-grants-workflow-set/version')::uuid`, the pattern of `sql/deploy/solo-grants-workflow-set.sql`.
- Produces: run resources `run:session-setup`, `run:session-checkout`, `run:entitlement-decision`, `run:makeup-booking`. Solo v3 id is `md5('solo-grants-session-workflows/version')::uuid`, and its set is v2's set plus those four.

- [ ] **Step 1: Write the failing test**

```perl
subtest 'solo v3 lists the session workflows and supersedes v2' => sub {
    my $v3 = solo_current($db);
    is $v3->{version}, 3;
    ok listed( $db, $v3->{id}, "run:$_" ), "lists $_" for qw( session-setup session-checkout entitlement-decision makeup-booking );
    ok listed( $db, $v3->{id}, 'run:in-studio-booking' ), 'keeps v2 set';
    is_deeply [ $v3->@{qw( price_cents fraction )} ], [ 0, '0.025' ];
};
subtest 'a tenant holding v2 is moved to v3 on identical terms' => sub {
    # deploy to solo-grants-workflow-set, accept v2 as a tenant, deploy this change
    is $moved->{offer_version_id}, $v3->{id};
    is $old->{state}, 'expired';
    is $old->{ended_reason}, 'superseded by Solo v3';
    ok Registry::DAO::Entitlement->may_run( $db, $tenant_id, 'session-checkout' );
};
subtest 'refuses when v2 and v3 terms differ' => sub {
    like $err, qr/Solo v3 must keep v2's price, fee and policies/;
};
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/database/solo-grants-session-workflows.t`. Expected: FAIL, no v3.
- [ ] **Step 3: Write the migration.** Copy v2's terms into a v3 draft, add the four run resources to v2's set, and publish v3 over v2. For each active v2 holder, end it at `now()` with reason `superseded by Solo v3` and insert a v3 entitlement on the same plan id from that instant. Before writing, raise if v3 differs from v2 in price, plan fraction or policies.
- [ ] **Step 4: Run it, then `carton exec prove -l t/priceops/`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`, then commit** `Solo v3 grants the session workflows; v2 holders move on identical terms`.

### Task 2: Session resources (TIER_2)

**Files:**
- Create: `sql/deploy/session-resources.sql` (+revert/verify), `t/lib/Test/Registry/Sessions.pm`. Modify: `lib/Registry/DAO/Resource.pm`, `lib/Registry/DAO/Entitlement.pm` (`expire_ended_occurrences`), `lib/Registry/DAO/WorkflowSteps/ApplyRefundPolicy.pm` (cutoff start).
- Test: `t/dao/session-resource.t`

**Interfaces:**
- Produces:
  - `Registry::DAO::Resource->create_session($db, { name, capacity, waitlist => { kind => 'none' } | { kind => 'queue', offer_hold_hours => N }, project_id, location_id, teacher_id, days => ['YYYY-MM-DD', ...], start => 'HH:MM', minutes => N }) -> Resource`: one finite resource and one `published` event per day, at `start` in the location's zone.
  - `$resource->waitlist -> HASH`
  - `$resource->session_days($db) -> [ { id, time, duration } ]`, in time order
  - `$resource->is_session($db) -> bool`
  - `$resource->occurrence_window($db) -> ($start, $end)`: for a session, first day's start to last day's end
  - `$resource->on_sale($db)`: for a session, all days published and the first not yet started
- Test helper: `Test::Registry::Sessions::make_session($db, %overrides) -> Resource`, with a project, location and teacher made as needed.
- Schema: `events.session_resource_id uuid REFERENCES resources(id)` and `resources.waitlist jsonb NOT NULL DEFAULT '{"kind":"none"}'`. CHECKs: `kind` is `none` or `queue`; `queue` has exactly `offer_hold_hours` as a whole number above 0; `queue` only on a finite resource; an event with `session_resource_id` has no occurrence resource.

- [ ] **Step 1: Write the failing test**

```perl
my $s = make_session( $db, days => [qw( 2027-06-07 2027-06-08 2027-06-09 )], start => '09:00', minutes => 420, capacity => 12 );
is scalar $s->session_days($db)->@*, 3;
my ( $from, $to ) = $s->occurrence_window($db);
is $from, local_instant( '2027-06-07 09:00', $tz );
is $to,   local_instant( '2027-06-09 16:00', $tz );
ok $s->on_sale($db);
ok !make_session( $db, days => [ yesterday() ] )->on_sale($db), 'started sessions are not on sale';
throws_ok { make_session( $db, waitlist => { kind => 'queue' } ) } qr/waitlist/;
# entitlement with end_of_occurrence expiry on a session expires at its last day's end
is_deeply Registry::DAO::Entitlement->expire_ended_occurrences($db), [ $past_session_entitlement->id ];
# full_until_cutoff cutoff_hours counts back from the first day
like ApplyRefundPolicy->refusal( $db, $e, $first_day_minus_23h ), qr/only until/;
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/session-resource.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration and `Resource` methods.** One shared `occurrence_window` query: by `event_id` for an occurrence, by `session_resource_id` for a session. `expire_ended_occurrences` and `ApplyRefundPolicy->refusal` read starts and ends through it instead of `r.event_id`.
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/priceops/`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `A session is one finite resource whose days are its events`.

### Task 3: The instalments payment plan, and missed_payment required to publish it (TIER_2)

**Files:**
- Create: `sql/deploy/instalment-payment-plans.sql` (+revert/verify). Modify: `lib/Registry/DAO/OfferVersion.pm`, `t/lib/Test/Registry/Offers.pm`.
- Test: `t/dao/offer-version-instalments.t`

**Interfaces:**
- Produces:
  - `payment_plans` entries `{ id, kind => 'instalments', count, cadence, surcharge_pct }`, accepted by `OfferVersion->draft` and returned by `$version->payment_plans($db)`.
  - `$version->publish` croaks `offer %s version %d offers instalments and has no missed_payment policy`. The database refuses the same at commit with constraint trigger `offer_versions_instalments_need_missed_payment`.
  - `Test::Registry::Offers::instalment_plan(%o) -> { id => 'parts', kind => 'instalments', count => 3, cadence => 'monthly', %o }`

- [ ] **Step 1: Write the failing test**

```perl
my $v = OfferVersion->draft( $db, $offer_id, offer_terms( $r->id,
    payment_plans => [ { id => 'pay', kind => 'one_time' }, instalment_plan( cadence => 'weekly', surcharge_pct => '5.00' ) ],
    policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'keep_and_owe' } } ) );
is_deeply [ map { $_->{kind} } $v->payment_plans($db)->@* ], [qw( instalments one_time )];
ok $v->publish($db);
throws_ok { draft_with( instalment_plan( count => 1 ) ) } qr/count/;
throws_ok { draft_with( instalment_plan( cadence => 'daily' ) ) } qr/cadence/;
throws_ok { draft_with( instalment_plan( surcharge_pct => '1.234' ) ) } qr/surcharge/;
throws_ok { draft_with( { id => 'pay', kind => 'one_time', count => 3 } ) } qr/instalments/;
throws_ok { draft_without_missed_payment()->publish($db) } qr/no missed_payment policy/;
throws_ok { $db->query("UPDATE offer_versions SET published_at = now() WHERE id = ?", $bare->id) } qr/missed_payment/;
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/offer-version-instalments.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration** (kind CHECK adds `instalments`; columns `count integer CHECK (count BETWEEN 2 AND 52)`, `cadence text CHECK (cadence IN ('weekly','monthly','quarterly'))`, `surcharge_pct numeric CHECK (surcharge_pct >= 0 AND surcharge_pct <= 100 AND scale(surcharge_pct) <= 2)`, and `(kind = 'instalments') = (count IS NOT NULL AND cadence IS NOT NULL)`, with surcharge only on instalments) and the constraint trigger. `draft` inserts the three fields.
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Instalments are a payment plan kind, published only with a missed_payment policy`.

### Task 4: Policy and condition vocabulary (TIER_2)

**Files:**
- Create: `sql/deploy/priceops-session-vocabulary.sql` (+revert/verify). Modify: `lib/Registry/DAO/OfferVersion.pm` (`%POLICY`, `%CONDITION`, `$fits`).
- Test: `t/dao/offer-version-vocabulary.t`

**Interfaces:**
- Produces, as the only accepted shapes:
  - `refund`: each existing kind, optionally with `approval => 'required'|'none'`
  - `change`: `none`, or `window { window_hours, fee_cents, targets, price_difference?, approval? }`. `targets` is `'same_offer'`, `'same_program'` or `{ offer_ids => [uuid, ...] }` (non-empty). `price_difference` is `charge_and_refund`, `charge_only` or `same_price_only`.
  - `use`: `optional_attendance`, `none`, `makeup { offer_id => uuid, credit_days => whole > 0, max_per_term? => whole > 0 }`
  - `missed_payment`: `keep_and_owe`, `end`, `grace { days => whole > 0 }`
  - conditions: `family_holds_entitlement { offer_ids? => [uuid, ...] }`, `before { at => instant }`, `holder_is_offerer`
  - `OfferVersion->approval_for($policy) -> 'required'|'none'` and `OfferVersion->price_difference_for($change) -> kind`, which read absence as `none` and `same_price_only` (call 12)
- Schema: CHECK `offer_versions_missed_payment_kind_check` on `policies #>> '{missed_payment,kind}'`. The migration raises if any published version's conditions contain `offer_id`.

- [ ] **Step 1: Write the failing test.** Cover every shape above. For each policy, accept one example per kind and refuse an unknown field, a wrong type and a missing required field. Pin the absence reads:

```perl
is OfferVersion->approval_for( { kind => 'none' } ), 'none';
is OfferVersion->price_difference_for( { kind => 'window', window_hours => 48, fee_cents => 0, targets => 'same_offer' } ), 'same_price_only';
ok  ok_policy( change => { kind => 'window', window_hours => 0, fee_cents => 0, targets => { offer_ids => [$o1] }, price_difference => 'charge_only', approval => 'required' } );
ok !ok_policy( change => { kind => 'window', window_hours => 0, fee_cents => 0, targets => { offer_ids => [] } } );
ok  ok_condition( { kind => 'before', at => '2027-03-01T00:00:00-05:00' } );
ok !ok_condition( { kind => 'family_holds_entitlement', offer_id => $o1 } ), 'the singular shape is retired';
ok  ok_condition( { kind => 'family_holds_entitlement' } ), 'offer_ids is optional';
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/offer-version-vocabulary.t`. Expected: FAIL.
- [ ] **Step 3: Extend the tables.** Keep the exact-match rule: a shape's optional fields are written as a field check that accepts its absence. Remove the `shortcut:` comment on `targets`.
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/priceops/`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Offer versions declare approval, targets, price difference, make-ups, missed payment, sibling and early-bird`.

### Task 5: Past due, unpaid, transferred, and instalment payment links (TIER_2)

**Files:**
- Create: `sql/deploy/entitlement-past-due-and-transfer.sql` (+revert/verify). Modify: `lib/Registry/DAO/Entitlement.pm`, `lib/Registry/DAO/Payment.pm` (field `entitlement_id`).
- Test: `t/dao/entitlement-past-due.t`

**Interfaces:**
- Schema: `entitlements.past_due_since timestamptz` and `past_due_invoice_id text`, both or neither. `entitlements.transferred_from_entitlement_id uuid UNIQUE REFERENCES entitlements(id)`, fixed once set (stamp trigger). The state CHECK adds `unpaid` and `transferred`. `payments.entitlement_id uuid REFERENCES entitlements(id)`.
- Produces:
  - `$e->mark_past_due($db, $invoice_id)`: idempotent per invoice
  - `$e->clear_past_due($db, $invoice_id)`: only when that invoice is the one past due
  - `$e->is_past_due -> bool`
  - `$e->paid_cents($db) -> int`: share, plus completed payments with `entitlement_id = id`, plus predecessors', less `refunded_cents` over the chain
  - `$e->chain($db) -> [Entitlement]`: oldest first

- [ ] **Step 1: Write the failing test**

```perl
$e->mark_past_due( $db, 'in_1' );
ok $e->reload($db)->is_past_due;  is $e->state, 'active';
ok Registry::DAO::Resource->find( $db, { id => $r->id } )->held_units($db)->@*, 'seat kept';
$e->clear_past_due( $db, 'in_other' );  ok $e->reload($db)->is_past_due, 'another invoice clears nothing';
$e->clear_past_due( $db, 'in_1' );      ok !$e->reload($db)->is_past_due;
is $e->end( $db, 'unpaid', 'in_2' )->state, 'unpaid';
is $e2->paid_cents($db), 3000 + 1500, 'share plus completed instalment rows';
throws_ok { $db->update( 'entitlements', { transferred_from_entitlement_id => undef }, { id => $t->id } ) } qr/keeps/;
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/entitlement-past-due.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration** (extend `entitlement_stamp()` for `transferred_from_entitlement_id`) **and the methods.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `An entitlement can be past due, end unpaid or transferred, and names its instalment payments`.

### Task 6: A day's present or absent mark (TIER_2)

**Files:**
- Create: `sql/deploy/entitlement-uses-per-day.sql` (+revert/verify). Modify: `lib/Registry/DAO/Entitlement.pm`, `lib/Registry/DAO/WorkflowSteps/DayView.pm` (present query keys on `event_id`).
- Test: `t/dao/entitlement-day-marks.t`

**Interfaces:**
- Schema: `entitlement_uses.event_id uuid NOT NULL REFERENCES events(id)`, backfilled from `resources.event_id`. `mark text NOT NULL DEFAULT 'present' CHECK (mark IN ('present','absent'))`. `credit_entitlement_id uuid REFERENCES entitlements(id)`. PK `(entitlement_id, event_id)`.
- Produces:
  - `$e->mark_day($db, $event_id, $mark, $recorded_by) -> $e`. It refuses (`Entitlement::Refused`) unless the entitlement is in effect, its use policy is `optional_attendance` or `makeup`, and the day is its occurrence's event or one of its session's days. A second mark replaces the first.
  - `$e->record_use($db, $occurrence_id, $by)` becomes `mark_day` with the occurrence's event and `present`.
  - `$e->day_marks($db) -> { event_id => mark }`

- [ ] **Step 1: Write the failing test**

```perl
$e->mark_day( $db, $day2->{id}, 'absent', $teacher->id );
is_deeply $e->day_marks($db), { $day2->{id} => 'absent' };
$e->mark_day( $db, $day2->{id}, 'present', $teacher->id );
is $e->day_marks($db)->{ $day2->{id} }, 'present', 'replaced, not added';
throws_ok { $e->mark_day( $db, $other_session_day, 'present' ) } 'Registry::DAO::Entitlement::Refused';
throws_ok { $e->mark_day( $db, $day1->{id}, 'late' ) } qr/present or absent/;
# in-studio record_use still records present on the occurrence's event
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/entitlement-day-marks.t t/dao/entitlement-use.t`. Expected: FAIL on the new file.
- [ ] **Step 3: Write the migration and methods.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/controller/in-studio-day-view.t`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Attendance is a present or absent mark per day, for occurrences and session days`.

### Task 7: Conditions evaluated, versions chosen (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/OfferVersion.pm`, `t/lib/Test/Registry/Sessions.pm`
- Test: `t/dao/offer-conditions.t`

**Interfaces:**
- Consumes: Task 4's shapes; Task 5's past due (still `active`).
- Produces:
  - `$version->unmet_conditions($db, $ctx) -> [ sentence ]`, where `$ctx = { holder_family_member_id, at, cart_offer_ids => [offer_id of earlier lines for other children] }`.
    - `family_holds_entitlement` is met by another family member of the holder's family with an `active` entitlement in effect at `at` whose `offer_id` is in `offer_ids` (or any offer when `offer_ids` is absent), or by an earlier cart line.
    - `before` is met when `at < at` as instants.
    - `holder_is_offerer` is never met here.
  - `Registry::DAO::OfferVersion->choosable_for($db, $resource_id, $ctx) -> [ { version, unmet => [...] } ]`: every current version buying the resource, sorted by price, offer name, then id. Choosable ones have an empty `unmet`.
  - `Test::Registry::Sessions::session_offer($db, $resource, %terms) -> OfferVersion` (published)

- [ ] **Step 1: Write the failing test**

```perl
my ( $regular, $sibling, $early ) = map { session_offer( $db, $s, %$_ ) }
    { price_cents => 30000 },
    { price_cents => 27000, conditions => [ { kind => 'family_holds_entitlement' } ] },
    { price_cents => 25000, conditions => [ { kind => 'before', at => '2027-03-01T00:00:00Z' } ] };
my $c = sub (%ctx) { [ map { $_->{version}->id } grep { !$_->{unmet}->@* } OfferVersion->choosable_for( $db, $s->id, { at => '2027-02-01T00:00:00Z', %ctx } )->@* ] };
is_deeply $c->( holder_family_member_id => $kid1 ), [ $early->id, $regular->id ];
is_deeply $c->( holder_family_member_id => $kid1, at => '2027-03-01T00:00:00Z' ), [ $regular->id ], 'before is exclusive';
is_deeply $c->( holder_family_member_id => $kid2, cart_offer_ids => [ $regular->offer_id ] ), [ $early->id, $sibling->id, $regular->id ];
grant_active( $kid1 );  # active entitlement, other offer
ok !$sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $now } )->@*, 'a sibling bought earlier qualifies';
ok  $sibling->unmet_conditions( $db, { holder_family_member_id => $kid1, at => $now } )->@*, 'the holder itself does not';
end_it( $kid1 );  ok $sibling->unmet_conditions( $db, { holder_family_member_id => $kid2, at => $now } )->@*, 'an ended one does not';
past_due_it( $kid1 );  ok !$sibling->unmet_conditions(...)->@*, 'a past due one does';
# offer_ids limits which offers count
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/offer-conditions.t`. Expected: FAIL.
- [ ] **Step 3: Implement** both methods with one SQL query for the family check, using `Entitlement->in_effect_sql`.
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `Sibling and early-bird conditions are evaluated; the parent chooses among versions`.

### Task 8: Waitlist entries (TIER_2)

**Files:**
- Create: `sql/deploy/waitlist-entries.sql` (+revert/verify), `lib/Registry/DAO/WaitlistEntry.pm`
- Test: `t/dao/waitlist-entry.t`

**Interfaces:**
- Schema: `waitlist_entries(id, resource_id → resources, family_member_id → family_members, payer_user_id → users, joined_at default clock_timestamp(), state CHECK IN (waiting, offered, accepted, lapsed, left), hold_id → holds, workflow_run_id → workflow_runs, offered_at)`. `offered` requires `hold_id`, `workflow_run_id` and `offered_at`. A partial unique index on `(resource_id, family_member_id) WHERE state IN ('waiting','offered')`.
- Produces:
  - `WaitlistEntry->join($db, { resource_id, family_member_id, payer_user_id })`: refused (`Entitlement::Refused`) unless the resource's waitlist kind is `queue`
  - `WaitlistEntry->next_waiting($db, $resource_id)`, locked
  - `$entry->offer($db, $hold_id, $run_id)`, `$entry->accept($db)`, `$entry->lapse($db)`, `$entry->leave($db)`: each a legal-predecessor update
  - `WaitlistEntry->position($db, $entry_id) -> int`
  - `WaitlistEntry->waiting_count($db, $resource_id) -> int`

- [ ] **Step 1: Write the failing test.** Cover: join on a `none` session refused; FIFO by `joined_at`; a second join for the same child refused; `offer` from `waiting` only; `accept` only from `offered`; `lapse` then a new join allowed; positions after `leave`.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/waitlist-entry.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration and DAO.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `A session resource's waitlist is a first-come queue of children`.

### Task 9: Entitlement requests, the approval queue (TIER_2)

**Files:**
- Create: `sql/deploy/entitlement-requests.sql` (+revert/verify), `lib/Registry/DAO/EntitlementRequest.pm`
- Test: `t/dao/entitlement-request.t`

**Interfaces:**
- Schema: `entitlement_requests(id, entitlement_id → entitlements, kind CHECK IN ('refund','change'), workflow_run_id UNIQUE → workflow_runs, outcome jsonb NOT NULL, state CHECK IN ('pending','approved','declined') DEFAULT 'pending', requested_by → users, decided_by → users, decided_at, note, created_at)`. Decided means `decided_by` and `decided_at` are set.
- Produces:
  - `EntitlementRequest->open($db, { entitlement_id, kind, workflow_run_id, outcome, requested_by })`
  - `EntitlementRequest->for_run($db, $run_id)`
  - `$request->decide($db, $state, $admin_id, $note) -> bool`: one `UPDATE … WHERE state = 'pending'`, so the second decider gets false
  - `EntitlementRequest->pending($db) -> [rows with child name, offer name, outcome]`

- [ ] **Step 1: Write the failing test.** Cover: open, then `for_run`; `decide('approved')` true, then `decide('declined')` false and the state stays `approved`; `decide('maybe')` croaks; `pending` lists only pending, oldest first.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/entitlement-request.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration and DAO.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Refund and change requests that need approval are recorded for an admin`.

---

## PR 2 — Step 8.2: Session product design

### Task 10: session-setup: program and sessions (TIER_1)

**Files:**
- Create: `workflows/session-setup.yml` (steps `program`, `sessions` and, for now, `complete`), `lib/Registry/DAO/WorkflowSteps/SessionProgram.pm`, `lib/Registry/DAO/WorkflowSteps/SessionDays.pm`, `templates/session-setup/{program,sessions,complete}.html.ep`
- Test: `t/controller/session-setup.t`

**Interfaces:**
- Consumes: `Resource->create_session` (Task 2).
- Produces:
  - Run data `session_program => { project_id, location_id }` and `sessions => [resource_id, ...]` (the ones this run made).
  - `SessionDays` form: `name`, `first_day`, `last_day`, `weekdays[]` (1 to 7), `start`, `minutes`, `capacity`, `waitlist` (`none` or `queue`), `offer_hold_hours`. Days are the weekdays from first to last inclusive. It refuses a last day before the first, no matching weekday, or `queue` without hours.
  - The YAML has `roles: [admin]`.

- [ ] **Step 1: Write the failing test.** Through the real routes as an admin: create a program, add "Camp week 1" Mon to Fri for 2027-06-07..11, 09:00, 420 minutes, capacity 12, queue with 48 hours. Assert one resource with 5 days, `waitlist` `{kind=>'queue', offer_hold_hours=>48}`, and the page listing it. Then a staff user gets 403, and a week with no matching weekday stays on the step with the error.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/session-setup.t`. Expected: FAIL.
- [ ] **Step 3: Write the steps, YAML and templates.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/security/workflow-roles-cover-every-workflow.t t/priceops/solo-lists-every-shipped-workflow.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `session-setup creates a program's sessions, each a resource with its days`.

### Task 11: Instalment and missed-payment steps, and the cadence fit (TIER_2)

**Files:**
- Create: `lib/Registry/PriceOps/Instalments.pm`, `lib/Registry/DAO/WorkflowSteps/InstalmentPaymentPlan.pm`, `lib/Registry/DAO/WorkflowSteps/MissedPaymentPolicy.pm`, their templates. Modify: `workflows/session-setup.yml`, `lib/Registry/DAO/WorkflowSteps/PublishOfferVersion.pm`, `lib/Registry/DAO/WorkflowSteps/OfferBasics.pm` (`@TERMS`).
- Test: `t/unit/instalments.t`, `t/dao/session-setup-payment-plans.t`

**Interfaces:**
- Produces:
  - `Registry::PriceOps::Instalments::due_dates($plan, $first_date) -> [YYYY-MM-DD]`
  - `parts($total_cents, $plan, $first_date) -> [ { amount_cents, due_date } ]`: surcharge first, then an even split with the remainder on the last, as `PricingPlan::instalment_schedule`
  - `fits($plan, $first_date, $last_day) -> bool`
  - Run data `instalment_payment => { id => 'parts', count, cadence, surcharge_pct } | undef` and `missed_payment_policy => { kind, days? }`
  - `PublishOfferVersion` refusals: `Choose what happens when an instalment is missed` and `A %s plan of %d payments bought today would end after %s, the last day of %s`.

- [ ] **Step 1: Write the failing tests**

```perl
is_deeply due_dates( { count => 3, cadence => 'weekly' },  '2027-05-31' ), [qw( 2027-05-31 2027-06-07 2027-06-14 )];
is_deeply due_dates( { count => 2, cadence => 'quarterly' }, '2027-11-30' ), [qw( 2027-11-30 2028-02-29 )];
is_deeply [ map { $_->{amount_cents} } parts( 10000, { count => 3, cadence => 'monthly' }, '2027-01-31' )->@* ], [ 3333, 3333, 3334 ];
is_deeply [ map { $_->{amount_cents} } parts( 10000, { count => 2, cadence => 'monthly', surcharge_pct => '5' }, '2027-01-01' )->@* ], [ 5250, 5250 ];
ok !fits( { count => 4, cadence => 'weekly' }, '2027-06-01', '2027-06-11' );
ok  fits( { count => 2, cadence => 'weekly' }, '2027-06-01', '2027-06-11' );
```

The DAO test drives the steps on a session run. Publishing with instalments and no missed-payment step is refused with the first sentence. A weekly ×4 plan over a one-week camp is refused with the second. With `grace` 7 days it publishes, and `policies->{missed_payment}` is `{kind=>'grace', days=>7}`.
- [ ] **Step 2: Run them**: `carton exec prove -l t/unit/instalments.t t/dao/session-setup-payment-plans.t`. Expected: FAIL.
- [ ] **Step 3: Implement.** `MissedPaymentPolicy` is skipped (`{}`, `missed_payment_policy => undef`) when the run offers no instalment plan.
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `Sessions can be paid in weekly, monthly or quarterly instalments, with a missed-payment policy`.

### Task 12: Refund, change and use policy steps extended (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/{RefundPolicy,ChangePolicy,UsePolicy,PublishOfferVersion}.pm`, their templates under `templates/session-setup/`, `templates/in-studio-class-setup/` and `templates/offer-publishing/`, and `workflows/session-setup.yml`. Create `sql/deploy/offer-publishing-asks-approval.sql`, which clears the stored `offer-publishing` and `in-studio-class-setup` workflows.
- Test: `t/dao/policy-steps-sessions.t`

**Interfaces:**
- Produces (run data):
  - `refund_policy` always carries `approval`
  - `change_policy` window carries `targets` (`same_offer`, `same_program` or `{ offer_ids }` from a list of this tenant's offers), `price_difference` and `approval`
  - `use_policy` may be `makeup { offer_id, credit_days, max_per_term? }`, where `offer_id` must be a current class offer in this schema
- Copy: the policy words in `ChooseOfferAndUnits->policy_words` gain
  - "Refunds are reviewed by the studio before they are made."
  - "Changes are reviewed by the studio."
  - "Moving to a different price charges or refunds the difference." (and "charges the difference." for `charge_only`; "only to the same price." for `same_price_only`)
  - "A missed day earns a make-up class within %d days."

- [ ] **Step 1: Write the failing test.** Cover each step's new choice saved and published, a `makeup` naming another tenant's or an unknown offer refused, `offer_ids` naming an unknown offer refused, an in-studio publish still writing `approval => 'none'`, and the policy words above.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/policy-steps-sessions.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/controller/`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Publishing asks for approval, change targets, price difference and make-ups`.

### Task 13: Conditions, session-mode offer basics, and publish (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/OfferConditions.pm`, `templates/session-setup/conditions.html.ep`. Modify: `OfferBasics.pm` (session mode), `PublishOfferVersion.pm` (writes `conditions` and `resource_ids`), `workflows/session-setup.yml` (full step list as `in-studio-class-setup`, plus `instalment-payment`, `missed-payment-policy` and `conditions`).
- Test: `t/controller/session-setup-publish.t`

**Interfaces:**
- Consumes: Task 10's `sessions`, Task 7's shapes.
- Produces: `OfferBasics` in a `session-setup` run lists the program's sessions as checkboxes and records `offer_basics => { resource_ids => [...] }`. `OfferConditions` records `conditions => [ ... ]` from `sibling` (with an optional offer list) and `early_bird_until` (a local date and time read in the location's zone, stored as an instant).

- [ ] **Step 1: Write the failing test.** Through the routes, publish three versions over two sessions: "Camp" $300, "Camp sibling" $270 with `family_holds_entitlement`, and "Camp early bird" $250 `before` 2027-03-01 00:00 America/New_York. Assert `before.at` is `2027-03-01T05:00:00Z`, each version's `covered_resources` is the two sessions, and a version with no sessions chosen is refused.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/session-setup-publish.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `session-setup publishes sibling and early-bird versions over a program's sessions`.

### Task 14: GenerateEvents onto session resources (TIER_1)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/GenerateEvents.pm`, `templates/program-location-assignment/generate-events.html.ep`, `templates/program-location-assignment/complete.html.ep`
- Test: rewrite `t/dao/generated-session-dates.t` and `t/dao/solo-tenant-event-generation.t`; delete `t/dao/generate-events-pricing.t` (register).

**Interfaces:**
- Consumes: `Resource->create_session`.
- Produces: GenerateEvents makes one session resource per configured location (capacity from the location's configuration, `waitlist` `none` unless set) and writes no `sessions`, `session_events` or `pricing_plans` rows. The complete page links to `session-setup` to price them.

- [ ] **Step 1: Rewrite the two tests** to assert resources with days, and that `sessions` and `pricing_plans` stay unwritten (count before equals after).
- [ ] **Step 2: Run them**: `carton exec prove -l t/dao/generated-session-dates.t t/dao/solo-tenant-event-generation.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `program-location-assignment generates session resources, not priced sessions`.

---

## PR 3 — Step 8.3: Checkout

### Task 15: An instalment schedule per entitlement (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/Payment.pm` (`instalment_schedule_params`, `schedule_remaining_instalments` → `schedule_instalments_for`, `schedules_with_owed_instalments`, `instalment_awaiting_schedule`, `outstanding_instalments`), `lib/Registry/Job/InstalmentSchedule.pm`, `lib/Registry/Job/InstalmentReconcile.pm`, `lib/Registry/Controller/Webhooks.pm` (`_schedule_not_recorded`, drop `_instalment_to_schedule`), `lib/Registry/Service/Stripe.pm` (add `update_subscription_schedule_async`).
- Test: rewrite `t/dao/instalment-schedule.t`, `t/dao/instalment-stripe-phases.t`, `t/controller/instalment-invoice-webhooks.t`, `t/controller/instalment-reconcile-job.t`, `t/controller/instalment-schedule-job-retry.t`, `t/stripe-live/instalment-schedule.t` and `t/stripe-live/instalment-invoice-schedule.t`.

**Interfaces:**
- Consumes: `Instalments::parts`; Task 5's `payments.entitlement_id`.
- Produces:
  - `Payment::instalment_schedule_params({ instalments, currency, product, customer, payment_method, revenue_share_pct, cadence, description, entitlement_id })`: `recurring[interval]` is `week` or `month`, `recurring[interval_count]` is 1 or 3, and the params carry `metadata[entitlement_id]`.
  - `$checkout_payment->schedule_instalments_for($db, $entitlement) -> schedule_id`: idempotent on `instalment_schedule:<entitlement_id>`. It reads the parts from `metadata.lines`, makes the schedule for parts 2..N on the checkout payment's customer and saved card, and inserts rows 2..N with `entitlement_id`.
  - Job `instalment_schedule` args are `(entitlement_id, slug)`.
  - `$checkout_payment->cancel_instalment_schedule($db, $entitlement)`: appends the entitlement id to `metadata.cancelled_schedules` before asking Stripe (key `cancel_schedule:<entitlement_id>`), and is a no-op when the schedule is already cancelled. Job `cancel_instalment_schedule(entitlement_id, slug)` calls it with retries; its last failure alerts admins. Tasks 21, 22, 25 and 23 use this one path.
  - `Stripe->update_subscription_schedule_async($id, $params)`.

- [ ] **Step 1: Rewrite the tests.** Pin `interval week` for weekly, `interval month` with `interval_count 3` for quarterly (the defect G fix), rows 2..N with `entitlement_id` and due dates from `due_dates`, a second job run returning the recorded schedule with no second insert, `cancel_instalment_schedule` recording the entitlement in `metadata.cancelled_schedules` before the Stripe call and doing nothing on a second call, the reconcile job settling a paid invoice on an entitlement's row, and the last failed attempt alerting admins. The live files assert Stripe accepts a weekly and a quarterly schedule on a connected account.
- [ ] **Step 2: Run them**: `carton exec prove -l t/dao/instalment-schedule.t t/dao/instalment-stripe-phases.t t/controller/instalment-*.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them; with `STRIPE_SECRET_KEY=sk_test_…`, run `carton exec prove -l t/stripe-live/instalment-schedule.t t/stripe-live/instalment-invoice-schedule.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `Each instalment entitlement gets its own Stripe schedule; quarterly bills every three months`.

### Task 16: The session cart (TIER_2)

**Files:**
- Create: `workflows/session-checkout.yml` (`public: true`; steps `account` AccountCheck, `children` SelectChildren, `cart` SessionCart, `hold` HoldSessionSeats, `payment` SessionCartPayment, `complete` CompleteSessionCheckout, `done` CompleteSessionCheckout), `lib/Registry/DAO/WorkflowSteps/SessionCart.pm`, `templates/session-checkout/{children,cart}.html.ep`
- Test: `t/controller/session-cart.t`

**Interfaces:**
- Consumes: `choosable_for` (Task 7); `Instalments::fits`; `Registry::Terms::record_agreement`.
- Produces:
  - Run data `cart_lines => [ { family_member_id, resource_id, offer_version_id, payment_plan_id } ]` in the order shown. Children come from `SelectChildren`, and only the signed-in payer's children are accepted.
  - `SessionCart->refusal($db, $data, $lines) -> sentence | undef`: each line's child is the payer's, its session is on sale and not full for the public, its version is choosable for that child given earlier lines, its plan is one of that version's and fits, and a child appears at most once per session.
  - `SessionCart->policy_words($version)`: reuses `ChooseOfferAndUnits->policy_words` with Task 12's sentences.
  - A full session shows "Join the waitlist" (wired in Task 31).
  - `/terms` is linked and recorded here, as `ChooseOfferAndUnits` does.
- Page copy: "Prices you qualify for", with the cheapest preselected; "Pay in %d %s payments of $%s" for an instalment plan; "Not offered: the last payment would fall after the session ends" for a plan that no longer fits.

- [ ] **Step 1: Write the failing test.** Two children and two sessions, with the regular, sibling and early-bird versions from `session_offer`. Assert:
  - Child 1's page preselects early-bird and does not list sibling.
  - Child 2, after child 1's line, lists sibling.
  - Posting the sibling version for child 1 is refused with "Choose one of the listed prices".
  - A child from another family is refused.
  - No terms agreement means the step stays.
  - A weekly plan past the session's end is not listed.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/session-cart.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/security/workflow-roles-cover-every-workflow.t t/security/workflow-run-data-server-owned-keys.t`** (add `cart_lines` and `owed_payment` lines to the server-owned list). Expected: PASS.
- [ ] **Step 5: Commit** `The session cart: each child, a session, a price they qualify for and a payment plan`.

### Task 17: Hold the cart's seats (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/HoldSessionSeats.pm`, `templates/session-checkout/hold.html.ep`
- Test: `t/dao/hold-session-seats.t`

**Interfaces:**
- Consumes: `SessionCart->refusal` (asked again here, at the hold's instant); `Registry::PriceOps::Hold->place`; `Instalments::parts`.
- Produces:
  - Run data `cart_holds => { "<family_member_id>:<resource_id>" => hold_id }`
  - `owed_payment => { purpose => 'session_checkout', amount_cents => Σ first charges, lines => [ { family_member_id, resource_id, offer_version_id, payment_plan_id, kind, share_cents, parts => [...] | undef, hold_id } ] }`
  - A one-time line's `share_cents` is `price_cents`; an instalment line's is `parts[0]`. One hold of 1 seat per line, 15 minutes.
  - A resubmit keeps live holds (as `HoldSeats` does). Any refusal releases every hold the run has.
  - A run carrying `waitlist_entry_id` reuses that entry's hold for its line (Task 32).

- [ ] **Step 1: Write the failing test**

```perl
is $owed->{amount_cents}, 30000 + 9000, 'one-time child plus first of three instalments of $270';
is_deeply [ map { $_->{share_cents} } $owed->{lines}->@* ], [ 30000, 9000 ];
is free_units($s1), $cap - 2, 'two seats held';
# early-bird crossed between cart and hold (Review Focus 5)
set_clock_after('2027-03-01T05:00:00Z');
like process_hold()->{errors}[0], qr/early-bird.*ended|no longer offered/i;
is free_units($s1), $cap, 'every hold released';
# one session filled meanwhile
like process_hold()->{errors}[0], qr/no longer has room/;
```

- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/hold-session-seats.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `Holding a cart's seats re-checks each price and writes one owed charge with its lines`.

### Task 18: One charge for the cart (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/SessionCartPayment.pm` (`:isa(OneTimePayment)`), `templates/session-checkout/payment.html.ep`. Modify: `lib/Registry/DAO/Payment.pm` (`saves_card`, used by `_intent_params`).
- Test: `t/dao/session-cart-payment.t`; rewrite `t/dao/enrollment-checkout-closed-in-production.t` as `t/dao/session-checkout-closed-in-production.t`.

**Interfaces:**
- Consumes: `owed_payment` (Task 17); `Registry::DAO::WorkflowSteps::Payment->camp_checkout_refusal` (still present until Task 44 moves it here).
- Produces:
  - `$step->owed_payment($db, $run)` override. It validates every line (UUIDs, plan on its version, published, `share_cents` whole and above 0, `Σ share_cents == amount_cents`). It creates the payment with `offer_version_id => undef` and `metadata.lines` (call 10). It is refused in production by `camp_checkout_refusal`.
  - `_matches` compares the lines as well.
  - `hold_for_charge` checks every line's hold.
  - `$payment->saves_card -> bool`: true when any line is instalments. `_intent_params` then sends `setup_future_usage => 'off_session'` and the customer.

- [ ] **Step 1: Write the failing test.** Assert:
  - The payment row's amount is 39000, `offer_version_id` is NULL, and it carries two lines.
  - A tampered `owed_payment.lines[0].share_cents` is refused with no row written.
  - The intent params for a cart with an instalment line carry `setup_future_usage` and a customer; one-time only carries neither.
  - Production mode is refused with "Online payment for this program is not open yet. Nothing has been charged."
  - With no `STRIPE_SECRET_KEY`, the charge is refused with nothing written.
  - Intent params are built with no Stripe call (as `t/dao/payment-intent-*` do).
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/session-cart-payment.t t/dao/session-checkout-closed-in-production.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, then `carton exec prove -l t/dao/payment*.t t/stripe-live/one-time-offer-payment.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `A session cart is one charge; it saves the card when a child pays in instalments`.

### Task 19: Complete the checkout (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/CompleteSessionCheckout.pm`, `templates/session-checkout/{complete,done}.html.ep`
- Test: `t/dao/complete-session-checkout.t`; rewrite `t/dao/enrollment-confirmation-email.t` as `t/dao/session-checkout-confirmation.t`.

**Interfaces:**
- Consumes: `Hold->convert` with `holder_family_member_id`, `payer_user_id`, `payment_id`, `payment_share_cents => line.share_cents`, `terms_version`, and `ends_at` from `occurrence_window` when the expiry policy is `end_of_occurrence`. Also job `instalment_schedule` (Task 15).
- Produces:
  - It converts each line's hold once, under the run's lock (re-entry safe, as `CompleteBooking`). For each instalment line it enqueues `instalment_schedule(entitlement_id, slug)` after commit.
  - A line whose hold lapsed is re-held if room remains. Otherwise only that line is refunded its `share_cents` (key `refund:session-line:<run>:<family_member_id>:<resource_id>`): no entitlement, no schedule. The payer and admins are told.
  - An `enrollment_confirmation` email to the payer lists each child, session, dates in the location's zone, the price, the plan with due dates, and policy words.
  - `nothing_to_ask` mirrors `CompleteBooking`.

- [ ] **Step 1: Write the failing test.** Drive with a completed payment (stored `payment_intent.succeeded`) through `ContinueWorkflowRun`:
  - Two entitlements, held by each child, payer the parent, shares 30000 and 9000, `terms_version` set.
  - One `instalment_schedule` job, for the instalment child.
  - A second drive changes nothing (Review Focus 1).
  - With child 2's hold lapsed and the session full: child 1 is booked, a refund of 9000 is requested for that line only, no job is queued for child 2, and both notifications exist (Review Focus 1).
  - The confirmation email names both children and the three due dates.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/complete-session-checkout.t t/dao/session-checkout-confirmation.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, then `carton exec prove -l t/job/continue-workflow-run*.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `Checkout makes each child's entitlement, paid by the parent, and schedules its instalments`.

### Task 20: The storefront lists sessions (TIER_1)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/ProgramListing.pm`, `templates/tenant-storefront/program-listing.html.ep`, `templates/registry-storefront/landing.html.ep` (sign-up call to action, no listing)
- Test: rewrite `t/controller/tenant-storefront.t`, `t/dao/storefront-advertises-a-price-you-can-get.t`, `t/dao/storefront-capacity-is-the-session.t`, `t/dao/storefront-publish-filter.t`, `t/dao/tenant-storefront-provision.t`, `t/controller/tenant-pricing-display.t`, `t/controller/unsellable-session-is-not-the-parents-problem.t`, `t/user-journeys/nancy/01-program-discovery.t`

**Interfaces:**
- Produces: `prepare_template_data` returns programs, each with sessions on sale that at least one current version buys. Each session has `{ resource_id, name, first_day, last_day, weekdays, start, location, free, waitlist, from_cents, conditions_words, checkout_url => '/session-checkout' }`. `from_cents` is the cheapest current version with no conditions. Filters keep `location`, `program_type`, `date_from` and `date_to`.

- [ ] **Step 1: Rewrite the tests.** A session with no published version is not listed. "From $300" is shown even though an early-bird $250 exists. "Sibling and early-bird prices available" is shown. Free seats are the resource's. A session whose first day started is not listed. The registry landing has no session list and links to `/tenant-signup`.
- [ ] **Step 2: Run them**: `carton exec prove -l t/controller/tenant-storefront.t t/dao/storefront-*.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `The storefront lists sessions on sale with the price anyone can get`.

---

## PR 4 — Step 8.4: Missed payments

### Task 21: Stripe's final failed retry applies the missed_payment policy (TIER_2)

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm` (`_process_instalment_invoice`), `lib/Registry/DAO/Entitlement.pm`, `docs/operations/sacp-stripe-connect-onboarding.md`
- Test: `t/controller/missed-payment-policy.t`

**Interfaces:**
- Consumes: Task 5's methods; `Payment->fail_instalment`.
- Produces: `Entitlement->apply_missed_payment($db, $row_id, $invoice) -> 'kept'|'ended'|'grace'|undef`. It is called when an `invoice.payment_failed` has `next_payment_attempt` null and its row has an `entitlement_id`. It is locked on the entitlement and idempotent per invoice.
  - `keep_and_owe`: `mark_past_due`, alert admins, and email the payer `invoice.hosted_invoice_url`.
  - `end`: `end('unpaid', invoice id)` and enqueue `cancel_instalment_schedule(entitlement_id, slug)` (Task 15).
  - `grace`: `mark_past_due`, then the same alert and pay link, with "If it is not paid by %s, %s's place ends."
  - An entitlement already ended or already past due on this invoice: nothing.
- Runbook: a section "Stripe retry settings for instalments". After all retries fail, set the subscription to "leave the subscription past-due" and the invoice to "leave the invoice as-is", under Settings → Billing → Subscriptions and emails → Manage failed payments, on the studio's account. Explain why: Registry applies `missed_payment` and needs the invoice payable.

- [ ] **Step 1: Write the failing test.** For each kind, post stored Connect events:
  - A non-final failure (`next_payment_attempt` set) changes no entitlement.
  - A final failure applies the kind.
  - A second delivery of the final failure sends no second email (count notifications).
  - `invoice.paid` before a late final failure means the failure applies nothing (Review Focus 2).
  - `end` frees the seat (`free_units` +1) and queues the cancel job.
  - The payer's email contains the hosted invoice URL.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/missed-payment-policy.t`. Expected: FAIL.
- [ ] **Step 3: Implement**, keeping the controller's SQL count unchanged (logic in the DAO).
- [ ] **Step 4: Run it, then `carton exec prove -l t/controller/instalment-*.t t/unit/no-sql-outside-dao.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `A missed instalment follows the version's missed_payment policy once Stripe stops retrying`.

### Task 22: Paying restores; grace runs out (TIER_2)

**Files:**
- Create: `lib/Registry/Job/MissedPaymentGrace.pm`. Modify: `Webhooks.pm` (paid branch), `lib/Registry/Job/Recurring.pm` (`missed_payment_grace => { delay => 3600, priority => 5 }`), `lib/Registry.pm` (register).
- Test: `t/job/missed-payment-grace.t`

**Interfaces:**
- Produces:
  - On `invoice.paid` for a row whose entitlement is past due on that invoice: `clear_past_due`.
  - `Entitlement->end_lapsed_grace($db) -> [ids]`: active, past due, stamped `grace`, and `past_due_since + days` has passed. Each one is ended `unpaid` with a cancel job queued.
  - The `missed_payment_grace` task sweeps every tenant with a Stripe account, as `InstalmentReconcile` does.

- [ ] **Step 1: Write the failing test.** Grace 7 days: paid on day 6 restores (not past due, still active). Unpaid on day 8 ends `unpaid` and frees the seat. `keep_and_owe` is never ended by the sweep. The job queues its next run (`t/job/recurring-jobs-recur.t` lists it).
- [ ] **Step 2: Run it**: `carton exec prove -l t/job/missed-payment-grace.t t/job/recurring-jobs-recur.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `Paying a missed instalment restores the place; under grace an unpaid one ends`.

### Task 23: A schedule Stripe cancels is reported, not acted on (TIER_2)

**Files:**
- Modify: `lib/Registry/Controller/Webhooks.pm` (handle `subscription_schedule.canceled` and `customer.subscription.deleted` on the Connect endpoint), `lib/Registry/DAO/Payment.pm` (`entitlement_for_schedule`)
- Test: `t/controller/schedule-cancelled-at-stripe.t`

**Interfaces:**
- Produces: when a cancelled schedule (or its subscription) maps to an active entitlement with pending instalment rows, and the cancel was not Registry's (the entitlement is not in its checkout payment's `metadata.cancelled_schedules`, Task 15), the tenant's admins are alerted: "Stripe cancelled the instalments for %s in %s; %d payments of $%s are no longer scheduled. Nothing in Registry changed." No entitlement, row or seat changes.

- [ ] **Step 1: Write the failing test.** Cover: an unexpected cancel gives one alert and no state change; a cancel that Registry requested (Task 21's `end`) gives no alert; a redelivery gives no second alert.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/schedule-cancelled-at-stripe.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `An instalment schedule Stripe cancels alerts the studio and changes nothing`.

---

## PR 5 — Step 8.5: Drops and transfers

### Task 24: Refunds on what was paid so far (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/ApplyRefundPolicy.pm` (`remaining_cents` → `paid_cents`; `request` returns one request per payment), `lib/Registry/DAO/WorkflowSteps/ApplyStripeRefund.pm` (match `payments.entitlement_id` rows; end the chain head)
- Test: `t/dao/refund-paid-so-far.t`

**Interfaces:**
- Consumes: `Entitlement->paid_cents`, `chain` (Task 5).
- Produces:
  - `ApplyRefundPolicy->request($db, $e) -> [ { payment, amount_cents, idempotency_key => "refund:entitlement:<id>:<payment_id>" } ]`: the checkout share first, then completed instalment and change payments, newest last, each up to its unrefunded part.
  - `ApplyStripeRefund` records a refund of a row with `entitlement_id` against that entitlement. It ends the chain's current entitlement as `refunded` when the chain's refunds reach its `paid_cents`.

- [ ] **Step 1: Write the failing test.** An instalment entitlement with share 9000 and two paid rows of 9000 gives three requests summing 27000. Stored refund events for all three end it `refunded`; two of three do not. A transferred chain (old share 30000, new difference payment 2000) gives two requests across both payments, and the head ends when both are refunded.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/refund-paid-so-far.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/stripe-live/refund-policy-full-until-cutoff.t`** (live only with a key). Expected: PASS.
- [ ] **Step 5: Commit** `A refund covers everything paid for an entitlement so far, across its payments`.

### Task 25: Approval on refunds (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/DecideRefund.pm`, `lib/Registry/DAO/WorkflowSteps/AwaitApproval.pm`, templates. Modify: `workflows/entitlement-refund.yml` (`choose`, `decide`, `await-approval`, `apply`, `done`), `ApplyRefundPolicy.pm` (`process` uses the decided outcome; cancels an instalment schedule first). Create `sql/deploy/entitlement-refund-adds-approval.sql`, which clears the stored workflow.
- Test: `t/dao/refund-approval.t`

**Interfaces:**
- Consumes: `EntitlementRequest` (Task 9), `approval_for`, `request` (Task 24).
- Produces:
  - `DecideRefund` computes `refund_outcome => { amount_cents, requests => [...] }` or `refund_refused`. With approval required it opens a request (`kind => 'refund'`). With approval none it writes `refund_approved => 1`.
  - `AwaitApproval->process` stays while pending. When declined it writes `refund_declined => note` and moves to `done`. When approved it writes `refund_approved => 1`.
  - `ApplyRefundPolicy` refunds only with `refund_approved`. For an instalment entitlement it first calls `cancel_instalment_schedule` (Task 15), then refunds.

- [ ] **Step 1: Write the failing test.** Cover:
  - An in-studio version with no `approval` refunds at once, as today (existing `t/dao/entitlement-refund-policy.t` stays green).
  - Approval required parks at `await-approval` with one pending request whose outcome is 27000.
  - Declined: the run reaches `done` with the note, and nothing is refunded.
  - Approved: the schedule is cancelled (request recorded), then three refunds are requested.
  - A policy refusal (past cutoff) opens no request (contradiction F).
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/refund-approval.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/controller/`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `A refund that needs approval waits for an admin; an approved instalment drop stops the schedule first`.

### Task 26: The entitlement-decision workflow (TIER_2)

**Files:**
- Create: `workflows/entitlement-decision.yml` (`roles: [admin]`; steps `decide`, `done`), `lib/Registry/DAO/WorkflowSteps/DecideRequest.pm`, `templates/entitlement-decision/{decide,done}.html.ep`
- Test: `t/controller/entitlement-decision.t`

**Interfaces:**
- Consumes: `EntitlementRequest->decide`; Minion `continue_workflow_run` with `{ tenant, run_id }`.
- Produces:
  - Started with `?request_id=`. It shows the child, offer, outcome and policy words. On `approve` or `decline` with a note, `decide` runs. A true result enqueues `continue_workflow_run` for the parked run after commit and notifies the payer ("Your request for %s was approved" / "declined: %s").
  - A false result stays with "This request was already decided by %s".
  - A request whose entitlement has ended stays with "This booking has ended; nothing to decide".

- [ ] **Step 1: Write the failing test.** Cover:
  - Staff get 403.
  - An admin approves, the job is queued, and running the queued job drives the parent's run to `done` with refunds requested. This is the stuck-admin-decision fix: no `new_run`; the parked run continues.
  - Two admins decide concurrently: one wins, the other sees the sentence (Review Focus 3).
  - The payer is notified once.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/entitlement-decision.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/security/`.** Expected: PASS.
- [ ] **Step 5: Commit** `An admin decides a request, and the parked run continues on its own`.

### Task 27: Change targets (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/ChooseChangeDestination.pm`, template. Modify: `lib/Registry/DAO/Entitlement.pm` (`change_targets`), `HoldChangeTarget.pm` (reads `change_destination_id` from the run), `CompleteChange.pm` (cross-offer: end `transferred`, grant new, move pending instalment rows), `workflows/entitlement-change.yml` (`choose-target`, `choose-destination`, `hold-target`, `pay`, `complete-change`, `done`). Create `sql/deploy/entitlement-change-adds-destination.sql`.
- Test: `t/dao/change-targets.t`

**Interfaces:**
- Consumes: `choosable_for` (target version), Task 5's `transferred_from_entitlement_id`.
- Produces:
  - `$e->change_targets($db) -> [ { resource, version } ]`. `same_offer` is today's rule. `{offer_ids}` is the on-sale resources covered by those offers' current versions. `same_program` is the on-sale resources whose days or occurrence belong to the same project. The version is the cheapest choosable for the holder. Targets not offering the entitlement's plan kind (for instalments, also its count and cadence) are dropped. The resource held now is excluded.
  - `CompleteChange`: same offer moves in place (unchanged). Another offer ends the old as `transferred` (reason = new id) and grants the new with `transferred_from_entitlement_id`, the same holder, payer and terms version, no payment link, and the units from the hold. It then runs `UPDATE payments SET entitlement_id = new WHERE entitlement_id = old AND status = 'pending'`.

- [ ] **Step 1: Write the failing test.** For each target kind, list the expected resources. A target whose sibling version the holder now qualifies for uses that version's price. An instalment entitlement is not offered a target whose only plan is one-time. A cross-offer complete leaves the old one `transferred`, the new one holding the seat, and pending rows on the new one. A same-offer move keeps the id.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/change-targets.t t/dao/change-holds-target.t t/dao/change-charges-then-moves.t t/dao/in-studio-change-window.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `A change may move to listed offers or the same program; another offer is a transfer`.

### Task 28: Price difference on one-time entitlements (TIER_2)

**Files:**
- Create: `lib/Registry/DAO/WorkflowSteps/DecideChange.pm`, `lib/Registry/DAO/WorkflowSteps/PayChangeDifference.pm` (`:isa(OneTimePayment)`, replacing `PayChangeFee` in the YAML). Modify: `CompleteChange.pm` (refunds a negative difference after the move), `workflows/entitlement-change.yml` (`decide` after `choose-destination`).
- Test: `t/dao/change-price-difference.t`

**Interfaces:**
- Produces:
  - `DecideChange` writes `change_outcome => { difference_cents, fee_cents, charge_cents, refund_cents }`. `difference_cents` is the target version price minus `paid_cents`. `same_price_only` refuses a non-zero difference ("This booking can move only to the same price"). `charge_only` sets `refund_cents` to 0. `charge_and_refund` gives the refund.
  - `PayChangeDifference` charges `fee_cents + max(difference, 0)` as `purpose => 'change'`, with `payments.entitlement_id` set at completion. A zero charge passes through (as `PayChangeFee` does today).
  - `CompleteChange` requests the refund of `refund_cents` from the latest payments (key `refund:change:<run>`).

- [ ] **Step 1: Write the failing test.**
  - A $300 entitlement to a $330 target under `charge_and_refund` with a $10 fee charges 4000.
  - To a $270 target it charges the 1000 fee, then refunds 3000.
  - Under `charge_only` the refund is 0.
  - Under `same_price_only` it is refused.
  - In-studio same-offer changes behave as today.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/change-price-difference.t`. Expected: FAIL.
- [ ] **Step 3: Implement.** Delete `PayChangeFee.pm` and fold its test into this one (register).
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/ t/stripe-live/`** (live with a key). Expected: PASS.
- [ ] **Step 5: Commit** `Moving to a different price charges or refunds the difference, as the change policy says`.

### Task 29: Price difference on instalment entitlements (TIER_2)

**Files:**
- Modify: `DecideChange.pm`, `CompleteChange.pm`, `lib/Registry/DAO/Payment.pm` (`resettle_instalments($db, $entitlement, $difference)`)
- Test: `t/dao/change-instalment-difference.t`

**Interfaces:**
- Produces:
  - For an instalment entitlement, `change_outcome` has `charge_cents = fee_cents` only and `schedule_delta_cents = difference`.
  - `resettle_instalments` spreads the delta over the pending rows (remainder on the last) and updates the Stripe schedule's remaining phases with `proration_behavior => 'none'` (key `resettle:<run>`).
  - A negative delta beyond the pending total zeroes them and returns the excess to refund (`charge_and_refund`) or 0 (`charge_only`).
- Uses Task 15's `update_subscription_schedule_async`. The DAO test checks the params built, with no Stripe call. Task 49 calls it live.

- [ ] **Step 1: Write the failing test.** 3 × 9000 with one paid, moved to a $300 target (+3000), gives pending rows 10500 and 10500. Moved to a $180 target (−9000) gives pending 4500 and 4500. A −20000 delta gives pending 0 and 0 with 2000 refunded under `charge_and_refund`, 0 under `charge_only`. The schedule params carry `proration_behavior none`.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/change-instalment-difference.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `A transfer on instalments settles the difference against the payments still to come`.

### Task 30: Approval on changes (TIER_2)

**Files:**
- Modify: `workflows/entitlement-change.yml` (`await-approval` after `decide`), `DecideChange.pm` (opens a `change` request when approval is required), `AwaitApproval.pm` (handles `change`), `HoldChangeTarget.pm` (after approval, if the destination is full: stay with "That session has no room now; choose another").
- Test: `t/dao/change-approval.t`

**Interfaces:**
- Consumes: Tasks 9, 25 and 26.
- Produces: an approved change continues through `hold-target`. With a charge due it stops at `pay` (`needs_person`); the decision email links the run. With no charge it completes without a person.

- [ ] **Step 1: Write the failing test.** Approval none behaves as today. Approval required parks. A decline ends at `done`. An approved zero-charge instalment transfer completes through `ContinueWorkflowRun`. An approved one-time transfer with a charge stops at `pay`, and the payer's email links `/entitlement-change/<run>/pay`. A destination filled while pending stays at `hold-target`.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/change-approval.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `make test`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `A change that needs approval waits for an admin, then holds its seat`.

---

## PR 6 — Step 8.6: Waitlist

### Task 31: Join the queue; public holds yield to it (TIER_2)

**Files:**
- Modify: `SessionCart.pm` (a `join_waitlist` action per full line), `HoldSessionSeats.pm`, `lib/Registry/DAO/Resource.pm` (`free_for_public`)
- Test: `t/dao/waitlist-join.t`; rewrite `t/dao/waitlist-join-is-in-writing.t`

**Interfaces:**
- Produces:
  - `$resource->free_for_public($db) -> int`: `free_units`, or 0 while `waiting_count > 0`.
  - The cart and hold use it, except for the line of a run whose `waitlist_entry_id` names this resource.
  - Joining writes a `waitlist_entries` row and a `waitlist_joined` email with the position, then removes that line from the cart. A session with `waitlist.kind = 'none'` shows "Full".

- [ ] **Step 1: Write the failing test.** A full queue session offers the join, and joining records position 1 and sends one email. Then a seat frees (end an entitlement): a public cart still sees the session full and a hold is refused (Review Focus 4). A `none` session shows no join.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/waitlist-join.t t/dao/waitlist-join-is-in-writing.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `A full session's queue can be joined, and a freed seat goes to the queue first`.

### Task 32: Offers to the next child, and lapses (TIER_2)

**Files:**
- Create: `lib/Registry/Job/WaitlistOffers.pm`. Modify: `lib/Registry/Job/Recurring.pm` (`waitlist_offers => { delay => 300, priority => 6 }`), `lib/Registry.pm`, `lib/Registry/DAO/WaitlistEntry.pm` (`offer_next`, `lapse_expired`)
- Test: `t/job/waitlist-offers.t`; rewrite `t/dao/an-offered-seat-is-held.t`, `t/controller/waitlist-offer-window.t`, `t/job/waitlist-notifications-are-sent.t`, `t/dao/accepting-an-offer-goes-to-checkout.t`

**Interfaces:**
- Produces:
  - `WaitlistEntry->offer_next($db, $resource_id) -> entry | undef`. Under the resource lock, if `free_units > 0`, it takes the next waiting entry, creates a `session-checkout` run with data `{ user_id => payer, children => [child], cart_lines => [{ family_member_id, resource_id }], waitlist_entry_id }` at step `cart`, places a 1-seat hold for that run expiring at `now() + offer_hold_hours` with `lifetime` 15 minutes, and marks the entry offered. The email (`waitlist_offer`) carries the run URL and the local expiry.
  - `WaitlistEntry->lapse_expired($db) -> [ids]`: offered entries whose hold is no longer live and whose run made no entitlement for that line. Each lapses with a `waitlist_expiration` email.
  - `CompleteSessionCheckout` marks the entry `accepted`.
  - The job runs `lapse_expired`, then `offer_next` for each queue resource with free seats, per tenant.

- [ ] **Step 1: Write the failing test.** Cover:
  - A seat frees: one offer, the hold counted in `free_units`, and the run owned by the payer (another user opening it gets 404, Review Focus 4).
  - The hold lapses: the entry lapses, the next child gets an offer, and two emails exist.
  - An accepted checkout marks the entry accepted.
  - The version is the one current at offer time (publish a new version after joining: the cart lists the new one).
- [ ] **Step 2: Run it**: `carton exec prove -l t/job/waitlist-offers.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/job/ t/security/workflow-run-belongs-to-its-starter.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `When a seat frees, the next child's family gets a held seat and a checkout link`.

### Task 33: Accept, decline and status (TIER_2)

**Files:**
- Modify: `lib/Registry/Controller/Waitlist.pm`, `templates/waitlist/{offer,expired,parent_status}.html.ep`, `t/unit/no-sql-outside-dao.t` (Waitlist count to 0, entry removed)
- Test: rewrite `t/controller/waitlist-accept-decline.t`

**Interfaces:**
- Produces: `/waitlist/:id` shows the entry if the signed-in user is its payer (else 404). `accept` redirects to the offer's run `cart` step. `decline` releases the hold, marks `left` and sends the next offer at once via `offer_next`. `/waitlist/status` lists the payer's entries with position, session and local expiry.

- [ ] **Step 1: Rewrite the test.** Cover: owner only; decline frees the seat to the next child; status positions.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/waitlist-accept-decline.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/unit/no-sql-outside-dao.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `Families accept, decline and follow waitlist offers on the new queue`.

---

## PR 7 — Step 8.7: Attendance and make-ups

### Task 34: A make-up credit for each absence (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/Entitlement.pm` (`mark_day` grants or ends credits)
- Test: `t/dao/makeup-credit.t`

**Interfaces:**
- Consumes: `use` `makeup { offer_id, credit_days, max_per_term? }` (stamped).
- Produces:
  - On an `absent` mark under `makeup`, unless `max_per_term` credits already exist for this entitlement: a `create` of a $0 entitlement to `offer_id`'s current version, under its `one_time` plan. It is held by the child, paid for by the same payer, in effect `[now, now + credit_days)`, with no payment and no units. `entitlement_uses.credit_entitlement_id` is set and the payer is told.
  - No current version, or no one-time plan: no credit, and admins are alerted.
  - `absent` to `present` ends an unused credit (`expired`, "absence corrected"). It is refused when the credit holds units.
  - `$e->makeup_credits($db) -> [Entitlement]`.

- [ ] **Step 1: Write the failing test.** Cover: one absence makes one credit with the right period and holder; `max_per_term => 2` means the third absence makes none; correction ends the credit; correction after booking is refused; with no version, admins are alerted and nothing is created; `optional_attendance` makes no credit.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/makeup-credit.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `An absence the teacher marks earns a make-up credit, as the use policy says`.

### Task 35: Staff book make-ups (TIER_1)

**Files:**
- Create: `workflows/makeup-booking.yml` (`roles: [admin, staff]`; steps `credit`, `occurrence`, `done`), `lib/Registry/DAO/WorkflowSteps/ChooseMakeupCredit.pm`, `lib/Registry/DAO/WorkflowSteps/BookMakeup.pm`, templates. Modify: `Entitlement.pm` (`book_makeup`).
- Test: `t/controller/makeup-booking.t`

**Interfaces:**
- Produces: `$credit->book_makeup($db, $occurrence_resource_id, $by)`. Under the resource lock it takes `units_per_acceptance` units. It is refused unless the credit is in effect with no units, its stamped version buys the occurrence, the occurrence is on sale and starts before the credit ends, and there is room. Afterwards the period ends at the occurrence's end under `end_of_occurrence`.

- [ ] **Step 1: Write the failing test.** Staff search a child, see their credits and book an occurrence. A seat is taken (`free_units` −1), and the class appears on the in-studio day view. A second booking with the same credit is refused. An occurrence after the credit's end is not listed. A parent gets 403.
- [ ] **Step 2: Run it**: `carton exec prove -l t/controller/makeup-booking.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it**. Expected: PASS.
- [ ] **Step 5: Commit** `Staff book a child's make-up class with the credit it earned`.

### Task 36: The teacher attendance view on entitlements (TIER_1)

**Files:**
- Modify: `lib/Registry/Controller/TeacherDashboard.pm`, `templates/teacher_dashboard/*.html.ep`, and `lib/Registry/DAO/Event.pm` (`roster($db)`: children holding units of the event's session or occurrence resource, in effect, with their marks)
- Test: rewrite `t/controller/teacher-attendance.t`, `t/controller/teacher-attendance-reload.t`, `t/controller/teacher-dashboard.t`, `t/robustness/teacher-completeness.t`, `t/user-journeys/amara/01-attendance.t`, `t/playwright/amara-attendance.spec.js`, `t/playwright/setup_teacher_test_data.pl`

**Interfaces:**
- Produces: `GET /teacher/attendance/:event_id` lists the roster for the event's teacher. `POST` takes `marks[<entitlement_id>] = present|absent` and calls `mark_day` for each. Only the event's teacher or an admin may post.

- [ ] **Step 1: Rewrite the tests.** The roster is session holders. Marking absent creates a credit (Task 34). A reload shows the marks. Another teacher gets 403.
- [ ] **Step 2: Run them**: `carton exec prove -l t/controller/teacher-*.t t/robustness/teacher-completeness.t t/user-journeys/amara/`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `Teachers take attendance from entitlements, present or absent per day`.

### Task 37: The attendance-check job on entitlements (TIER_1)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/AttendanceCheck/{MissingAttendanceProcessor,UpcomingEventProcessor}.pm`
- Test: rewrite `t/job/attendance-check.t`, `t/dao/attendance-check-platform-tenant.t`, `t/integration/attendance-notifications.t`

**Interfaces:**
- Produces: "missing attendance" means an event that has ended with a roster (Task 36) where some holder has no mark. Upcoming reminders go to the event's teacher. `attendance_records` is read nowhere.

- [ ] **Step 1: Rewrite the tests**, using session and occurrence entitlements.
- [ ] **Step 2: Run them**: `carton exec prove -l t/job/attendance-check.t t/integration/attendance-notifications.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `The attendance check reads entitlements and day marks`.

---

## PR 8 — Step 8.8: Screens

### Task 38: The parent dashboard (TIER_2)

**Files:**
- Modify: `lib/Registry/Controller/ParentDashboard.pm`, `templates/parent_dashboard/index.html.ep`, `lib/Registry/DAO/Family.pm` (`dashboard($db, $payer_id)`), and the routes in `lib/Registry.pm` (`drop_enrollment` and `request_transfer` replaced by links that start `entitlement-refund` and `entitlement-change`; `/api/sessions/available` removed)
- Test: rewrite `t/dao/parent-dashboard.t`, `t/dao/parent-dashboard-enrollment-details.t`, `t/dao/parent-sees-attendance.t`, `t/controller/parent-dashboard-destinations.t`, `t/controller/dashboard-timestamp-rendering.t`, `t/security/child-ownership.t`, `t/playwright/parent-dashboard.spec.js`

**Interfaces:**
- Produces: `Family->dashboard($db, $payer_id) -> { children => [ { name, bookings => [ { entitlement_id, offer, session, first_day, last_day, state, past_due => { invoice_url? }, plan => { paid_cents, owed => [ { due_date, amount_cents, status } ] }, marks => { date => mark }, makeup_credits => n, pending_request => kind? } ], waitlist => [ { session, position, offer_expires_at? } ] } ] }`. It covers only entitlements whose payer is the parent, and times are local to each location.

- [ ] **Step 1: Rewrite the tests.** Two children, one on instalments and past due with the pay link shown, one with an absence. Waitlist position shown. Drop and Transfer buttons lead to the entitlement workflows. Another parent's child never appears (security).
- [ ] **Step 2: Run them**: `carton exec prove -l t/dao/parent-*.t t/controller/parent-dashboard-destinations.t t/security/child-ownership.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `The parent dashboard reads each child's entitlements, payments, marks and waitlist`.

### Task 39: The admin dashboard (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/AdminDashboard.pm`, `lib/Registry/Controller/AdminDashboard.pm`, `lib/Registry/DAO/WorkflowSteps/AdminDashboardOverview.pm`, `templates/admin-dashboard/*.html.ep` (`pending_drop_requests` and `pending_transfer_requests` replaced by `pending_requests`), routes in `lib/Registry.pm`
- Test: rewrite the admin-dashboard tests in the register

**Interfaces:**
- Produces:
  - `AdminDashboard->program_overview($db)`: per program and session, capacity, held, waiting and revenue cents (completed payments' shares and instalment rows, less refunds), with dates in the location's zone (call 17).
  - `waitlist($db)`
  - `pending_requests($db)` from `EntitlementRequest->pending`, linking `/entitlement-decision?request_id=`
  - `outstanding_instalments($db)` (rows with `entitlement_id`, past due first)
  - `GET /admin/dashboard/pending_requests` replaces the two old routes.

- [ ] **Step 1: Rewrite the tests.** Counts match entitlements. Revenue equals the sum of the fixtures' paid cents less a refund. A pending refund appears with an Approve link. Past-due instalments sort first. Export CSV columns: child, session, offer, state, paid_cents.
- [ ] **Step 2: Run them**: `carton exec prove -l t/dao/admin-dashboard.t t/controller/admin-dashboard-*.t t/robustness/admin-data-accuracy.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them**. Expected: PASS.
- [ ] **Step 5: Commit** `The admin dashboard counts entitlements, sums payments and queues requests`.

### Task 40: Message recipients (TIER_2)

**Files:**
- Modify: `lib/Registry/DAO/Message.pm` (recipient resolution), `lib/Registry/Controller/Messages.pm` (allowlist count only goes down), `templates/messages/compose.html.ep`
- Test: rewrite `t/dao/every-message-says-who-it-is-from.t`; add `t/dao/message-recipients-entitlements.t`

**Interfaces:**
- Produces: `Message->recipients_for($db, { scope => 'program'|'session'|'tenant', id })`: the distinct payers of active entitlements holding units of the program's sessions or occurrences, or of that session. Past due counts; ended does not.

- [ ] **Step 1: Write the failing test.** Cover: payers of two children are listed once; an ended entitlement's payer is not; another program's payers are not.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/message-recipients-entitlements.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/dao/every-message-says-who-it-is-from.t t/unit/no-sql-outside-dao.t`.** Expected: PASS.
- [ ] **Step 5: Commit** `Messages reach the payers of a program's or session's entitlements`.

### Task 41: Notification and email templates (TIER_1)

**Files:**
- Modify: `lib/Registry/Email/Template.pm`, `lib/Registry/DAO/Notification.pm`, `lib/Registry/Job/SendNotifications.pm` (no enrollment reads)
- Test: rewrite `t/unit/email-templates.t`

**Interfaces:**
- Produces: template variables come from entitlements (child, session, dates, offer, amount), with no `enrollment` keys. Variables `session_name`, `child_name`, `first_day`, `last_day`, `amount`, `pay_link` and `run_url` are used by Tasks 19, 21, 32 and 34.

- [ ] **Step 1: Rewrite the test.** Each template renders from the new variables, and a template naming `enrollment` fails.
- [ ] **Step 2: Run it**: `carton exec prove -l t/unit/email-templates.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run it, then `carton exec prove -l t/job/`.** Expected: PASS.
- [ ] **Step 5: Commit** `Emails speak of children, sessions and entitlements`.

### Task 42: Program setup and session admin routes (TIER_1)

**Files:**
- Modify: `lib/Registry/DAO/WorkflowSteps/ProgramSetupOverview.pm`, `templates/program-setup/overview.html.ep`, `templates/admin-dashboard/edit_session.html.ep`, `AdminDashboard` controller (`edit_session`, `update_session` and `set_session_status` act on session resources), `lib/Registry/DAO/Resource.pm` (`update_session_settings($db, { capacity, waitlist })`: capacity never below held units; `set_session_published($db, $bool)` flips its days' status)
- Test: rewrite `t/controller/program-setup.t`, `t/controller/session-edit-screen.t`, `t/dao/session-can-be-edited.t`, `t/controller/session-publish-connect-gate.t`, `t/controller/admin-publish.t`, `t/controller/admin-publish-ui.t`

**Interfaces:**
- Produces: the checklist links `session-setup` instead of `session-creation` and `pricing-plan-creation`. Routes keep their paths with `:id` being a resource id.

- [ ] **Step 1: Rewrite the tests.** Cover: capacity below held refused with a sentence; waitlist edited; unpublish hides the session from the storefront; the connect gate (no Stripe account means publish refused) still holds.
- [ ] **Step 2: Run them**: `carton exec prove -l t/controller/program-setup.t t/controller/session-*.t t/controller/admin-publish*.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, then `make test`.** Expected: PASS.
- [ ] **Step 5: Commit** `Program setup and the session screens act on session resources`.

---

## PR 9 — Step 8.9: Retire the old path

Before each task, `grep -rn` each name the task deletes across `lib templates workflows t sql/seed`. Any hit outside the deleted set is a reader Tasks 14 to 42 missed: rewire it in this task before deleting.

### Task 43: Retire the old workflows (TIER_2)

**Files:**
- Delete: `workflows/{summer-camp-registration.yaml,pricing-plan-creation.yaml,session-creation.yml,parent-drop-request.yml,parent-transfer-request.yml,admin-drop-approval.yml,admin-transfer-approval.yml,drop-request-processing.yml,transfer-request-processing.yml}`
- Create: `sql/deploy/retire-old-workflows.sql`. It deletes those workflows, their steps and runs in every schema, and publishes Solo v4 without their run rights (moving v3 holders as Task 1 does).
- Modify: `lib/Registry/WorkflowDivergence.pm` if it names any of them.
- Test: `t/database/retire-old-workflows.t`. Delete the tests in the register marked 43.

**Interfaces:** Produces: no workflow row with those slugs in any schema; Solo v4 is current.

- [ ] **Step 1: Write the failing test.** After deploy there are no rows in registry or a tenant schema; Solo v4 lists no retired slug; a v3 holder holds v4; `revert` restores v3 as current.
- [ ] **Step 2: Run it**: `carton exec prove -l t/database/retire-old-workflows.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration; delete the YAML and the register's 43 tests.**
- [ ] **Step 4: Run `make test`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Retire the old camp, pricing-plan, session and drop/transfer workflows`.

### Task 44: Retire the old steps, controllers, routes, templates and jobs (TIER_2)

**Files:**
- Delete steps: `WorkflowSteps/{Payment,MultiChildSessionSelection,RegistrationComplete,PricingModel,PricingPlanBasics,PricingPlanSelection,ReviewActivatePlan,ResourceAllocation,RequirementsAndPatterns,RequirementsRules,CreateSession,SelectEnrollmentForDrop,SelectEnrollmentForTransfer,CollectDropReason,CollectTransferReason,ReviewDropRequest,ReviewTransferRequest,SubmitDropRequest,SubmitTransferRequest,ValidateDropRequest,ValidateTransferRequest,LoadDropRequest,LoadTransferRequest,AdminDropDecision,AdminTransferDecision,ProcessAdminDropDecision,ProcessAdminTransferDecision,ProcessDropRefund,ProcessEnrollmentDrop,ProcessEnrollmentTransfer,ProcessWaitlistAfterDrop,ProcessWaitlistsAfterTransfer,CompleteDropRequest,CompleteTransferRequest,NotifyDropProcessed,NotifyTransferProcessed,SelectTargetSession,ValidateTargetCapacity}.pm`. Keep any that `grep` shows a surviving workflow uses: `RequirementsAndPatterns`, `RequirementsRules` and `ResourceAllocation` are checked against `program-creation*.yml`.
- Delete jobs: `Job/ProcessWaitlist.pm`, `Job/WaitlistExpiration.pm` (and their `Recurring` entries and allowlist entry).
- Delete templates: `templates/{summer-camp-registration,parent-drop-request,parent-transfer-request,admin-drop-approval,admin-transfer-approval,session-creation*,pricing-plan-creation}`.
- Move `camp_checkout_refusal` into `SessionCartPayment.pm` (Task 48 deletes it).
- Test: delete the register's 44 tests. `t/security/workflow-route-authorization.t` and `t/playwright/all-workflows-visual.spec.js` list only surviving workflows.

- [ ] **Step 1: Run `carton exec prove -lr t/` on a branch with only the deletions** to list failures. Expected: only files marked 44 in the register.
- [ ] **Step 2: Delete those tests; rewrite the two listing tests.**
- [ ] **Step 3: Run `make test`.** Expected: PASS.
- [ ] **Step 4: Run `grep -rn "ProcessWaitlist\|WaitlistExpiration\|camp_checkout_refusal" lib t`.** Expected: only `SessionCartPayment.pm` and its test.
- [ ] **Step 5: Commit** `Retire the old checkout, drop, transfer and waitlist steps and jobs`.

### Task 45: Retire the old DAOs and Payment.pm's enrollment code (TIER_2)

**Files:**
- Delete: `lib/Registry/DAO/{Enrollment,PricingPlan,Session,SessionTeacher,Waitlist,DropRequest,TransferRequest,Attendance}.pm`, `lib/Registry/Utility/PriceFormat.pm` if unused.
- Modify `lib/Registry/DAO/Payment.pm`. Delete `_lock_cart_sessions`, `finalize_enrollment`, `record_capacity_obligation`, `capacity_refund_key`, `drop_refund_key`, `add_line_item`, `line_items`, `calculate_enrollment_total` and `_schedule_options`. Delete `_share_or_flag` and `refund_share_for` only if `grep` finds no surviving caller. Keep the refund-increment machinery the platform runbook reads (`Tenant->unpaid_obligations`).
- Modify: `lib/Registry/DAO.pm` (exports), `lib/Registry/DAO/Event.pm` and `lib/Registry/DAO/User.pm`, `FamilyMember.pm`, `Location.pm`, `Project.pm` and `Tenant.pm` (methods reading the old tables), `t/lib/Test/Registry/Fixtures.pm` (delete `create_session`, `create_pricing`, `create_enrollment`; point callers at `Test::Registry::Sessions`).
- Test: delete the register's 45 tests and rewrite its 45-rewrite tests.

- [ ] **Step 1: Delete the files and methods; run `carton exec prove -lr t/`.** Expected: failures only in the register's 45 files.
- [ ] **Step 2: Delete or rewrite those as the register says.**
- [ ] **Step 3: Run `make test`.** Expected: PASS.
- [ ] **Step 4: Run `grep -rn "Enrollment\b\|PricingPlan\|DAO::Session\b\|DAO::Waitlist\b\|DropRequest\|TransferRequest\|DAO::Attendance" lib t`.** Expected: no hits.
- [ ] **Step 5: Commit** `Retire the enrollment, pricing-plan, session, waitlist, drop, transfer and attendance DAOs`.

### Task 46: Drop the old tables (TIER_2)

**Files:**
- Create: `sql/deploy/drop-old-after-school-tables.sql` (+revert recreating the shapes empty, +verify). In registry and every schema it drops `drop_requests`, `transfer_requests`, `waitlist`, `attendance_records`, `payment_items`, `enrollments`, `session_events`, `session_teachers`, `sessions` and `pricing_plans`, with their triggers and the `get_next_waitlist_position` function.
- Modify: `sql/test-schema.sql`, `t/database/revert-round-trip.t`, `t/database/schema-dump-current.t`
- Test: `t/database/old-tables-dropped.t`. Delete the register's 46 tests (past migrations whose subject table is gone).

- [ ] **Step 1: Write the failing test.** No `to_regclass` hit for any of the ten tables in registry or a tenant schema, and revert recreates them empty.
- [ ] **Step 2: Run it**: `carton exec prove -l t/database/old-tables-dropped.t`. Expected: FAIL.
- [ ] **Step 3: Write the migration; `make test-schema`.**
- [ ] **Step 4: Run `make test`.** Expected: PASS.
- [ ] **Step 5: Commit** `Drop the old after-school tables from every schema`.

### Task 47: The seeds (TIER_2)

**Files:**
- Modify: `sql/seed/sacp-tenant.sql` (drop both projects and the `enrollment_rules`/`default_price` keys), `sql/seed/README.md`
- Create: `sql/deploy/retire-registry-storefront-session.sql`, which deletes registry's `tiny-art-empire` project and its `registration` event. Its `sessions` row is already gone with Task 46's table drop.
- Test: rewrite `t/priceops/day-one.t`'s seed assertions; `t/dao/sacp-seed.t`

**Interfaces:** Produces: the SACP seed runs after signup and writes program types, locations and no projects. Registry has no storefront project.

- [ ] **Step 1: Write the failing test.** The seed runs twice cleanly; `sacp.projects` is 0; no program type config has `enrollment_rules`; registry has no `tiny-art-empire`.
- [ ] **Step 2: Run it**: `carton exec prove -l t/dao/sacp-seed.t t/priceops/day-one.t`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them, then `make test`.** Expected: PASS.
- [ ] **Step 5: `make test-schema`; commit** `Seeds: SACP starts with no old-model programs; registry's storefront session goes`.

---

## PR 10 — Step 8.10: Acceptance

### Task 48: The after-school and camp acceptance test, and camp checkout opens (TIER_2)

**Files:**
- Create: `t/priceops/after-school-and-camp.t`
- Modify: `SessionCartPayment.pm` (delete `camp_checkout_refusal`), `t/dao/session-checkout-closed-in-production.t` → `t/dao/session-checkout-open-in-production.t`

**Interfaces:** Consumes everything above, through real workflows and stored Stripe events only (no Stripe call), as `t/priceops/day-one.t` does.

- [ ] **Step 1: Write the failing test.** Its subtests, in order:
  1. `sacp signs up holding solo v4 and runs the seed`
  2. `victoria sets up camp and after-school in session-setup`: two camp weeks (queue, 48 h) and one after-school term. Regular, sibling and early-bird versions. Monthly ×3 instalments with `grace` 7 days, refund `full_until_cutoff` with approval required, change `same_program` `charge_and_refund` with approval, use `makeup` to an in-studio class offer.
  3. `a parent buys two children in one checkout`: child 1 early-bird one-time, child 2 sibling on instalments. One charge of first parts; two child-held entitlements, shares, terms version; one schedule job.
  4. `the schedule rows and invoices settle` (stored `invoice.paid`)
  5. `a final failed retry puts child 2 past due, paying restores it`
  6. `a third child joins the full week, gets a held seat when child 1 drops after approval`: approval, refund of paid so far, waitlist offer run owned by the parent
  7. `a transfer to the other week settles the difference on the remaining instalments after approval`
  8. `the teacher marks an absence and staff book the make-up`
  9. `the parent and admin dashboards show it all, the storefront lists what is on sale`
  10. `camp checkout is open in production mode`
  11. `another tenant sees none of it`
- [ ] **Step 2: Run it**: `carton exec prove -l t/priceops/after-school-and-camp.t`. Expected: FAIL at subtest 10 (still refused).
- [ ] **Step 3: Delete `camp_checkout_refusal` and its call.**
- [ ] **Step 4: Run it, then `make test`.** Expected: PASS.
- [ ] **Step 5: Commit** `Acceptance: camp and after-school end to end on PriceOps; camp checkout opens`.

### Task 49: A live instalment checkout on a connected account (TIER_2)

**Files:**
- Create: `t/stripe-live/session-instalment-checkout.t`. Delete `t/stripe-live/paid-enrollment.t` (register).

**Interfaces:** Consumes `Test::Registry::StripeConnect::ready_account`, `Test::Registry::StripeConfirm`, and the real `session-checkout` workflow.

- [ ] **Step 1: Write the test.** `plan skip_all` without `sk_test_` (the gate every live file uses). On a ready connected account, check out two children (one one-time, one weekly ×3):
  - One PaymentIntent on the account with `setup_future_usage off_session` and an application fee of 2.5% of the charge.
  - Confirm with a test card and drive completion.
  - One subscription schedule on the account with `metadata.entitlement_id`, 2 remaining phases' iterations, `interval week`, `application_fee_percent 2.5` and `end_behavior cancel`.
  - Update it as Task 29 would, with `proration_behavior none`, and Stripe accepts it.
  - Cleanup cancels schedules and deletes customers in `END`, as `t/stripe-live/instalment-schedule.t` does.
- [ ] **Step 2: Run it**: `STRIPE_SECRET_KEY=sk_test_… carton exec prove -l t/stripe-live/session-instalment-checkout.t`. Expected: PASS (it exercises code already merged); without a key it skips.
- [ ] **Step 3: Run `carton exec prove -lr t/stripe-live/` with the key.** Expected: PASS.
- [ ] **Step 4: Commit** `Live: a session checkout with instalments builds its schedule on the studio's account`.

---

## Test Retirement Register

The owning task deletes (D) or rewrites (R) each file. A file marked R whose subject turns out to be retired is deleted instead, and the commit says why. Nothing is skipped.

**Task 14:** R `t/dao/generated-session-dates.t`, `t/dao/solo-tenant-event-generation.t`. D `t/dao/generate-events-pricing.t`.

**Task 15:** R `t/dao/instalment-schedule.t`, `t/dao/instalment-stripe-phases.t`, `t/controller/instalment-invoice-webhooks.t`, `t/controller/instalment-reconcile-job.t`, `t/controller/instalment-schedule-job-retry.t`, `t/stripe-live/instalment-schedule.t`, `t/stripe-live/instalment-invoice-schedule.t`. D `t/dao/instalments-are-offered.t`, `t/dao/instalment-offer-at-checkout.t`.

**Task 16:** R (onto the cart) `t/security/session-selection-offered-set.t`, `t/security/cart-item-operator-injection.t`, `t/dao/enrollment-foreign-seat.t` → `t/security/cart-child-is-the-payers.t`, `t/dao/enrollment-reenrol-after-drop.t` → `t/dao/child-can-buy-again-after-ending.t`, `t/dao/select-children-workflow-step.t`, `t/security/workflow-run-data-server-owned-keys.t`.

**Task 17:** R `t/security/capacity-edge-cases.t`.

**Task 18:** R (onto `SessionCartPayment`) `t/dao/enrollment-checkout-closed-in-production.t`, `t/dao/payment-idempotency.t`, `t/dao/payment-callback-atomicity.t`, `t/dao/payment-refused-without-stripe-key.t`, `t/dao/payment-step-readiness-gate.t`, `t/controller/payment-page-without-stripe-key.t`, `t/controller/payment-return-callback.t`, `t/controller/payment-retry-render.t`, `t/controller/payment-element-stripe-account.t`, `t/controller/payment-failures.t`, `t/security/payment-id-operator-injection.t`.

**Task 19:** R `t/dao/enrollment-confirmation-email.t`, `t/controller/webhook-tenant-payment-finalization.t`, `t/controller/webhook-capacity-refund.t` (a late line refunded), `t/controller/connect-webhook-intent-ownership.t`, `t/integration/tenant-paid-enrollment.t`, `t/integration/stripe-webhook-integration.t`.

**Task 20:** R `t/controller/tenant-storefront.t`, `t/dao/storefront-advertises-a-price-you-can-get.t`, `t/dao/storefront-capacity-is-the-session.t`, `t/dao/storefront-publish-filter.t`, `t/dao/tenant-storefront-provision.t`, `t/controller/tenant-pricing-display.t`, `t/controller/unsellable-session-is-not-the-parents-problem.t`, `t/user-journeys/nancy/01-program-discovery.t`.

**Task 28:** fold the `PayChangeFee` tests into `t/dao/change-price-difference.t`.

**Task 31:** R `t/dao/waitlist-join-is-in-writing.t`.

**Task 32:** R `t/dao/an-offered-seat-is-held.t`, `t/controller/waitlist-offer-window.t`, `t/job/waitlist-notifications-are-sent.t`, `t/dao/accepting-an-offer-goes-to-checkout.t`, `t/playwright/waitlist-flow.spec.js`, `t/playwright/setup_waitlist_test_data.pl`.

**Task 33:** R `t/controller/waitlist-accept-decline.t`.

**Task 36:** R `t/controller/teacher-attendance.t`, `t/controller/teacher-attendance-reload.t`, `t/controller/teacher-dashboard.t`, `t/robustness/teacher-completeness.t`, `t/user-journeys/amara/01-attendance.t`, `t/playwright/amara-attendance.spec.js`, `t/playwright/setup_teacher_test_data.pl`, `t/controller/staff-offboarding.t` (history references move to `entitlement_uses.recorded_by`).

**Task 37:** R `t/job/attendance-check.t`, `t/dao/attendance-check-platform-tenant.t`, `t/integration/attendance-notifications.t`.

**Task 38:** R `t/dao/parent-dashboard.t`, `t/dao/parent-dashboard-enrollment-details.t`, `t/dao/parent-sees-attendance.t`, `t/controller/parent-dashboard-destinations.t`, `t/controller/dashboard-timestamp-rendering.t`, `t/security/child-ownership.t`, `t/playwright/parent-dashboard.spec.js`, `t/user-journeys/nancy/03-schedule-management.t`.

**Task 39:** R `t/dao/admin-dashboard.t`, `t/dao/admin-workflow-smoke.t`, `t/dao/program-overview-sessions.t`, `t/controller/admin-dashboard-actions.t`, `t/controller/admin-dashboard-endpoints.t`, `t/controller/admin-dashboard-export.t`, `t/controller/admin-dashboard-workflow-integration.t`, `t/controller/admin-dashboard-workflow.t`, `t/controller/outstanding-instalments-screen.t`, `t/robustness/admin-data-accuracy.t`, `t/user-journeys/jordan/01-admin-dashboard.t`, `t/playwright/admin-dashboard.spec.js`, `t/playwright/jordan-admin-dashboard.spec.js`, `t/playwright/jordan.spec.js`, `t/playwright/setup_admin_test_data.pl`, `t/playwright/setup_jordan_landing_data.pl`.

**Task 40:** R `t/dao/every-message-says-who-it-is-from.t`.

**Task 41:** R `t/unit/email-templates.t`.

**Task 42:** R `t/controller/program-setup.t`, `t/controller/session-edit-screen.t`, `t/dao/session-can-be-edited.t`, `t/controller/session-publish-connect-gate.t`, `t/controller/admin-publish.t`, `t/controller/admin-publish-ui.t`, `t/e2e/admin-program-management.t`.

**Task 43:** D `t/controller/admin-drop-approval.t`, `t/controller/drop-request.t`, `t/controller/transfer-request.t`, `t/integration/drop-transfer-workflows.t`, `t/dao/admin-decision-workflow-step.t`, `t/controller/camp-registration-errors.t`, `t/controller/camp-registration-new-parent.t`, `t/controller/camp-registration-resume.t`, `t/controller/camp-registration-returning-parent.t`, `t/controller/enrollment-account-check.t`, `t/controller/session-selection-shows-its-rules.t`, `t/dao/pricing-plan-workflow.t`, `t/dao/pricing-plan-form-offers-only-what-it-uses.t`, `t/dao/pricing-model-offers-only-storable-types.t`, `t/security/staff-cannot-set-prices.t` → R onto `session-setup` publish. R `t/playwright/drop-transfer.spec.js` and `t/playwright/setup_drop_test_data.pl` onto the approval flow. R `t/playwright/camp-registration.spec.js` and `t/playwright/setup_registration_test_data.pl` and `t/playwright/setup_registration_test_data.t` onto `session-checkout`.

**Task 44:** D `t/dao/payment-workflow-step.t`, `t/dao/payment-step-async.t`, `t/dao/payment-free-by-total.t`, `t/dao/payment-capacity-obligation.t`, `t/dao/payment-finalization-idempotency.t`, `t/dao/payment-line-item-description.t`, `t/dao/multi-child-session-selection-workflow-step.t`, `t/dao/registration-complete-details.t`, `t/dao/pricing-plan-selection-workflow-step.t`, `t/priceops/tier-options.t`, `t/dao/tenant-signup-pricing-integration.t`, `t/job/process-waitlist-tenant.t`, `t/job/waitlist-expiration-tenant.t`, `t/dao/demoted-child-joins-the-waitlist.t`, `t/dao/waitlist-join-at-settlement.t`, `t/dao/waitlist-live-enrollment-check.t`. R `t/security/workflow-route-authorization.t`, `t/playwright/all-workflows-visual.spec.js`, `t/job/recurring-jobs-recur.t`, `t/job/recurring-sweeps-cover-platform.t`, `t/controller/workflow-engine-fixes.t`, `t/dao/workflow-stay-behavior.t`, `t/e2e/workflow-no-body-swap.t`.

**Task 45:** D `t/dao/enrollment-alerts-use-session-capacity.t`, `t/dao/enrollment-capacity-at-capture.t`, `t/dao/enrollment-capacity-demotion.t`, `t/dao/enrollment-capacity-partial-fit.t`, `t/dao/enrollment-seat-vocabulary.t`, `t/dao/enrollment-total-picks-the-applicable-plan.t`, `t/dao/enrollment-transfer.t`, `t/dao/finalize-enrollment-email-isolation.t`, `t/dao/drop-request.t`, `t/dao/transfer-request.t`, `t/dao/drop-refund-is-a-request-not-a-refund.t`, `t/dao/drop-refund-moves-money.t`, `t/dao/waitlist.t`, `t/dao/waitlist-automation.t`, `t/dao/waitlist-position-debug.t`, `t/dao/waitlist-rapid-test.t`, `t/dao/waitlist-stress-test.t`, `t/dao/pricing-plans.t`, `t/dao/pricing-plan-amount-cents.t`, `t/dao/pricing-plan-clean-architecture.t`, `t/dao/pricing-plan-versions.t`, `t/dao/session-business-rules.t`, `t/dao/summer-camp-schema.t`, `t/dao/tenant-summer-camp.t`, `t/dao/attendance.t`, `t/dao/attendance-polymorphic-student.t`. R (drop old fixtures; the subject survives) `t/dao/payments.t`, `t/dao/payment-amount-cents.t`, `t/dao/payment-fee-snapshot.t`, `t/dao/payment-intent-customer-async.t`, `t/dao/payment-intent-destination-charge.t`, `t/dao/payment-refund-plumbing.t`, `t/dao/payment-refund-debt-lifecycle.t`, `t/dao/refund-application-fee.t`, `t/dao/json-columns-round-trip.t`, `t/dao/family.t`, `t/dao/program-types.t`, `t/dao/platform-runbook-queue.t`, `t/dao/platform-tenant-checkout.t`, `t/dao/priceops-identity-checks.t`, `t/dao/tenant-payment-schema-isolation.t`, `t/dao/tenant-provision.t`, `t/controller/connect-webhook-refund-updated.t`, `t/controller/payment-intent-webhook.t`, `t/controller/signup-lists-platform-offers.t`, `t/controller/stripe-connect-onboarding.t`, `t/security/cross-tenant-isolation.t`, `t/security/platform-admin-only.t`, `t/robustness/db-constraints.t`, `t/robustness/suite-stderr-is-clean.t`, `t/job/continue-workflow-run-retry.t`, `t/stripe-live/continue-workflow-run-retry.t`, `t/stripe-live/helpers.t`, `t/stripe-live/webhook-ignores-tenant-billing.t`, `t/e2e/full-onboarding-pipeline.t`, `t/e2e/parent-journey.t`, `t/e2e/tenant-onboarding.t`, `t/user-journeys/alex/02-activate-and-collect.t`, `t/user-journeys/alex/04-platform-health.t`, `t/user-journeys/nancy/02-enrollment.t`, `t/playwright/lifecycle.spec.js`, `t/playwright/morgan.spec.js`, `t/playwright/nancy.spec.js`, `t/playwright/payment-smoke.spec.js`, `t/playwright/setup_payment_test_data.pl`, `t/playwright/tenant-team.spec.js`, `t/lib/Test/Registry/Fixtures.pm`, `t/unit/no-sql-outside-dao.t`.

**Task 46:** D `t/database/pricing-plan-rate-check.t`, `t/database/remove-free-platform-plan.t`, `t/database/retire-launch-rate-marker.t`, `t/database/retire-registry-plus-plan.t`, `t/database/retire-unpublished-platform-plans.t`, `t/database/seed-tier-pricing-options.t`, `t/dao/platform-pricing-plans-seed.t`, `t/database/enrollment-reenrol-tenant.t`. R (no `pricing_plans` reads) `t/database/backfill-platform-entitlements.t`, `t/database/bootstrap-platform-offers.t`, `t/database/platform-tenant-unlinks-solo.t`, `t/database/revert-round-trip.t`, `t/database/schema-dump-current.t`.

**Task 47:** R `t/priceops/day-one.t` (seed assertions).

**Task 49:** D `t/stripe-live/paid-enrollment.t` (superseded).
