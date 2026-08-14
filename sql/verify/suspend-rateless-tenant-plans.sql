-- ABOUTME: Verify no selectable tenant plan lacks a revenue-share rate.
-- ABOUTME: Asserts the signup menu cannot offer a plan whose charges would all fail.

-- Verify registry:suspend-rateless-tenant-plans on pg

BEGIN;

DO $$
DECLARE rateless_count INT;
BEGIN
    SELECT COUNT(*) INTO rateless_count
      FROM registry.pricing_relationships pr
      JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
     WHERE pr.status = 'active'
       AND p.plan_scope = 'tenant'
       AND p.pricing_configuration->>'percentage' IS NULL;

    IF rateless_count > 0 THEN
        RAISE EXCEPTION '% selectable tenant plan(s) still have no revenue-share rate',
            rateless_count;
    END IF;
END $$;

ROLLBACK;
