# Architecture review: the PriceOps layer

Date: 2026-08-06. Head: `7a76456`. Branch: `feature/money-path-e2e`.
Scope: `lib/Registry/PriceOps/` and everything the money flows through to reach it --
`Registry::DAO::Payment`, `Registry::DAO::Subscription`, `Registry::Controller::Webhooks`,
`Registry::DAO::PricingPlan`, and the workflow steps between them.

Question asked: is PriceOps fit for purpose?

## Verdict

No, not as a layer. As a namespace holding one file, yes.

`lib/Registry/PriceOps/` is 1,339 raw lines across six modules. 47 of its 882
non-blank, non-comment lines execute during a real HTTP request against production data,
and all 47 are in `RevenueShare.pm`. `ScheduledPayment.pm` is the one qualification:
it is genuinely HTTP-reachable, via `Webhooks.pm:69` -> `:234-236`, and
`t/controller/payment-failures.t` drives it over real HTTP today. But the classifier at
`Webhooks.pm:222` only routes to it when a `payment_schedules` row matches the
subscription, and no production writer creates one, so the branch is live in test and
dead in production. The other four modules contribute zero. Two of them
(`UnifiedPricingEngine.pm`, `PricingRelationships.pm`) have never been called from
production code in any commit in the repository's history, and both contain SQL that
would raise if it ran: `PricingRelationships.pm:241-248` and `:255-264` filter
`registry.payments` on a `tenant_id` column that the creating migration never defined
(`sql/deploy/payments.sql:7-20`) and no later migration added, and
`UnifiedPricingEngine.pm:101` inserts an `amount` column that
`sql/deploy/pricing-plans-amount-cents.sql:35` dropped. The remaining three
(`PaymentSchedule.pm`, `PricingPlan.pm`, `ScheduledPayment.pm`) are the installment
feature, which is complete, tested, and reachable only through a workflow step that
appears in none of the 67 step classes wired into `workflows/*.yml` -- a gap you have
already diagnosed yourself in issue #295.

The one live module is genuinely good. `RevenueShare.pm` is the only module in the
directory with a spec (`docs/specs/plan-driven-revenue-share.md`), the only one with an
HTTP-driven end-to-end assertion (`t/user-journeys/alex/02-activate-and-collect.t:452-457`
pins `application_fee_amount` at 300 cents through a real workflow POST), and the only
one whose failure modes are deliberate: `_coerce_pct` (`RevenueShare.pm:143-160`) refuses
to guess a rate rather than infer one from a price. It is also 82 code lines of exported
subs in a plain `package` with `Exporter` -- not an object, not a tier, and it does not
need to be either.

The honest reading of the layer, though, is that its problems are not in the layer.
Every defect worth acting on that this review found sits *outside* `lib/Registry/PriceOps/`,
on the live money path that PriceOps was supposed to own and does not: a webhook that can
permanently lose a paid enrollment (`Webhooks.pm:46-56, 85`), an enrollment total that
converts "no price configured" into "$0, enroll them free"
(`Payment.pm:517-518` -> `WorkflowSteps/Payment.pm:47-49`), and a tenant-subscription
lifecycle that can start a subscription and can never react to one
(`TenantPayment.pm:340-344` vs `Subscription.pm:118`). PriceOps was created in a day as a
reaction to review feedback and then populated twice with code no caller wanted; what it
never did was take ownership of the decisions that actually cost money. That is the fitness
answer: the abstraction is not wrong so much as absent from the places where it would have
paid for itself.

## What the layer was meant to be

There is no design document. `grep -rn "PriceOps" CONTRIBUTING.md CLAUDE.md docs/TECHNICAL.md
docs/ROADMAP.md docs/MISSION.md` returns nothing; `docs/decisions/` contains only
`001-security-middleware-architecture.md`; none of the four files in `docs/architecture/`
mentions it. The single written statement of intent is a bullet in a commit message,
7b043f6 (2025-09-23): "Maintain proper separation: SQL in DAO, Stripe API in Client,
business logic in PriceOps", followed by "This addresses the architectural feedback to
properly separate concerns as requested."

That commit landed roughly eighteen hours after the code it refactors (85c70b7, same day),
at the tail of a multi-week campaign moving SQL out of controllers into DAOs (cfebe2f,
771a9aa, 7068cbf, 79c503c, 3995641). Having pushed logic from controllers down into DAOs,
the next round of review said DAOs should be SQL-only, and a third tier appeared the same
day to hold what was left over. That is the entire design process for the first three
modules.

The name is older than the layer and originally meant something else. "PriceOps" enters
the repo on 2025-05-27 at `docs/MVP_SPECIFICATION.md:57` as "### 3. PriceOps-Style Pricing
System" -- a product feature list (multiple plans per session, early bird, sibling
discounts, installment options) with nothing to say about code layering. Four months later
the namespace borrowed the word.

The six modules arrived in three waves. Wave 1 (7b043f6, 2025-09-23) extracted
`PaymentSchedule`, `PricingPlan` and `ScheduledPayment` from the installment feature --
real behaviour, moved for a stated reason. Wave 2 (31b1f6d, 2025-09-29) added
`UnifiedPricingEngine` and `TenantRelationships` as, in its own words, "the foundation for
evolving Registry into a marketplace ecosystem where any tenant can offer services to other
tenants." The same message claims a "TDD approach with failing tests written first"; three
hours later c1096de commented out all four `use` lines in `t/dao/unified-pricing-engine.t`,
deleted 312 lines of it, and replaced seven subtests with `plan skip_all =>
"UnifiedPricingEngine module not yet implemented"` -- for a module that had existed for
three hours -- under the message "All tests now pass at 100% as required." Those skips and
the commented `use` are still in the file at lines 18-21 and 71-95. The same boundary was
redrawn five more times within 22 hours (357e658, 8524f83, 1f6c2d2, a510845). By 2025-10-03
issue #76 recorded these modules as "completely unimplemented" with "test stubs in place";
the tracker believed the code did not exist, because its tests had been disabled.

