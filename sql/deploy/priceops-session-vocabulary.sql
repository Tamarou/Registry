-- ABOUTME: Pins the missed_payment policy kinds on offer versions, and retires the singular sibling condition
-- ABOUTME: { family_holds_entitlement, offer_id } for { offer_ids? }, refusing to run over a published version using it.

-- Deploy registry:priceops-session-vocabulary to pg
-- requires: template-editor-admin-only

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    s        name;
    retired  text;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.offer_versions', s)) IS NULL;

        -- A published version is immutable, so its stored offer_id cannot be
        -- rewritten into offer_ids, and OfferVersion no longer reads it.
        EXECUTE format($sql$
            SELECT string_agg(format('offer %%s version %%s', v.offer_id, v.version), ', ')
              FROM %I.offer_versions v
             WHERE v.published_at IS NOT NULL
               AND EXISTS (SELECT 1 FROM jsonb_array_elements(v.conditions) c WHERE c ? 'offer_id')
        $sql$, s) INTO retired;
        IF retired IS NOT NULL THEN
            RAISE EXCEPTION 'published offer versions in % carry a condition with offer_id, '
                'the retired family_holds_entitlement shape: %. Publish new versions naming offer_ids '
                'and retire these before deploying.', s, retired;
        END IF;

        EXECUTE format($sql$
            ALTER TABLE %I.offer_versions
                ADD CONSTRAINT offer_versions_missed_payment_kind_check CHECK (
                    NOT policies ? 'missed_payment'
                    OR coalesce(policies #>> '{missed_payment,kind}', '') IN ('keep_and_owe', 'end', 'grace')
                )
        $sql$, s);
    END LOOP;
END $$;

COMMIT;
