-- ABOUTME: Verify every offer_versions table has the missed_payment kind CHECK and no published version
-- ABOUTME: carries a condition with the retired offer_id field, in registry and every tenant schema.

-- Verify registry:priceops-session-vocabulary on pg

BEGIN;

DO $$
DECLARE
    s       name;
    retired boolean;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;
        IF NOT EXISTS (SELECT 1 FROM pg_constraint
                        WHERE conrelid = format('%I.offer_versions', s)::regclass
                          AND conname = 'offer_versions_missed_payment_kind_check') THEN
            RAISE EXCEPTION '%.offer_versions has no offer_versions_missed_payment_kind_check', s;
        END IF;
        EXECUTE format($sql$SELECT EXISTS (SELECT 1 FROM %I.offer_versions v
                         WHERE v.published_at IS NOT NULL
                           AND EXISTS (SELECT 1 FROM jsonb_array_elements(v.conditions) c WHERE c ? 'offer_id'))$sql$, s)
           INTO retired;
        IF retired THEN
            RAISE EXCEPTION 'a published offer version in % carries offer_id', s;
        END IF;
    END LOOP;
END $$;

ROLLBACK;
