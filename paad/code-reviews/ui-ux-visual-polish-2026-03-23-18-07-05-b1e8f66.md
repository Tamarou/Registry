# Agentic Code Review: ui-ux-visual-polish

**Date:** 2026-03-23 18:07:05
**Branch:** ui-ux-visual-polish -> main
**Commit:** b1e8f669caaff916922fb2a0b5400aad7b6e41e2
**Files changed:** 26 | **Lines changed:** +1068 / -228
**Diff size category:** Large

## Executive Summary

The branch fixes 14 UI/UX issues across the TinyArtEmpire tenant signup workflow with solid template, CSS, and JS fixes. The core architectural improvement -- atomic jsonb merge in `WorkflowRun` -- is well-designed but introduced a critical regression: `process()` unconditionally advances `latest_step_id` and merges all step output (including validation errors and control-flow metadata) into persistent run data. This breaks step retry on validation failure and causes silent error swallowing in TenantPayment. Three critical issues require immediate attention.

## Critical Issues

### [C1] WorkflowRun::process advances latest_step_id on validation errors, breaking step retry
- **File:** `lib/Registry/DAO/WorkflowRun.pm:83-86`
- **Bug:** The atomic UPDATE unconditionally sets `latest_step_id = $step->id` regardless of whether the step returned `_validation_errors`. When the controller catches validation errors and redirects back, `next_step()` now returns the step AFTER the current one (since `latest_step_id` was advanced). The controller's assertion at `Workflows.pm:236` then `die`s with "Wrong step expected..." -- the user gets a 500 error when retrying.
- **Impact:** Any workflow step returning `_validation_errors` causes a fatal error on retry. This is a regression: the old code's `next_step` mechanism returned `$self->id` to signal "stay here," but the new atomic merge doesn't honor that signal.
- **Suggested fix:** Check for `_validation_errors` (and `errors`) before the atomic merge. Skip persistence and step advancement on validation failure:
  ```perl
  my $step_result = $step->process( $db, $new_data );
  if ($step_result->{_validation_errors} || $step_result->{errors}) {
      return $step_result;  # Don't persist or advance
  }
  # ... proceed with atomic merge ...
  ```
- **Confidence:** High
- **Found by:** Logic & Correctness, Contract & Integration, Error Handling

### [C2] TenantPayment uses 'errors' key but controller only checks '_validation_errors'
- **File:** `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm` (13 return paths at lines 31, 184, 194, 224, 258, 315, 332, 350, 370)
- **Bug:** TenantPayment returns `errors => [...]` in all error paths (rate limiting, missing billing info, max retries exceeded, Stripe failures). The controller at `Workflows.pm:268` only checks `$result->{_validation_errors}`. TenantPayment errors are never caught -- they get silently merged into run data and the workflow advances past the payment step.
- **Impact:** Users encountering payment errors (Stripe down, max retries, missing billing info) skip past the payment step instead of seeing the error. PricingPlanSelection was correctly updated to use `_validation_errors` but TenantPayment was not.
- **Suggested fix:** Either update TenantPayment to use `_validation_errors`, or update the controller to also check `errors`. The former is cleaner and consistent with PricingPlanSelection's pattern.
- **Confidence:** High
- **Found by:** Contract & Integration

### [C3] payment.html.ep still reads from undeclared $data variable -- Stripe payment form never renders
- **File:** `templates/tenant-signup/payment.html.ep:82,121,123,164`
- **Bug:** Lines 82, 121, 123, 164 reference `$data->{show_payment_form}`, `$data->{stripe_publishable_key}`, `$data->{client_secret}`, `$data->{setup_intent_id}`. The controller spreads `%$template_data` into the stash as individual keys, so there is no `$data` hashref. `$data` is undef. The billing/config reads on lines 4-8 were correctly fixed to use `stash()`, but the Stripe JS section was missed.
- **Impact:** `$data->{show_payment_form}` is always falsy, so the Stripe Elements form never shows. The "Add Payment Method" button always displays but clicking it submits to a Stripe integration with empty keys. This is a pre-existing bug that this branch partially fixed but did not complete.
- **Suggested fix:** Replace `$data->{...}` with `stash('...')` for the remaining references, consistent with the fixes already applied to lines 4-8.
- **Confidence:** High
- **Found by:** Error Handling

## Important Issues

### [I1] Control-flow metadata pollutes persistent workflow run data
- **File:** `lib/Registry/DAO/WorkflowRun.pm:83-86`
- **Bug:** `WorkflowRun::process` merges the entire step result hash into the persistent JSONB `data` column with zero filtering. Step results include transient keys like `next_step`, `errors`, `data` (nested template rendering data), `_validation_errors`, `tenant_created`, `retry_count`, `retry_delay`, `should_retry`. These all accumulate permanently. PricingPlanSelection's "show plan" return includes the full pricing plan catalog in `data => { pricing_plans => [...] }`.
- **Impact:** Run data grows unboundedly with transient metadata. Stale `errors` or `_validation_errors` from one step persist across future steps. A nested `data` key collides conceptually with `$run->data`.
- **Suggested fix:** Strip known transient keys before merging: `delete @to_persist{qw(next_step errors data _validation_errors retry_count retry_delay retry_exceeded should_retry)}`. Or establish a `_persist` convention in step return values.
- **Confidence:** High
- **Found by:** Logic & Correctness, Contract & Integration

