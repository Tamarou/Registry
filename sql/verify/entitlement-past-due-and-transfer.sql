-- ABOUTME: Verify every entitlements table has past due and the transfer link, and every payments table its entitlement.
-- ABOUTME: Checked per schema, because a tenant's entitlements live in its own schema.

-- Verify registry:entitlement-past-due-and-transfer on pg

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
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;
        EXECUTE format('SELECT past_due_since, transferred_from_entitlement_id
                          FROM %I.entitlements WHERE false', s);
        EXECUTE format('SELECT entitlement_id, invoice_id, failed_at
                          FROM %I.entitlement_past_due_invoices WHERE false', s);
        EXECUTE format('SELECT entitlement_id FROM %I.payments WHERE false', s);
    END LOOP;
END $$;

ROLLBACK;