Wave 3 (0ec723f, 2026-06-16) added `RevenueShare` -- the only module written from a spec
and a plan. Its placement in `PriceOps/` was an explicitly deferred, low-confidence call:
`docs/specs/plan-driven-revenue-share.md:365-369` lists "Resolver home --
`UnifiedPricingEngine` vs a dedicated `Registry::PriceOps::RevenueShare`" under "Deferred to
implementation/planning (low-risk, no blocker)". The plan's stated reason for going
standalone -- "a heavy engine constructor would be awkward to call per-charge"
(`docs/superpowers/plans/2026-06-16-plan-driven-revenue-share.md:34`) -- does not survive
reading the constructor: `UnifiedPricingEngine.pm:16` has one field, `$db`, which the caller
already holds. The unstated reason is better: the engine had never been called and had seven
skipped tests, and wiring the live money path to it would have been reckless.

## What it actually is

| Module | Raw | Code | Production callers | Reachable from HTTP |
|---|---|---|---|---|
| `RevenueShare.pm` | 162 | 82 | `Payment.pm:91`, `Payment.pm:114`, `TenantPayment.pm:162` | 47 lines |
| `PaymentSchedule.pm` | 262 | 181 | `InstallmentPayment.pm:309` only | 0 |
| `PricingPlan.pm` | 187 | 120 | `InstallmentPayment.pm:78,95,178` only | 0 |
| `ScheduledPayment.pm` | 178 | 121 | `Webhooks.pm:236,239,242` | 0 (see below) |
| `PricingRelationships.pm` | 319 | 221 | none | 0 |
| `UnifiedPricingEngine.pm` | 231 | 157 | none | 0 |
| **Total** | **1339** | **882** | | **47 (5.3%)** |

Counts from `wc -l` and `grep -cvE '^\s*(#|$)'`. The 47 reachable lines are
`RevenueShare.pm:3-11` (preamble), `:24-46` (`revenue_share_fraction_for_tenant`),
`:55-72` (`platform_default_fraction`) and `:143-160` (`_coerce_pct`).

The live chain is: `Registry.pm:766` (`POST /:workflow/:run/:step`) ->
`Workflows.pm:330,378` -> `WorkflowSteps::Payment::process` (`:22`) -> `create_payment`
(`:101`) -> `Payment.pm:551` `create_payment_intent_async` -> `:192` `_intent_params` ->
`:200` `_connect_params` -> `:91` `RevenueShare::revenue_share_fraction_for_tenant`. The
second live entry is `workflows/tenant-signup.yml:26` -> `TenantPayment.pm:117-119,161-162`
-> `platform_default_fraction`, and only on the branch where no plan was selected.

Two entries in that table need qualifying.

`RevenueShare`'s other public resolver, `refund_application_fee_for_tenant`
(`RevenueShare.pm:87`, called from `Payment.pm:114`), is not reachable from any HTTP
request. Its only entry is `_refund_connect_params` (`Payment.pm:109`), called only from
`refund` (`:461`) and `refund_async` (`:582`), and neither has a caller anywhere in `lib/`
(`grep -rn -- "->refund(\|->refund_async(" lib/ registry script/` finds none). That is 35
of RevenueShare's 82 code lines. It is not abandoned: it is the operator-invoked refund
path, asserted against real Stripe at `t/stripe-live/paid-enrollment.t:379-391`, documented
as an operational contract at `docs/operations/sacp-stripe-connect-onboarding.md:196-205`,
and named as the foundation of open issue #286. Keep it.

`ScheduledPayment` is reachable in principle and unreachable in fact. The route exists
(`Registry.pm:644` -> `Webhooks.pm:69` -> `:229-242`) and `t/controller/payment-failures.t`
drives it over real HTTP (`:120-130` posts a signed body to `/webhooks/stripe`; `:135`,
`:170`, `:220` assert the resulting row transitions). But the gate at `Webhooks.pm:203-227`
returns true only when a `payment_schedules` row matches the subscription id, and the sole
writer of that table in `lib/` is `PriceOps/PaymentSchedule.pm:86-89`, reached only from
`InstallmentPayment.pm:309`. `grep -rn "INSERT INTO.*payment_schedules" sql/` returns
nothing. The test creates the rows itself (`t/controller/payment-failures.t:94,105`).

Of the nine tables PriceOps touches, the live charge path touches three. `pricing_plans`
is read by `RevenueShare.pm:31-37` for the fee rate and written by two workflow steps
(`ReviewActivatePlan.pm:101`, `GenerateEvents.pm:97`); `payments` and `payment_items` are
written by the enrollment payment step. `billing_periods` has no production writer at all --
its only two writers are in the two never-called modules. `pricing_relationship_events` is
written only from those same modules. `payment_schedules` and `scheduled_payments` have one
writer, the unwired installment step; `sql/deploy/tenant-scoped-payments.sql:137` records
that fact in a comment. `pricing_relationships` has one production reader
(`PricingPlanSelection.pm:84,139`) and no production writer in `lib/` -- rows come from
`sql/deploy/create-default-pricing-relationships.sql:63`.

All six modules compile. This is unreferenced code, not broken code -- except where noted
above, where it is both.

## Findings

### Critical: the Stripe webhook can permanently lose a paid enrollment, and nothing would find it

`Webhooks.pm:46-50` claims the event by inserting into `registry.webhook_events` with
`ON CONFLICT DO NOTHING`, outside any transaction (Mojo::Pg autocommits). An unclaimed
redelivery is answered 200 "OK (duplicate)" at `:52-56` without processing. Processing
starts at `:58`. The claim is released only from the Perl `catch` block, at `:85`.

Anything that kills the process between the claim committing and the catch running -- a
deploy restart, an OOM kill, a request timeout, a dropped DB connection (which would also
make the release DELETE at `:85` fail) -- leaves the claim standing with the work undone.
Stripe's retries then all receive 200 "OK (duplicate)" and stop. The work being guarded is
`_process_payment_intent_succeeded` (`:130-143`), which is the safety net that grants the
enrollment for 3DS and redirect cards where the parent never returns to the success page.
The parent's card has been charged; Registry has no enrollment row. There is no
`processed_at` or status column that could distinguish "claimed" from "done"
(`sql/deploy/webhook-event-dedup.sql:13-18`), no reconciliation job
(`ls lib/Registry/Job/` -- AttendanceCheck, DomainVerification, ProcessWaitlist,
WaitlistExpiration, WorkflowExecutor), and `grep -rni "reconcil" lib/ script/ registry
sql/deploy/ docs/specs/` returns nothing. The only discovery mechanism is a parent
complaining.

