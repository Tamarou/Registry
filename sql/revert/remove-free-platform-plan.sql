-- ABOUTME: Restore the platform Free plan rows this change deleted, by id, from the table the deploy kept them in.
-- ABOUTME: Drops that table afterwards.

-- Revert registry:remove-free-platform-plan from pg

BEGIN;

INSERT INTO registry.pricing_plans
SELECT * FROM public.removed_free_platform_plan;

DROP TABLE public.removed_free_platform_plan;

COMMIT;
