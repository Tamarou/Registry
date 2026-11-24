-- ABOUTME: Verify registry's payments carry the offer version stamp and the trigger that fixes it once set.
-- ABOUTME: Tenant schemas get the same column and trigger from the deploy loop and from clone_schema.

-- Verify registry:payments-offer-version-stamp on pg

BEGIN;

SELECT offer_version_id FROM registry.payments WHERE FALSE;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_trigger
                    WHERE tgrelid = 'registry.payments'::regclass
                      AND tgname = 'payments_offer_version_stamp') THEN
        RAISE EXCEPTION 'registry.payments has no payments_offer_version_stamp trigger';
    END IF;
END $$;

ROLLBACK;