Compounding it, in the same handler: `Webhooks.pm:135-140` marks the payment completed via
`$payment->update($tdb, {...})`. `Registry::DAO::Payment` (`:6`) inherits from
`Registry::DAO::Object` and defines no `update`, so this resolves to `Object.pm:38-49`,
whose `catch` is `carp "Error updating $self: $e"` with no rethrow. If that UPDATE fails,
execution continues to `finalize_enrollment` at `:142`, the enrollment is granted, 200 is
rendered, and the claim stands -- so Stripe never retries. The parent is enrolled and paid
while `registry.payments` still says pending. `Payment.pm:417-424` documents this exact
hazard verbatim and provides `save` as the fail-loud alternative: "Intentionally bypasses
the inherited `Registry::DAO::Object::update()`, which silently carps and continues on
database errors." The parent-return path obeys it (`Payment.pm:321,326,332` all call
`save`); the webhook does not. `Payment.pm:208` and `:221` share the defect.
`Object.pm:44` also returns a *new* object rather than mutating `$self`, so even on success
the in-memory `$payment` is stale for the rest of the method.

**Fix.** Move the claim into the same transaction as the work: BEGIN, INSERT ... ON CONFLICT
DO NOTHING, process, COMMIT. A crash then rolls the claim back with the work and Stripe's
retry heals it for free -- strictly less code than the current claim/release pair. Then
replace `$payment->update(...)` at `:136` with field assignment plus `$payment->save($tdb)`,
so a failed write dies, releases the claim, and lets Stripe finish the job.

### Important: an unpriced session enrolls children for free, silently

`Payment.pm:517-518` is `my $pricing_plans = $session->pricing_plans($db); next unless
$pricing_plans && @$pricing_plans;` -- a session with no pricing plan contributes 0 to the
total and produces no line item. `Payment.pm:522-530` skips the item whenever
`calculate_price` returns undef. The consumer treats 0 as "free program":
`WorkflowSteps/Payment.pm:47-49` routes a zero total to `create_demo_enrollments`, which
enrolls every child in `enrollment_items` with no payment row and no Stripe call. Nothing
upstream filters unpriced sessions out of selection --
`MultiChildSessionSelection.pm:100-150` validates age eligibility only -- and sessions
without a plan are routinely creatable, because `GenerateEvents.pm:92-103` creates one only
when the optional `pricing_override` field is non-empty
(`ConfigureLocation.pm:43`).

A studio that leaves the per-location price blank when generating sessions gets a fully
registerable session that charges nothing. The children are enrolled for real; the parent
never sees a card form; no error, no warning. On a $150 program with 20 children that is
$3,000 the studio never collects and $60 Registry never collects. Mixed carts are worse than
all-or-nothing: `finalize_enrollment` (`Payment.pm:350-385`) enrolls from
`metadata->{enrollment_items}`, a list built independently of pricing at
`MultiChildSessionSelection.pm:125-131`, so a priced child pays and an unpriced sibling
rides along free.

Two related defects in the same function. `Payment.pm:521` takes `$pricing_plans->[0]` from
a SELECT with no ORDER BY (`PricingPlan.pm:126-133`), so the day a session legitimately
carries two plans the price charged is whichever row Postgres returns first. And
`PricingPlan.pm:154-166` compares `time()` (~1.78e9) against a de-hyphenated cutoff
(`20261231`) numerically, so `$today > $cutoff` is true for every date -- every early-bird
plan fails its requirements check and prices at nothing. Neither branch is producible from
today's plan-creation UI (see the dead-configuration finding below), so these two are
latent; the unpriced-session case is live.

**Fix.** Make "no applicable price" a refusal, not a zero. In
`calculate_enrollment_total`, collect an error for a selected session with no plan and for a
plan whose requirements are unmet, and have `WorkflowSteps/Payment.pm` surface it rather
than falling into `create_demo_enrollments`. Reserve $0 for a plan that genuinely prices at
zero, which `GenerateEvents` already supports. Fix the date comparison to compare like units
while you are in there.

### Important: tenant subscription billing is write-only

`TenantPayment.pm:340-344` calls `create_subscription_with_config($customer_id,
$payment_method, $config)` with three arguments. The signature is
`($customer_id, $payment_method_id, $config, $tenant_id = undef)` (`Subscription.pm:118`),
and `metadata[tenant_id]` is set only `if ($tenant_id)` (`:131-133`). The four-argument
wrapper `create_subscription` (`:105-116`) has no production caller. So no subscription
Registry creates carries a tenant id, and every lifecycle handler bails on its first line:
`my $tenant_id = $subscription->{metadata}->{tenant_id}; return unless $tenant_id;` at
`:265`, `:282`, `:298`, `:320` and `:333` -- including `_handle_payment_failed` (`:314-325`),
the `past_due` transition.

Second failure stacked on the first: `billing_status` has no readers at all.
`grep -rn billing_status lib/ templates/` returns only writers (`Subscription.pm:148,188-190`;
`TenantPayment.pm:434,442`) plus the column list at `Tenant.pm:141`. So the status never
changes, and nothing would gate on it if it did. A tenant on the seeded "Registry Plus -
$100/month" plan (`sql/deploy/unified-pricing-infrastructure.sql:138`) whose card fails keeps
full platform service indefinitely and no human is told. This is latent only because the
default tier is $0/month.

**Fix.** Pass the tenant id through to `create_subscription_with_config`. The subscription is
created before `_provision_tenant`, so either provision first or patch `metadata[tenant_id]`
onto the subscription immediately after provisioning. Then make at least one thing read
`billing_status` -- a banner or a login gate on `past_due`/`cancelled`.

### Important: one test suite file reports PASS while asserting nothing, on a database it killed

`t/dao/pricing-plan-clean-architecture.t:21` is `my $db = Test::Registry::DB->new->db;`. The
helper is a temporary: `t/lib/Test/Registry/DB.pm:63` creates a `Test::PostgreSQL` instance
and `:211 sub DESTROY` tears it down, so the ephemeral server dies at the end of that
statement. Every subsequent subtest then swallows the resulting failure -- `:59-63`,
`:81-85`, `:127-131`, `:196-200` are each `if ($@) { diag(...); pass("Skipping test due to
database issue"); return; }`.

