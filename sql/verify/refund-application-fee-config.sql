-- ABOUTME: Verify refund_application_fee is declared on seeded plans.
-- ABOUTME: Asserts key presence on the platform default plan and all tenant percentage plans.

-- Verify registry:refund-application-fee-config on pg

BEGIN;

-- Platform default plan must have the key
SELECT 1/COUNT(*) FROM registry.pricing_plans
 WHERE plan_scope = 'platform'
   AND metadata->>'default' = 'true'
   AND pricing_configuration ? 'refund_application_fee';

-- No tenant percentage plan may lack the key (zero missing -> COUNT(*) = 0 -> 1/0 would
-- trigger; invert: assert zero rows missing the key via COUNT(*) = 0 check using a DO block)
DO $$
DECLARE missing_count INT;
BEGIN
    SELECT COUNT(*) INTO missing_count
      FROM registry.pricing_plans
     WHERE plan_scope = 'tenant'
       AND pricing_model_type = 'percentage'
       AND NOT (pricing_configuration ? 'refund_application_fee');

    IF missing_count > 0 THEN
        RAISE EXCEPTION 'refund_application_fee missing on % tenant percentage plan(s)', missing_count;
    END IF;
END $$;

ROLLBACK;
