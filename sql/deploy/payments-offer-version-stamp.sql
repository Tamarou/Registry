-- ABOUTME: Stamps each payment with the offer version it was sold under: a same-schema foreign key, fixed once set.
-- ABOUTME: Added in registry and every tenant schema; after-school payments leave it NULL.

-- Deploy registry:payments-offer-version-stamp to pg
-- requires: platform-offer-resource-keeps-name

BEGIN;

SET client_min_messages = 'warning';

-- A refund or a change resolves against the terms a charge was sold under, so
-- the stamp is never re-pointed. Enforced here so psql and fixtures are held to
-- it too. One shared function; each schema's table gets its own trigger.
CREATE OR REPLACE FUNCTION registry.payment_offer_version_stamp() RETURNS trigger AS $t$
BEGIN
    IF OLD.offer_version_id IS NOT NULL
       AND NEW.offer_version_id IS DISTINCT FROM OLD.offer_version_id THEN
        RAISE EXCEPTION
            'payment % keeps the offer version it was sold under: its stamp cannot change.', OLD.id;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

DO $$
DECLARE
    s name;
BEGIN
    FOR s IN
        SELECT 'registry'::name
        UNION ALL
        SELECT slug::name FROM registry.tenants WHERE slug != 'registry'
    LOOP
        CONTINUE WHEN to_regclass(format('%I.payments', s)) IS NULL
                   OR to_regclass(format('%I.offer_versions', s)) IS NULL;

        -- Same schema: a tenant's sale is under its own offer version.
        EXECUTE format('ALTER TABLE %1$I.payments
            ADD COLUMN offer_version_id uuid REFERENCES %1$I.offer_versions (id)', s);
        EXECUTE format($c$COMMENT ON COLUMN %I.payments.offer_version_id IS
            'The offer version this charge was sold under, in this schema. Fixed once set.'$c$, s);
        EXECUTE format($f$
            CREATE TRIGGER payments_offer_version_stamp
                BEFORE UPDATE OF offer_version_id ON %I.payments
                FOR EACH ROW EXECUTE FUNCTION registry.payment_offer_version_stamp()
        $f$, s);
    END LOOP;
END $$;

COMMIT;
