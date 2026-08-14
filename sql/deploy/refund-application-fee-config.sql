-- ABOUTME: Declares refund_application_fee explicitly on seeded plans for visibility.
-- ABOUTME: Merges true onto the platform default plan and all tenant percentage plans.

-- Deploy registry:refund-application-fee-config to pg
-- requires: seed-free-platform-plan

BEGIN;

UPDATE registry.pricing_plans
   SET pricing_configuration = pricing_configuration || '{"refund_application_fee": true}'::jsonb
 WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

-- NOTE: this targets ALL tenant percentage plans, not just the launch plan the
-- tenant-platform-pricing-plan backfill selected. That is intentional: every
-- percentage plan should declare the flag. Default is true regardless; this
-- makes it visible.
UPDATE registry.pricing_plans
   SET pricing_configuration = pricing_configuration || '{"refund_application_fee": true}'::jsonb
 WHERE plan_scope = 'tenant' AND pricing_model_type = 'percentage';

COMMIT;
