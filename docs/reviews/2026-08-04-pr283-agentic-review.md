# Agentic review: PR #283 (money path)

Date: 2026-08-04. Head: `f3c463b`. Base: `8799cde` (merge-base with main).
153 agents, 8 finder dimensions, 3 adversarial verifiers per finding (majority upheld to survive).

Raw findings 48 -> **25 confirmed**, 23 refuted. Plus 5 completeness-critic gaps.

## BLOCKER (2) -- both FIXED

Both are closed. `Registry::DAO::Payment::_apply_intent` now refuses to let a
superseded intent demote a captured row (it reports `already_completed`), the
payment step routes that outcome to completion, and every rendering return in
the step nests under `step_data` so the card form actually reaches the page.
Covered by `t/dao/payment-stale-intent-replay.t`, the new subtests in
`t/dao/payment-step-async.t`, and content assertions in
`t/user-journeys/alex/02-activate-and-collect.t`.

Not carried over to `WorkflowSteps/InstallmentPayment.pm`: it handles
`already_completed` as an error, which is now safe (no row demotion) but still
poor UX. Mirroring the completion routing there is unsafe without work --
its `create_enrollments` is not idempotent the way `finalize_enrollment` is,
so it needs its own fix and its own tests.

### Stale-but-owned intent re-drives the decline branch on an already-captured payment, minting a fresh live client_secret (double charge) and orphaning the real charge

- **Location:** `lib/Registry/DAO/WorkflowSteps/Payment.pm:236-245, 289-333`
- **Dimension:** idempotency | **Votes:** 3/3 upheld

**Mechanism:**

handle_payment_callback has no guard on the payment row's own state -- it goes straight to process_payment_async and lets the *retrieved intent's* status drive the outcome. The ownership check in Payment::_apply_intent (lib/Registry/DAO/Payment.pm:277-286) accepts an intent EITHER by matching the stored stripe_payment_intent_id OR by `$intent->{metadata}{payment_id} eq $id`. Every intent ever minted for this payment carries metadata[payment_id] (Payment.pm:202, _stripe_metadata_params), so a superseded intent still passes ownership.

Sequence: (1) parent's first card declines -> pi_1 = requires_payment_method; the decline branch cancels pi_1, rotates the token, mints pi_2. (2) parent pays with pi_2, it succeeds; the row is completed, the enrollment is created. (3) Anything replays the *earlier* Stripe return URL `/summer-camp-registration/<run>/payment?payment_intent=pi_1` -- it is a plain GET with no auth (Registry.pm:764, no under/require_auth), and 93dcb86 made that GET a live finalizer. (4) retrieve(pi_1) returns status `canceled` (or `requires_payment_method`); ownership passes via metadata; _apply_intent's else-branch sets $status='failed' and save()s over the completed row. (5) _settle_callback line 293 lets `canceled` through to the decline branch; line 313-316 cancels `$payment->stripe_payment_intent_id`, which is now pi_2 -- the SUCCEEDED intent -- and swallows the error; line 319-320 rotates the idempotency token and mints pi_3; line 333 persists payment_retry_state with pi_3's client_secret and show_stripe_form=1. (6) _render_step_result flashes the error and redirects to the payment step, whose prepare_template_data (Payment.pm:80-90) merges retry_state, so a parent who has already paid is shown a live Stripe card form.

Collateral: _record_intent (Payment.pm:209-219) overwrites stripe_payment_intent_id with pi_3, so pi_2 -- the intent that actually captured money -- is no longer referenced by any DB row. Payment::refund/refund_async die on a non-completed status, so the capture is unrefundable from inside Registry.

**Impact:** Parent is presented with a live card form after already paying and can be charged a second time for the same enrollment. The first, real capture becomes unreachable: the row reads status='failed' and its stripe_payment_intent_id has been overwritten, so the in-app refund path refuses it and revenue reporting (AdminDashboard.pm:35-38, PricingRelationships.pm:247/263, both filter status='completed') silently drops the money. No test covers a callback arriving for an intent other than the current one against a completed row.

**Evidence:**

```
lib/Registry/DAO/Payment.pm:277-286:
    my $owned =
        ( defined $stripe_payment_intent_id && $intent_id eq $stripe_payment_intent_id )
        || ( ( $intent->{metadata}{payment_id} // '' ) eq $id );

lib/Registry/DAO/WorkflowSteps/Payment.pm:293-316:
    unless ($intent_status eq 'requires_payment_method' || $intent_status eq 'canceled') { ... }
    my $cancel = Mojo::Promise->resolve;
    if (my $old_intent = $payment->stripe_payment_intent_id) {
        $cancel = $payment->stripe_client->cancel_payment_intent_async($old_intent)
            ->catch(sub ($cancel_err) { });   # already settled/canceled is fine
    }
    return $cancel->then(sub {
        $payment->rotate_idempotency_token($db);
        $payment->create_payment_intent_async($db, { ... })
```

> Verifier correction: Core mechanism confirmed; two secondary details in the write-up are off. (a) The AdminDashboard.pm:35-38 citation is wrong — that file contains no `status='completed'` payment filter at all (grep finds none); the accurate citation is lib/Registry/PriceOps/PricingRelationships.pm:247 and :263, which do filter `status = 'completed'`, though they query registry.payments for platform billing usage while tenant enrollment payments live in per-tenant schemas (see the comment at PricingRelationships.pm:228-230), so the revenue-reporting impact is weaker than stated. (b) The cancel at WorkflowSteps/Payment.pm:313-316 does not actually harm pi_2 at Stripe — Stripe rejects cancellation of a succeeded PaymentIntent and the error is swallowed; the real damage is the DB row (status flipped to 'failed', stripe_payment_intent_id overwritten with pi_3), which is what blocks refund/refund_async. Also worth noting for triage: the harmful variant requires replaying a *superseded* intent id, not the current one, and the decline branch redirects to a query-less URL, so this does not fire by itself during a normal browser flow — it needs a replay of a stale intent id at the unauthenticated GET.

> Verifier correction: The mechanism is confirmed exactly as described, at the cited lines. Two framing corrections, neither of which reduces severity below blocker:

1. The "unauthenticated caller" angle is the weak part. Exploiting it deliberately requires knowing both the run UUID and a valid prior intent id for that payment row. The realistic trigger is the parent's own browser replaying an earlier Stripe return URL. That URL only exists after a *redirect-based* attempt (3DS or a redirect payment method), because a plain card decline in confirmPayment returns an error client-side without ever navigating to return_url. So the sequence is: 3DS/redirect attempt fails -> Stripe GETs back with ?payment_intent=pi_1&redirect_status=failed -> decline branch cancels pi_1 and mints pi_2 -> parent pays with pi_2 -> back-button/tab-restore/refresh on the pi_1 history entry re-fires the finalizer. Narrower than "anything replays", still an ordinary user action.

2. The finding does not mention it, but the same commit (93dcb86) introduces an auth/state asymmetry worth naming in the writeup: process_workflow_run_step guards with `if ($run->completed($dao->db)) { return ... 'DONE' }` at lib/Registry/Controller/Workflows.pm:340, and the new GET hook at Workflows.pm:253-257 has no equivalent. That guard would not have caught this case anyway, since _persist_step_result sets latest_step_id to the payment step, leaving completed() false.

> Verifier correction: Two framing corrections that do not change the verdict. (1) The enrollments created in step 3 are NOT removed — finalize_enrollment's rows survive, so the parent keeps their enrollment; the guaranteed damage is the payment row being demoted completed->failed, stripe_payment_intent_id overwritten from the capturing intent (pi_2) to a fresh unpaid intent (pi_3), and a live Stripe Elements form re-offered. The actual second charge additionally requires the parent to re-enter a card, so "double charge" is the worst case, not the automatic outcome. (2) The trigger is not limited to a `canceled` intent: a stale intent still in `requires_payment_method` (e.g. the best-effort cancel at WorkflowSteps/Payment.pm:313-316 failed and was swallowed) passes the same gate at line 293 and drives the identical path.

