-- ABOUTME: Superseded verify for the pricing relationship event log.
-- ABOUTME: Everything it checked is dropped by drop-pricing-relationships.

-- Verify registry:pricing-relationship-events on pg

BEGIN;

-- Every verify runs again against the final schema
-- (t/database/migration-verification.t), where none of what this change
-- created exists any more.  See drop-pricing-relationships' verify.

ROLLBACK;
