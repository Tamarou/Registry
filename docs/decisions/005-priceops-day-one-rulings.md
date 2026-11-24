# ABOUTME: Architecture Decision Record holding perigrin's rulings on the PriceOps day-one questions outside ADR 004.
# ABOUTME: Covers delivery, admin roles, bootstrap, retiring old code, Stripe keys, SACP, money and refund edges, and /terms.

# ADR 005: PriceOps Day-One Rulings

**Status:** Accepted

**Date:** 2026-11-22

**Asked:** in the Claude Code session that executes the `priceops-day-one` chain,
<https://claude.ai/code/session_01V7rs98q3bwA7Cs9ZBpVuL5>, one question at a
time on 2026-11-22. Each ruling quotes perigrin's answer verbatim. The
questions' original numbers (1-14, from the consolidated message after
chain-review round 1) are kept for cross-reference. Questions 2, 3 and 6 are
recorded in [ADR 004](004-step-6-workflow-reach-and-storefront.md).

---

## Delivery

**14b. Where the git-zhi chain lives.** The chain is stored only in `refs/zhi`
in the session's container. perigrin first chose "Push refs/zhi
(Recommended)". The session's git proxy refused the push (HTTP 403: the
session may push only `claude/priceops-model-design-ad98wx`). Offered fallbacks,
he answered: "The refs are ephemeral we don’t need them". **Ruling:** nothing
backs up `refs/zhi`; the chain is disposable working state.

**14a. Pull request shape.** "One PR per step (Recommended)". **Ruling:** merge
#500 when step 0 is done; the working branch then restarts from `main` for
each step, giving one reviewable PR per step on the one branch this session
may push.

## Platform and tenancy (step 1)

**4. Admin role.** "Per-membership role (Recommended)". **Ruling:** step 1 adds
a role column to `tenant_users`, and admin checks read the role for the
current tenant. This closes the route by which an admin of any tenant, added
as a member of `registry`, became a platform admin through the global
`users.user_type`.

**5. Bootstrap from deployment configuration.** "Entrypoint command
(Recommended)". **Ruling:** the migration creates the `registry` row with safe
defaults. An idempotent `./registry platform bootstrap`, run by
`docker-entrypoint.sh` on every start after migrations, writes
`PLATFORM_STRIPE_ACCOUNT_ID`, `PLATFORM_STRIPE_READY` and
`PLATFORM_ADMIN_EMAIL`. It never overwrites a value an admin has since changed,
and a missing variable leaves the default and logs a warning.
What shipped, and how an operator runs and verifies it, is in
[the platform tenant bootstrap runbook](../operations/platform-tenant-bootstrap.md).

## Running workflows (steps 5 and 6)

**9. Retiring the old executor.** "Delete in step 5 (Recommended)".
**Ruling:** step 5 deletes `lib/Registry/Job/WorkflowExecutor.pm` and the
CLI-only `workflow_job` command once its run driver takes over their callers.
Issue `01a204ea` (attendance checks never schedule their next run, because
the executor stores the app object in JSON run data) is fixed by moving
attendance scheduling onto the new driver, not by patching the executor.

**10. SACP before step 6.** "Yes, one-time bridge (Recommended)". **Ruling:**
one recorded, manual `./registry workflow import sacp` is acceptable so SACP
can take Solo before step 6. Step 6's divergence report checks SACP's
workflows against its entitlement.

**11. The step-6 divergence report.** "You run it (Recommended)". **Ruling:**
the report is a read-only `./registry priceops divergence` command, tested
against fixtures. perigrin runs it in production and shares the output;
production data does not leave production.

## Stripe

**13. Stripe test key.** "Credential form at step 2 (Recommended)". GitHub
Actions already holds test-mode secrets (`stripe-e2e` ran against Stripe test
mode on 2026-11-22). **Ruling:** when step 2 starts, the executor confirms
that the session's environment is personal to perigrin, then requests an
`sk_test_` key through the secure credential form. The proxy injects it, and
the value never appears in chat or to the agent.

**Stripe activation wait (not in the original fourteen).** "Raise to 180s +
log (Recommended)". **Ruling:** the test helper's wait for a Stripe test
account to become chargeable rises from 90 to 180 seconds, and it logs each
account's actual activation time.

## In-studio money (step 7)

**7a. A payment succeeds after the seat hold lapsed and the seat was resold.**
"Auto-refund + notify (Recommended)". **Ruling:** refund automatically,
despite a "refund: none" policy (that policy governs customer cancellations,
not our race), and notify the parent and staff.

**7b. The charged amount differs from the quote.** "Refuse, refund, flag
(Recommended)". **Ruling:** no automatic booking; refund the charge; alert
staff and the platform. Staff can book by hand at the right price.

**7c. Rounding the 2.5% fee.** "Half to even (banker's)". **Ruling:** the fee
is computed once, at quote time, in integer cents, rounding an exact half to
the nearest even cent (32.5 ¢ becomes 32 ¢, 37.5 ¢ becomes 38 ¢). The displayed
fee, Stripe's `application_fee_amount` and the recorded fee all use that one
number. A test pins exact-half cases.

## Refunds (step 7)

**8a. A full refund after a partial one.** "Yes, capped (Recommended)".
**Ruling:** a full refund returns everything not already returned.

**8b. Time boundaries.** "Inclusive (Recommended)". **Ruling:** at exactly the
refund cutoff or the 48-hour change boundary the action is allowed
(`now <= boundary`). Display and server use one shared comparison.

**8c. A refund fails after the entitlement ended.** "Restore unless resold
(Recommended)". **Ruling:** restore the entitlement and alert staff. If the
seat was resold in the meantime, keep it ended and alert staff to pay the
parent out by hand.

## Open

**1. The in-studio draft.** "I'll push / point to it (Recommended)". On
2026-11-24 the old draft was still not on the remote, and asked again, perigrin
answered "Write from scratch (Recommended)". **Ruling:** the rewrite
(`docs/superpowers/specs/2026-11-24-in-studio-bookings-design.md`) is written
from scratch on the PriceOps model; no prior draft is used. Its own approval
still gates step 7.

**12. `/terms` wording.** "Placeholder + I supply text (Recommended)".
**Ruling:** the executor builds the `/terms` page, the agreement step and
terms versioning. Until perigrin supplies the text, a marked DRAFT placeholder
stands in, and production checkout is refused while it is in place.
