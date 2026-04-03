# Phase 1: Production Readiness Test Spec

## Overview

Registry needs provably production-ready test coverage before driving real
traffic. This spec covers the first phase: validated, tested workflows for all
core user journeys in both Perl HTTP tests and Playwright browser tests,
covering happy paths and critical unhappy paths.

## Context

### Current Baseline (2026-04-03)
- 153 Perl test files, 1632 tests, all passing
- 27 Playwright browser tests (auth + custom domains only)
- 8 user journey tests (Morgan x4, Nancy x4), 188 assertions
- 6 security test suites
- Zero Playwright coverage for registration, dashboard, or waitlist flows

### Target Customer
Super Awesome Cool Pottery — a pottery studio in Orlando currently on HiSawyer,
switching to Registry (Tiny Art Empire). They run weekly summer camps (K-5th
grade, Mon-Fri 9am-4pm, $300/week, capacity 16 students) at their studio
location (930 Hoffner Ave, Orlando, FL 32809).

### Architectural Principles
- **Workflows drive the experience.** Controllers process workflows; they do
  not implement bespoke page logic. The public program listing page should be
  a workflow with continuations (`callcc`) into registration workflows.
- **Program types are distinct workflows.** Camps and afterschool programs have
  separate workflows that may share steps (account-check, select-children,
  payment).
- **Pricing is revenue-share.** The platform takes 2.5% from the provider
  (Jordan). Parents see the camp price only — no processing fees, no platform
  surcharges.
- **Payment in tests uses demo mode.** When `STRIPE_SECRET_KEY` is not set,
  the payment step accepts a terms-agreement checkbox without Stripe Elements.
  Real Stripe integration tests will be added when keys are configured.

## Prerequisites (Separate Tickets)

These must be completed before the tests in this spec can be fully implemented:

### P1: Tenant Storefront Workflow
A workflow (e.g., `tenant-storefront`) that runs at the tenant subdomain root
(`/`). Its step(s) list available programs and sessions for the current tenant,
with "Register" buttons implemented as `callcc` continuation links to the
appropriate registration workflow (`summer-camp-registration-enhanced`, etc.).

This replaces the current `Schools` controller (`/school/:slug`) with the
proper workflow architecture. The existing `Schools#show` logic (session
grouping, pricing lookup, capacity display, HTMX filtering) moves into a
workflow step class.

**Route change:** The root route on tenant subdomains should render this
workflow instead of the Tiny Art Empire marketing page.

### P2: Marketing Opt-In Capture
Add consent checkboxes during the `account-check` workflow step for:
- Provider communications (e.g., "Receive news from Super Awesome Cool Pottery")
- Platform communications (e.g., "Receive Tiny Art Empire updates")

Store consent with timestamp in user preferences.

### P3: Route Naming Cleanup
The `/school/:slug` route and "Schools" controller naming is a holdover from
the afterschool model. Programs should have program-type-appropriate entry
points. This is addressed by P1 (workflow-driven storefront) but any remaining
references need cleanup.

## Test Data Setup

### Script: `t/playwright/setup_registration_test_data.pl`

Follows the pattern established by `t/playwright/setup_domain_test_data.pl`.
Accepts `DB_URL` env var, outputs JSON with IDs and tokens needed by tests.

Creates:

```
Tenant: "Super Awesome Cool Pottery"
  slug: super-awesome-cool-pottery

Location: "Super Awesome Cool Pottery Studio"
  address: 930 Hoffner Ave, Orlando, FL 32809

Program (Project): "Potter's Wheel Art Camp - Summer 2026"
  program_type: summer-camp
  age_range: { min: 5, max: 11 }  (K-5th grade)
  notes: "FULL Day Camp | M-F | 9am-4pm | Grades K to 5"

Sessions (3 weekly sessions):
  - "Week 1 - Jun 1-5"   capacity: 16, status: published, price: $300
  - "Week 2 - Jun 8-12"  capacity: 16, status: published, price: $300
  - "Week 3 - Jun 15-19" capacity: 2,  status: published, price: $300
    (low capacity for waitlist testing)

Events: 5 per session (Mon-Fri), 9am-4pm, linked to location

Pricing Plan: $300 per session, type: standard

Pre-seeded Users:
  - returning_parent: user_type=parent, email, magic link token
    - existing_child: "Emma Johnson", DOB 2018-03-15, grade 3rd
  - admin_user: user_type=admin, for waitlist management

Pre-seeded Enrollments (for waitlist tests on Week 3):
  - 2 existing enrollments filling Week 3 to capacity
```