Verified by running it: `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove
-lv t/dao/pricing-plan-clean-architecture.t` emits `Failed to create pricing plan:
DBD::Pg::st execute failed: no connection to the server` on stderr, then `ok 2 - Skipping
test due to database issue`, `ok 3`, `ok 4`, `All tests successful. Result: PASS`. Three of
four subtests assert nothing. The one that does (`:24-48`) is `->can()` introspection that
needs no database. It is the only file in `t/` with this shape:
`grep -rn 'Test::Registry::DB->new()\?->db' t/` returns exactly that one line. It also
violates the pristine-output rule on every run, so a real regression here would look
identical to the current state.

Related gap, on the live path: no test anywhere exercises a `RevenueShare` die through the
charge. All five die paths (`RevenueShare.pm:66,122,144,148,155`) are covered as direct unit
calls in `t/priceops/revenue-share.t:70-242`, and none through a request.
`grep -rn "Payment processing error" t/` returns nothing, against four hits in `lib/`
(`WorkflowSteps/Payment.pm:21,238`, `InstallmentPayment.pm:143,221`, `ErrorHandler.pm:180`).
This is the failure mode the codebase most expects to happen --
`sql/deploy/suspend-rateless-tenant-plans.sql:9-16` exists precisely because a tenant on a
rateless plan "has every enrollment charge fail" -- and we do not know whether that parent
gets the payment page back with a readable error, a 500, or a run stuck with an orphaned
payment row and a spent idempotency token (`Payment.pm:174-179` makes the token single-use
per row).

**Fix.** Delete `t/dao/pricing-plan-clean-architecture.t`; its field-shape assertions
duplicate `t/dao/pricing-plan-amount-cents.t` and its relationship assertions duplicate
`t/dao/pricing-relationships-integration.t`. Add one subtest to
`t/dao/payment-intent-destination-charge.t` (it already has a connect-ready tenant and a
tenant db handle) that nulls the plan's `percentage` key, calls `$step->process`, and asserts
the result carries an `errors` entry matching `/Payment processing error/` and that no second
payment row was created. About twenty lines.

### Minor: the fee-fraction guard admits the one ambiguous value

`RevenueShare.pm:151-157` dies unless `$raw >= 0 && $raw <= 1`. The guard exists to catch
the fraction-vs-percent mix-up that already bit once (a rate stored as 200). It catches 200
and 2. It does not catch 1, which is simultaneously a legal 100% fraction and the most
likely percent typo. Verified against the real code: `_coerce_pct('1')` returns 1 and
`application_fee_cents(15000, 1)` (`Payment.pm:43-45`) returns 15000. The percent convention
is live in the same repo -- `t/controller/tenant-pricing-display.t:117` authors a tier as
`revenue_share_percent => 1`, and `PricingModel.pm:96` stores `percentage =>
$form_data->{percentage_rate} / 100`.

A tenant on a plan carrying `percentage: 1` has `application_fee_amount` equal to the full
charge on every enrollment: a $150 registration settles $150 to Registry and $0 to the
studio. Nothing fails loudly -- Stripe caps the application fee at the charge total, so the
charge succeeds and the studio finds out at payout. Every platform plan in the repo is
authored by hand-typed SQL (`sql/deploy/seed-free-platform-plan.sql:24`,
`sql/deploy/unified-pricing-infrastructure.sql:112,138`); there is no UI that writes
`percentage` for a platform- or tenant-scope plan, so a hand-typed `1` is the realistic
authoring path.

**Fix.** Change `$raw <= 1` to `$raw <= 0.5` at `:157` and put both readings in the message
("0.02 means 2%; if you meant 1%, write 0.01"). Every real rate stays valid and the
ambiguous value fails at the plan rather than at the payout.

### Minor: the plan-creation workflow's entire output is orphaned

`workflows/pricing-plan-creation.yaml` is admin-reachable (`templates/layouts/dashboard.html.ep:36`
-> `/program-setup` -> `ProgramSetupOverview.pm:75` callcc) and collects a full pricing
configuration, including discounts: `RequirementsRules.pm:46-90` writes
`early_bird_discount`, `early_bird_cutoff_date`, `family_discount_enabled/type/amount`,
`min_children`, `volume_discount_*`, `prorate_on_upgrade`, `prorate_on_downgrade` and
`refund_policy`. `templates/pricing-plan-creation/review-activate.html.ep:170-199` echoes
them back to the admin.

None of it reaches an enrollment, because the plan it creates has no session.
`ReviewActivatePlan.pm:101-125` passes no `session_id` (`grep -n session_id
lib/Registry/DAO/WorkflowSteps/ReviewActivatePlan.pm` returns nothing), and the charge path
reads plans only via `Session::pricing_plans` (`Session.pm:164-166` ->
`PricingPlan.pm:126-133`), which filters `{ session_id => $session_id }`. A NULL-session row
never matches. It is not selectable on the tenant side either: `PricingPlanSelection.pm:83-95`
requires an active `pricing_relationships` row that this workflow never creates.

Underneath that, the vocabularies do not line up even if the plan were attached. The live
calculator `PricingPlan.pm:143` reads `percentage_discount`, which nothing in the repo ever
writes (`grep -rn percentage_discount lib/ templates/ workflows/` finds only that read and
two tests). `PriceOps/PricingPlan.pm:112` reads `sibling_discount`, whose only writer is the
historical migration `sql/deploy/enhanced-pricing-model.sql:28` reading columns that no
longer exist. `PricingPlan.pm:154,170` branch on `plan_type` values `'early_bird'` and
`'family'`, but `PricingPlanBasics.pm:76-81` offers only subscription/per_use/hybrid/one_time
and `GenerateEvents.pm:100` hardcodes `'standard'`, and the DB no longer constrains the
column (`sql/test-schema.sql:1205` is bare `plan_type text DEFAULT 'standard'`). A fourth
fragment, `Family::sibling_discount_eligible` (`Family.pm:68`), has tests and no caller.

Nobody is mischarged by this today -- the plan is orphaned wholesale, so display and charge
cannot diverge; the single parent-facing price
(`templates/summer-camp-registration/payment.html.ep:101`) is fed by the same
`calculate_enrollment_total` call that funds the PaymentIntent. But an admin can configure a
10% family discount, see it confirmed, and reasonably believe it is live.

