-- ABOUTME: Delete the platform Free (0%) plan: absence is not zero, so no tenant falls back to it.
-- ABOUTME: The deleted rows are kept in public.removed_free_platform_plan so the revert re-inserts them by id.

-- Deploy registry:remove-free-platform-plan to pg
-- requires: drop-pricing-relationships

BEGIN;

SET client_min_messages = 'warning';

-- Outside registry: clone_schema copies every registry table into each new
-- tenant schema, and this is the revert's handle, not tenant data.
CREATE TABLE public.removed_free_platform_plan AS
SELECT * FROM registry.pricing_plans
 WHERE plan_scope = 'platform' AND metadata->>'default' = 'true';

DELETE FROM registry.pricing_plans
 WHERE id IN (SELECT id FROM public.removed_free_platform_plan);

COMMIT;
