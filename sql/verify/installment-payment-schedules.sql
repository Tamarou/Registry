-- ABOUTME: Superseded verify for the original installment schedule tables.
-- ABOUTME: Those tables are dropped by drop-installment-schedules; this asserts nothing.

-- Verify registry:installment-payment-schedules on pg

BEGIN;

-- Every object this change created is dropped by drop-installment-schedules,
-- whose verify asserts their absence.  Asserting anything here would have to be
-- true both at this point in the plan, where the tables exist, and at the end,
-- where they do not -- and nothing about these tables is true at both points.

ROLLBACK;