**Fix.** Delete the discount section of `templates/pricing-plan-creation/requirements-rules.html.ep`
and the fields at `RequirementsRules.pm:46-90` that nothing reads, plus
`Family::sibling_discount_eligible`. Collecting configuration nothing consumes is worse than
not offering it. If discounts are wanted later, add them to `Registry::DAO::PricingPlan` --
the live calculator -- with the keys the form actually writes, and pass the real child count
from `Payment.pm:523` (that is a one-line change; `PriceOps/PricingPlan.pm:172` already
derives the count from the same `$enrollment_data` hash).

### Minor: two modules have never been called and would raise if they were

`UnifiedPricingEngine.pm` has zero references in the entire repository outside its own class
declaration. A full-repo sweep excluding `.git`, `local`, `node_modules` and `docs` returns
seven hits: `UnifiedPricingEngine.pm:9`, a commented-out `use` at
`t/dao/unified-pricing-engine.t:18`, and five `plan skip_all` strings at `:71,75,83,91,95`.
`git log --all --oneline -S 'UnifiedPricingEngine' -- lib/Registry/Controller lib/Registry/DAO`
returns nothing -- it has never appeared in a controller or a DAO in any commit. It is still
being maintained: 96b8251 (2026-08-06) ported it to integer cents. It duplicates
`PricingRelationships::_calculate_amount` (`UnifiedPricingEngine.pm:186` vs
`PricingRelationships.pm:281`). And `:101` inserts an `amount` column dropped by
`sql/deploy/pricing-plans-amount-cents.sql:35`, which is proof nobody runs it. Issue #76
("Implement Unified Pricing Engine") is still open and asserts the module is unimplemented,
so the tracker and the tree disagree.

`PricingRelationships.pm` likewise has zero production callers:
`grep -rn "PriceOps::PricingRelationships" lib/ | grep -v '^lib/Registry/PriceOps/'` is empty.
Its `_get_usage_data` queries at `:241-248` and `:255-264` filter `registry.payments` on
`tenant_id`, which the table has never had. The comment at `:226-236` documents this
accurately and explains why it is deliberately unfixed -- the 2.5% share is collected at
charge time as a Stripe application fee, so recomputing it here would double-collect -- and
issue #263 tracks the redesign. The one subtest that would execute those queries is
`plan skip_all => "Billing calculation needs payments table fix"`
(`t/dao/pricing-relationships-integration.t:293`).

Deletion is not symmetric across the DAOs beneath them.
`Registry::DAO::PricingRelationship` must stay: `PricingPlanSelection.pm:10,84,139` reads it
on the live tenant-signup path, and `sql/deploy/create-default-pricing-relationships.sql:63`
writes the table. `Registry::DAO::BillingPeriod` (129 lines) and
`Registry::DAO::PricingRelationshipEvent` (268 lines) die with the PriceOps modules -- every
caller of either is inside `PricingRelationships.pm` or `UnifiedPricingEngine.pm`.

Two stale skips go with them, and their stated reasons are wrong rather than merely
outdated: `t/dao/pricing-relationships-integration.t:219-220` skips a test that passes when
unskipped, and `t/dao/pricing-relationship-events.t:294`'s "ambiguous column" reason
misnames the actual defect (a state-reconstruction fallthrough to `'unknown'` in the CASE at
`sql/deploy/pricing-relationship-events.sql:147-152`). The `if 1` on that line was there in
the commit that created the file (1f6c2d2); nothing was forced later.

**Fix.** Delete `lib/Registry/PriceOps/{UnifiedPricingEngine,PricingRelationships}.pm`,
`lib/Registry/DAO/{BillingPeriod,PricingRelationshipEvent}.pm`,
`t/dao/unified-pricing-engine.t`, `t/dao/pricing-relationships-integration.t` and
`t/dao/pricing-relationship-events.t`. Close #76 as won't-do. Keep
`Registry::DAO::PricingRelationship`. Then write forward migrations dropping
`registry.billing_periods` (and its trigger at
`sql/deploy/unified-pricing-infrastructure.sql:201`) and `registry.pricing_relationship_events`
with its view and trigger functions from `sql/deploy/pricing-relationship-events.sql`. Do
*not* revert `unified-pricing-infrastructure` -- it also creates `registry.pricing_plans`,
which is the live table `RevenueShare` reads.

Coverage note before deleting `t/dao/unified-pricing-engine.t`: its two asserting subtests
duplicate `t/dao/pricing-plan-amount-cents.t:66-92` (which asserts all four seeded plans with
amounts *and* rates) and `t/dao/platform-pricing-plans-seed.t:22-51`. Nothing is lost but two
string comparisons on the platform tenant's name and slug, which no production code reads.

### Minor: the installment stack is complete, unreachable, and crashes if you reach it

`PaymentSchedule.pm`, `PricingPlan.pm`, `ScheduledPayment.pm`, their two DAOs, and
`WorkflowSteps/InstallmentPayment.pm` are ~1,150 lines of finished feature behind a door
nothing opens. `grep -rn "InstallmentPayment\|installment" workflows/` returns nothing; the
step appears in none of the 67 classes wired into workflow YAML and is absent from the
`lib/Registry/DAO/WorkflowSteps.pm` aggregator.

Two facts bear on any decision about it. First, opening the door does not work as-is:
`InstallmentPayment.pm:266` and `:290` call
`Registry::DAO::Payment->new(id => $payment_id)->load($db)`, and `Registry::DAO::Payment` has
no `load` method -- it never has
(`git log --all --oneline -S 'method load' -- lib/Registry/DAO/Payment.pm` is empty). Wiring
the step into a workflow today produces `Can't locate object method "load"` on the enrollment
path. Tracked as #279, and issue #295 lists three further parity gaps (stale-intent handling,
`already_completed`, async settlement) where `Payment.pm` has taken fixes that
`InstallmentPayment.pm` has not.

Second, the tenant-facing half is already live. `PricingModel.pm:73-74` and
`ReviewActivatePlan.pm:109-110` persist `installments_allowed` and `installment_count`, fed
by `templates/pricing-plan-creation/pricing-model.html.ep`, and both steps are wired. A tenant
can configure installments today; no parent can ever choose them.