### The Stripe card form never renders: show_stripe_form/client_secret land at the top of the stash, but the template only reads them out of step_data

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/lib/Registry/Controller/Workflows.pm:444`
- **Dimension:** test-integrity | **Votes:** 3/3 upheld

**Mechanism:**

1. Parent submits agreeTerms. Payment::create_payment creates a REAL Stripe PaymentIntent and resolves { next_step => $self->id, data => { payment_id, client_secret, show_stripe_form => 1 } } (lib/Registry/DAO/WorkflowSteps/Payment.pm:223-224).
2. WorkflowRun::process sees next_step == step id, so it takes the stay branch and sets $stay_result{template_data} = $step_result->{template_data} || $step_result->{data} (lib/Registry/DAO/WorkflowRun.pm:145-147). template_data is therefore the FLAT data hash: client_secret and show_stripe_form are top-level keys.
3. _render_step_result merges { %{ $step->prepare_template_data(...) }, %{ $result->{template_data} } }. prepare_template_data returns { step_data => { total, items, stripe_publishable_key } } and nothing else (Payment.pm:73-83). The merge produces { step_data => {3 keys}, client_secret => ..., show_stripe_form => 1 } -- the second hash has no step_data key, so it does not merge INTO step_data.
4. templates/summer-camp-registration/payment.html.ep:4-5 reads `my $step_data = stash('step_data') || {}; my $show_stripe = $step_data->{show_stripe_form};` -> undef.
5. Line 116 `<% if ($show_stripe) { %>` gates the entire block containing #payment-element, the Stripe.js include, `const clientSecret = '<%= $step_data->{client_secret} %>'` (empty), and this PR's new return_url (line 167). None of it is emitted.
Both halves pre-date this PR (verified with `git show 8799cde:` on both files), so this is not a regression introduced here -- but this PR is the one that claims the money path is complete, and it added the return_url line INSIDE the dead block.

**Impact:** An unlucky parent reaches the payment step, checks the terms box, submits, and gets the same summary page back with no card form. They cannot pay and cannot enroll. Meanwhile a real Stripe PaymentIntent has already been created against the tenant's connected account and is left dangling. Every blocking test in the suite is green while the money path cannot take a single dollar.

**Evidence:**

```
Workflows.pm:444-447:
            my $template_data = {
                %{ $step->prepare_template_data($dao->db, $run) },
                %{ $result->{template_data} || {} },
            };
WorkflowRun.pm:145-147:
            $stay_result{template_data} = $step_result->{template_data}
                ...
                if ($step_result->{template_data} || $step_result->{data});
Payment.pm:78-82:
    return {
        step_data => {
            %$step_data,
            %$retry_state,
        },
    };
payment.html.ep:4-5, 116:
<% my $step_data = stash('step_data') || {}; %>
<% my $show_stripe = $step_data->{show_stripe_form}; %>
    <% if ($show_stripe) { %>
```

> Verifier correction: Finding stands, with two clarifications the reporter already half-flagged. (a) It is not a regression from the reviewed commits: `prepare_template_data` returning only `{ step_data => ... }` and the template's `$step_data->{show_stripe_form}` gate both exist unchanged at merge-base 8799cde. This PR's only change to that template is swapping the return_url (line 167) — inside the block that never renders. (b) Impact is "cannot pay", not "loses money": the created PaymentIntent is left uncaptured, and a resubmit reuses the same payment row + idempotency token (Payment.pm:184-207), so there is no double-charge — the parent is simply stranded on the agreement form forever, because the retry path that DOES render the form (via payment_retry_state) can only be reached after a card decline, which requires the form the user never sees.

> Verifier correction: Two refinements, neither of which rescues the flow. (a) "Never renders" is slightly too strong: the decline-retry path DOES render it — handle_payment_callback persists payment_retry_state (Payment.pm:326-333) and prepare_template_data merges that state INTO step_data (Payment.pm:80-89), so show_stripe_form/client_secret reach the template on re-entry. What is broken is specifically the FIRST-submit path (create_payment success), and since that is the only way to reach a card at all, the retry path is unreachable in practice; net user impact is exactly as described. (b) The finding is correct that both halves pre-date the PR — the controller stay-merge (Workflows.pm:444-447) and WorkflowRun's `|| $step_result->{data}` are context lines, not additions, in the diff against 8799cde — so this is a pre-existing blocker the PR ships on top of (and adds the new return_url into), not a regression it introduces.

> Verifier correction: Two corrections to the finding as written. (1) No money is taken and nothing is double-charged: the intent is created but never confirmed (confirmPayment lives inside the block that is never emitted), so it sits at requires_payment_method and expires. Resubmits reuse the same payment row and the same idempotency token because the amount is unchanged, so Stripe replays the same intent rather than accumulating new ones. The damage is "cannot collect a dollar" plus a dangling intent per abandoned run, not "charged without delivery". (2) The finding is right that both halves pre-date the PR (I confirmed at 8799cde: the controller's stay merge and Payment::prepare_template_data's step_data wrapper both already existed), so this is not a regression introduced here. It is however an incomplete fix inside the weighted, never-reviewed range: commit 93dcb86 (B-4) added the GET-side callback dispatch and rewrote return_url at payment.html.ep:167, and that line sits inside the dead block — so the B-4 fix is unreachable from a browser in this workflow, and the decline-retry path (which does render, via payment_retry_state -> prepare_template_data) can only be entered from a callback that requires the card form, making it unreachable too.

## HIGH (10)

### Stripe-return GET lets an unauthenticated caller flip any payment row to 'failed' — the ownership guard only exists on the success branch

- **Location:** `lib/Registry/DAO/Payment.pm:245 (entry point lib/Registry/Controller/Workflows.pm:255)`
- **Dimension:** b4-callback-auth | **Votes:** 3/3 upheld

**Mechanism:**

1. The workflow routes are unauthenticated and un-scoped: `my $r = $self->routes;` (lib/Registry.pm:651) then `$w->get("/:run/:step")->to('#get_workflow_run_step')` (lib/Registry.pm:764). `get_workflow_run_step` never calls require_auth and never checks that the run belongs to the session user — `method run ($id = $self->param('run')) { ($dao->find(WorkflowRun => {id => $id}))[0] }` is the whole access control. 2. Commit 93dcb86 added a dispatch at Workflows.pm:255 that hands `payment_intent` from the query string to the step. 3. WorkflowSteps/Payment.pm:236 handle_payment_callback reads `$run->data->{payment_id}` and calls `$payment->process_payment_async($db, $form_data->{payment_intent_id})`. 4. Payment.pm:548 process_payment_async installs `_record_retrieval_failure` as the REJECTION handler. Payment.pm:245 does `$status = 'failed'; $self->save($db);` with NO ownership check at all — the ownership check lives only in `_apply_intent`, the resolution handler. 5. So `GET /summer-camp-registration/<run-id>/payment?payment_intent=pi_doesnotexist` makes Stripe return 404, Registry::Service::Stripe::_request_async croaks (Stripe.pm:64), the promise rejects, and the victim's payment row is written to status='failed'. No POST, no session, no CSRF token (there are none anywhere in this app), so a bare <img src=...> on any page the victim's browser loads is enough. 6. Non-adversarial trigger, same defect: the return leg now runs on EVERY successful payment and races the payment_intent.succeeded webhook. If the webhook lands first it sets status='completed' and finalizes (Webhooks.pm:135-142) and the event id is dedup-claimed (Webhooks.pm:46-56), so Stripe never redelivers. A transient Stripe API error on the browser-return retrieve then rewrites the completed row to 'failed' permanently — nothing heals it. 7. This variant is new to 93dcb86: the POST handler refuses after completion (Workflows.pm:340) and refuses off-position steps (Workflows.pm:348). The GET dispatch has neither guard.

**Impact:** A paid, captured charge is recorded as `failed`. Registry::DAO::Payment::refund and refund_async both start with `die "Cannot refund non-completed payment" unless $status eq 'completed'` (Payment.pm:434, 557), so the tenant can no longer refund that parent through Registry. Tenant revenue reporting silently loses the charge: AdminDashboard.pm:36 sums `payments` filtered on `status => 'completed'`. An attacker needs only a run id; alternatively, via the base-class passthrough steps `landing`/`camper-info` (both class Registry::DAO::WorkflowStep, whose process returns the whole form hash into run data), they can inject an arbitrary `payment_id` into their OWN run and target a payment id instead.

**Evidence:**

```
lib/Registry/DAO/Payment.pm:548-554
    method process_payment_async ($db, $payment_intent_id) {
        return $self->stripe_client->retrieve_payment_intent_async($payment_intent_id)
            ->then(
                sub ($intent) { $self->_apply_intent($db, $intent, $payment_intent_id) },
                sub ($error)  { $self->_record_retrieval_failure($db, $error) },
            );
    }

lib/Registry/DAO/Payment.pm:245-250
    method _record_retrieval_failure ($db, $error) {
        $error_message = $error;
        $status = 'failed';
        $self->save($db);
        return { success => 0, error => $error };
    }

_apply_intent's own comment states the invariant its sibling handler breaks — lib/Registry/DAO/Payment.pm:275:
        # Do not mutate status on mismatch: a forged id must not be able to
        # flip a payment to failed either.

lib/Registry.pm:651,764 (no auth on the route)
        my $r = $self->routes;
        ...
        $w->get("/:run/:step")->to('#get_workflow_run_step')
```

> Verifier correction: Mechanism confirmed; three details in the finding are wrong but non-load-bearing. (a) "no CSRF token (there are none anywhere in this app)" is false — Registry.pm:487-517 validates a CSRF token and Registry.pm:545-556 auto-injects the hidden field into every form; it returns early unless the method is POST/PUT/DELETE, so the GET attack is unaffected and the <img src> claim still stands. (b) The revenue aggregation is lib/Registry/DAO/AdminDashboard.pm:35-38, not lib/Registry/Controller/AdminDashboard.pm:36. (c) refund_async (Payment.pm:557) dies with "Payment must be completed before refunding", not the quoted "Cannot refund non-completed payment" (that is refund at line 434); the gate is equivalent. Also worth scoping severity: both attacker-driven shapes require an unguessable UUID (a victim run id, or a victim payment id injected into the attacker's own run via the landing/camper-info passthrough steps), so mass exploitation is not practical. The variant that needs no attacker at all — webhook completes and finalizes first, then a transient Stripe error on the browser-return retrieve rewrites the completed row to 'failed' with no path to heal it — is the strongest and is fully confirmed.

> Verifier correction: Two qualifications, neither of which refutes the finding. (a) The CSRF / bare-<img> framing is irrelevant: the route consults no session at all, so an attacker simply issues the GET directly; SameSite/CSRF never enter it. (b) "flip ANY payment row" overstates blind reachability — the attacker must know either the victim's run UUID or the victim's payment UUID (both unguessable capability URLs; run URLs do leak via sharing/history, and a parent can always corrupt their own row). The variant needing no secret is mechanism point 6: the return leg now runs on every successful payment and races the payment_intent.succeeded webhook, so one transient Stripe retrieve error (timeout/5xx) after the webhook has already set status='completed' rewrites a genuinely captured charge to 'failed' permanently — refunds then die and the charge vanishes from revenue reporting. Realistic severity: high on the corruption/unrefundable-charge axis, medium on the "attacker picks a target" axis.

> Verifier correction: The finding is correct in mechanism and impact. Three factual details in the write-up need fixing, none of which change the conclusion:

1. "no CSRF token (there are none anywhere in this app)" is wrong. Registry.pm:544 registers a CSRF before_dispatch hook and Registry.pm:~583 injects a hidden csrf_token into every rendered form. The hook only validates POST/PUT/DELETE, so the GET return leg is genuinely unprotected — the conclusion stands, the parenthetical does not. Practically this means CSRF is irrelevant here anyway: the route needs no session, so an attacker can just curl it directly rather than needing a victim's browser.

2. The revenue-reporting reference is lib/Registry/DAO/AdminDashboard.pm:36, not lib/Registry/Controller/AdminDashboard.pm:36. The query is `$db->select('payments','SUM(amount)',{status=>'completed', created_at=>{'>='=>$month_start}})` — the claim itself is correct.

3. The `landing` passthrough escalation does not work. start_workflow already consumes the first step, so a POST to landing hits Workflows.pm:348 `die "Wrong step expected account-check"`. The escalation does work via `camper-info`, which is also class Registry::DAO::WorkflowStep (workflows/summer-camp-registration.yaml:18-22), is reachable in normal sequence, and whose outcome-definition validation only enforces required fields — so `POST /summer-camp-registration/<attacker-run>/camper-info` with `payment_id=<victim-payment-uuid>` persists into the attacker's run data (payment_id is not in @TRANSIENT_KEYS), after which the GET at step 2 flips the victim's row.

One scoping note the write-up understates: both attack variants require knowing a UUID that belongs to someone else (a run id, or a payment id plus one's own run). Run ids are exposed in the URL the parent browses, so they leak via referrer, browser history, shared links, and access logs — but this is not a zero-knowledge attack. The attacker-free race variant (webhook wins, then a transient Stripe error on the return leg rewrites a completed row to failed) needs no secret at all and is the stronger argument for fixing it.

Minimal fix: give _record_retrieval_failure the same guards _apply_intent has — refuse to mutate status when the row is already 'completed'/'refunded', and do not record a failure for an intent id that is neither $stripe_payment_intent_id nor metadata-stamped with this payment id. That is one guard in the shared DAO method rather than a check in the GET dispatch, and it also covers the sync process_payment caller at Payment.pm:258.

### The Stripe-return GET is unauthenticated and unscoped: any caller who knows a run UUID can flip a captured payment to 'failed'

- **Location:** `lib/Registry/Controller/Workflows.pm:255-259`
- **Dimension:** idempotency | **Votes:** 3/3 upheld

**Mechanism:**

`$w->get("/:run/:step")` (lib/Registry.pm:764) hangs directly off $r -- no `under`, no require_auth, and Workflows::run() (Workflows.pm:15-18) looks the run up by id with no ownership check. Commit 93dcb86 turned that GET into a money-path mutator: if the step can('handle_payment_callback') and a `payment_intent` query param is present, it calls _process_step with attacker-supplied data.

The intent id flows unvalidated into Registry::Service::Stripe::retrieve_payment_intent_async, which interpolates it into the URL path (Stripe.pm:78-80). A nonexistent id yields HTTP 404, _request_async croaks (Stripe.pm:50-65), the promise rejects, and process_payment_async's rejection handler runs _record_retrieval_failure (Payment.pm:245-250), which does `$status = 'failed'; $self->save($db)` with no check of the current status. save() (Payment.pm:410-420) rewrites the whole row.

So `GET /summer-camp-registration/<run-uuid>/payment?payment_intent=pi_garbage` -- no session, no CSRF, no POST -- rewrites a completed payment row to status='failed'. Run UUIDs appear in URLs, browser history, Referer headers and access logs. The same thing happens with no attacker at all: a parent reloading the Stripe return URL while Stripe's API is timing out (30s request_timeout) hits the identical path.

**Impact:** Data corruption on the money path with no authentication required: a captured payment reads 'failed'. Payment::refund and refund_async both `die "Cannot refund non-completed payment"`, so the tenant loses the in-app refund path for a real charge; AdminDashboard monthly revenue and PricingRelationships usage billing both filter on status='completed', so platform revenue is understated. It is also the cheap trigger for the double-charge above, because Payment step create_payment reuses any row whose status ne 'completed' (WorkflowSteps/Payment.pm:145).

**Evidence:**

```
lib/Registry/Controller/Workflows.pm:255-259:
        if ( $step && $step->can('handle_payment_callback')
             && ( my $intent = $self->param('payment_intent') ) ) {
            return $self->_process_step( $run, $step,
                { payment_intent_id => $intent } );
        }

lib/Registry/DAO/Payment.pm:245-250:
    method _record_retrieval_failure ($db, $error) {
        $error_message = $error;
        $status = 'failed';
        $self->save($db);
        return { success => 0, error => $error };
    }

lib/Registry.pm:764 (no auth wrapper):
        $w->get("/:run/:step")->to('#get_workflow_run_step')
```

> Verifier correction: The mechanism is confirmed; two details in the write-up are slightly off but do not change the verdict. (a) refund_async's message is "Payment must be completed before refunding" (Payment.pm:557), not "Cannot refund non-completed payment" — that wording is from the sync refund (Payment.pm:434). Both still block. (b) The unconditional status='failed' on retrieval failure is not new in this PR: the base commit already had it in the sync process_payment (base Payment.pm:188-199), reachable via the POST step route (which is also auth-free, though CSRF-gated). What commit 93dcb86 newly introduces is reachability from a bare GET — no form body, no CSRF token, no session — which is what turns a POST-only edge case into something triggerable by a link, a prefetch, or a URL lifted from an access log. Also worth noting for the fix: the same unguarded flip is reachable through Registry::DAO::WorkflowSteps::InstallmentPayment (lines 264 and 288), which also satisfies the controller's can('handle_payment_callback') gate, so the guard belongs in _record_retrieval_failure (do not downgrade a completed payment), not in the controller.

> Verifier correction: The core mechanism is confirmed exactly as described: lib/Registry.pm:762-767 puts GET /:workflow/:run/:step on $r with no `under` (require_auth appears nowhere in the workflow path), the CSRF hook at lib/Registry.pm:490-493 exempts GET, and the new block at lib/Registry/Controller/Workflows.pm:255-259 runs before any of the guards the POST twin has (process_workflow_run_step at Workflows.pm:339-348 has both `$run->completed` -> DONE/201 and a next_step slug match; the GET path has neither and resolves $step by slug). A nonexistent intent id 404s at Stripe, _request_async croaks (Stripe.pm:50-65), the promise rejects, and _record_retrieval_failure (Payment.pm:245-250) sets status='failed' and save()s unconditionally — bypassing the ownership/amount guards in _apply_intent (Payment.pm:279-300), which only run on the resolve branch and are explicitly commented as preventing exactly this flip. No CHECK constraint or trigger on payments.status (sql/deploy/payments.sql), and no test covers it.

Two secondary claims are overstated:
1. The double-charge corollary is weaker than stated. After the flip, a resubmit with an UNCHANGED cart reuses the row along with its existing idempotency_token (WorkflowSteps/Payment.pm:143-180), so Stripe replays the same already-succeeded intent — no second charge. A genuine double charge additionally requires the cart total to change, which rotates the token (lines 169-178) and mints a new intent while the first is already captured.
2. The retrieval-failure result carries no intent_status, so _settle_callback falls into the "surface the failure without minting a replacement charge" branch (WorkflowSteps/Payment.pm:293-300); that path does not itself create a retry intent.

Minor: refund_async's message is "Payment must be completed before refunding" (Payment.pm:557), not "Cannot refund non-completed payment" (that is refund at Payment.pm:434). Both gate on status eq 'completed', so the impact is as described.

Severity nuance: the run UUID is a v4 UUID and must be known, so this is not mass-exploitable — but it needs no session or CSRF token, and the same code path fires with no attacker at all whenever the Stripe retrieval on the return leg errors or times out (30s request_timeout, Stripe.pm:22), or when a stale intent id from browser history is replayed.

> Verifier correction: The core finding holds; two details need narrowing. (a) The status flip requires the Stripe *retrieve* to fail — an unknown/garbage intent id (HTTP 404 -> croak -> promise rejection) or a transport error/30s timeout. A valid-but-foreign intent id does NOT corrupt the row: the ownership guard at lib/Registry/DAO/Payment.pm:277-286 returns a refusal without mutating status, and that guard is intact. (b) The secondary "cheap trigger for the double-charge" claim is not demonstrated: create_payment does reuse a row whose status ne 'completed' (lib/Registry/DAO/WorkflowSteps/Payment.pm:145), but an identical resubmit keeps the same idempotency_token so Stripe replays the same intent; only an amount change rotates the token, and that branch cancels the superseded intent first. Also, run ids are gen_random_uuid() so this is not enumerable — the caller must already have the URL (the run's own owner always does), though the identical corruption happens with no attacker at all when Stripe's API errors or times out during a legitimate reload of the return URL. Confirmed downstream impact: Payment::refund/refund_async die on non-completed (Payment.pm:434, 557) and PriceOps/PricingRelationships.pm:247,263 sums only status='completed', so a real captured charge drops out of platform usage billing.

### Unauthenticated GET replay of the Stripe return URL re-runs handle_payment_callback, cancelling live intents and rotating the idempotency token

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/lib/Registry/Controller/Workflows.pm:255-259`
- **Dimension:** async-promises | **Votes:** 3/3 upheld

**Mechanism:**

The new gate in get_workflow_run_step dispatches any GET carrying ?payment_intent= into _process_step. Three things stack: (1) lib/Registry.pm:761-769 mounts $w->get('/:run/:step') on the bare router — no require_auth under(); only /teacher, /parent and /admin groups are guarded. (2) get_workflow_run_step has neither of the two guards the POST handler enforces at lines 340-349 (`return ... 201 if $run->completed` and `die "Wrong step expected ..." unless $step->slug eq $self->param('step')`). (3) On the decline branch, _settle_callback (lib/Registry/DAO/WorkflowSteps/Payment.pm:312-322) cancels the current intent, calls rotate_idempotency_token, and mints a brand-new PaymentIntent. So each replay of the return URL is an unauthenticated, unbounded, state-mutating Stripe write. The URL leaks by construction: it is in browser history, in the Referer sent to js.stripe.com, in access logs, and is trivially shareable. Rotating the token also destroys the exact double-charge protection create_payment documents (an identical resubmit is supposed to keep the token so Stripe replays the same intent, at most one charge). The gate is keyed on $step->can('handle_payment_callback'), which also matches Registry::DAO::WorkflowSteps::InstallmentPayment::handle_payment_callback (line 251) — that implementation calls the *synchronous* process_payment (lines 264, 287), which now routes through Registry::Service::Stripe::_await and dies under the daemon's already-running IOLoop.

**Impact:** Anyone holding the return URL can drive Stripe API writes against another family's payment row without logging in: repeatedly cancelling the live intent and minting replacements. Token rotation on each pass removes idempotency protection, so a concurrent legitimate confirm can land on a second intent and double-charge. On the installment step the same URL is a guaranteed 500/hang under the running loop.

**Evidence:**

```
lib/Registry/Controller/Workflows.pm:255-259:
        if ( $step && $step->can('handle_payment_callback')
             && ( my $intent = $self->param('payment_intent') ) ) {
            return $self->_process_step( $run, $step,
                { payment_intent_id => $intent } );
        }

Compare the POST handler, lines 340-349, which does have both guards:
        return $self->render(json => {...}, status => 201) if $run->completed($dao->db);
        die "Wrong step expected ..." unless $step->slug eq $self->param('step');

lib/Registry.pm:761-769 — workflow routes hang off the bare $r router, not a require_auth under().

lib/Registry/DAO/WorkflowSteps/Payment.pm:312-322 — cancel, rotate_idempotency_token, create_payment_intent_async on the decline branch.

lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm:251 handle_payment_callback -> synchronous process_payment at :264 and :287.
```

> Verifier correction: The mechanism holds, but three framing details are off. (a) The POST route is equally unauthenticated (lib/Registry.pm:766), so "unauthenticated" is not GET-specific; the GET-specific gaps are the two missing guards (completed-run, step-position) plus CSRF exemption, which make the GET strictly weaker than the POST. (b) The leak vectors are overstated: both the success and decline branches end in redirect_to($self->url_for), and url_for with no args drops the query string, so the browser is not left on the intent-bearing URL and no page rendered from it sends a Referer to js.stripe.com. Realistic vectors are server/proxy access logs, browser redirect-chain history, and a copied or shared link; the run id is an unguessable UUID, so possession of the URL is required -- this is not a mass, blind attack. (c) "Unbounded" is capped by the 100 req/min/IP limiter (lib/Registry.pm:556-560), which is not a real mitigation but does bound the rate. The double-charge outcome is a plausible race rather than a guarantee; the guaranteed outcomes are unauthenticated state-mutating Stripe writes (cancel + create), idempotency-token rotation, and demotion of a completed payment row to 'failed' with a live orphan intent left behind.

> Verifier correction: The mechanism holds; three sub-claims are overstated and should be narrowed.

1. Reachability is a capability URL, not an open endpoint. The attacker needs the run UUID. The Referer-to-js.stripe.com vector is weak: modern browsers default to strict-origin-when-cross-origin and send only the origin, not the path. The real triggers are the parent's own refresh/back on the return URL, browser history, access logs, and shared URLs -- which is enough, since no attacker is required for the self-inflicted case.

2. Double-charge needs the best-effort cancel to fail. Payment.pm:311-314 swallows the cancel rejection (`->catch(sub {})`). If the cancel succeeds the superseded intent is dead and no second charge is possible. The double-charge window is real but narrower than stated: it requires a transient cancel failure leaving two live intents with distinct idempotency keys.

3. The InstallmentPayment leg is dead code. `grep -rl InstallmentPayment` over workflows/ returns nothing -- no workflow YAML wires Registry::DAO::WorkflowSteps::InstallmentPayment into a step, so no route instantiates it. The _await analysis is correct in principle (Registry/Service/Stripe.pm:241-252 dies when the promise does not settle, and Mojo::Promise::wait no-ops under a running loop) but is currently unreachable.

Also: the finding cites two missing POST guards. Only one is material. The `die "Wrong step expected"` check is vacuous on the GET path because $step is looked up by the URL slug, so slug equality is trivially true. The guard that actually matters is `$run->completed` plus the POST's use of `$run->next_step`.

Missed, and worse than what was reported: _record_retrieval_failure (lib/Registry/DAO/Payment.pm:245-250) runs as the rejection handler of retrieve_payment_intent_async, i.e. before _apply_intent's ownership check. An unauthenticated GET with a garbage ?payment_intent= sets status='failed' on the payment row unconditionally. On an already-completed payment this corrupts the money record and permanently blocks refunds (refund_async, Payment.pm:557, dies unless status eq 'completed').

> Verifier correction: The core finding holds. Three sub-claims are over-reach and should be trimmed before it is written up: (1) "unbounded" is capped by the global rate limiter at lib/Registry.pm:574-578 (~100 req/min per IP) -- practically unlimited but not literally unbounded. (2) The InstallmentPayment leg is latent, not live: `grep -rn InstallmentPayment workflows/ lib/` matches nothing outside lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm, and step classes are inflated from the DB `class` column seeded by workflow YAML (WorkflowStep.pm:70-85), so no workflow instantiates it. Its synchronous process_payment -> Service/Stripe.pm:241-252 _await death is a future hazard, not a reachable 500 today. (3) The double-charge framing is better stated concretely than as a concurrency race: the deterministic harm on a single replay against an already-completed payment is P.status flipped 'completed'->'failed' (Payment.pm:314-317) plus a fresh live PaymentIntent and client_secret handed back to the run, which is itself the double-charge setup -- no concurrent confirm required.

### cancel_payment_intent_async failures are swallowed with an empty catch, then a replacement intent is minted anyway

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/lib/Registry/DAO/WorkflowSteps/Payment.pm:171-178`
- **Dimension:** async-promises | **Votes:** 3/3 upheld

**Mechanism:**

Both cancel sites use `->catch(sub ($cancel_err) { })` — an empty block that discards every failure class, including Stripe's 'You cannot cancel this PaymentIntent because it has a status of succeeded'. Control then proceeds unconditionally to rotate the token and create a replacement intent. The only guard is `$existing->status ne 'completed'` at line 145, and that status is a *local* column that only becomes 'completed' when the return-GET or the webhook lands. During the gap between Stripe capturing I1 and Registry learning about it, a resubmit with a changed cart: cancels I1 (fails, error swallowed), rewrites the payment row's amount, rotates the token, and creates I2 against the new amount. I2 captures too. Then the payment_intent.succeeded webhook for I1 arrives and hits the new amount check at lib/Registry/Controller/Webhooks.pm:127-133, which dies because $intent->{amount} no longer equals _to_cents($payment->amount) — and dying releases the dedup claim, so every redelivery of that event dies the same way forever.

**Impact:** Two real captures against one payment row, and the first capture's webhook can never reconcile — the money is taken, no enrollment is created for it, and the event retries until Stripe gives up. Nothing is logged at the cancel site to point at the cause because the catch body is empty.

**Evidence:**

```
lib/Registry/DAO/WorkflowSteps/Payment.pm:171-178:
            if (my $old_intent = $payment->stripe_payment_intent_id) {
                $supersede = $payment->stripe_client
                    ->cancel_payment_intent_async($old_intent)
                    ->catch(sub ($cancel_err) { });
            }

and the second site, :312-316:
        my $cancel = Mojo::Promise->resolve;
        if (my $old_intent = $payment->stripe_payment_intent_id) {
            $cancel = $payment->stripe_client->cancel_payment_intent_async($old_intent)
                ->catch(sub ($cancel_err) { });   # already settled/canceled is fine
        }

Guard at :145: `if ($existing && $existing->status ne 'completed') {`

lib/Registry/Controller/Webhooks.pm:127-133 dies on the amount mismatch, releasing the dedup claim.
```

> Verifier correction: Three corrections, none of which break the finding. (a) Order is rotate-then-cancel (line 170 before 175-176), not cancel-then-rotate; immaterial to the mechanism. (b) The second cancel site at :312-316 is benign: it is only reached when intent_status is 'requires_payment_method' or 'canceled' (guard at :294-303), never a captured intent, so it cannot mint a second live intent over a capture. The high severity rests entirely on the site-1 path at :169-177. (c) "no enrollment is created for it" is loose — the new cart's enrollment IS created once I2 settles; the accurate statement is that the first capture is a duplicate charge that buys nothing and whose webhook can never reconcile. Also, the preconditions are narrower than the report implies: I1 must be captured while the row is still non-'completed' (browser never returned from confirmPayment, and the webhook has not yet landed — or webhooks are entirely down, e.g. STRIPE_WEBHOOK_SECRET unset makes Webhooks.pm:17-21 500 every delivery, which widens the window indefinitely) AND the recalculated total must differ.

> Verifier correction: Two refinements. (a) The second cancel site (Payment.pm:312-316) is NOT exploitable by this mechanism: it is only reached after the early return at :293 (unless intent_status is requires_payment_method or canceled), so the intent there is never 'succeeded'. Only the create_payment site at :171-178 can swallow a cancel-a-captured-intent error; that is where the fix belongs. (b) The race window is wider than the finding states: _apply_intent (lib/Registry/DAO/Payment.pm:309-313) sets status='processing' for delayed-settlement intents, which also passes the ne 'completed' guard, and Stripe refuses to cancel a processing intent too -- so the same swallow-and-mint applies to a payment legitimately in flight for hours, not only during the seconds-long capture-to-webhook gap. Note also that the double capture requires the parent to actively confirm the second intent; it is not an unattended double-charge, but the first capture is then unreconcilable and the I1 webhook event fails until Stripe gives up. The comment at :172-173 explicitly treats 'already-settled' as ignorable -- already-canceled is ignorable, already-settled must abort the mint.

> Verifier correction: Two details of the reported narrative are wrong, but they do not save the code.

1. The stated trigger — "a resubmit with a changed cart" at site 1 (Payment.pm:145-176) — is NOT reachable through the UI. `process_workflow_run_step` (lib/Registry/Controller/Workflows.pm:345-349) computes `$step = $run->next_step` and dies "Wrong step expected payment" unless the POSTed slug matches, so once the run has advanced past session-selection the parent cannot re-POST it; the payment step never merges form params into run data (WorkflowRun.pm:106-167 persists only step-result keys), so `children`/`session_selections` are frozen. The m4 test at t/dao/payment-idempotency.t:485-543 only reaches that branch by calling `$run->update_data` directly, which no request can do. Site 1's amount-change branch therefore fires only if server-side pricing changes between two agreeTerms submits (an admin editing the plan). Note the early-bird path cannot cause it either: PricingPlan.pm:151-166 compares an epoch `time()` against a `YYYYMMDD` integer, so early-bird plans are always past cutoff — a constant, not a crossing.

2. Consequently the "webhook dies forever" tail (Webhooks.pm:127-133 releasing the dedup claim on an amount mismatch — which I confirmed is real code) only applies to that hard-to-reach amount-change variant, not to the reachable one. In the reachable sequence both captures are for the same amount, so the webhook reconciles; the loss is purely the duplicate charge plus the corrupted row.

The finding's core claim — empty catch swallows the cancel failure and a replacement confirmable intent is minted anyway, producing two real captures against one payment row — holds, at Payment.pm:312-320 (and identically at :171-178). The right fix is to inspect the cancel failure (or retrieve the intent) and refuse to mint a replacement when the current intent is `succeeded`/`processing`, plus a status guard in `handle_payment_callback` so a stale intent id cannot re-open a completed payment.

### Payment step 'stay' render puts client_secret/show_stripe_form in the wrong stash shape, so the card form never appears after the first submit

**FIXED** -- same defect as blocker 2, reported by a second dimension. Fixed in
the step (`_render_data`), not the controller: 52 of the 57
`prepare_template_data` implementations return flat data, so the controller's
flat splat is right for the majority and only this step disagreed with it.

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/lib/Registry/Controller/Workflows.pm:444-447`
- **Dimension:** async-promises | **Votes:** 3/3 upheld

**Mechanism:**

prepare_template_data returns `{ step_data => { %$step_data, %$retry_state } }` (lib/Registry/DAO/WorkflowSteps/Payment.pm:80-90), and the template reads only stash('step_data') (templates/summer-camp-registration/payment.html.ep:4-7). But _render_step_result flat-merges the step's own template_data as *sibling* stash keys alongside step_data, so client_secret and show_stripe_form land at the top level where the template never looks. On the first agreeTerms POST the run's payment_retry_state is still empty, so step_data is just { total, items, stripe_publishable_key } and the page re-renders the agreement form instead of mounting the Stripe Payment Element. The retry path works only by accident, because retry data is routed through payment_retry_state into step_data. This shape predates the PR (verified with `git show 8799cde:`), but the PR's stated purpose is making the money path work end to end, and the promise/stay branch it introduces is exactly the code path that must deliver the client secret to the browser.

**Impact:** After agreeing to terms the parent sees the same agreement form again with no way to enter a card — the money path dead-ends on first attempt. Meanwhile the server has already created a live PaymentIntent, so Stripe accumulates abandoned intents. Only the Playwright smoke test would catch it, and that spec self-skips without STRIPE_SECRET_KEY.

**Evidence:**

```
lib/Registry/Controller/Workflows.pm:444-447:
            my $template_data = {
                %{ $step->prepare_template_data($dao->db, $run) },
                %{ $result->{template_data} || {} },
            };

lib/Registry/DAO/WorkflowSteps/Payment.pm:80-90 returns the nested shape:
        my $retry_state = $run->data->{payment_retry_state} || {};
        return { step_data => { %$step_data, %$retry_state } };

templates/summer-camp-registration/payment.html.ep:4-7 reads only stash('step_data').

t/playwright/payment-smoke.spec.js:116 is the only check: `await registryPage.waitForSelector('#payment-element iframe', { timeout: 30000 });` — behind `test.skip(!process.env.STRIPE_SECRET_KEY, ...)` at :52.

(Determined by reading, not by running — per the read-only constraint.)
```

> Verifier correction: The mechanism is confirmed; two details in the impact statement are slightly off. (a) Stripe does not accumulate a new abandoned PaymentIntent per resubmit: because the payment row is reused and the idempotency token is only rotated when the amount changes (Payment.pm:140-180), an identical resubmit replays the SAME intent — so it is one stranded intent per run, not a growing pile. (b) The same flat-shape defect also silences the two `processing` branches (Payment.pm:260-268 and 279-287), so "Payment is being processed" / "requires additional verification" messages never reach the page either — this widens the bug rather than narrowing it.

> Verifier correction: Finding confirmed as written. Two refinements worth carrying forward:

(a) It is not only the first agreeTerms POST. The same flat merge breaks the `processing` and `requires_action` branches of `_settle_callback` (lib/Registry/DAO/WorkflowSteps/Payment.pm, both return `{ next_step => $self->id, data => { ..., processing => 1, message => ... } }` with no `errors` key, so they also take the stay path). Those branches are reached through the GET return leg this PR adds (Workflows.pm:254-258), so a parent whose card is mid-3DS or still processing gets the terms-agreement form back instead of the "Payment is being processed" banner — a genuinely new-in-this-PR instance of the bug. Re-submitting from there does not double-charge (the payment row is reused and the idempotency token is unchanged, so Stripe replays the same intent), so the damage is confusion plus abandoned intents, not a duplicate charge.

(b) Nothing catches it: the only assertion on the rendered card form is t/playwright/payment-smoke.spec.js:116, and .github/workflows/stripe-e2e.yml:83 and :91 both set `continue-on-error: true`, so that job is informational. t/user-journeys/alex/02-activate-and-collect.t:436-437 POSTs agreeTerms through the controller with Stripe intercepted and asserts only `status_is(200)` — it would pass unchanged with the card form completely absent from the body. That test is worth strengthening with a `content_like(qr/cs_journey/)` (or `#payment-element`) assertion; it is the cheapest non-Stripe regression guard for this exact path.

The smallest fix is at the merge site (Workflows.pm:444-447): fold `$result->{template_data}` into the nested `step_data` key rather than splatting it as siblings, e.g. merge `template_data` into `$td->{step_data}` when the step's `prepare_template_data` returned a `step_data` key. Fixing it in the controller covers both the POST stay path and the GET return leg's processing branches at once.

> Verifier correction: Two small corrections to the finding, neither of which changes the verdict. (a) "Stripe accumulates abandoned intents" is overstated: with an unchanged cart the idempotency token is preserved on resubmit, so Stripe replays the SAME intent — the result is one abandoned requires_payment_method intent per run, not an accumulating pile. (b) The finding is right that the stay-branch shape predates the PR (git show 8799cde confirms the merge at Workflows.pm and Payment::prepare_template_data both pre-existed); the PR only moved the block into _render_step_result and added the promise branch. It is still in scope as a money-path blocker because the PR's whole purpose is making paid enrollment work end to end, and this is the exact code path that must hand the client secret to the browser. Also worth noting for the fix: the natural minimal repair is to route the first-submit client_secret through the same channel the retry path already uses (persist it as payment_retry_state, or nest create_payment's data under step_data), since the retry path only works because prepare_template_data folds payment_retry_state into step_data.

### I3 'declined card creates no enrollment' never invokes the production decline path -- two of its three assertions are vacuously true

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/t/stripe-live/paid-enrollment.t:343`
- **Dimension:** test-integrity | **Votes:** 3/3 upheld

**Mechanism:**

1. The subtest creates a real PaymentIntent through the step, then confirms it DIRECTLY against Stripe with Test::Registry::StripeConfirm::confirm($pi_id3, 'pm_card_visa_chargeDeclined') (line 357).
2. It never calls handle_payment_callback, process_payment_async, or the webhook. No Registry code ever observes the decline.
3. Therefore `is $enr3_count, 0` (line 363) and `isnt $pay3_fresh->status, 'completed'` (line 366) assert that code which was never executed did not write rows. They are true by construction.
4. Mutation test: delete the entire decline branch of _settle_callback, or make it mark the payment 'completed' and call finalize_enrollment on a card_declined error. I3 still passes -- nothing in it runs that branch. Only `like $decline_err, qr/card_declined/` has any content, and that assertion is about Stripe's API, not about Registry.

**Impact:** The suite advertises coverage of the declined-card path on the file's headline invariant list. It has none. A regression that finalizes an enrollment on a declined card -- delivering a program seat for a charge that never captured -- passes I3 green.

**Evidence:**

```
t/stripe-live/paid-enrollment.t:356-367:
    my $decline_err = '';
    eval { Test::Registry::StripeConfirm::confirm($pi_id3, 'pm_card_visa_chargeDeclined') };
    $decline_err = $@;

    like $decline_err, qr/card_declined/,
        'I3: confirm with chargeDeclined card dies with card_declined';

    my $enr3_count = scalar @{ $tdb->select('enrollments', '*', { payment_id => $pay3->id })->hashes };
    is $enr3_count, 0, 'I3: no enrollment created for declined card';

    my $pay3_fresh = Registry::DAO::Payment->find($tdb, { id => $pay3->id });
    isnt $pay3_fresh->status, 'completed',
```

> Verifier correction: The mechanism is confirmed as described. Two refinements to the wording: (1) the two post-decline assertions are vacuous with respect to the decline specifically, not literally impossible to fail — they would catch a regression where create_payment itself enrolled or completed the payment at intent-creation time; (2) the claim "The suite advertises coverage of the declined-card path. It has none" is accurate for the real-Stripe suite, but the repo is not fully unprotected: t/dao/payment-failure-recovery.t:97-150 exercises handle_payment_callback → _settle_callback's requires_payment_method branch with Test::MockObject and asserts the retry client_secret, error message, and persisted payment_retry_state. That is mocked unit coverage, so the specific gap is that no test drives Registry's decline handling with a real Stripe decline; severity is better placed at medium than high.

> Verifier correction: The core claim holds; three details in the write-up need adjusting.

1. Assertion count: the subtest has six assertions, not three (`isa_ok` inside `process_payment_step` at :188, `ok !$result3->{errors}` :348, `like $pi_id3` :353, `like $decline_err` :359, plus the two at :363 and :367). The finding's "two of its three" should read "the two post-decline state assertions".

2. "Vacuously true" is slightly too strong. :363 and :367 are not content-free — together they prove that creating a real Stripe PaymentIntent through the step neither writes an enrollment row nor marks the payment completed (i.e. no eager seat allocation before capture). That is a genuine, if weak, invariant that no other subtest in the file asserts. What they prove nothing about is the decline: nothing observed it, so the labels "for declined card" / "after decline" are false advertising, not the assertions themselves.

3. Severity should be medium, not high. The impact line — "a regression that finalizes an enrollment on a declined card passes I3 green" — is true of I3 in isolation but not of the repo. /home/perigrin/dev/Registry/.claude/worktrees/main/t/dao/payment-failure-recovery.t drives the real `_settle_callback` decline branch, and because its Test::MockObject payment does not stub `finalize_enrollment` while `settle()` (t/lib/Test/Registry/Async.pm:19-32) re-dies on rejection, that exact mutation would blow up there. The residual gap is real but narrower: no test anywhere asserts that a decline leaves zero enrollment rows and a non-completed payment, and the live suite's headline "invariants I1-I7" (paid-enrollment.t:1) overstates what I3 covers.

Minimal fix, if wanted: in I3, after the direct confirm, feed the declined intent back through production — `settle($step3->handle_payment_callback($tdb, $run3, { payment_intent_id => $pi_id3 }))` — then keep the existing :363/:367 assertions. They become load-bearing at that point and the retry-intent path gets real-Stripe coverage for free.

> Verifier correction: Two scoping corrections, neither of which rescues I3. (1) The two post-decline assertions are not literally content-free: they weakly pin that the CREATE branch does not pre-create an enrollment or pre-mark the payment completed for a fresh payment row. They carry zero information about decline handling, which is what the subtest name and the I1-I7 headline claim. (2) The decline branch is not untested globally - t/dao/payment-failure-recovery.t:97-150 and t/dao/payment-idempotency.t:380-423 exercise _settle_callback's retry path, but both hand-feed {intent_status=>'requires_payment_method'} or a stub intent hash, bypassing the real Stripe transport. So the one thing only a live test can prove - that a genuinely declined Stripe intent retrieves in the shape _apply_intent maps to success=0/requires_payment_method - is covered nowhere. Severity high is defensible; the live-suite blindness is real even though a stubbed unit test would catch some (not all) mutations. Fix is two lines: after the eval, settle($step3->process($tdb, { payment_intent_id => $pi_id3 }, $run3)) and assert errors, data->{show_stripe_form}, a distinct rotated pi_ id, and payments.status eq 'failed'.

### The webhook dedup-claim release is asserted by a comment, not by the test -- the retry uses a different event id

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/t/controller/payment-intent-webhook.t:150`
- **Dimension:** test-integrity | **Votes:** 3/3 upheld

**Mechanism:**

1. Webhooks.pm:85 releases the dedup claim on failure: `$dao->db->delete('registry.webhook_events', { stripe_event_id => $event_id });`. This is what lets Stripe's retry of the SAME event id reprocess after a transient failure.
2. The test posts a mismatched-amount event as 'evt_pi_amt_bad' and asserts 500 (line 150).
3. The comment on line 155 says 'The failed event's claim was released', but line 157 posts 'evt_pi_amt_good' -- a DIFFERENT event id. A fresh id takes the insert path regardless of whether the failed claim was ever deleted.
4. Mutation test: delete line 85 of Webhooks.pm entirely. Both assertions still pass; nothing in the file re-posts a previously-failed event id.

**Impact:** If the release is ever dropped or scoped wrong, the first delivery of a payment_intent.succeeded that fails for a transient reason (row not yet visible, tenant schema lag) permanently poisons that event id. Stripe retries, the dedup ledger absorbs the retry at 200, and the payment is captured with no enrollment ever finalized -- money taken, seat never delivered, and Stripe stops retrying because we answered 200.

**Evidence:**

```
t/controller/payment-intent-webhook.t:149-157:
    post_webhook(pi2_event('evt_pi_amt_bad', 12345))->status_is(500);
    ...
    # The failed event's claim was released, and a matching delivery (Stripe
    ...
    post_webhook(pi2_event('evt_pi_amt_good', 10000))->status_is(200);
lib/Registry/Controller/Webhooks.pm:85:
            $dao->db->delete('registry.webhook_events', { stripe_event_id => $event_id });
```

> Verifier correction: Substance confirmed; only the framing needs narrowing. The rest of the subtest is not vacuous — t/controller/payment-intent-webhook.t:151 (`is p2_enrollments(), 0`) does genuinely pin the new amount check at lib/Registry/Controller/Webhooks.pm:127-133, since without that check the mismatched event would have created an enrollment. Likewise :153 and :158/:160 are real assertions. What is asserted by prose only is specifically the dedup-claim release at Webhooks.pm:85; the comment at t/controller/payment-intent-webhook.t:155 is explanatory narrative rather than a verified claim, and no test in the repository (not just this file) ever re-delivers an event id that previously failed.

> Verifier correction: The finding's mechanism is right, but two scope points should be corrected. (a) The release line is NOT introduced by this PR: git diff <base>..HEAD -- lib/Registry/Controller/Webhooks.pm contains a single hunk, the amount check. Webhooks.pm:85 predates the branch. So this is a missing regression test around pre-existing behavior, not a newly introduced production bug; what is new (commit 121d9fc, +51 lines to the test) is the amount-mismatch subtest and the die path that now depends on the release for its retry story. (b) The subtest's own name -- 'amount mismatch fails loudly and does not finalize (Leg W1)' -- IS fully asserted (500, zero enrollments, status not completed); the unasserted claim is confined to the prose at :155, whose parenthetical ("or the true intent's event") does accurately describe the different-id case actually exercised. So it is assertion-by-comment plus a coverage gap, not a mislabeled subtest. Consequently 'high' severity is generous: the money-loss impact described is the consequence of a hypothetical future regression, not of current code. The one-line close is to re-post the same failed id (a retained claim would answer 200 instead of 500) or assert the webhook_events row for 'evt_pi_amt_bad' is gone.

> Verifier correction: The mechanism is exactly as described, but severity is medium, not high: the production release at Webhooks.pm:85 is present and correct today, so no money is currently at risk. The impact narrative (poisoned event id -> Stripe retry absorbed at 200 -> charge captured, enrollment never finalized, retries stop) is conditional on that line regressing. This is an uncovered invariant on a money path, not a live bug. Also, the comment at t:155-156 is wrong on a second count the report did not name: the failure it induces (amount mismatch) can never "heal", so even with the release intact a retry of evt_pi_amt_bad would fail permanently -- the retryable failure the release actually exists for is the "payment not found in tenant schema" die at Webhooks.pm:117.

### The stripe-e2e Playwright step can never touch Stripe: globalSetup deletes the Stripe keys from the app server's env, so a paid enrollment silently takes the free path

- **Location:** `t/playwright/global-setup.js:76`
- **Dimension:** ci-secrets | **Votes:** 3/3 upheld

**Mechanism:**

stripe-e2e.yml sets STRIPE_SECRET_KEY/STRIPE_PUBLISHABLE_KEY as job-level env (lines 23-29) and runs `npx playwright test t/playwright/payment-smoke.spec.js` (lines 90-93). payment-smoke.spec.js drives the shared server started by t/playwright/global-setup.js, which builds that server's env with `delete env.STRIPE_SECRET_KEY; delete env.STRIPE_PUBLISHABLE_KEY;`. So the runner process has the keys (spec does not self-skip, seed script talks to Stripe) but the *server under test* has none. In lib/Registry/DAO/WorkflowSteps/Payment.pm:47 the gate is `if (($info->{total} // 0) == 0 || !$ENV{STRIPE_SECRET_KEY}) { return $self->create_demo_enrollments(...) }` -- a $150 total with no key falls through to create_demo_enrollments, which calls Enrollment->enroll_children and writes `status => 'active'` with no charge. The spec then times out at step 6 waiting for `#payment-element iframe` (never rendered, stripe_publishable_key is undef). Both `continue-on-error: true` steps mean the job still reports PASS. Net: even after the repo secrets are configured, the only browser-level proof that money moves is structurally incapable of passing, and CI will stay green either way.

**Impact:** The headline artifact of this PR -- an end-to-end proof that a real card charge produces a real enrollment -- cannot run at all. Configuring the secrets will not fix it. Whoever configures them will see the same green job and conclude the money path is verified.

**Evidence:**

```
global-setup.js:70-79: `// Unset Stripe keys so payment steps take the test-mode (no-Stripe) mock\n      // path instead of attempting real Stripe API calls...\n      delete env.STRIPE_SECRET_KEY;\n      delete env.STRIPE_PUBLISHABLE_KEY;`  //  Payment.pm:47: `if (($info->{total} // 0) == 0 || !$ENV{STRIPE_SECRET_KEY}) {\n            return $self->create_demo_enrollments($db, $run, $form_data);`  //  stripe-e2e.yml:90-93: `- name: Run Playwright payment smoke test\n      continue-on-error: true\n      run: |\n        npx playwright test t/playwright/payment-smoke.spec.js --project=chromium`
```

> Verifier correction: The mechanism holds, with three refinements:

(a) The spec does not silently PASS -- it fails at step 6 (waitForSelector on #payment-element iframe) and that failure is visible in the uploaded Playwright report. What stays green is the JOB, because of `continue-on-error: true` on stripe-e2e.yml lines 83 and 91.

(b) Right now the repo secrets appear to be unset (commit 38bbeb4 "Stop CI claiming to hold a usable Stripe test key"), so GitHub expands them to empty string, the spec's own test.skip at payment-smoke.spec.js:52-55 fires, and the job is green with zero coverage. The finding already scopes its claim correctly to "even after the repo secrets are configured".

(c) global-setup.js is NOT modified by this PR (no diff vs 8799cde); lines 73-77 are pre-existing. The defect is that the PR's new deliverable (payment-smoke.spec.js + the stripe-e2e job) is structurally incompatible with the shared-server setup it runs under, not a regression introduced in global-setup.

Extra corroboration for the "does not assert what it claims" charge: step 10 (payment-smoke.spec.js:165-178) asserts only `COUNT(*) FROM <tenant>.enrollments WHERE ... status='active' > 0`. create_demo_enrollments produces exactly such a row. So even if the iframe wait were removed, the DB assertion could not distinguish a real card charge from the free/demo path -- the spec never asserts on the payments table, a stripe_payment_intent_id, or an amount.

> Verifier correction: Two nuances, neither changing the verdict. (a) global-setup.js is pre-existing and untouched by this PR; the defect is that the PR adds payment-smoke.spec.js and stripe-e2e.yml on top of it without exempting the new spec, so the fix belongs here. (b) The money path is not entirely unproven by CI: the sibling step `carton exec prove -lv t/stripe-live/` (stripe-e2e.yml:80-85) runs in-process in the runner, which does have the keys, so t/stripe-live/paid-enrollment.t can genuinely exercise real Stripe once secrets exist — only the browser-level proof is dead. That step is also continue-on-error, so its failures are equally invisible. Minimal fix: in global-setup.js, keep the keys when an explicit opt-in is set by stripe-e2e.yml (and the key is sk_test_-prefixed), and drop continue-on-error from the smoke step once it can actually pass.

> Verifier correction: Three imprecisions, none of which affect the conclusion: (1) t/playwright/global-setup.js is NOT modified by this PR — `git diff 8799cde..HEAD -- t/playwright/global-setup.js` is empty; the `delete env.STRIPE_SECRET_KEY` predates it (commit 280d49c). What is new here is stripe-e2e.yml and payment-smoke.spec.js aiming a Stripe-requiring spec at that pre-existing setup, so this is a design gap in the new CI wiring, not a regression in global-setup. (2) The delete is lines 76-77, not line 76 alone. (3) The Playwright step itself is rendered as FAILED in the Actions UI; it is the job *conclusion* that stays success because of continue-on-error, so nothing that gates a merge goes red. Also worth adding to the finding: the spec's final psql assertion (payment-smoke.spec.js:165-178) would be SATISFIED by the free path, since Enrollment.pm:107-112 writes status='active' for the same child_id/session_id — so the only thing preventing a green-and-lying test is the `#payment-element iframe` wait at spec:116.

### Webhook-only completion leaves the run replayable: re-submitting the terms form mints a second Stripe charge for an already-paid cart

- **Location:** `lib/Registry/DAO/WorkflowSteps/Payment.pm:145`
- **Dimension:** failure-modes | **Votes:** 3/3 upheld

**Mechanism:**

create_payment reuses the run's existing payment row only when its status is not 'completed' (line 145); a completed row falls through to `unless ($payment)` at line 182 and a brand-new Payment (new idempotency_token, new intent, new charge) is created. That branch is only safe if the run can never be re-POSTed after a completed payment -- and after a webhook-only completion it can. Walk it: (1) parent POSTs agreeTerms; create_payment returns `{next_step => $self->id, ...}`, which WorkflowRun::_persist_step_result treats as a 'stay', so latest_step_id remains on `session-selection`, the step before payment. (2) Parent confirms the card and closes the tab during 3DS (or the return leg 500s -- see the finalize-raise finding). Stripe captures. (3) payment_intent.succeeded arrives; Webhooks.pm:136-142 marks the row completed and creates the enrollment, but never touches the workflow run. (4) Parent reopens /<workflow>/<run>/payment from history. get_workflow_run_step renders the payment form unconditionally -- prepare_payment_data always returns the full total and the template has no 'already paid' branch. (5) They tick the box again. process_workflow_run_step computes $run->next_step, which is still `payment` (latest_step_id never advanced), so the slug guard passes, create_payment sees the completed row and charges again. The second charge then cannot deliver anything: finalize_enrollment for payment2 hits enrollments_session_student_type_unique (the dedup arbiter only covers (session, student, payment_id), and payment_id differs) and raises.

**Impact:** Parent is charged twice for one enrollment. The second charge produces no enrollment (hard unique-constraint failure), no refund, and no operator alert -- just a 500 and a webhook that retry-fails until Stripe gives up. This is the exact 'closed the tab during confirmPayment' path the webhook safety net was added for, and no test covers what happens when the parent comes back afterwards.

**Evidence:**

```
lib/Registry/DAO/WorkflowSteps/Payment.pm:136-145
    # ponytail: reuse check; completed payments start a new row (second purchase)
    my $existing_payment_id = $run->data->{payment_id};
    ...
        if ($existing && $existing->status ne 'completed') {

t/dao/payment-idempotency.t:437-463 blesses precisely this behaviour and cannot tell a resubmit from a genuine second purchase:
    subtest 'B3-fix m1: completed payment starts a NEW row (second purchase)' => sub {
        settle($step->process($b3db, { agreeTerms => 1 }, $run));
        my $first = $run->data->{payment_id};
        $b3db->update('payments', { status => 'completed' }, { id => $first });
        settle($step->process($b3db, { agreeTerms => 1 }, $run));
        isnt $second, $first, 'completed row is NOT reused (second purchase)';

lib/Registry/Controller/Webhooks.pm:136-142 -- the webhook advances the payment row and the enrollments, never the run.
```

> Verifier correction: Two wording-level corrections, neither of which changes the outcome. (a) The re-POST does not by itself "mint a second Stripe charge" -- create_payment creates a second PaymentIntent and re-renders a payable Stripe Elements form showing the full total with no indication the cart is already paid. The second capture requires the parent to enter card details once more, which the page actively invites (button reads "Pay $<total>"). (b) "No operator alert" is approximate: the failure does produce an app->log->error line at Workflows.pm:394 and a 500 on the webhook (Webhooks.pm:86-87), which releases the dedup claim so Stripe retries until it gives up -- but there is no refund and no alerting beyond logs. Everything else in the finding, including the enrollments_session_student_type_unique failure for the second payment, is accurate.

> Verifier correction: Two precisions, neither of which refutes the finding. (a) Re-submitting the terms form does not by itself capture money: it mints a second confirmable PaymentIntent and re-renders the Stripe Elements card form. The parent must enter a card and confirm again for the second capture to happen — which is exactly the scenario's premise (they believe the first attempt failed). The title should read "mints a second confirmable intent and re-presents the pay form" rather than "mints a second Stripe charge". (b) The completed->new-row branch is new in this PR (the base commit 8799cde had no reuse logic at all and created a payment row on every submit), so this is a residual hole in new code rather than a pre-existing behaviour, and it is deliberately documented at lib/Registry/DAO/WorkflowSteps/Payment.pm:136.

> Verifier correction: The mechanism holds, with one precision fix: the resubmitted terms form mints a second PaymentIntent, not a second charge on its own. The actual double charge needs the parent to re-enter a card and press "Pay $X" on the freshly rendered Elements form — which is exactly what the page invites, since it shows the full unpaid total with no indication the cart already settled. Two smaller refinements: the entry point does not require browser history — _find_or_create_run (lib/Registry/Controller/Workflows.pm:109-126) resumes the same run because it is not `completed`, dropping the parent back on session-selection and then forward to payment; and the second charge's failure to deliver depends on the cart being unchanged (same session/child pair). If the parent alters the selection first, the second charge enrolls a different session instead of raising — money still taken twice for a cart already paid, different failure shape.

### finalize_enrollment raises after Stripe has captured, and nothing reconciles it: money taken, no enrollment, no alert

- **Location:** `lib/Registry/DAO/Enrollment.pm:95`
- **Dimension:** failure-modes | **Votes:** 3/3 upheld

**Mechanism:**

create_for_payment's named arbiter only absorbs (session_id, student_id, payment_id) conflicts. Any other unique violation -- notably enrollments_session_student_type_unique (session_id, student_id, student_type), which is status-blind -- now raises. That fires whenever a parent re-registers a child for a session they previously dropped (drop cancels the row in place, it is never deleted). By the time finalize_enrollment runs, Stripe has already captured. Both finalization paths then dead-end: (a) browser return leg -- Payment::_apply_intent saves status='completed' at line 306 BEFORE _settle_callback calls finalize_enrollment, so the row is marked paid, the insert raises, the promise rejects, and Workflows::_process_step renders a bare 500 'Workflow error'; (b) webhook -- Webhooks.pm:83-88 catches, deletes the dedup claim, returns 500 so Stripe retries, and every retry hits the identical constraint. After ~3 days Stripe stops retrying. The payment row is left status='completed' with zero enrollment rows, and the only signal is log noise. There is no queue, no flag, no refund, no operator notification.

**Impact:** Charge captured, nothing delivered, permanently. The parent sees an unexplained 500 after paying. Discovery requires a human noticing a completed payment with no enrollment. The PR's own test acknowledges this ('the raise is the only signal') without wiring any signal.

**Evidence:**

```
lib/Registry/DAO/Enrollment.pm:95
    on_conflict => \'(session_id, student_id, payment_id) WHERE payment_id IS NOT NULL DO NOTHING'

t/dao/payment-finalization-idempotency.t:93-101
    my $ok = eval { $repay->finalize_enrollment($db); 1 };
    ok !$ok, 'finalize raises instead of dropping the insert on the floor';
    like $err, qr/enrollments_session_student_type_unique/, ...
    is scalar(@$rows), 0, 'no enrollment row for the new payment (the raise is the only signal)';

lib/Registry/DAO/Payment.pm:303-306 (status saved before finalize) and lib/Registry/Controller/Webhooks.pm:83-88 (retry loop that can never succeed).
```

> Verifier correction: The finding is correct and if anything understates the damage in two places. (a) No confirmation email is sent to the parent: create_for_payment raises before Notification->ensure_enrollment_confirmation in Payment.pm:346-370, so the failure is silent rather than actively misleading. The test comment's phrase "and a confirmation email sent anyway" describes the pre-fix swallow scenario, not the current one. (b) It is worse than a one-time dead end: if the parent restarts registration, WorkflowSteps/Payment.pm:141 reuses an existing payment row only `if ($existing && $existing->status ne 'completed')`. The stranded row IS completed, so a brand new payment row and a brand new Stripe intent are minted and the parent is charged again -- into the identical constraint failure. Repeatable double-charge with zero enrollments, not a single lost charge.

> Verifier correction: Two refinements, neither of which weakens the finding.

(a) The trigger is broader than drop-then-re-register. Because MultiChildSessionSelection.pm performs no already-enrolled check, a parent who registers the same child into the same session a second time while the first enrollment is still 'active' hits the same constraint. That variant captures a second charge and delivers nothing, which is worse than the drop case the finding describes.

(b) This is an incomplete fix, not a regression. Before commit 78296d7 the bare ON CONFLICT DO NOTHING swallowed this collision silently (money taken, no enrollment, and a confirmation email sent anyway). The named arbiter correctly turned silent loss into loud failure; what is missing is the second half -- anything that catches the loud failure (retry queue, operator alert, or auto-refund). The test at t/dao/payment-finalization-idempotency.t:93-101 asserts exactly what it claims and is honest that 'the raise is the only signal'; it is not a false-assertion finding.

> Verifier correction: One detail in the finding is wrong but not load-bearing. It frames the trigger as a parent dropping from the dashboard. The route POST /dashboard/drop_enrollment is registered at lib/Registry.pm:670 but Registry::Controller::ParentDashboard has no drop_enrollment method (it defines only index, upcoming_events, recent_attendance, unread_messages_count, _get_dashboard_data), so that specific route is dead. Reachability is nonetheless broader than the finding claims: (a) the parent-drop-request and admin-drop-approval workflows reach the same cancelled-in-place state via DropRequest->approve; and (b) no drop is required at all -- an existing ACTIVE enrollment for the same (session_id, student_id, student_type) collides identically, so a parent who simply registers and pays for the same child/session twice (e.g. after a missing confirmation email) hits the same raise and is double-charged with no second enrollment.

## MEDIUM (10)

### GET dispatch omits both guards the POST path has: no run-completed check and no check that payment is the run's current step

- **Location:** `lib/Registry/Controller/Workflows.pm:255`
- **Dimension:** b4-callback-auth | **Votes:** 2/3 upheld

**Mechanism:**

`$step` is resolved purely from the URL slug at Workflows.pm:237-243, and falls back to `$run->latest_step` when the slug does not exist in the workflow. The new block then dispatches on nothing more than `$step->can('handle_payment_callback')` plus a non-empty `payment_intent` param. Compare process_workflow_run_step (Workflows.pm:330-349), which refuses a completed run and dies unless `$step->slug eq $self->param('step')` where $step came from `$run->next_step`. Consequences: (a) a run already advanced to `complete` still re-enters the payment step — that is what makes finding #1 reachable after the money has settled; (b) a run that never reached payment (`$run->data->{payment_id}` absent) hits `die "No payment_id in workflow data"` (WorkflowSteps/Payment.pm:237) synchronously inside `$run->process`, outside any eval — an unhandled 500 on an unauthenticated GET for any known run id; (c) because of the `$step ||= $run->latest_step` fallback, a garbage step slug (`/<run>/zzz?payment_intent=...`) also dispatches whenever the run sits on payment, and _render_step_result then builds its redirect URL from `$self->param('step')` — the garbage slug.

**Impact:** Extends the window for the status-flip above from 'while the run is parked on payment' (the pre-PR POST-only reachability) to 'forever, at any run position'. Also a trivially reachable unauthenticated 500.

**Evidence:**

```
lib/Registry/Controller/Workflows.pm:255-259
        if ( $step && $step->can('handle_payment_callback')
             && ( my $intent = $self->param('payment_intent') ) ) {
            return $self->_process_step( $run, $step,
                { payment_intent_id => $intent } );
        }

versus lib/Registry/Controller/Workflows.pm:340-349
        if ( $run->completed( $dao->db ) ) {
            return $self->render( text => 'DONE', status => 201 );
        }
        my ($step) = $run->next_step( $dao->db );
        die "No step found" unless $step;
        die "Wrong step expected ${\$step->slug}"
          unless $step->slug eq $self->param('step');
```

> Verifier correction: Finding stands. Two details need narrowing: (1) sub-claim (c) — the garbage-slug fallback only dispatches once latest_step IS the payment step, which happens after the successful callback advances the pointer, not while the parent is parked on the payment form (the page-view/create_payment branches return `next_step => $self->id`, a stay, so WorkflowRun::_persist_step_result:117 does not advance latest_step_id). (2) `_render_step_result` does not build the *advance* redirect from param('step') — it uses url_for(step => $next->slug) at Workflows.pm:487; the garbage slug instead lands in the template name on the stay branch (:463) and in redirect_to($self->url_for) on the no-JS error branch (:430). Also worth stating: Payment::_apply_intent (lib/Registry/DAO/Payment.pm:277-301) rejects non-owned intents and amount mismatches without mutating status, so the missing controller guards do not by themselves let an arbitrary caller settle a payment — the reachable harms are the unauthenticated 500 and post-settlement re-entry with the run's own intent id.

> Verifier correction: Accurate part: the new GET dispatch at lib/Registry/Controller/Workflows.pm:255 has no step-currency guard, so a settled payment step can be re-entered on GET where POST refuses it (POST's next_step after payment is `complete`). That is a real guard-parity gap. Everything the finding builds on top of it is wrong or unreachable: (1) the run is never in `completed` state at that point -- `_persist_step_result` sets latest_step_id to the payment step (WorkflowRun.pm:155-158), so the missing completed check is inert; (2) `_render_step_result` redirects with `$self->url_for( step => $next->slug )` at Workflows.pm:489, not the URL slug, so the garbage-slug redirect claim is false; (3) an unauthenticated caller cannot advance anything -- `_apply_intent` (Payment.pm:277-286) rejects a non-owned intent with no status mutation; (4) the die-to-500 is the controller's existing error convention, not a money/security defect. The genuine latent risk is different and smaller than reported: `_apply_intent` has no terminal-status guard, so if refunds are ever wired to a route, replaying the Stripe return URL would flip `refunded` back to `completed`. Worth a one-line status guard in `_apply_intent` before refunds ship; not a live vulnerability in this PR.

> Verifier correction: The finding holds on its core claim (both guards are missing on the GET dispatch), but three details need correcting:

1. Consequence (c)'s redirect claim is wrong on the success path. _render_step_result redirects via `$self->url_for( step => $next->slug )` (Workflows.pm:489), which overrides the placeholder, so a garbage slug does NOT survive into the redirect. The garbage slug only leaks into the template name on the validation-error/stay branches (`$step_slug = $self->param('step')`, :414 and :435), and that behaviour is pre-existing for any bad slug. The dispatch-on-garbage-slug half is real: once latest_step_id is the payment step (post-success), /<run>/zzz?payment_intent=… runs the callback.

2. Consequence (a) is close to moot as written. A summer-camp-registration run essentially never reaches `completed` in the browser flow: after the callback the pointer sits on `payment`, the controller only redirects to GET /complete, and get_workflow_run_step never advances the pointer (templates/summer-camp-registration/complete.html.ep has no form/POST). Reaching `completed` requires a hand-rolled POST to /complete first. The load-bearing omission is the missing current-step check, not the missing run-completed check.

3. Consequence (b) is real but weak and not a new class of bug. GET /summer-camp-registration/<any-run>/payment?payment_intent=x on a run without payment_id does 500 via the unevaled die at WorkflowSteps/Payment.pm:237 (the run id is not even checked against the URL's workflow), but the same handler already 500s pre-PR on a bogus run id without the param.

The impact should be restated: not merely "extends the window for a status flip" plus a 500, but that the GET path lets a superseded/canceled intent id be replayed onto an already-completed payment, flipping it to 'failed' (blocking refunds) and minting a fresh live PaymentIntent for the full amount — a double-charge setup an unlucky parent reaches by revisiting an old Stripe return URL from their failed first attempt.

### _to_cents truncates instead of rounding, undercharging by a cent on ~4.6% of two-decimal amounts and making the receipt disagree with the quoted price

- **Location:** `lib/Registry/DAO/Payment.pm:41`
- **Dimension:** money-units | **Votes:** 3/3 upheld

**Mechanism:**

`sub _to_cents ($dollars) { int($dollars * 100) }`. payments.amount is DECIMAL(10,2) (sql/deploy/payments.sql:10), so Postgres hands back a string like "18.40"; Perl numifies that to the nearest double (18.399999999999998579), multiplies by 100 to 1839.9999999999998, and int() truncates toward zero to 1839. Verified with the interpreter: 8.20 -> 819, 18.40 -> 1839, 0.29 -> 28, 1.15 -> 114, 2.01 -> 200. A sweep of every value from $0.01 to $500.00 gives 2292/50000 = 4.6% truncating one cent low. The dollar total is also what the checkout page renders (templates/summer-camp-registration/payment.html.ep:135 `Pay $<%= $step_data->{total} %>`), so the parent is shown "Pay $18.4" and Stripe charges 1839 = $18.39, while the payments row still says 18.40. The application fee is computed off the truncated base too (application_fee_cents(_to_cents($amount), $fraction)). This PR makes the function newly load-bearing in two more places -- lib/Registry/Controller/Webhooks.pm:128 and the succeeded-branch guard in Payment.pm:296 both do integer equality against _to_cents($amount) -- so any future caller that computes cents by any other method (sprintf, a rounded helper) will silently start failing those equality guards and dying in the webhook. Worked examples: $150.00 @ 2% -> _to_cents 15000, fee int(300.00000000000006+0.5)=300, both correct; $0.99 @ 2.5% -> _to_cents 99, fee int(2.475+0.5)=2, correct; $18.40 @ 2% -> _to_cents 1839 (should be 1840), charge $18.39, fee 37. The half-up rounding in application_fee_cents is correct; only the dollars->cents conversion is wrong. sprintf('%.0f', $dollars*100) or int($dollars*100 + 0.5) fixes it.

**Impact:** Systematic one-cent undercharge on roughly one in twenty enrollments, and a customer-visible mismatch between the price quoted on the payment page, the amount in the payments table, and the amount on the Stripe receipt. Reconciling Stripe against the payments table will never tie out exactly. The truncated base also propagates into the application fee, so the platform's own cut is computed from a number that is not what the row says.

**Evidence:**

```
$ perl -e 'my $s="8.20"; printf "str %s *100 = %.17g int=%d\n", $s, $s*100, int($s*100);'
str 8.20 *100 = 819.99999999999989 int=819
str 18.40 *100 = 1839.9999999999998 int=1839

$ perl -e 'my $bad=0; for my $c (1..50000){ my $d=sprintf("%.2f",$c/100); $bad++ if int($d*100)!=$c } print "$bad of 50000\n"'
2292 of 50000   # 4.6%

lib/Registry/Controller/Webhooks.pm:128 -- `my $row_cents = Registry::DAO::Payment::_to_cents($payment->amount);` ... `if $intent->{amount} != $row_cents;`
```

> Verifier correction: Two refinements, neither of which breaks the finding. First, _to_cents is NOT new in this PR: it exists verbatim at the merge-base (git show 8799cde:lib/Registry/DAO/Payment.pm line 41), along with the intent-creation callers. What the PR adds is the two equality guards (lib/Registry/DAO/Payment.pm:296 and lib/Registry/Controller/Webhooks.pm:128), so this is a pre-existing bug the PR makes more load-bearing, not a regression it introduces. Second, those new guards do not misfire today: intent creation and both guards call the same _to_cents on the same DB-sourced $amount, so they agree and no enrollment currently dead-ends in the webhook (the finding's concern about a future caller using a different conversion is speculative, not an active defect). The live harm is therefore the systematic one-cent undercharge, an application fee computed from a base that disagrees with the payments row, and the quoted-vs-charged-vs-row mismatch that will never reconcile against Stripe. Severity reads closer to low than medium on a per-transaction basis, but it is a genuine money-path correctness bug. The proposed one-line fix in _to_cents (sprintf('%.0f', $dollars*100) or int($dollars*100 + 0.5)) is correct and covers every caller, since all cents conversion routes through that one sub.

> Verifier correction: The finding holds. Three factual corrections that do not change the verdict: (a) _to_cents and the application-fee call site predate the diff base -- confirmed present at 8799cde:lib/Registry/DAO/Payment.pm:41 and :99 -- so this PR did not introduce the truncation, it only adds two new call sites (Payment.pm:296 and Webhooks.pm:128) that make the function more load-bearing; (b) the template line is `Pay $<%= $step_data->{total} || 0 %>` at templates/summer-camp-registration/payment.html.ep:135, not `$step_data->{total}`; (c) the 4.6% figure is over uniformly-distributed two-decimal values, so "roughly one in twenty enrollments" overstates the real-world rate -- common price points such as 99.99, 149.99, 29.99, 49.95, 12.50, 250.00 all convert correctly, though 19.99 (-> 1998) and any multi-child total that lands on an unlucky sum do truncate.

> Verifier correction: Three scope corrections, none of which change the verdict. (1) _to_cents is NOT introduced by this PR -- it already exists verbatim at line 41 of the diff base (8799cde). What the PR adds is two new consumers of it: the succeeded-branch guard at Payment.pm:296 and Webhooks.pm:128. The truncation is pre-existing; this PR is the one that makes it charge real cards. (2) The "one in twenty enrollments" impact figure comes from a uniform sweep of all cent values; the real-world rate depends on the tenant's price list, and several very common endings are exact (0.99, 0.95, 0.50, 0.25, 19.95, 24.99, 89.95 all convert correctly). But it is not a corner case either -- $9.95 -> 994 and $149.95 -> 14994 are both wrong, and those are canonical price points, so a single tenant can be undercharged on 100% of their enrollments. (3) The finding's forward-looking claim that "any future caller that computes cents by any other method will silently start failing those equality guards and dying in the webhook" is speculative, not a present defect -- both sides of both guards route through _to_cents today.

### Money captured with no enrollment and no recovery when the child already has any enrollment row for that session

- **Location:** `lib/Registry/DAO/Enrollment.pm:94-96`
- **Dimension:** idempotency | **Votes:** 3/3 upheld

**Mechanism:**

The named arbiter only covers (session_id, student_id, payment_id). enrollments also carries the status-blind constraint enrollments_session_student_type_unique (session_id, student_id, student_type) (sql/test-schema.sql:2901). A drop sets status='cancelled' in place; nothing deletes the row. So a parent who drops a child and re-registers for the same session pays, Stripe captures, and then create_for_payment raises a unique_violation on the constraint the arbiter does NOT cover.

Both finalizers die on it. The browser return leg surfaces `Workflow error` / 500 (Workflows.pm:394-395). The webhook releases its dedup claim and returns 500 (Webhooks.pm:83-88), so Stripe retries -- into the identical constraint, forever, until Stripe gives up after ~3 days. There is no refund, no alert, no reconciliation job, and no operator-visible signal beyond a log line.

The PR's own test (t/dao/payment-finalization-idempotency.t:75-102) asserts this behavior as intended, so it is deliberate -- but 'raise' was chosen over 'silently swallow' without adding any compensating action, which leaves the fix for B-3 incomplete on the money side.

**Impact:** A real, reachable flow (drop then re-register) charges the parent's card and produces no enrollment, no refund, and an error page. Neither retry path can ever succeed.

**Evidence:**

```
lib/Registry/DAO/Enrollment.pm:94-96:
        $db->insert( $class->table, $data, {
            on_conflict => \'(session_id, student_id, payment_id) WHERE payment_id IS NOT NULL DO NOTHING'
        } );

t/dao/payment-finalization-idempotency.t:96-101:
    ok !$ok, 'finalize raises instead of dropping the insert on the floor';
    like $err, qr/enrollments_session_student_type_unique/, ...
    is scalar(@$rows), 0, 'no enrollment row for the new payment (the raise is the only signal)';
```

> Verifier correction: The finding is correct but understates scope. The collision is not specific to drop-then-re-register: ANY pre-existing enrollment row for that (session_id, child) tuple triggers it, including an 'active' row from an admin/free enrollment or a duplicate registration started in a second workflow run. There is no "already enrolled" guard anywhere in the registration flow -- MultiChildSessionSelection only checks capacity, and it counts status IN ('active','pending'), so a cancelled row is invisible to it. The drop scenario is just the most obvious instance. Also worth noting for triage: the payment row IS durably marked 'completed' with enrollment_items snapshotted in its metadata, so manual recovery is possible -- but nothing automated exists, and both retry paths (browser reload of the return URL, Stripe webhook redelivery) re-enter the identical deterministic violation forever.

> Verifier correction: Mechanism stands; two details are slightly off. (a) The trigger is broader than drop-then-re-register: because session selection has no already-enrolled filter at all, simply registering the same child for the same session a second time (after a first run finalized) hits the identical wall, charging the parent again with no enrollment. (b) 'No operator-visible signal beyond a log line' is overstated: the payment row is left status='completed' with metadata.enrollment_items intact, so completed-payments-with-zero-enrollments is queryable, and Stripe emails the account owner about a persistently failing webhook endpoint. There is still no automated refund, alert, or reconciliation job. Also, characterizing this as strictly worse than before is wrong -- the loud raise is an improvement over the pre-B-3 silent swallow (which took the money and sent a confirmation email anyway); it is an incomplete fix, not a regression.

> Verifier correction: Two understatements, both making it worse rather than better. First, the drop is not required: any pre-existing enrollment row for (session_id, student_id, 'family_member') collides, including a still-active one, so a parent starting a second registration run for an already-enrolled child hits the same wall. Second, the natural user recovery double-charges: after the 500 the payment row is status='completed', and create_payment (lib/Registry/DAO/WorkflowSteps/Payment.pm:180-198) reuses only non-completed rows, so resubmitting agreeTerms mints a fresh payment row and a fresh idempotency token and takes a second real charge — which then dies on the same constraint. Repeat per retry. Also minor: the cited line range is right (lib/Registry/DAO/Enrollment.pm:94-96 is the insert), and the constraint ships in production via sql/deploy/flexible-enrollment-architecture.sql, not just sql/test-schema.sql.

### Webhook dedup claim is committed before processing, so a hard crash mid-finalize permanently swallows the redelivery

- **Location:** `lib/Registry/Controller/Webhooks.pm:45-56`
- **Dimension:** idempotency | **Votes:** 3/3 upheld

**Mechanism:**

The claim `INSERT INTO registry.webhook_events ... ON CONFLICT DO NOTHING` runs on $dao->db in autocommit, and commits immediately. Only the `catch` block (line 83-88) releases it. If the process dies without unwinding to that catch -- SIGKILL, worker restart, OOM, a dropped DB connection between the claim and _process_payment_intent_succeeded, or a deploy mid-request -- the claim row survives and every Stripe redelivery of that event id hits `unless ($claimed)` and is answered 200 'OK (duplicate)' without ever being processed.

The browser-return leg is the only other finalizer, and it does not fire when the parent never comes back -- which is precisely the 3DS/mobile/redirect case the webhook exists to cover. Note also that the claim lives in registry.webhook_events while the payment and enrollment work happens in the tenant schema, so the two can never be made transactional as written.

**Impact:** Answers the 'captured with no enrollment and no retry' question: yes, this is the path. Stripe has the money, the parent has no enrollment, Stripe considers the event delivered, and nothing in the codebase reconciles payments in status 'completed' (or intents succeeded at Stripe) against missing enrollment rows.

**Evidence:**

```
lib/Registry/Controller/Webhooks.pm:46-56:
        my $claimed = $dao->db->query(
            q{INSERT INTO registry.webhook_events (stripe_event_id, event_type)
              VALUES (?, ?) ON CONFLICT (stripe_event_id) DO NOTHING},
            $event_id, $event->{type}
        )->rows;

        unless ($claimed) {
            $self->app->log->info("Duplicate Stripe webhook event $event_id ignored");
            $self->render(status => 200, text => 'OK (duplicate)');
            return;
        }
```

> Verifier correction: Two corrections, neither of which breaks the mechanism.

(a) "the claim lives in registry.webhook_events while the payment and enrollment work happens in the tenant schema, so the two can never be made transactional as written" -- overstated. Both schemas live in the same Postgres database. They are on different connections only because Registry::DAO::connect_schema (lib/Registry/DAO.pm:104-106) constructs a whole new Registry::DAO with its own Mojo::Pg. A single schema-qualified connection could wrap both in one transaction. Accurate phrasing: not transactional as currently written, not impossible in principle.

(b) The impact is understated, not overstated. If the crash lands after Webhooks.pm:135-140 sets status => 'completed' but before/inside finalize_enrollment, the run never advances ('next_step => complete' is only returned from _settle_callback), so a parent returning to the workflow URL without ?payment_intent= is shown the payment page again. lib/Registry/DAO/WorkflowSteps/Payment.pm:143-145 reuses the existing row only `if ($existing && $existing->status ne 'completed')` -- it is completed, so line 182's `unless ($payment)` mints a brand-new payment row with a fresh idempotency token and a new intent. That is a second charge on top of the swallowed first one, still with no enrollment.

> Verifier correction: Two refinements, neither of which defeats the finding.

(a) Scope: Webhooks.pm:45-56 and _process_payment_intent_succeeded are pre-existing on main (commits c6b4110, 0258766, 8f52ea6), not introduced by this PR. This PR's only edit to that file is the +14-line intent-amount match check. The claim-before-process structure is inherited, not new -- though the new check widens the set of events that take the die-and-release path, per its own comment at Webhooks.pm:124-125.

(b) Trigger is broader than stated: the finding frames it as SIGKILL/OOM/deploy. A milder, non-exotic variant also reaches the same state -- the release is $dao->db->delete(...) inside the catch, so if that DELETE itself throws (dead connection, which is also a plausible cause of the original exception), the exception escapes the catch, Mojolicious renders its own 500, Stripe retries, and the retry hits the surviving claim. Ordinary error path, no machine-level kill needed.

Unrelated but found while verifying: t/controller/payment-intent-webhook.t:155-158 claims "The failed event's claim was released" but posts a different event id (evt_pi_amt_good vs evt_pi_amt_bad), so it never exercises the release. That assertion would pass identically if the catch block's DELETE were removed.

> Verifier correction: Three corrections. (1) Not introduced by this PR: git show 8799cde:lib/Registry/Controller/Webhooks.pm is byte-identical for the claim block (41-56) and the catch/release (83-89); the only change to that file in the PR is the amount-match block at :121-133. So it is pre-existing code, not a regression or an incomplete B-1..M-1 fix. (2) The impact framing overstates it. This is a crash-window durability gap, not a normal-operation money-loss path: it needs an abnormal termination inside a sub-second window AND the parent never returning. In ordinary operation a die is caught, the claim is released at :85, and Stripe's retry reprocesses; and in the ordinary 3DS redirect flow Stripe returns the browser and Workflows.pm:255-259 finalizes idempotently. There is no attacker path -- signature verification at :22-26 precedes the claim, so an unauthenticated caller cannot plant a claim row. (3) 'The two can never be made transactional as written' is wrong as reasoning: registry and tenant schemas are in the same Postgres database; they are on different connections only because Registry::DAO::connect_schema (lib/Registry/DAO.pm:104) builds a whole new Mojo::Pg. The cheap fix is not transactionality but a processed_at column (only treat a claim as duplicate once marked processed, or expire stale claims), converting at-most-once loss into at-least-once retry.

### Journey test claims the Stripe form renders but only asserts the HTTP status

**FIXED** -- the status assertion now chains `content_like(qr/id="payment-form"/)`
and `content_like(qr/cs_journey/)`. This is what produced the RED for blocker 2:
the rendered page contained neither.

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/t/user-journeys/alex/02-activate-and-collect.t:437`
- **Dimension:** async-promises | **Votes:** 3/3 upheld

**Mechanism:**

The assertion message says 'payment step renders Stripe form after passing gate' but status_is(200) only checks the response code. Nothing inspects the body for #payment-element, the client secret, or show_stripe_form. The page could render the agreement form, an empty div, or an error banner and this test would still be green — which is precisely the failure described in the stash-shape finding above.

**Impact:** The one test whose name asserts the card form reaches the browser cannot detect its absence. The suite reports 100% green while the money path's most visible step is broken, which is exactly how a shipped regression reaches paying customers.

**Evidence:**

```
t/user-journeys/alex/02-activate-and-collect.t:437:
    )->status_is(200, 'payment step renders Stripe form after passing gate');
```

> Verifier correction: Minor scoping correction, not a refutation: the subtest is not vacuous overall. Lines 440-467 assert that create_payment_intent_async was invoked and check transfer_data[destination], on_behalf_of, application_fee_amount and the bracket-notation metadata keys, so intent creation itself is genuinely covered. What is uncovered is exactly what the message at :437 asserts — that the rendered page carries the Stripe card form. Also note the failure is not merely "could render an empty div": given the step_data vs top-level stash mismatch, the first-submit render provably omits the form today, so this test is masking a live defect rather than just being loosely worded.

> Verifier correction: The finding stands as written. One refinement: status_is(200) is not entirely vacuous - a validation error takes the flash+redirect path (302) and step advancement also redirects, and this test does NOT set max_redirects, so a 200 does prove the controller reached the "stay" render with a settled promise. What it cannot prove is which half of the payment template rendered. The fix is one line: add ->content_like(qr/payment-element/) (or qr/cs_journey/, the fixture client_secret) to that chain, which would immediately expose the step_data-nesting mismatch between Payment.pm:218-226 (flat data) and Payment.pm:80-88 / payment.html.ep:117 (nested under step_data).

> Verifier correction: Two refinements to the reported mechanism. (1) The claim "the page could render ... an error banner and this test would still be green" is too broad: an intent-creation failure returns `errors`, which the controller turns into a flash + 302 (Workflows.pm:405-430), so status_is(200) would in fact catch that case. The failure mode the test is genuinely blind to is the narrower and more damaging one: intent created successfully (so $captured_params and the DB-row assertions all pass), 200 returned, but the body re-renders the agreement-checkbox form instead of the Stripe form. (2) The stash-shape defect is not hypothetical — I confirmed it on this branch. Workflows.pm:444-447 merges `$result->{template_data}` (flat: client_secret, show_stripe_form) as siblings of `step_data` rather than into it, while templates/summer-camp-registration/payment.html.ep:5 reads `$step_data->{show_stripe_form}`. So on a first paid attempt the parent gets the terms checkbox back, loops, and never sees a card field, while a PaymentIntent already exists server-side.

### I5's gate precondition reads a stale in-memory tenant object, so it passes no matter what the database says

- **Location:** `/home/perigrin/dev/Registry/.claude/worktrees/main/t/stripe-live/paid-enrollment.t:227`
- **Dimension:** test-integrity | **Votes:** 2/3 upheld

**Mechanism:**

1. $tenant is built once at line 56 by Tenant->provision, before any Stripe fields are set.
2. I5 then does `UPDATE registry.tenants SET stripe_connect_account_id = $1 WHERE slug = $2` (lines 222-225) to put the tenant into the 'account set, charges disabled' state the gate is supposed to catch.
3. The very next assertion checks `!$tenant->stripe_connect_ready` on the ORIGINAL object. Tenant::stripe_connect_ready (lib/Registry/DAO/Tenant.pm:100-104) reads the object's own fields, which were populated at provision time and are not refreshed by the raw UPDATE.
4. The object has all three fields unset, so stripe_connect_ready is 0 unconditionally. The assertion cannot fail -- not even if the UPDATE silently matched zero rows, or if a future change made charges_enabled default TRUE.

**Impact:** The precondition that gives I5 its meaning ('the tenant is in the exact state the gate must refuse') is not actually checked. If the setup UPDATE stops working, or the account is already charges-enabled, I5 keeps reporting that the gate held while in fact the gate was never presented with the state it is meant to refuse. The gate is what stops a tenant with no payable Connect account from collecting tuition into a black hole.

**Evidence:**

```
t/stripe-live/paid-enrollment.t:56 -> `my $tenant = Registry::DAO::Tenant->provision($db, {`
t/stripe-live/paid-enrollment.t:221-228:
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = $1 WHERE slug = $2',
        $unready_acct, $slug,
    );

    ok !$tenant->stripe_connect_ready,
        'precondition: tenant stripe_connect_ready is false (charges_enabled=FALSE)';
lib/Registry/DAO/Tenant.pm:100-104 (reads fields, no DB re-read):
    method stripe_connect_ready {
        return $stripe_connect_account_id
            && $stripe_charges_enabled
            && $stripe_details_submitted ? 1 : 0;
    }
```

> Verifier correction: The mechanism is confirmed; two small refinements to the finding's wording. (1) The object's stripe fields are not "populated at provision time" from Object::Pad field defaults — they come from the INSERT ... RETURNING * in Registry::DAO::Object::create (lib/Registry/DAO/Object.pm:21-27), i.e. from live DB column defaults. A future DDL default change therefore would propagate into the object; the finding's own parenthetical is still correct that flipping only stripe_charges_enabled to DEFAULT TRUE would not flip the assertion, because stripe_connect_account_id stays NULL. (2) Severity is closer to low-medium than medium: the gate itself is genuinely exercised, because lib/Registry/DAO/WorkflowSteps/Payment.pm:119-122 re-reads the tenant with `SELECT * FROM registry.tenants WHERE slug = ?` and constructs a fresh Tenant before calling stripe_connect_ready. The loss is confined to the precondition — I5 cannot detect that it is testing "no account at all" instead of the intended "account set, charges disabled" state. The fix is one line: re-read the tenant after the UPDATE (e.g. Registry::DAO::Tenant->find($db, { slug => $slug }) or Tenant->new(%$row) from a registry-qualified SELECT) and assert on that object.

> Verifier correction: The one true part: t/stripe-live/paid-enrollment.t:227 does read a stale in-memory Tenant and can never fail, and its label ("charges_enabled=FALSE") misattributes the reason -- the object has all three stripe fields unset, not just charges_enabled. It is a dead line worth deleting or replacing with a DB re-read. But it is not load-bearing: the gate re-reads registry.tenants fresh (lib/Registry/DAO/WorkflowSteps/Payment.pm:118-121), the columns are NOT NULL DEFAULT FALSE (sql/deploy/tenant-stripe-connect.sql:13-14) so the intended state is guaranteed, and I5's five real assertions fail loudly if the tenant is ready. Worst realistic degradation is a coverage nuance (exercising "no account" instead of "account set, charges off"), not a silent false pass.

> Verifier correction: The assertion is genuinely vacuous, but the report overstates impact in two ways. (a) The 'charges_enabled defaults TRUE' variant would NOT silently pass: the gate reads the tenant fresh from the DB (Payment.pm:118-121), so it would not fire and line 234 (`ok $result->{errors}`) would fail loudly. Only the zero-row-UPDATE and weakened-gate variants degrade silently. (b) As the code stands today the subtest DOES exercise the intended state — $1/$2 are valid DBD::Pg placeholders and the identical UPDATE form at lines 250-253 must work or I1/I2 would fail on the destination-account assertion. So this is a latent tautology providing false assurance, not a currently-broken assertion; low-to-medium rather than medium.

### suspend-rateless-tenant-plans closes the menu but never checks whether a tenant is already linked to the rateless plan; such a tenant can take zero payments and deploy+verify both report success

- **Location:** `sql/deploy/suspend-rateless-tenant-plans.sql:21`
- **Dimension:** migrations | **Votes:** 2/3 upheld

**Mechanism:**

The migration only touches registry.pricing_relationships.status, which is read exclusively by the signup menu (Registry::DAO::WorkflowSteps::PricingPlanSelection prepare_pricing_data/validate_plan_selection filter status => 'active'). The charge path never looks at the relationship: Registry::DAO::Payment::_connect_params calls revenue_share_fraction_for_tenant, which joins registry.tenants.platform_pricing_plan_id -> registry.pricing_plans (RevenueShare.pm:40-44). Step by step: (1) create-default-pricing-relationships made 'Registry Standard - $200/month' selectable in production -- the commit message for f3c463b says so explicitly ("which is live and selectable in production"); (2) any tenant who picked it during that window has tenants.platform_pricing_plan_id pointing at a fixed, rateless plan -- tenant-platform-pricing-plan's backfill only repointed tenants whose FK was still NULL at 2026-06-16, so a later signup is not covered; (3) this migration suspends the offer but leaves that FK untouched; (4) at the first enrollment, _connect_params calls the resolver unguarded, _coerce_pct dies ("carries no 'percentage' in pricing_configuration and is not a percentage-model plan"), the payment intent is never created, and the parent gets a 500 on every attempt, forever; (5) the new verify only counts active relationships, so it returns clean and the operator sees a green deploy. Neither the migration, the verify, nor the updated onboarding runbook (docs/operations/sacp-stripe-connect-onboarding.md sections 2 and 6) ever asserts that a tenant's linked plan resolves to a rate.

**Impact:** A live tenant is silently unable to collect a single dollar, and the migration written specifically to prevent that failure mode neither detects nor repairs the case where it has already happened. Detection is one SELECT in the verify (tenants JOIN pricing_plans on platform_pricing_plan_id with the same COALESCE ... IS NULL predicate); repair is one UPDATE.

**Evidence:**

```
deploy:  UPDATE registry.pricing_relationships pr SET status = 'suspended' ... FROM registry.pricing_plans p WHERE p.id = pr.pricing_plan_id AND pr.status = 'active' ...

RevenueShare.pm:40-44 (the charge path -- no relationship involved):
          FROM registry.tenants t
          JOIN registry.pricing_plans p
            ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?

Payment.pm:94 (unguarded, so it throws out of intent creation):
        my $fraction = Registry::PriceOps::RevenueShare::revenue_share_fraction_for_tenant($db, $slug);
```

> Verifier correction: Two refinements, neither of which breaks the finding. (a) The exposure window is narrower than "any tenant who picked it": before 832ed08 (2026-06-16) nothing wrote tenants.platform_pricing_plan_id from the selection, so a pre-#267 picker had a NULL FK and was then backfilled onto the 2% percentage plan by tenant-platform-pricing-plan. The at-risk set is specifically tenants provisioned after 832ed08 that selected "Registry Standard - $200/month". (b) The runtime consequence on the actual web path is worse than described: create_payment_intent_async (Payment.pm:536-538) evaluates _intent_params as an argument, outside the promise and outside any try, so the die is synchronous and unguarded -- the payment row is not even marked 'failed'. Only the sync create_payment_intent (Payment.pm:232-241) catches it and records the failure before re-dying.

> Verifier correction: The plumbing claims are true (the migration only touches pricing_relationships.status; the charge path reads tenants.platform_pricing_plan_id and dies on a rateless plan; the verify counts only active relationships). What is false is the impact: no tenant is or plausibly can be linked to the rateless plan. Production has two tenants, both on the 2% percentage plan (resolved rate 0.02); the rateless 'Registry Standard - $200/month' has no tenant pointing at it. The migration removes the only application path that could create such a link (PricingPlanSelection filters status='active', and TenantPayment.pm:429 is the sole writer of the FK), and two rate-bearing tenant plans stay selectable. Adding the tenants-side check to the verify is optional belt-and-suspenders, not a fix for an existing money-losing state.

> Verifier correction: The mechanism is right; three refinements. (a) The impact is gated on the tenant having completed Connect onboarding - Payment.pm:83-89 returns early when stripe_connect_account_id is unset, so the fee resolver is never reached for a tenant that cannot charge anyway. The broken case is exactly the tenant that is otherwise ready to take money. (b) "500 on every attempt" is approximate: create_payment_intent's catch calls _record_intent_failure, which marks the payment row status='failed' and rethrows, so the parent sees whatever the controller renders for a thrown enrollment error; either way no intent is created and no money moves. (c) The exposure is stronger than described - it is not purely historical. TenantPayment.pm:429-430 does not re-validate relationship status at provision time, so a signup run whose pricing step ran before this migration and whose payment step runs after it still links the now-suspended rateless plan, producing a fresh broken tenant post-deploy.

### CI's "Test schema rollback" step has never executed a single revert script -- the two revert scripts this PR adds are unverified

- **Location:** `.github/workflows/ci.yml:271`
- **Dimension:** migrations | **Votes:** 3/3 upheld

**Mechanism:**

The step runs `carton exec sqitch revert -n 3 <target> || true`. sqitch revert has no `-n <count>` option (it takes --to-change / --modified / -y); the bare `3` is parsed as a stray argument and the command aborts before connecting. Verified against the pinned toolchain in this checkout: `carton exec sqitch revert -n 3 'db:pg://127.0.0.1:1/nonexistent_db_xyz'` prints `Unknown argument "3"` and exits 2. The `|| true` swallows that, the following `carton exec sqitch deploy` is a no-op on an already-current database, and the step echoes "Rollback test completed" and goes green. So no revert script in sql/revert/ has ever been executed by CI, and the database-compatibility job is the only place reverts would run at all.

**Impact:** The single automated safety net over revert correctness passes unconditionally. It is exactly the check that would have caught the deploy/revert asymmetry above, and it will not catch the next one either. Pre-existing on main rather than introduced here, but this PR adds two new revert scripts under its cover.

**Evidence:**

```
ci.yml:270-274
        # Test rollback of last few changes
        carton exec sqitch revert -n 3 db:pg://postgres@localhost/registry_migration_test || true
        # Redeploy
        carton exec sqitch deploy db:pg://postgres@localhost/registry_migration_test

$ carton exec sqitch revert -n 3 'db:pg://127.0.0.1:1/nonexistent_db_xyz'; echo $?
Unknown argument "3"
2
```

> Verifier correction: Two small refinements, neither affecting the conclusion. (a) The error message names the stray positional `3`, not the `-n` flag itself — sqitch consumes/discards `-n` and then rejects the extra argument; the net effect (parse abort, exit 2, no DB connection) is exactly as described. (b) The impact is understated: the `database-compatibility` job is gated by `contains(github.event.head_commit.modified, 'sql/')`, which can never match since that function requires an array element exactly equal to 'sql/', not a prefix. So the job runs only on the nightly `schedule` event — the broken step is not merely toothless, it also does not run on the sql-touching pushes it was meant to guard.

> Verifier correction: The finding is correct as written. One amplification it understates: ci.yml:200 gates the entire `database-compatibility` job on `github.event_name == 'schedule' || contains(github.event.head_commit.modified, 'sql/') || contains(github.event.head_commit.modified, 'sqitch')`. `github.event.head_commit` is null on pull_request events, and on push the `contains()` array form does exact element matching, so `'sql/'` never equals a path like `'sql/deploy/refund-application-fee-config.sql'`. The job therefore effectively runs only on the nightly schedule -- the broken revert step is even less reachable than the reporter claims, and this PR's revert scripts will not be touched by CI on the PR itself at all. Minor mechanical detail (not load-bearing): `-n` is silently absorbed during core-option parsing (App::Sqitch::_parse_core_opts uses `bundling pass_through`), which is why only the bare `3` survives to be reported as the unknown argument.

> Verifier correction: Two refinements, both of which strengthen rather than weaken the finding:

1. The finding is understated on how rarely the step runs. The job gate at ci.yml:200 is `if: github.event_name == 'schedule' || contains(github.event.head_commit.modified, 'sql/') || contains(github.event.head_commit.modified, 'sqitch')`. On `pull_request` events `github.event.head_commit` is null, so both `contains()` calls are false — the `database-compatibility` job never runs on a PR at all, including this one. On `push`, GitHub's `contains(array, item)` tests element equality, not substring, so a modified path like `sql/deploy/suspend-rateless-tenant-plans.sql` does not match the literal string `'sql/'`. In practice the job only ever runs on the weekly Sunday cron — and when it does, the revert step is the no-op described above.

2. Minor mechanical detail: `-n` itself is not what sqitch rejects. Getopt::Long consumes/discards it and the error is raised later by parse_args on the orphaned positional `3`. The observable outcome (`Unknown argument "3"`, exit 2, no DB connection) is exactly as the finding states.

### database-compatibility's sql/-change trigger is dead, so this PR's two new migrations merge with their revert scripts never exercised

- **Location:** `.github/workflows/ci.yml:200`
- **Dimension:** ci-secrets | **Votes:** 3/3 upheld

**Mechanism:**

The condition is `github.event_name == 'schedule' || contains(github.event.head_commit.modified, 'sql/') || contains(github.event.head_commit.modified, 'sqitch')`. Two independent reasons the last two clauses can never be true: (a) `github.event.head_commit` only exists on `push` events, so on a `pull_request` it is null; (b) when the search operand is an array, GitHub's `contains()` does exact element matching, so it is asking whether a modified path is literally the string 'sql/' -- it never equals 'sql/deploy/refund-application-fee-config.sql'. The job therefore only ever runs on the weekly `schedule`. It is the only job that runs `sqitch revert -n 3` + redeploy; ci.yml's `test` job only runs `sqitch deploy` (and the actual test suite loads sql/test-schema.sql, not sqitch). This PR adds two migrations with new revert and verify scripts. On PR run 30866114026 the job shows as skipped and the overall run is a green check.

**Impact:** sql/revert/suspend-rateless-tenant-plans.sql and sql/revert/refund-application-fee-config.sql are merged untested. If either revert is broken, that is discovered during an incident rollback of the pricing/revenue-share tables -- exactly when it costs the most. The green check on the PR implies migration compatibility was verified when it was not.

**Evidence:**

```
`gh run view 30866114026` -> `✓ feature/money-path-e2e CI ... JOBS ✓ lint ✓ test ✓ security - quality in 0s - database-compatibility` (both dashes = skipped, run conclusion `success`). ci.yml:200: `if: github.event_name == 'schedule' || contains(github.event.head_commit.modified, 'sql/') || contains(github.event.head_commit.modified, 'sqitch')`. ci.yml:271: `carton exec sqitch revert -n 3 db:pg://postgres@localhost/registry_migration_test || true`
```

> Verifier correction: Two corrections, both of which change the shape of the fix rather than weakening the finding:

(a) The verify scripts ARE tested; only the revert scripts are not. sqitch.conf contains `[deploy] verify = true`, and ci.yml:93 runs `carton exec sqitch deploy` on every PR, so the two new sql/verify/*.sql files execute on every PR run. The finding should be narrowed to revert scripts only.

(b) The revert step is dead twice over, so the reverts are exercised NOWHERE, not merely "only weekly." ci.yml:271 is `carton exec sqitch revert -n 3 db:pg://... || true`, but App::Sqitch v1.5.2 (pinned at cpanfile.snapshot:21) declares revert's options in local/lib/perl5/App/Sqitch/Command/revert.pm:75-85 as `target|t=s`, `to-change|to|change=s`, `set|s=s%`, `log-only`, `lock-timeout=i`, `modified|m`, `y` -- there is no `-n`. Getopt::Long (bundling, no_pass_through) rejects it, `|| true` swallows the failure, and the following "Redeploy" step then succeeds trivially because nothing was reverted. Fixing the `if:` alone (e.g. gate on github.event.pull_request plus a paths-filter/changed-files step, since array contains() is exact-element matching) would still test nothing until `-n 3` becomes a real target such as `@HEAD^^^` and the `|| true` is removed.

> Verifier correction: Two amendments. (a) The verify scripts are NOT untested: sqitch.conf sets `[deploy] verify = true`, and ci.yml:93 runs `carton exec sqitch deploy` in the `test` job on every PR, so sql/verify/*.sql for both new changes execute on every run. Only the two revert scripts are unexercised. (b) The finding understates the gap: fixing the `if:` at ci.yml:200 would not fix it, because ci.yml:271 is `carton exec sqitch revert -n 3 ... || true` and the following `sqitch deploy` is then a no-op that exits 0 -- so the "Test schema rollback" step cannot fail even on the weekly scheduled run where the job does execute. Two independent defects. Scope note: ci.yml:200 is unchanged by this PR (its ci.yml diff touches only the two STRIPE_SECRET_KEY exports at ~121 and ~365), so this is pre-existing CI debt rather than a regression. Finally, no revert is currently broken on inspection -- pricing_relationships.metadata is `JSONB DEFAULT '{}'` and is always populated by create-default-pricing-relationships.sql:63-78, so the suspend revert's `metadata->>'suspended_by_migration'` predicate will match -- making this a real missing-check finding with low immediate blast radius.

> Verifier correction: One correction, and it makes the finding stronger rather than weaker: the finding implies the reverts at least get exercised by the weekly `schedule` run. They do not. `.github/workflows/ci.yml:271` is `carton exec sqitch revert -n 3 db:pg://postgres@localhost/registry_migration_test || true`, and `sqitch revert` has no `-n` option — `local/lib/perl5/App/Sqitch/Command/revert.pm:75-85` declares only `target|t=s to-change|to|change=s set|s=s% log-only lock-timeout=i modified|m y`, and the core opts at `App/Sqitch.pm:230-241` are `chdir|cd|C=s etc-path no-pager quiet verbose|V|v+ help man version`. The scheduled run proves it: job 91459721134 log, line 676 `Unknown argument "3"`, immediately followed by line 677 `Nothing to deploy (up-to-date)` from the redeploy step — i.e. the revert aborted, `|| true` swallowed the non-zero exit, and the redeploy confirmed nothing had been rolled back. Step reported green.

So the accurate statement is: `sql/revert/*` is executed by ZERO CI paths, on any event, including the weekly schedule. Fixing only the `if:` condition at ci.yml:200 would not restore coverage — the `-n 3` argument and the `|| true` mask both have to go too (and a broken revert would still be hidden by `|| true` even with a correct `--to-change`/`-y` invocation).

Minor: the finding's parenthetical that "the actual test suite loads sql/test-schema.sql, not sqitch" is correct (`t/lib/Test/Registry/DB.pm:15`, `Makefile:6`), though the `test` job does separately run `sqitch deploy` at ci.yml:93 — so deploy-side breakage would still be caught on a PR. It is specifically the revert side that is uncovered.

### _to_cents truncates instead of rounding: roughly a third of two-decimal prices are charged a cent short

- **Location:** `lib/Registry/DAO/Payment.pm:41`
- **Dimension:** failure-modes | **Votes:** 3/3 upheld

**Mechanism:**

`int($dollars * 100)` truncates the IEEE-754 product toward zero. For prices whose double representation lands just below the exact cent boundary, the charge is one cent low: $19.99 -> 1998, $149.95 -> 14994, $74.99 -> 7498, $20.15 -> 2014, $1.15 -> 114, $0.29 -> 28. This value is what goes to Stripe as `amount` in _intent_params, what application_fee_cents is computed from, what the _apply_intent amount guard compares against, what Webhooks.pm:128 compares against, and what refund() sends as the refund amount. All call sites use the same truncated figure, so the guards stay self-consistent -- the loss is silent.

**Impact:** Systematic under-collection: every enrollment at an affected price bills a cent less than the listed price, and the platform's application fee is computed from the short amount. A 'full' refund also returns the short amount while the row is marked 'refunded'. Roughly a third of arbitrary two-decimal prices are affected. sprintf('%.0f', $dollars*100) (or a Postgres-side round) is the correct form.

**Evidence:**

```
lib/Registry/DAO/Payment.pm:41
    sub _to_cents ($dollars) { int($dollars * 100) }

$ perl -e 'for (0.29,1.15,19.99,20.15,74.99,149.95){printf "%s int=%d round=%d\n",$_,int($_*100),sprintf("%.0f",$_*100)}'
0.29 int=28 round=29
1.15 int=114 round=115
19.99 int=1998 round=1999
20.15 int=2014 round=2015
74.99 int=7498 round=7499
149.95 int=14994 round=14995
```

> Verifier correction: The mechanism is real and confirmed, but two details in the finding are wrong. (1) Magnitude: not "roughly a third" of two-decimal prices. Measured over uniform two-decimal values: 573/10000 (5.7%) in $0.01-$100.00, 4.6% up to $1000, 6.6% up to $10000. The cited examples (0.29, 1.15, 19.99, 20.15, 74.99, 149.95) are all genuinely affected, and .99/.95 endings are over-represented in real pricing so practical exposure exceeds a uniform sample — but "a third" is overstated. (2) Provenance: _to_cents is NOT introduced by this PR. `git show 8799cde:lib/Registry/DAO/Payment.pm` has the identical line at the same line 41. This PR adds two new consumers of it (the _apply_intent amount guard at Payment.pm:296 and Webhooks.pm:128) and is the change that turns on real charges, so it is a legitimate thing to flag here, but it must be reported as pre-existing rather than as a regression this PR introduced.

> Verifier correction: The core mechanism holds and is unguarded, but the magnitude is materially overstated. Measured over all two-decimal prices from $0.01 to $1000.00, 4.6% are charged a cent short -- not "roughly a third". Common retail endings are mostly safe: .99 is affected 2.1% of the time, .95 3.7%, .49 2.2%, and .00/.25/.50/.75 never. $19.99, $149.95, $74.99, $20.15 are genuinely affected; $9.99, $49.99, $99.99, $199.99, $349.99, $123.45 are not. The refund sub-claim is wrong: refund() sends _to_cents($amount), exactly the amount Stripe was charged, so a "full" refund does make the customer whole -- no money is lost on that path. The application-fee impact is nil (2.5% of one cent, and application_fee_cents rounds half-up). Net impact is 1 cent under-collected on ~4.6% of charges: real and silent, but low severity rather than medium. Also, _to_cents predates the diff base (commit 38188e4 is an ancestor of 8799cde), so it is a pre-existing bug that this PR promotes onto the live-money path rather than a regression from the unreviewed commits. A fix at Payment.pm:41 alone is incomplete -- lib/Registry/PriceOps/PaymentSchedule.pm:43 has the identical `int($installment_amount * 100)` truncation on the installment path.

> Verifier correction: The bug is real; the "roughly a third of two-decimal prices" figure is wrong by about 7x. Measured over every cent value from $0.01 to $500.00 (50,000 prices), 2,292 are short-charged — 4.6%, not ~33%. Among the common .99 endings ($0.99 through $499.99), only 21 of 500 are affected, but they cluster in commercially important bands: 16.99, 17.99, 18.99, 19.99 and 64.99-69.99 are all short. Of a hand-picked list of realistic program prices (24.99, 29.99, 39.99, 49.99, 89.99, 99.99, 199.99 ...) only 19.99, 74.99 and 149.95 miss. So the headline should be "a small but non-trivial minority of two-decimal prices, including $19.99," rather than "a third."

Second overstatement: the refund claim. `refund()` at Payment.pm:437-454 defaults `$refund_amount` to `$amount` and sends `_to_cents($refund_amount)`, which is the same truncated 1998 that was actually charged. Marking the row 'refunded' is therefore correct — the customer is made whole. There is no extra loss on the refund path; the only loss is the one cent never collected at charge time.

Everything else in the finding stands: file:line is right, all six evidence values reproduce, the fix (`sprintf('%.0f', $dollars*100)`) is right, and the reason it is silent — every guard reading the same truncated number — is right.

Worth folding in as a related item: t/dao/payments.t:136-159 gives false assurance here. The subtest is titled "_to_cents converts dollars to integer cents" but its second assertion is `is(_to_cents($dollars), int($dollars * 100))` — a tautology checking the implementation against itself. Its fixtures (0, 9.99, 100, 100.50, 0.025) are all values where truncation happens not to bite, and the 0.025 case has a comment enshrining the truncation as intended. Fixing _to_cents requires updating that test, and the test as written would never have caught this.

## LOW (3)

### The stripe-test-keys guard test can be bypassed by quoting, and two of its four subtests pass on any child-process failure

- **Location:** `t/security/stripe-test-keys.t:65`
- **Dimension:** ci-secrets | **Votes:** 2/3 upheld

**Mechanism:**

Two problems in the file this PR adds. (1) The regression guard is `grep { /STRIPE_SECRET_KEY=sk_test_/ } <$fh>` against ci.yml. It requires `sk_test_` to immediately follow the `=`. `export STRIPE_SECRET_KEY="sk_test_dummy"` -- the ordinary way anyone would write it back -- does not match, so the exact bug the test exists to prevent (a test-shaped placeholder that makes t/stripe-live believe Stripe is reachable) can be reintroduced with the guard still green. (2) The subtests at lines 39-46 and 48-55 assert only `unlike $out, qr/Refusing to use a live Stripe key/`. `$out` is the captured output of a `carton exec perl ...` backtick. If that child fails for any unrelated reason -- carton not on PATH, compile error, missing module -- `$out` contains a different error and `unlike` passes. Those two subtests can never fail for the reason they name.

**Impact:** The regression fence around the sk_test_ placeholder is one pair of quotes wide. The 'allowed' half of the live-key guard is unasserted, so a change that makes stripe_client die on all keys (failing closed but breaking every payment) would still show these subtests green.

**Evidence:**

```
stripe-test-keys.t:65: `my @offending = grep { /STRIPE_SECRET_KEY=sk_test_/ } <$fh>;`  //  stripe-test-keys.t:43-45: `my $out = `carton exec perl -Ilib -e '$build_client' 2>&1`;\n    unlike $out, qr/Refusing to use a live Stripe key/,\n        'sk_test_ key passes the live-key guard';`
```

> Verifier correction: Accurate but low-value part: the ci.yml grep at t/security/stripe-test-keys.t:65 is quote-sensitive and would miss `STRIPE_SECRET_KEY="sk_test_..."` or a YAML `env:` mapping; broadening it to /STRIPE_SECRET_KEY[=:]\s*["']?sk_test_/ would be a one-character-class improvement. Everything else is wrong: (a) evading the guard does not hide the bug — the stripe-live suite un-skips and fails loudly against the real API on the same CI run; (b) the two `unlike` subtests do fail for the reason they name (any regression in the sk_live_/MOJO_MODE condition at lib/Registry/DAO/Payment.pm:150 turns them red); (c) generic child-process failures turn subtests 1-2 red, so the file does not stay green; (d) the one blind spot (client construction broken for all keys) is covered by eleven other test files.

> Verifier correction: Part (1) holds as written and is slightly understated: the bypass is not only quoting. The guard also misses the YAML `env:` form `STRIPE_SECRET_KEY: sk_test_dummy`, which is the form the sibling workflow stripe-e2e.yml:27 already uses, making it the most likely real-world reintroduction path. Verified by running the regex: unquoted CAUGHT, double-quoted MISSED, single-quoted MISSED, YAML-colon MISSED. No other guard exists anywhere (available() and _key() in t/lib/Test/Registry/StripeConnect.pm are the same bare prefix check).

Part (2) needs correcting on two points. First, "Those two subtests can never fail for the reason they name" is wrong -- they name "passes the live-key guard" and would fail if a regression made the guard reject sk_test_ keys, because the die message would then be present in $out. Second, "pass on any child-process failure" does not produce an all-green file: all four subtests invoke the identical $build_client child, so if carton is missing or Registry::DAO::Payment fails to compile, subtests 1-2 (like $out, qr/Refusing/) fail loudly. The residual weakness is narrower than claimed: only a failure introduced *after* the guard at lib/Registry/DAO/Payment.pm:151 (e.g. Registry::Service::Stripe->new dying) goes undetected by this file -- and that specific breakage would still be caught by other suites that construct stripe_client. Fix is two lines: widen :65 to /STRIPE_SECRET_KEY\s*[:=]\s*["']?sk_test_/ and add `like $out, qr/^OK/` at :44 and :53, since the child already prints "OK\n".

> Verifier correction: Two corrections to the finding as written.

(1) Attribution. "Two problems in the file this PR adds" is wrong for problem 2. `git log -- t/security/stripe-test-keys.t` shows the four `like`/`unlike` subtests came in with 58e6359 ("Refuse live Stripe keys outside production (#159)") and are present in the merge base 8799cde. This PR's commit 38bbeb4 adds only the fifth subtest (the ci.yml grep). The +16-line diff on this file is subtest 5 alone. So only problem 1 is in this PR's diff; problem 2 is pre-existing main code.

(2) Impact overstated for problem 2. "A change that makes stripe_client die on all keys would still show these subtests green" is true of subtests 3 and 4 in isolation but not of the file. Subtests 1-2 use `like $out, qr/Refusing to use a live Stripe key/`, so any global child failure (carton missing, compile error, module gone) turns the file red there. The escape window is narrower: only a breakage confined to the sk_test_ path or to MOJO_MODE=production, emitting a message other than the refusal string, passes the whole file green. Example: Registry::Service::Stripe->new gaining a key-shape or api_version validation that rejects only test-shaped keys -- subtests 1-2 still pass, subtest 3 passes vacuously, every non-production payment is broken and the suite is green.

The precise defect in problems 1 and 2 is the same shape: the guard matches one spelling of a thing rather than asserting the property. Problem 1 should test the resolved value (parse the YAML, or `grep /STRIPE_SECRET_KEY\W+\W*["']?sk_test_/`); problem 2 should assert `like $out, qr/^OK$/` rather than merely the absence of one string.

### The PR edits a STRIPE_SECRET_KEY placeholder in the `quality` job, which is hard-failed at 'Set up job' and can never execute

- **Location:** `.github/workflows/ci.yml:369`
- **Dimension:** ci-secrets | **Votes:** 2/3 upheld

**Mechanism:**

The PR changes `export STRIPE_SECRET_KEY=sk_test_dummy` to `ci_placeholder_not_a_stripe_key` at ci.yml:369, inside the `quality` job. That job has `if: github.event_name == 'schedule' || github.event_name == 'push'`, so it is skipped on every PR, and on push/schedule it fails immediately at 'Set up job' because it references `actions/upload-artifact@v3`, which GitHub retired. Job 91459721151 on the last scheduled run has exactly one step, `Set up job: failure`, with the annotation quoted below. So the coverage job has produced nothing for months, its edited line is unreachable, and it is one of the reasons main's push/schedule CI is perpetually red -- which trains everyone to ignore red on main.

**Impact:** No coverage has been generated in months, and a permanently red main desensitizes reviewers to the CI signal that the rest of this PR's safety argument rests on. The edited line gives false reassurance that the placeholder fix was applied everywhere it runs.

**Evidence:**

```
`gh api repos/Tamarou/Registry/actions/jobs/91459721151 --jq '.steps[] | "\(.name): \(.conclusion)"'` -> `Set up job: failure`; annotation: `This request has been automatically failed because it uses a deprecated version of 'actions/upload-artifact: v3'`. ci.yml:377: `uses: actions/upload-artifact@v3`
```

> Verifier correction: Two refinements, both making the finding stronger/more precise rather than weaker. (1) The finding says quality is "one of the reasons main's push/schedule CI is perpetually red" -- it understates: in every run sampled (30751308864, 27847076733, 27081272678) quality is the ONLY failing job; test, lint, security and database-compatibility all pass. Bumping actions/upload-artifact@v3 -> @v4 at ci.yml:377 and ci.yml:389 alone would turn main green. (2) "produced nothing for months" is confirmed and conservative: the identical Set-up-job/upload-artifact-v3 failure is present at least as far back as job 79927493793 on the 2026-06-07 scheduled run, and the separately-registered "Code Quality" workflow has no file in the repo, so there is no other coverage source.

> Verifier correction: The dead-job facts are accurate: ci.yml:369 is unreachable because `quality` is gated to push/schedule and hard-fails at 'Set up job' on the deprecated actions/upload-artifact@v3 (ci.yml:377, :389), and it has been the sole cause of red push/schedule runs for months. What is wrong is the impact: the placeholder fix that matters lives at ci.yml:129 in the ungated `test` job, which runs on every PR and push and passes on this PR (run 30866114026). The fix therefore IS applied everywhere it runs, and the :369 copy is harmless consistency rather than false reassurance. The quality job also swallows its own exit status (`cover ... || true`), so it asserted nothing even when it worked. Legitimate separate chore ticket: bump ci.yml:377 and :389 to actions/upload-artifact@v4. Not a defect in this PR.

> Verifier correction: The finding is accurate; two refinements. (1) Fixing only ci.yml:377 would not unblock the job -- ci.yml:389 is the same deprecated actions/upload-artifact@v3, and job setup resolves all action references, so the job would still hard-fail at "Set up job". (2) Even with both bumped to v4, the coverage step asserts nothing: ci.yml:372 is `carton exec cover -test -report html_basic -ignore_re '^t/' || true`, and the `|| true` swallows any failure. So the job is a report generator, not a gate -- the real loss is the artifact, not a safety signal. Blast radius is contained to ci.yml: the new stripe-e2e.yml added by this PR, plus playwright.yml and deploy-validation.yml, all correctly use upload-artifact@v4.

### Raw Stripe/croak errors -- including absolute server file paths -- are rendered verbatim to the parent

- **Location:** `lib/Registry/DAO/WorkflowSteps/Payment.pm:230`
- **Dimension:** failure-modes | **Votes:** 2/3 upheld

**Mechanism:**

Service::Stripe::_request_async croaks inside a promise callback (line 64). Carp appends the caller's file and line, and inside a Mojo::Promise callback that caller frame is Mojo/Promise.pm, so the rejection string carries an absolute server path. Payment::_record_intent_failure re-dies with that string prefixed, the workflow step wraps it again as "Payment processing error: $error", it is stored in payments.error_message, passed through as `errors`, encoded into errors_json, and the payment template prints each entry unescaped-of-context in a <li>. The same happens for _record_retrieval_failure and for a non-JSON Stripe/proxy error body, which is embedded whole (Stripe.pm:57).

**Impact:** A declined card shows the parent something like 'Payment processing error: Failed to create payment intent: Stripe card_error: Your card was declined. (card_declined) at /home/.../local/lib/perl5/Mojo/Promise.pm line 248.' That is an unusable error message and it discloses the deployment's filesystem layout and dependency paths. No API key is exposed, but nothing filters the string either.

**Evidence:**

```
$ perl -e 'use Mojo::Promise; use Carp qw(croak); my $p=Mojo::Promise->new; my $q=$p->then(sub{croak "Stripe card_error: Your card was declined. (card_declined)"}); $q->catch(sub{print "ERROR SEEN: $_[0]"}); $p->resolve(1); $q->wait;'
ERROR SEEN: Stripe card_error: Your card was declined. (card_declined) at /home/perigrin/dev/Registry/.claude/worktrees/main/local/lib/perl5/Mojo/Promise.pm line 248.

lib/Registry/DAO/WorkflowSteps/Payment.pm:230  errors => ["Payment processing error: $error"],
templates/summer-camp-registration/payment.html.ep:76  <li><%= $err %></li>
```

> Verifier correction: Two parts of the writeup are wrong and should not be repeated verbatim:

(a) The impact example is not what a declined card produces. An ordinary decline in the PaymentIntents flow is a *successful* HTTP retrieval whose intent has status `requires_payment_method`; Payment.pm:316 sets `$error_message = $intent->{last_payment_error}{message} // 'Payment failed'`, which is a clean Stripe-authored sentence with no path. The path-laden string only appears when Stripe (or a proxy) returns a non-2xx HTTP response — auth error, invalid_request, idempotency_error, rate limit, 5xx — or a non-JSON body, i.e. Stripe.pm:57/64. Transport-level failures (connection refused, timeout) reject before the `then` callback and carry no path either.

(b) "prints each entry unescaped-of-context" is wrong. Mojolicious `<%= %>` HTML-escapes by default, and the line is templates/summer-camp-registration/payment.html.ep:78, not :76. There is no XSS here; the issue is purely the verbatim path/technical text being shown.

> Verifier correction: The string plumbing is real but the impact is misattributed and below the finding bar. A DECLINED CARD does not take this path: _intent_params (lib/Registry/DAO/Payment.pm:195-205) sends no `confirm`/`payment_method`, the card is confirmed client-side (templates/summer-camp-registration/payment.html.ep:164, stripe.confirmPayment), so declines return via _apply_intent's else-branch (lib/Registry/DAO/Payment.pm:316) with a clean `last_payment_error.message` and no file path. What actually can reach the parent with Carp/die annotations is a Stripe API error at intent-creation time (Connect account misconfig, amount_too_small, rate limit) or a retrieval transport failure, rendering e.g. "Payment processing error: Failed to create payment intent: Stripe invalid_request_error: ... at /.../Mojo/Promise.pm line 248. at /.../lib/Registry/DAO/Payment.pm line 228." That discloses dependency/deployment paths only -- no API key (the key is header-only; Mojo::UserAgent::start_p rejects with $tx->error->{message}), no money impact (payment row correctly marked failed, parent can resubmit), no data corruption, no auth bypass. The template also auto-escapes via <%= $err %>, so the whole-body embed at lib/Registry/Service/Stripe.pm:57 is not an injection vector. Cosmetic low-severity info disclosure, not a money-path defect.

> Verifier correction: The finding's headline impact is not reachable as written. A plain declined card does NOT produce the path-bearing message.

- Intent creation attaches no payment method: _intent_params (lib/Registry/DAO/Payment.pm:195-204) sends amount, currency, description, receipt_email, metadata and Connect params only -- no payment_method, no confirm. Stripe cannot return card_error at PaymentIntent creation, so "Failed to create payment intent: Stripe card_error: Your card was declined" is impossible.
- A real decline retrieves successfully. _apply_intent (lib/Registry/DAO/Payment.pm:316) sets error_message from $intent->{last_payment_error}{message} -- a clean Stripe sentence with no file path -- and returns intent_status='requires_payment_method', which routes to the retry branch at lib/Registry/DAO/WorkflowSteps/Payment.pm:324-338 where errors => [$result->{error}] is exactly that clean string.
- A decline only leaks a path if the REPLACEMENT intent creation also fails, via "Retry unavailable: $retry_err" at lib/Registry/DAO/WorkflowSteps/Payment.pm:352.

The real triggers are (a) any PaymentIntent-creation failure (amount below Stripe minimum, restricted/disabled Connect account, auth or transport error) hitting lib/Registry/DAO/WorkflowSteps/Payment.pm:230, and (b) any retrieve_payment_intent failure hitting the fall-through at lib/Registry/DAO/WorkflowSteps/Payment.pm:288 -- reachable on demand by POSTing a bogus client-supplied payment_intent_id.

Also correct two sub-claims: the template does NOT render unescaped -- <%= $err %> HTML-escapes, so there is no XSS -- and no API key is present in the string. The impact is filesystem-layout disclosure plus an unusable error message, nothing more.

Unrelated observation surfaced while tracing repro B (out of scope of this finding, not counted): _record_retrieval_failure at lib/Registry/DAO/Payment.pm:247-249 flips the live payment row to status='failed' purely on a client-supplied garbage payment_intent_id, before any ownership check runs.

## Completeness critic

### [high] WorkflowRun::process changed contract (may now return a promise) but 2 of its 4 callers still discard the return value — neither file was opened by any dimension

- **Location:** `lib/Registry/Utility/WorkflowProcessor.pm:25 (also :12); lib/Registry/Job/WorkflowExecutor.pm:59 (also :51)`

The PR made WorkflowRun::process polymorphic: `return $step_result->then(sub ($resolved) { $self->_persist_step_result(...) }) if $step_result isa Mojo::Promise;` (lib/Registry/DAO/WorkflowRun.pm:99-101). Persistence — the data merge AND the `latest_step_id = ?` write — now happens only inside that `then`. Two of the four call sites were updated (Controller/Workflows.pm:384 via _process_step; the first-step call at :60 is never a payment step). The other two were not, and no dimension in the sweep opened either file. (a) `Registry::WorkflowProcessor::process_workflow_run_step` calls `$run->process( $dao, $step, $data );` in void context on line 25, then immediately does `return $run->next_step($dao) unless $run->completed($dao)` — both of which read the in-memory `$latest_step_id` that the still-pending promise has not written. The promise reference is dropped on the next statement; on rejection the only trace is Mojo::Promise::DESTROY's `carp "Unhandled rejected promise"`. On success the Stripe PaymentIntent has been created and charged but its result is never merged into the run, and `next_step` hands back the same payment step. (b) `Registry::Job::WorkflowExecutor` does the same at :59 inside `while ($current_step) { ... $workflow_run->process($db, $current_step, {}); $current_step = $workflow_run->next_step($db); }` — with `latest_step_id` never advanced, `next_step` returns the same step forever, and each iteration re-enters the step (a fresh PaymentIntent per pass for a Stripe-touching step).

**Impact:** CLAUDE.md names `Registry::WorkflowProcessor->new_run` / `process_workflow_run_step` as THE sanctioned integration-test interface for workflows. Any integration test written against that interface for the payment step will report success while asserting nothing: no persisted data, no advanced pointer, a silently-dropped promise. That is precisely the class of bug B-1 was (a live suite that asserted nothing) reintroduced one layer up, in the interface the project's own docs point tests at. The executor path is an unbounded re-processing loop rather than a silent no-op. Both are latent today (no workflow YAML wires a Stripe step behind the Minion executor, and no current test drives payment through WorkflowProcessor), but the shared method's contract changed without its callers, so the trap is armed for the next test or workflow that uses either.

### [medium] _process_step returns a derived promise that Mojolicious discards; a throw inside _render_step_result after render_later hangs an already-charged request with no 500 and no log line

- **Location:** `lib/Registry/Controller/Workflows.pm:389-400`

`_process_step` calls `$self->render_later` then `return $result->then($ok, $err)`. The `$err` handler covers rejection of the *upstream* Stripe promise only. The value actually returned is the DERIVED promise produced by `->then(...)`, and nothing anywhere attaches a handler to it: Mojolicious uses an action's return value purely as a routing boolean — `return 1 if _action($old->app, $new, $sub, $last);` (local/lib/perl5/Mojolicious/Routes.pm:161) — so the promise ref is dropped on the next statement. `_render_step_result` (the `$ok` handler) does substantial work that can throw: `$step->prepare_template_data($dao->db, $run)` (:445), `$run->completed($dao->db)` / `$run->next_step` (:480-481), `$next->prepare_template_data` (:496), and `$self->render(template => $workflow_slug . '/' . $next->slug, ...)` (:499) which dies if that template does not exist. Any of these throwing inside the `then` rejects the derived promise. Because it has no handler, the failure surfaces only as Mojo::Promise::DESTROY's carp, and because `render_later` was already called and no render happened, the connection is simply held until the inactivity timeout. The synchronous path (:400) has no such hole — the die would propagate to Mojolicious's normal exception handling and produce a 500.

**Impact:** On the paid path this window is entirely AFTER the card has been charged: `handle_payment_callback` -> `_settle_callback` -> `finalize_enrollment` all run before `_render_step_result` is entered. A parent whose money has moved gets a hung request that eventually times out with no page, no error, and no server-side error log — the operator sees only a `carp` on STDERR with no request context. Enrollment is still finalized by the `payment_intent.succeeded` webhook, so this is not lost money, but it is the money path's worst-looking user-visible failure and it is invisible in logs. A terminal `->catch` on the derived promise (rendering 500) closes it.

### [medium] The Stripe-return GET gate runs the payment step from the URL slug with no current-step check, so a reload or Back on the return URL rewinds latest_step_id of a completed run back to payment

- **Location:** `lib/Registry/Controller/Workflows.pm:236-259`

`get_workflow_run_step` resolves `$step` purely from the URL slug (`my $requested_step_slug = $self->param('step'); my $step = Registry::DAO::WorkflowStep->find($dao->db, { workflow_id => $workflow->id, slug => $requested_step_slug });`, :236-240). The new B-4 gate at :255 then dispatches to `_process_step` on nothing more than `$step->can('handle_payment_callback')` plus the presence of `payment_intent`. Unlike the POST sibling, which enforces `die "Wrong step expected ${\$step->slug}" unless $step->slug eq $self->param('step')` against `$run->next_step` (:345-349), the GET path has no check that the run is actually parked on that step. `handle_payment_callback` on an already-settled intent returns `{ next_step => 'complete' }` (Payment.pm:259), which is not a stay, so `_persist_step_result` takes the advance branch and writes `latest_step_id = ?` with `$step->id` — the PAYMENT step — unconditionally (WorkflowRun.pm:156-158). Stripe's return URL sits in browser history and is a plain GET, so reload, Back, or a link prefetcher re-issues it after the run has moved on to 'complete'.

**Impact:** A completed enrollment run silently regresses: `$run->completed($db)` flips from true to false, `process_workflow_run_step`'s `return $self->render(text => 'DONE', status => 201)` guard (:340-342) stops firing, and the continuation redirect at :519 is bypassed. No double charge (the callback branch retrieves rather than creates an intent, and _apply_intent's ownership + captured-amount checks plus the enrollments_payment_dedup index hold), so this is pointer/state corruption of a paid run rather than lost money — but it is state corruption on the run that records a real payment, triggered by an ordinary browser reload. A `$step->id eq $run->latest_step_id`-style guard on the GET gate, or a stay result on an already-settled intent, closes it.

### [low] _await converts every remaining synchronous Stripe wrapper from silent-undef into a hard die under the daemon, and the two sibling callers were not converted to the _async variants that already exist

- **Location:** `lib/Registry/Service/Stripe.pm:235-252 (callers: lib/Registry/PriceOps/PaymentSchedule.pm:47,115,140,172,191,208; lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm:136,212,303)`

Commit aaf254a (in the range weighted as never reviewed) rewrote every sync wrapper to route through `_await`, which dies when the promise does not settle — the exact condition that holds under a running IOLoop, because `Mojo::Promise::wait` is a no-op there (`return if (my $loop = $self->ioloop)->is_running;`). The PR converted the one-time payment path to `_async` end to end, but `Registry::PriceOps::PaymentSchedule` (create/retrieve/cancel/pause/resume subscription) and `Registry::DAO::WorkflowSteps::InstallmentPayment` (create_payment_intent at :136 and :212, retrieve at :303) still call the sync wrappers, and both run inside the daemon's event loop when reached from a web request. The `_async` variants they would need already exist (create_subscription_async at Stripe.pm:147, cancel_subscription_async at :159, create_payment_intent_async at :72, retrieve_payment_intent_async at :78), so this is the root-cause fix applied to one caller instead of at the shared seam. Reachability check performed: no workflow YAML under workflows/ references the installment step, and `PriceOps::PaymentSchedule::create_for_enrollment` is called only from InstallmentPayment.pm:307, so both are currently unreachable dead code; `Registry::DAO::Payment::refund` (:433, sync) has no caller in lib/; Minion is unaffected because Minion::Job resets the loop in the forked child (local/lib/perl5/Minion/Job.pm:81); and `Registry::DAO::Subscription` has its own Mojo::UserAgent and never touches Registry::Service::Stripe.

**Impact:** No live path breaks today. But the installment-payment feature is now guaranteed to die on its first web request the moment anyone wires it into a workflow, with an error message ("use the _async variant there") that is correct and actionable but that nobody will see until a customer hits it. Flagged because the sweep treated aaf254a as a money-path-local change; it is a change to the transport shared by every Stripe caller in the tree, and only one caller was brought along.

### [low] The money-path design spec still documents the return_url contract that commit 93dcb86 replaced, and the synchronous-finalization property the Playwright smoke now depends on

- **Location:** `docs/superpowers/specs/2026-06-21-money-path-e2e-design.md:134-141`

Layer 2 of the spec pins two properties that the code no longer has. (1) It requires the smoke to 'preserve the template's `&payment_intent_id=...` query-param contract' — but 93dcb86 changed the template's return_url from `window.location.href + '&payment_intent_id={PAYMENT_INTENT}'` to a bare `url_for(...)->to_abs`, and the server now reads Stripe's own `payment_intent` parameter (Workflows.pm:256), not `payment_intent_id`. A reader implementing against the spec would build a URL the gate ignores. (2) It asserts the parent-return path 'finalizes enrollment synchronously' and reasons from that: 'Because the parent-return path finalizes synchronously, the smoke asserts a real enrollment without needing Stripe to deliver a webhook to CI.' That path is now a Mojo::Promise chain (Payment.pm:243-244 -> _settle_callback), so the property the CI-design argument rests on is no longer true as written — the smoke happens to still work because Mojolicious holds the response until the promise settles, but the spec's stated reason is wrong.

**Impact:** Documentation only — nothing at runtime depends on it. Worth correcting because this spec is the artifact the next person reads to decide whether the smoke can skip webhook delivery in CI, and both of its load-bearing sentences are now false. Included because the brief explicitly asked whether any claim in docs/superpowers/specs is not delivered by the code; this is the one that is not.

## Refuted (23) -- do not resurrect without new evidence

- **The duck-typed can('handle_payment_callback') gate also matches InstallmentPayment, whose finalizer is a raw non-idempotent INSERT** (`lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm:364`) -- 0/3 upheld
- **The only test for the new GET route stubs out the exact guard the commit relies on; _apply_intent's ownership and amount checks have zero coverage anywhere** (`t/controller/payment-return-callback.t:79`) -- 0/3 upheld
- **Every tenant not provisioned through the plan-selection step resolves to a 0% revenue share, so Registry collects nothing on their enrollments** (`lib/Registry/PriceOps/RevenueShare.pm:52`) -- 0/3 upheld
- **application_fee_amount => 0 is sent to Stripe on the Free-plan path and is only ever proven against a mock** (`lib/Registry/DAO/Payment.pm:99`) -- 0/3 upheld
- **Refunds are sent to Stripe with no Idempotency-Key, so a timed-out refund that an operator re-runs pays out twice** (`lib/Registry/Service/Stripe.pm:173`) -- 0/3 upheld
- **The refund's Connect params are decided from the tenant slug alone, while the charge's were decided from the connect account -- refunds of platform-routed tenant payments will be rejected** (`lib/Registry/DAO/Payment.pm:113`) -- 0/3 upheld
- **The live suite's refund subtest claims the transfer is reversed but only asserts it is greater than zero** (`t/stripe-live/paid-enrollment.t:390`) -- 0/3 upheld
- **A single partial refund permanently blocks any further refund of the same payment** (`lib/Registry/DAO/Payment.pm:434`) -- 0/3 upheld
- **finalize_enrollment is only half idempotent: the confirmation-notification leg is check-then-act with no unique constraint** (`lib/Registry/DAO/Notification.pm:439-447`) -- 0/3 upheld
- **suspend-rateless-tenant-plans suspends the wrong table for the charge-time resolver: a tenant already linked to the rateless plan still cannot take any payment** (`sql/deploy/suspend-rateless-tenant-plans.sql:21-33`) -- 0/3 upheld
- **_process_step sets render_later but the promise chain has no terminal catch — any die after Stripe settles hangs the browser silently** (`/home/perigrin/dev/Registry/.claude/worktrees/main/lib/Registry/Controller/Workflows.pm:383-401`) -- 0/3 upheld
- **The only end-to-end test that could catch a broken render path can never fail the build (continue-on-error on both real-Stripe steps)** (`/home/perigrin/dev/Registry/.claude/worktrees/main/.github/workflows/stripe-e2e.yml:83`) -- 1/3 upheld
- **The webhook test helper builds events with no amount, so the live suite's webhook subtest silently skips the new amount guard** (`/home/perigrin/dev/Registry/.claude/worktrees/main/t/lib/Test/Registry/StripeWebhook.pm:33`) -- 0/3 upheld
- **The Stripe-return GET test mocks away Payment::find, so it asserts only that a mock's methods were called** (`/home/perigrin/dev/Registry/.claude/worktrees/main/t/controller/payment-return-callback.t:79`) -- 0/3 upheld
- **t/security/stripe-test-keys.t does not prevent a pk_live_ key reaching a browser -- it only guards the server-side secret key** (`/home/perigrin/dev/Registry/.claude/worktrees/main/t/security/stripe-test-keys.t:20`) -- 0/3 upheld
- **The suspend predicate and its verify only catch a NULL rate, not an unusable one -- weaker than the invariant the change claims to enforce** (`sql/deploy/suspend-rateless-tenant-plans.sql:30`) -- 0/3 upheld
- **suspend-rateless-tenant-plans revert is not the inverse of its deploy when pricing_relationships.metadata is NULL** (`sql/deploy/suspend-rateless-tenant-plans.sql:23`) -- 0/3 upheld
- **refund-application-fee-config's verify cannot fail on the case its deploy silently skips (NULL pricing_configuration)** (`sql/verify/refund-application-fee-config.sql:23`) -- 1/3 upheld
- **payment-smoke.spec.js asserts nothing about Stripe -- its only durable check is satisfied by the free/demo enrollment path** (`t/playwright/payment-smoke.spec.js:165`) -- 0/3 upheld
- **Stripe secrets are exposed to every step of the stripe-e2e job, including `npm install` and `carton install` which execute third-party code** (`.github/workflows/stripe-e2e.yml:23`) -- 1/3 upheld
- **CI imports a real STRIPE_WEBHOOK_SECRET that no test needs -- both consumers override it or accept any string** (`.github/workflows/stripe-e2e.yml:29`) -- 1/3 upheld
- **Refunds are sent with no Idempotency-Key, so a timed-out refund that is retried refunds twice** (`lib/Registry/DAO/Payment.pm:442`) -- 0/3 upheld
- **Webhook acknowledges 200 even when the 'completed' write to the payment row silently fails** (`lib/Registry/Controller/Webhooks.pm:136`) -- 1/3 upheld
