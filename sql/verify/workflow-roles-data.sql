-- ABOUTME: Verify every schema's workflows carry roles and the public mark.
-- ABOUTME: Checked per schema, because a tenant's workflows live in its own schema.

-- Verify registry:workflow-roles-data on pg

BEGIN;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.workflows', s)) IS NULL;
        EXECUTE format('SELECT roles, public FROM %I.workflows WHERE false', s);
    END LOOP;

    -- A tenant's copy would otherwise arrive with no entry.
    IF pg_get_functiondef('registry.copy_workflow(text, uuid, text)'::regprocedure)
       NOT LIKE '%first_step, roles, public%' THEN
        RAISE EXCEPTION 'registry.copy_workflow does not copy roles and public';
    END IF;
END $$;

ROLLBACK;