Two smaller problems inside the stack, both moot if it ships and both worth knowing if it
does. `ScheduledPayment::handle_invoice_paid` (`:22-47`) keys off nothing invoice-specific --
it marks `$outstanding_payments[0]` from a `status IN ('pending','failed')` select ordered by
installment number -- so it advances a cursor rather than crediting an invoice. The
controller-level dedup at `Webhooks.pm:45-56` covers Stripe redelivery of the same event id,
which is the delivery shape Stripe actually produces, so this is defended in practice; if the
feature ships, a `stripe_invoice_id` column with a UNIQUE constraint on `scheduled_payments`
would make the defence local instead of remote. And
`t/dao/payment-schedule-race-condition.t` tests no race: it runs in one process on one DB
handle with no fork and no second connection, so the `FOR UPDATE` at `ScheduledPayment.pm:92`
is executed but never contended. Its comment at `:177` ("Stripe guarantees this") is not
true.

The dead installment gate also costs the live path a little. `Webhooks.pm:69` sits directly
before the tenant-billing branch; `_is_installment_payment_event` (`:204-227`) matches
`invoice.paid|invoice.payment_failed|customer.subscription..+` -- exactly the event types
tenant subscription billing uses -- then runs a `payment_schedules` lookup at `:220-223` that
can never return a row before falling through. One wasted round trip per tenant subscription
webhook.

Two of the stack's tests are named for layers they do not touch.
`t/e2e/installment-payment-enrollment.t` (138 lines) and
`t/controller/admin-installment-payment-dashboard.t` (265 lines) contain no `Test::Mojo`, no
`post_ok`, and in the second case no controller import at all -- its four subtests are named
"Admin dashboard ..." and touch no route, because no admin installment route exists
(`grep -rn "installment" lib/Registry/Controller/` outside `Webhooks.pm` returns nothing).
They are DAO CRUD in `t/e2e/` and `t/controller/`, which is how the feature reads as covered
from a directory listing and how a deletion comes to look risky when it is free.

**Fix.** This is a product decision, not a code decision -- see the open questions. Whichever
way it goes, delete those two mis-filed test files now; nothing in `lib/` is exercised by
either.

### Observations

**PriceOps owns one of roughly four money computations.** Tuition pricing lives in
`Payment.pm:499-546` -> `PricingPlan.pm:136-149` with no PriceOps involvement. The platform
fee is the one live PriceOps computation (`Payment.pm:91` -> `RevenueShare.pm:24-46`). The
entire tenant subscription flow lives in `Registry::DAO::Subscription`, which builds Stripe
form params and writes `UPDATE registry.tenants` in the same method (`:118-158`, `:263-338`)
-- the module with the most business logic in the codebase is the one that most flagrantly
mixes all three of the concerns 7b043f6 named. A reader looking for "where does Registry
decide what to charge" has to visit three namespaces, none authoritative. This is what issue
#256 is asking about from the naming side.

**Money types are integer cents everywhere except one column.**
`registry.billing_periods.calculated_amount` is still `numeric(10,2)`
(`sql/test-schema.sql:770`); the only other `numeric` columns in the whole dump are latitude
and longitude. Both `_calculate_amount` implementations divide by 100 to feed it and both say
so (`PricingRelationships.pm:285-287`, `UnifiedPricingEngine.pm:190-192`). It dies with those
modules. Everything else is enforced integer cents with CHECK constraints re-declared against
the new columns (`sql/test-schema.sql:1151-1153`, `:1375`).

**Tax and dispute handling do not exist anywhere.** `grep -rniE '\btax\b|automatic_tax|tax_rate'
lib/ --include='*.pm'` and `grep -rniE 'dispute|chargeback' lib/ --include='*.pm'` both return
nothing. Webhook dispatch handles three cases (`Webhooks.pm:61-81`); everything else falls
through to `Subscription->process_webhook_event`. No docs file places either in scope. Not a
defect against any stated requirement, but both are real obligations for a platform taking
money from parents in multiple US states, and a `charge.dispute.created` event today is
recorded and ignored -- so the first chargeback is discovered in the Stripe dashboard, after
the tenant has already been paid out of the destination charge.

**Refunds have a correct resolver, a proven Stripe mechanism, and no in-app caller.** The
wired admin drop-approval workflow does not fill the gap and is further from working than it
looks. `ProcessAdminDropDecision.pm:33` starts the drop-request-processing run via
`WorkflowProcessor->new_run`, which processes exactly one step -- the first
(`Utility/WorkflowProcessor.pm:9-14`; `WorkflowRun.pm:86-104` does a single `$step->process`
and returns). `process-refund` is step three of six
(`workflows/drop-request-processing.yml:12-14`), and nothing advances the run. Even if it
ran, `ProcessDropRefund.pm:14-17` gates on `refund_requested`, which
`ProcessAdminDropDecision.pm:18-25` never seeds, so it would return `refund_processed => 0`.
So no cents are at risk and no false promise reaches a parent -- but the admin flow also
no-ops entirely (the enrollment is never cancelled, the drop request stays pending) while
`templates/admin-drop-approval/complete.html.ep:7` reports "The drop request has been
processed successfully." That is an operator-trust bug worth its own issue, separate from
PriceOps.

## Recommendation

### Before taking real money

1. **Fix the webhook.** Wrap the dedup claim and the processing in one transaction
   (`Webhooks.pm:46-89`), and replace `$payment->update` at `:136` with
   `$payment->save($tdb)`. This is the only defect in this review that can silently lose a
   payment a parent has already made. Smallest diff, largest exposure.
2. **Make an unpriced enrollment a refusal.** `Payment.pm:517-518` collects an error instead
   of `next`; `WorkflowSteps/Payment.pm:47-49` surfaces it instead of enrolling for free.
   Add the test.
3. **Tighten the rate guard.** `RevenueShare.pm:157`, `$raw <= 0.5`, message naming both
   readings.
4. **Add the resolver-die-through-charge test** to
   `t/dao/payment-intent-destination-charge.t`. Twenty lines standing between a pricing typo
   and a silent outage for one tenant.