Output JSON format:
```json
{
  "tenant_slug": "super-awesome-cool-pottery",
  "tenant_id": "...",
  "location_id": "...",
  "program_id": "...",
  "sessions": {
    "week1": { "id": "...", "name": "Week 1 - Jun 1-5" },
    "week2": { "id": "...", "name": "Week 2 - Jun 8-12" },
    "week3_full": { "id": "...", "name": "Week 3 - Jun 15-19" }
  },
  "returning_parent": {
    "token": "...",
    "user_id": "...",
    "email": "...",
    "child_id": "...",
    "child_name": "Emma Johnson"
  },
  "admin": {
    "token": "...",
    "user_id": "..."
  }
}
```

## Test Specifications

### 1. Summer Camp Registration

#### 1.1 Happy Path — New Parent

**Perl test:** `t/controller/camp-registration-new-parent.t`
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "New parent registration")

Flow:
1. GET program listing page → 200, shows "Potter's Wheel Art Camp"
2. Click "Enroll Now" for Week 1 → redirected to registration workflow landing
3. POST landing step → redirected to account-check step
4. POST account-check with `action=create_account` → account created, redirected to select-children
5. POST select-children with `action=add_child`:
   - `new_child_name`: "Liam Martinez"
   - `new_birth_date`: "2017-09-01" (age 8, within K-5 range)
   - `new_grade`: "3"
   - `new_allergies`: "peanuts"
   - `new_medications`: ""
   - `new_medical_notes`: ""
   - `new_emergency_name`: "Sofia Martinez"
   - `new_emergency_phone`: "407-555-0123"
   - `new_emergency_relationship`: "Mother"
6. POST select-children with `action=continue`, child selected → redirected to session-selection
7. POST session-selection with `session_<child_id>=<week1_id>` → redirected to payment
8. POST payment with `agreeTerms=1` (demo mode) → redirected to complete
9. GET complete → 200, confirmation displayed

**Assertions (Perl):**
- Each step returns correct HTTP status (200 for GET, 302 for POST)
- User created in DB with correct email and user_type=parent
- FamilyMember created with correct name, DOB, grade, medical info, emergency contact
- Enrollment created with status=active, correct session_id and family_member_id
- Workflow run completed (all steps processed)

**Assertions (Playwright):**
- Each page renders with correct heading/content
- Form fields accept input and submit succeeds
- Error states not shown on valid input
- Confirmation page displays enrollment details

#### 1.2 Happy Path — Returning Parent

**Perl test:** `t/controller/camp-registration-returning-parent.t`
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "Returning parent registration")

Flow:
1. GET program listing → click "Enroll Now" for Week 2
2. Landing → proceed
3. Account-check → POST with `action=login`, existing credentials
4. Select-children → existing child "Emma Johnson" listed with checkbox, select and continue (no new child entry needed)
5. Session selection → pick Week 2
6. Payment → agree to terms
7. Complete → confirmation

**Assertions:**
- No new user created (existing user reused)
- No new FamilyMember created (existing child reused)
- New enrollment created for existing child in Week 2
- Child's existing medical info and emergency contact preserved

#### 1.3 Unhappy Path — Duplicate Email

**Perl test:** `t/controller/camp-registration-errors.t` (subtest: "duplicate email")
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "Registration errors")

Flow:
1. Start registration workflow → reach account-check step
2. POST create_account with email belonging to returning_parent
3. Response should show clear error message, not a 500

**Assertions (Perl):**
- HTTP status is 200 (re-renders form), not 500
- Response body contains error message about existing account
- No duplicate user created in DB

**Assertions (Playwright):**
- Error message visible on page
- Form still functional (can try again or switch to login)
- No browser error/crash

#### 1.4 Unhappy Path — Full Session

**Perl test:** `t/controller/camp-registration-errors.t` (subtest: "full session")
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "Registration errors")

Flow:
1. Complete through select-children with a new child
2. At session-selection, Week 3 (capacity 2, already full) should show as unavailable
3. If user attempts to select it, should be offered waitlist

