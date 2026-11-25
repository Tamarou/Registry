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

-- A charge, sale or entitlement still naming the row keeps it: refuse, and the
-- transaction deletes nothing. pricing_plans ids also live in columns with no
-- foreign key, in registry and in every tenant schema.
-- Not checked: payments.metadata->>'platform_pricing_plan_id', a stamp nothing
-- reads any more; platform-entitlement-replaces-plan-link already let that column
-- form go as "not recorded". The revert restores the row with its id.
DO $$
DECLARE
    c record;
    hit uuid;
BEGIN
    FOR c IN
        SELECT table_schema, table_name, column_name
          FROM information_schema.columns
         WHERE (table_name, column_name) IN (('payments', 'platform_offer_version_id'),
                                             ('payments', 'offer_version_id'),
                                             ('payment_items', 'pricing_plan_id'),
                                             ('offer_versions', 'id'),
                                             ('entitlements', 'offer_version_id'),
                                             ('pricing_relationships', 'pricing_plan_id'))
           AND table_schema IN (SELECT 'registry' UNION ALL SELECT slug FROM registry.tenants)
         ORDER BY 1, 2, 3
    LOOP
        EXECUTE format('SELECT %3$I FROM %1$I.%2$I
                         WHERE %3$I IN (SELECT id FROM public.removed_free_platform_plan) LIMIT 1',
                       c.table_schema, c.table_name, c.column_name) INTO hit;
        IF hit IS NOT NULL THEN
            RAISE EXCEPTION 'remove-free-platform-plan refused: %.%.% references the Free plan (%). '
                            'Resolve what is held or sold under it before deploying.',
                            c.table_schema, c.table_name, c.column_name, hit;
        END IF;
    END LOOP;
END $$;

DELETE FROM registry.pricing_plans
 WHERE id IN (SELECT id FROM public.removed_free_platform_plan);

COMMIT;
