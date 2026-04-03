# Registry Production Readiness Roadmap

## Goal

Provably production-ready: validated, tested workflows for all user journeys
in both Perl HTTP tests and Playwright browser tests, covering happy paths
and critical unhappy paths, so that driving real traffic to the site does not
require constant attention.

## Current Baseline (2026-04-03)

- 153 Perl test files, 1632 tests, all passing
- 27 Playwright browser tests passing (auth + custom domains)
- 8 user journey tests (Morgan x4, Nancy x4), 188 assertions
- 6 security test suites (auth, CSRF, headers, rate limiting, input validation, accessibility)

## Phase 1: Close Critical Gaps

Core workflows that real users will hit on day one with zero browser-level coverage.

### Playwright: Summer Camp Registration (Happy Path)
- [ ] Account check step (existing user vs new user)
- [ ] Select children step
- [ ] Camper info step
- [ ] Session selection step
- [ ] Payment step
- [ ] Completion and confirmation

### Playwright: Parent Dashboard
- [ ] Dashboard loads with HTMX endpoints (upcoming events, attendance, messages)
- [ ] Enrollment list displays correctly
- [ ] Message unread count updates

### Waitlist Accept/Decline (Perl + Playwright)
- [ ] Perl: GET /waitlist/:id renders offer page
- [ ] Perl: POST /waitlist/:id/accept creates enrollment
- [ ] Perl: POST /waitlist/:id/decline processes next in queue
- [ ] Perl: Expired offer handled gracefully
- [ ] Playwright: Parent receives and accepts waitlist offer

### Payment Failure Paths (Perl)
- [ ] Card decline scenarios (insufficient funds, expired card)
- [ ] Duplicate webhook delivery (idempotency)
- [ ] Failed installment in multi-payment schedule
- [ ] Refund processing

## Phase 2: Complete Workflow Coverage

### Playwright: Tenant Signup
- [ ] 7-step workflow with subdomain validation
- [ ] Subdomain uniqueness check (real-time validation)
- [ ] Payment integration
- [ ] Completion redirects to new tenant

### Playwright: Admin Dashboard
- [ ] Program overview (HTMX loaded)
- [ ] Today's events
- [ ] Waitlist management view
- [ ] Enrollment trends
- [ ] Pending drop/transfer requests

### Drop/Transfer Workflows (Perl first, then Playwright)
- [ ] Perl: parent-drop-request workflow (select enrollment, reason, review, submit)
- [ ] Perl: admin-drop-approval workflow (review, decision, process)
- [ ] Perl: drop-request-processing (refund, waitlist promotion)
- [ ] Perl: parent-transfer-request workflow
- [ ] Perl: admin-transfer-approval workflow
- [ ] Perl: transfer-request-processing (capacity check, waitlist update)
- [ ] Playwright: Parent initiates drop request
- [ ] Playwright: Admin approves/denies drop request

### Teacher Dashboard (Perl + Playwright)
- [ ] Perl: GET /teacher/ renders dashboard
- [ ] Perl: GET /teacher/attendance/:event_id renders form
- [ ] Perl: POST /teacher/attendance/:event_id marks attendance
- [ ] Playwright: Teacher marks attendance for event

## Phase 3: Harden Unhappy Paths

### Cross-Tenant Isolation
- [ ] Tenant A cannot see Tenant B's enrollments, users, or sessions
- [ ] API requests scoped to correct tenant schema
- [ ] Cross-tenant URL manipulation returns 404 not someone else's data

### Capacity and Enrollment Edge Cases
- [ ] Enrolling in a full session returns clear error
- [ ] Duplicate enrollment attempt prevented
- [ ] Concurrent enrollment race condition handled
- [ ] Capacity change with existing waitlist

### Workflow Validation Errors
- [ ] Missing required fields show field-level errors
- [ ] Invalid data types rejected with clear messages
- [ ] Submitting a step out of order handled gracefully
- [ ] Browser back button during workflow does not corrupt state

### Auth Edge Cases
- [ ] Session expiration behavior
- [ ] Already-logged-in user hitting login page
- [ ] Magic link on different device than requested
- [ ] Concurrent sessions from same user

## Phase 4: Robustness

### Email Delivery Failures
- [ ] Magic link email send failure shows user feedback
- [ ] Notification email failure does not block workflow
- [ ] Retry logic for transient failures

### Database Constraint Handling
- [ ] Duplicate username gives clear error, not 500
- [ ] Duplicate email gives clear error, not 500
- [ ] Foreign key violations handled at service boundary

### Admin Dashboard Data Accuracy
- [ ] Enrollment counts match actual enrollments
- [ ] Revenue totals match actual payments
- [ ] Waitlist counts match actual waitlist entries
- [ ] Export data matches dashboard display

### Teacher Dashboard Completeness
- [ ] Attendance records persist correctly
- [ ] Multiple events in same day handled
- [ ] Substitute teacher access