**Assertions (Perl):**
- Session-selection step data shows Week 3 with `is_full=true`
- Week 3 radio button is disabled or shows "Full - Waitlist available"
- Selecting a full session redirects to waitlist flow (or shows waitlist option)

**Assertions (Playwright):**
- Full session visually distinguished (greyed out, "Full" badge)
- "Join Waitlist" option visible for full session
- Available sessions still selectable

#### 1.5 Unhappy Path — Age/Grade Mismatch

**Perl test:** `t/controller/camp-registration-errors.t` (subtest: "age mismatch")
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "Registration errors")

Flow:
1. Add a child with birth_date making them age 3 (below K range)
2. At session-selection, sessions should show as unavailable for this child
3. Clear message about age range requirement

**Assertions (Perl):**
- Session-selection step data shows `age_appropriate=false` for underage child
- Sessions disabled with age range message

**Assertions (Playwright):**
- Sessions visually disabled for ineligible child
- Age range message displayed ("Age range: 5-11 years")

#### 1.6 Unhappy Path — Abandoned Workflow Resume

**Perl test:** `t/controller/camp-registration-resume.t`
**Playwright test:** `t/playwright/camp-registration.spec.js` (describe: "Workflow resume")

Flow:
1. Start registration as new parent through select-children (child added)
2. Record the workflow run ID and current step
3. Close browser / new session
4. Navigate back to the workflow run URL
5. Select-children step renders with previously added child data preserved

**Assertions (Perl):**
- GET workflow run at select-children step returns 200
- Response contains previously added child name
- Workflow run data in DB preserves child info across sessions

**Assertions (Playwright):**
- Page loads with child data visible
- Can continue workflow from where left off
- Previously entered data not lost

### 2. Parent Dashboard

**Playwright test:** `t/playwright/parent-dashboard.spec.js`

Prerequisite: Complete a registration (new parent happy path) first, then
navigate to parent dashboard.

#### 2.1 Enrollment Visible

Flow:
1. Authenticate as parent (magic link)
2. GET `/parent/dashboard` → 200
3. Dashboard shows enrolled child and session

**Assertions:**
- Child name appears on dashboard
- Session name appears (e.g., "Week 1 - Jun 1-5")
- Enrollment status shows as active

#### 2.2 Upcoming Events Display

Flow:
1. Wait for HTMX endpoint `/parent/dashboard/upcoming_events` to load
2. Events from enrolled session visible

**Assertions:**
- At least one upcoming event displayed
- Event shows date and time

#### 2.3 Unread Messages Count

Flow:
1. HTMX endpoint `/parent/dashboard/unread_messages_count` loads
2. Shows count (0 for new parent)

**Assertions:**
- Unread count element present
- Shows "0" or appropriate count

### 3. Waitlist Accept/Decline

#### 3.1 Accept Path

**Perl test:** `t/controller/waitlist-accept-decline.t` (subtest: "accept offer")
**Playwright test:** `t/playwright/waitlist-flow.spec.js` (describe: "Accept waitlist offer")

Setup: Week 3 is full (capacity 2, 2 enrolled). Nancy joins waitlist.

Flow:
1. Nancy enrolls → offered waitlist for Week 3 → joins waitlist (position 1)
2. Admin cancels one existing enrollment (spot opens)
3. System processes waitlist → Nancy gets offer
4. GET `/waitlist/:id` → 200, offer page with time remaining
5. POST `/waitlist/:id/accept` → enrollment created

**Assertions (Perl):**
- Waitlist entry created with correct position
- After cancellation + processing, waitlist entry status = "offered"
- Offer has expiration timestamp in the future
- POST accept creates enrollment with status=active (or pending)
- Waitlist entry status updated to "accepted"
- Enrollment count for session incremented

**Assertions (Playwright):**
- Offer page shows session name, time remaining
- Accept button visible and functional
- After accept, redirected to confirmation or dashboard
- Enrollment visible on parent dashboard

#### 3.2 Decline Path

**Perl test:** `t/controller/waitlist-accept-decline.t` (subtest: "decline offer")
**Playwright test:** `t/playwright/waitlist-flow.spec.js` (describe: "Decline waitlist offer")

Setup: Two parents on waitlist. First parent gets offer.

