-- ABOUTME: Verify every entitlements table has past due and the transfer link, and every payments table its entitlement.
-- ABOUTME: Also the six-state CHECK, the self-transfer CHECK and entitlement_stamp's refusal, per schema.

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
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = format('%I.entitlements', s)::regclass
                          AND conname = 'entitlements_state_check'
                          AND pg_get_constraintdef(oid) LIKE '%unpaid%'
                          AND pg_get_constraintdef(oid) LIKE '%transferred%') THEN
            RAISE EXCEPTION '%.entitlements_state_check lacks unpaid or transferred', s;
        END IF;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = format('%I.entitlements', s)::regclass
                          AND conname = 'entitlements_transferred_from_check') THEN
            RAISE EXCEPTION '%.entitlements may be transferred from itself', s;
        END IF;
        -- A tenant cloned with its own copy calls that copy; otherwise registry's.
        IF pg_get_functiondef(coalesce(to_regprocedure(format('%I.entitlement_stamp()', s)),
                                       'registry.entitlement_stamp()'::regprocedure))
           NOT LIKE '%NEW.transferred_from_entitlement_id IS DISTINCT FROM%' THEN
            RAISE EXCEPTION '%.entitlement_stamp does not keep the transfer link', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