5. **Delete `t/dao/pricing-plan-clean-architecture.t`.** A file that reports PASS on a dead
   database is worse than no file; it makes the aggregate number mean less than it should.
6. **Decide who is the merchant of record for sales tax** and write it down. The
   destination-charge design implies the tenant. No code needed now.

### Before scaling

7. **Pass `$tenant_id` to `create_subscription_with_config`** (`TenantPayment.pm:340-344`)
   and make one thing read `billing_status`. Latent only while the default tier is free.
8. **Add a `charge.dispute.created` branch** that at minimum alerts. Disputed funds are
   clawed back from the connected account, so the tenant has already been paid.
9. **Add a reconciliation query or job** -- payments in `pending` older than some interval
   with a `stripe_payment_intent_id` set. Step 1 closes the hole; this finds anything the
   hole already ate.

### Eventually

10. **Delete the two never-called modules** and their dependent DAOs and tests, as listed in
    that finding, plus forward migrations for `billing_periods` and
    `pricing_relationship_events`. About 1,300 lines out for zero behaviour change. Close
    #76.
11. **Delete `t/e2e/installment-payment-enrollment.t` and
    `t/controller/admin-installment-payment-dashboard.t`** regardless of the installment
    decision. Zero risk; no `lib/` path is exercised by either.
12. **Delete the orphaned discount configuration** -- the form section in
    `templates/pricing-plan-creation/requirements-rules.html.ep`, the unconsumed fields in
    `RequirementsRules.pm:46-90`, and `Family::sibling_discount_eligible`.
