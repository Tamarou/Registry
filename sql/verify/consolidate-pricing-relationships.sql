-- ABOUTME: Superseded verify for the pricing_relationships consolidation.
-- ABOUTME: Everything it checked is dropped by drop-pricing-relationships.

-- Verify registry:consolidate-pricing-relationships on pg

BEGIN;

-- Every verify runs again against the final schema
-- (t/database/migration-verification.t), where none of what this change
-- created exists any more.  See drop-pricing-relationships' verify.

ROLLBACK;
