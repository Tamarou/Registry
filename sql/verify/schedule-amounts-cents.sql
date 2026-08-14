-- ABOUTME: Superseded verify for the installment schedule cents conversion.
-- ABOUTME: The tables it checked are dropped by drop-installment-schedules.

-- Verify registry:schedule-amounts-cents on pg

BEGIN;

-- Both converted tables are dropped by drop-installment-schedules, whose
-- verify asserts their absence.  The sibling conversions for payments and
-- pricing_plans keep their own verify scripts.

ROLLBACK;