Flow:
1. Parent A and Parent B both join waitlist (positions 1 and 2)
2. Spot opens → Parent A gets offer
3. POST `/waitlist/:id/decline` → Parent A's offer declined
4. System processes waitlist → Parent B gets offer
5. Parent B accepts

**Assertions (Perl):**
- Parent A's waitlist entry status = "declined"
- Parent B's waitlist entry status changes from "waiting" to "offered"
- Parent B can accept and create enrollment
- No enrollment created for Parent A

**Assertions (Playwright):**
- Decline button visible and functional
- After decline, appropriate confirmation/message shown
- Parent B's offer page accessible and functional

#### 3.3 Expired Offer

**Perl test:** `t/controller/waitlist-accept-decline.t` (subtest: "expired offer")

Flow:
1. Parent joins waitlist → gets offer
2. Offer expires (manipulate expiration timestamp in DB for testing)
3. GET `/waitlist/:id` → shows expired message
4. POST `/waitlist/:id/accept` → rejected gracefully

**Assertions:**
- Expired offer page shows clear message (not a 500)
- Accept on expired offer returns error, does not create enrollment
- Next person in queue can be offered the spot

### 4. Payment Failures (Perl Only)

**Test file:** `t/controller/payment-failures.t`

These tests simulate Stripe API responses and webhook events at the HTTP layer
without requiring Stripe API keys.

#### 4.1 Card Decline

Simulate Stripe webhook with `payment_intent.payment_failed` event containing
decline codes: `insufficient_funds`, `expired_card`.

**Assertions:**
- Payment record status updated to "failed"
- Failure reason stored (decline code + message)
- Enrollment not created (or status set to payment_failed)
- Error propagated to workflow step with user-friendly message

#### 4.2 Duplicate Webhook Delivery

Send the same webhook event twice (same event ID).

**Assertions:**
- First delivery processed normally
- Second delivery returns 200 (acknowledged) but does not duplicate processing
- Payment record not duplicated
- Enrollment not duplicated

#### 4.3 Failed Installment

Setup: 3-installment payment schedule ($100 x 3).

Flow:
1. First installment succeeds
2. Second installment fails (card declined webhook)

**Assertions:**
- PaymentSchedule status reflects partial payment
- ScheduledPayment for installment 2 marked as failed with reason
- Enrollment status updated appropriately (e.g., "payment_hold")
- Installment 3 not charged until installment 2 resolved

#### 4.4 Refund Processing

Flow:
1. Successful payment exists
2. Process refund via `Payment->create_refund` or webhook

**Assertions:**
- Refund record created with correct amount
- Original payment status updated
- Enrollment status updated if full refund (e.g., "cancelled")
- Partial refund does not cancel enrollment

## File Organization

```
t/
  controller/
    camp-registration-new-parent.t
    camp-registration-returning-parent.t
    camp-registration-errors.t
    camp-registration-resume.t
    waitlist-accept-decline.t
    payment-failures.t
  playwright/
    setup_registration_test_data.pl
    camp-registration.spec.js
    parent-dashboard.spec.js
    waitlist-flow.spec.js
```

## Implementation Order

1. `setup_registration_test_data.pl` — test data script (everything depends on this)
2. Camp registration Perl tests (happy paths first, then unhappy paths)
3. Camp registration Playwright tests (mirrors Perl test scenarios)
4. Parent dashboard Playwright tests
5. Waitlist Perl + Playwright tests
6. Payment failure Perl tests

## Dependencies

- Existing workflow infrastructure (WorkflowProcessor, continuations, callcc)
- Existing auth infrastructure (magic links, session management)
- Existing Playwright test infrastructure (db_manager.pl, fixtures pattern)
- Test database with schema deployed and workflows imported
- `carton exec ./registry workflow import registry` before running tests

## Notes

- All Playwright tests run against demo payment mode (no STRIPE_SECRET_KEY)
- Perl tests can test Stripe webhook handling with mock signatures
- The tenant-storefront workflow (prerequisite P1) may not exist when initial
  tests are written; tests can use the existing `/school/:slug` route or
  direct workflow URLs as a temporary entry point, with a TODO to update
  when P1 is complete
- Test data script creates unique usernames/emails using timestamps to avoid
  conflicts with parallel test runs