### [I2] TenantPayment double-write: update_data inside process() plus WorkflowRun::process merge
- **File:** `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:64,267,301,376,514,546`
- **Bug:** TenantPayment::process fetches its own `$run` (line 19) and calls `$run->update_data()` at 6 callsites for subscription, payment_setup, retry, and rate-limiting data. Then returns a hash that `WorkflowRun::process` also merges. Two atomic UPDATEs on the same row, not in a transaction. Currently safe because keys don't overlap, but fragile. PricingPlanSelection was correctly refactored to return-only; TenantPayment was not.
- **Impact:** Inconsistent step contract. Future key overlaps between internal `update_data` and returned hash would cause silent data loss (last writer wins via shallow `||` merge). A crash between the two UPDATEs leaves data persisted but `latest_step_id` not advanced, causing retry and potential duplicate Stripe operations.
- **Suggested fix:** Refactor TenantPayment to follow PricingPlanSelection's return-data pattern. Track as follow-up if too large for this branch.
- **Confidence:** High
- **Found by:** Concurrency & State, Contract & Integration, Logic & Correctness

### [I3] update_data and process dereference undef when UPDATE matches no rows
- **File:** `lib/Registry/DAO/WorkflowRun.pm:65,86`
- **Bug:** If `$id` doesn't match any row, `->expand->hash` returns `undef`. The next line `$data = $result->{data}` crashes with "Can't use undefined value as HASH reference" -- no useful diagnostic.
- **Impact:** Stale run objects or concurrent deletes cause unhandled fatal errors instead of recoverable errors with context.
- **Suggested fix:** Guard: `croak "WorkflowRun id=$id not found during update" unless $result;`
- **Confidence:** High
- **Found by:** Error Handling

### [I4] payment.html.ep hardcodes "30-day free trial" while review uses dynamic trial_days
- **File:** `templates/tenant-signup/payment.html.ep:58,73-75`
- **Bug:** Payment template hardcodes "30-day free trial" and `DateTime->now->add(days => 30)`. Review template correctly reads `$plan_config->{trial_days} // 30`. A plan with 14-day trial shows "30-day" on payment but "14-day" on review.
- **Impact:** Contradictory trial period information between adjacent workflow steps. Could be a legal issue since payment is where users commit to terms.
- **Suggested fix:** Read `trial_days` from `stash('subscription_config')->{trial_days}` (already available) and use it dynamically.
- **Confidence:** High
- **Found by:** Error Handling

### [I5] DOM-based XSS via innerHTML in payment showPaymentError
- **File:** `templates/tenant-signup/payment.html.ep:217-223`
- **Bug:** `errorDiv.innerHTML = \`...<div class="error-message">${message}</div>...\`` where `message` comes from `error.message` (Stripe SDK). Using innerHTML with external strings is a security anti-pattern.
- **Impact:** Narrow attack surface (requires malicious Stripe SDK response or supply-chain compromise), but the page handles payment information. Fix is trivial.
- **Suggested fix:** Use `textContent` for the message: `errorDiv.querySelector('.error-message').textContent = message;`
- **Confidence:** Medium
- **Found by:** Security

### [I6] InstallmentPayment has same double-write pattern as TenantPayment
- **File:** `lib/Registry/DAO/WorkflowSteps/InstallmentPayment.pm:150,226,319`
- **Bug:** Same pattern as I2: fetches own `$run` (line 18), calls `update_data` at 3 callsites, then returns a hash for WorkflowRun::process to merge.
- **Impact:** Same fragility as TenantPayment. Should be refactored to return-data pattern.
- **Suggested fix:** Track as follow-up alongside TenantPayment refactor.
- **Confidence:** High
- **Found by:** Concurrency & State

## Suggestions

- **[S1]** `templates/tenant-signup/pricing.html.ep:36` -- No fallback message when `@$pricing_plans` is empty. Users see a blank grid with a submit button. Add a guard with a "No plans available" message. (Error Handling)
- **[S2]** `templates/tenant-signup/payment.html.ep:121,123,164` -- HTML `<%= %>` escaping used inside `<script>` tag is the wrong escaping context for JS strings. Currently moot since values are undef (C3), but will become relevant when C3 is fixed. Use `data-*` attributes instead. (Security)
- **[S3]** `templates/tenant-signup/review.html.ep:154` vs `lib/Registry/DAO/WorkflowSteps/TenantPayment.pm:154` -- `trial_days` uses `//` in review template but `||` in TenantPayment. Different behavior for `trial_days => 0`. Use `//` consistently. (Error Handling)
- **[S4]** TenantPayment (line 19) and InstallmentPayment (line 18) fetch their own `$run` via `$workflow->latest_run($db)`, creating a separate object from the caller's run. After both objects write to the same DB row, in-memory state diverges. Latent trap for future code that reads stale data. (Concurrency & State)

## Review Metadata

- **Agents dispatched:** Logic & Correctness, Error Handling & Edge Cases, Contract & Integration, Concurrency & State, Security
- **Scope:** 26 changed files + callers/callees (WorkflowProcessor.pm, WorkflowExecutor.pm, InstallmentPayment.pm, WorkflowStep.pm base class, Controller/Workflows.pm)
- **Raw findings:** 16 (before verification)
- **Verified findings:** 13 (after verification)
- **Filtered out:** 3 (Finding 2 subsumed by C1, Finding 10 unrealistic input path, Finding 16 product decision)
- **Steering files consulted:** CLAUDE.md (project root), CLAUDE.md (user global)
- **Plan/design docs consulted:** none found