13. **Resolve the naming (#256) last, after the deletions.** If the installment stack goes,
    `lib/Registry/PriceOps/` holds one plain package of exported subs and the right move is
    `git mv` to `Registry::RevenueShare` and delete the directory. If the installment stack
    stays, the collision is real and the rename is the fix -- but the shape of the rename
    depends on that decision, so do not make it first.

Run `STRIPE_SECRET_KEY=ci_placeholder_not_a_stripe_key carton exec prove -lr t/` after each
commit. Note that `t/dao/scheduled-payment.t:22`,
`t/dao/payment-schedule-race-condition.t:24`, `t/dao/payment-schedule.t:21` and
`t/controller/installment-payment-webhooks.t:24` set
`$ENV{STRIPE_SECRET_KEY} = 'sk_test_mock_key_for_testing'`, overriding the placeholder, and
make real failing HTTPS calls to api.stripe.com whose warnings (from
`ScheduledPayment.pm:137`) land in test output. That output is not pristine today.

## Open questions

**1. Do installments ship, or do they go?** This is the one decision that changes the shape
of everything else, and it is not mine to make. The case for shipping is on the record in
your own words: #295 is open, high-impact, and lists exactly what closing it needs; 7a76456
(today) fixed two real money bugs in `PaymentSchedule.pm` and `PricingPlan.pm`; the
tenant-facing configuration half is already live and wired. The case for cutting is that the
stack has been unreachable for eleven months, crashes on `Payment->load` if wired as-is
(#279), and has drifted from `Payment.pm` on four fixes. *My recommendation: ship or cut it
within one milestone, do not leave it in the third state.* If it ships, #295's option A --
fold installments into `Payment.pm` as a branch -- is the lazier call: it inherits the four
fixes instead of re-litigating them, at the cost of growing an already large step class. If
it is cut, the deletion is roughly 3,500 lines across `lib/` and `t/` plus a
`Webhooks.pm:69,204-295` edit and forward migrations for `payment_schedules` and
`scheduled_payments`; close #295 and #279 as won't-do in the same change.

**2. Does `PriceOps` survive as a name?** After the deletions in step 10, and if installments
go, the directory holds `RevenueShare.pm` alone: 82 code lines, a plain `package` with
`Exporter`, not an object. That is a namespace, not a tier. *My recommendation: `git mv
lib/Registry/PriceOps/RevenueShare.pm lib/Registry/RevenueShare.pm` and delete the
directory.* One counterweight you should weigh: #286 proposes `Registry::PriceOps::Refund`
and explicitly cites `PriceOps::ScheduledPayment` as the pattern to follow. If you want that,
the layer keeps a second occupant and the name stays -- but then write down what the layer
is for, because right now nothing does.

**3. Should refunds get a design before they get a caller?** #286 says yes, and says so for a
good reason: `refund` and `refund_async` need "the `_apply_intent` treatment (one shared
guard, two transports) BEFORE either gets a production caller, or they will drift on a money
decision." Meanwhile the wired drop-approval workflow is broken independently of refunds and
tells the operator otherwise. *My recommendation: fix the drop-approval workflow's own bug
first (it is an operator-trust bug, not a money bug, and it is cheap), keep the refund
resolver and `t/dao/refund-application-fee.t` as-is, and do #286's design work before wiring
`ProcessDropRefund` to anything.* Do not delete the refund half of `RevenueShare.pm`: it is
proven against real Stripe at `t/stripe-live/paid-enrollment.t:379-391` and documented as an
operational contract at `docs/operations/sacp-stripe-connect-onboarding.md:196-205`.

**4. Are discounts an MVP feature or not?** `docs/MVP_SPECIFICATION.md:61-62` lists early-bird
and sibling/family discounts. The admin can configure them today and nothing consumes them.
*My recommendation: cut them from the form until something reads them.* If they are wanted,
the implementation is two files -- pass the real child count at `Payment.pm:523` and apply
the discount in `PricingPlan.pm:136-149` using the keys `RequirementsRules` already writes --
not the four half-calculators currently in the tree.

**5. Is the tenant plan-switch gap acceptable?** You filed it yourself as #277 and triaged it
"fine today... low priority." Nothing here contradicts that: the rate is resolved per charge
from `tenants.platform_pricing_plan_id` (`RevenueShare.pm:35`), so a switch is one UPDATE
with no proration semantics on the revenue-share side, and there is no shipped upsell to
block. *My recommendation: leave it. It becomes real the day a second tier is sellable, and
the fix is small when it does.*

## Addendum: findings from the completeness critic

The five review dimensions above missed the following. Each was verified independently
after the synthesis was written; the citations were checked by hand.

### Important: the platform fee is computed, charged, and never recorded in Registry

`Payment.pm:43-45` computes `application_fee_cents` and `:96` ships it to Stripe as
`application_fee_amount`. That number is then discarded. `registry.payments` has twelve
columns and none of them is the fee (`sql/test-schema.sql`, `CREATE TABLE registry.payments`),
and it is not in `metadata` either -- `WorkflowSteps/Payment.pm:193-206` snapshots
workflow and enrollment keys, and `Payment.pm:50-62` sends only `user_id`, `payment_id`,
and scalar metadata to Stripe. `grep -rn application_fee lib/ sql/deploy/ templates/`
returns the compute site, the resolver, and one migration. No persistence anywhere.

Registry's own revenue therefore exists only inside Stripe. Four consequences, all live:

No query against Registry's database can answer what the platform earned in a period,
and nothing exists to reconcile a Stripe payout against. The rate is resolved live from
a mutable row at charge time (`RevenueShare.pm:31-37`), so editing
`pricing_configuration.percentage` retroactively rewrites the apparent rate of every
historical charge. The refund flag is resolved at refund time rather than charge time
(`Payment.pm:114`), so moving a tenant between plans moves the refund policy of all
their past charges with it. And the failure this module exists to prevent is
undetectable: `RevenueShare.pm:43-45` falls back to the Free plan at 0.00 whenever
`platform_pricing_plan_id` is NULL, and nothing in Registry's data distinguishes
"charged 0% because Free" from "charged 2%".

The fix is one integer column stamped in `_record_intent` beside the intent id, not a
ledger table.

### Important: the signup page discloses the revenue-share rate only inside a plan name

`templates/tenant-signup/pricing.html.ep:65-67` renders the rate from
`pricing_configuration->{revenue_share_percent}`. Nothing writes that key to a plan the
page can show. The seeds write `percentage` (`sql/deploy/unified-pricing-infrastructure.sql:110`
and `:139`, `sql/deploy/seed-free-platform-plan.sql:24`), which is also what the charge
reads (`RevenueShare.pm:32`, `:59`). `PricingPlanSelection.pm:97` passes
`pricing_configuration` through verbatim from the row, so the branch is dead for every
plan the signup workflow can offer. The only production writer of `revenue_share_percent`
is `TenantPayment.pm:125`, building a hash for a different template.

Net: on the live tenant-signup page, the rate a studio will be charged on every parent
payment appears nowhere except the plan's name string, "Registry Revenue Share - 2%".
The plan description is dead on the same page for the same reason -- the seeds put it in
`metadata` (`unified-pricing-infrastructure.sql:111`) while the template reads
`pricing_configuration->{description}` (`pricing.html.ep:49`).

This undermines the review's own best evidence for rate consistency.
`t/user-journeys/alex/03-platform-billing.t:135-141` extracts the displayed rate with a
fallback regex against the plan *name*, because the description regex cannot match
anything the template renders, and `:307` then asserts displayed equals charged. The
#267 definition of done -- one source, no drift -- is being satisfied by a hand-typed
substring in a plan name.

Related test-honesty gap: `t/controller/tenant-pricing-display.t:50-68` fabricates plans
carrying `revenue_share_percent` and no `percentage`. Were such a plan real,
`RevenueShare.pm:144` would die on every enrollment charge for the tenant who selected
it -- the exact shape `sql/deploy/suspend-rateless-tenant-plans.sql:29-32` was written to
pull from the menu. That migration is a one-shot UPDATE, not a constraint, so nothing
prevents the shape recurring.

### The installment stack is two breaks from working, not one

The review treats the installment gap as a missing line of workflow YAML. It is not.

`payment_schedules` and `scheduled_payments` are cloned into every tenant schema
(`sql/deploy/tenant-scoped-payments.sql:255-259`, `:266-284`). The writer runs
tenant-scoped: `InstallmentPayment.pm:309` -> `PriceOps/PaymentSchedule.pm:86` on the
workflow's `$db`. The reader runs registry-scoped: `Webhooks.pm:222` uses
`$self->app->dao->db`, and `Webhooks.pm:71` passes `$dao->db` into
`_process_installment_payment_event` with no schema switch. The same file shows the
correct pattern forty lines later -- the one-time payment path at `Webhooks.pm:112`
explicitly calls `$dao->connect_schema($slug)`, with a comment explaining that the
payment row lives in the schema the registration ran under.

So wiring the YAML alone puts every schedule in a tenant schema the classifier cannot
see. `_is_installment_payment_event` returns 0, every installment `invoice.paid` falls
through to the tenant-billing branch at `Webhooks.pm:72-79`, nothing marks the
installment paid, and the ScheduledPayment surface stays dead while appearing wired.

### Missed consumer: the admin dashboard overstates what a tenant earned

`AdminDashboard.pm:36` computes "Monthly Revenue" as `SUM(payments.amount_cents)` where
status is completed, rendered as-is at `templates/admin_dashboard/index.html.ep:115` and
`templates/admin-dashboard/dashboard-overview.html.ep:117`. These are destination charges
with `on_behalf_of` (`Payment.pm:94`), so the studio's actual payout is the amount minus
Stripe's processing fee minus `application_fee_amount`. The one money number Registry
shows a tenant overstates their take by exactly the number PriceOps computes and, per the
first finding above, never stores -- the dashboard could not subtract it if it wanted to.

### Corrections to the recommendations above

Three recommendations in this document are wrong as written.

The seam section's "make the surviving reader use the keys `RequirementsRules` actually
writes" buys nothing: the plan the form creates has a NULL `session_id`
(`ReviewActivatePlan.pm:101-125`) and `Session::pricing_plans` filters on `session_id`,
so the row is off the charge path entirely. Only the "delete the form fields" half is
actionable.

The money section's "swap `$pricing_plans->[0]` for `get_best_price`" would regenerate
the bug it fixes. `DAO/PricingPlan.pm:214-224` returns a *price*, not a plan, and returns
undef when nothing applies -- dropped into `Payment.pm:521-539` as-is it loses the plan
identity the line item needs and reintroduces the undef-to-skip-to-$0 path. The
recommendation must specify dying on undef.

The verdict's "move `RevenueShare.pm` to `Registry::RevenueShare`" is fine, but
`docs/operations/sacp-stripe-connect-onboarding.md:183` and `:202` name both resolvers by
fully-qualified package as a live operational contract. Rename and doc in one commit.
