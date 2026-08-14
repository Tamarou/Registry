-- ABOUTME: Reverts refund_application_fee key from seeded plans.
-- ABOUTME: Uses #- operator to remove the key from the same target sets as deploy.

-- Revert registry:refund-application-fee-config from pg

BEGIN;

UPDATE registry.pricing_plans
   SET pricing_configuration = pricing_configuration #- '{refund_application_fee}'
 WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

UPDATE registry.pricing_plans
   SET pricing_configuration = pricing_configuration #- '{refund_application_fee}'
 WHERE plan_scope = 'tenant' AND pricing_model_type = 'percentage';

COMMIT;
