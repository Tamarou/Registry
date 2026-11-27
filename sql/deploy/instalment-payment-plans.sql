-- ABOUTME: Instalments are a payment plan kind beside one_time: a count, a cadence and an optional surcharge.
-- ABOUTME: Published only with a missed_payment policy, and discrete like one_time; registry and every tenant schema.

-- Deploy registry:instalment-payment-plans to pg
-- requires: waitlist-entries

BEGIN;

SET client_min_messages = 'warning';

-- What happens on a missed instalment is never left unspecified. Plans must
-- exist before a version is published (a published version's plans are
-- immutable) and policies are on the row itself, so the check needs nothing
-- later in the transaction; it is deferred alongside
-- offer_versions_require_payment_plan all the same. It reads its own row's
-- schema so clone_schema's copy works in each tenant.
CREATE FUNCTION registry.offer_version_instalments_need_missed_payment() RETURNS trigger AS $t$
DECLARE
    has_instalments boolean;
BEGIN
    IF NEW.published_at IS NULL OR NEW.policies ? 'missed_payment' THEN RETURN NULL; END IF;
    EXECUTE format(
        'SELECT EXISTS (SELECT 1 FROM %I.offer_version_payment_plans
                         WHERE offer_version_id = $1 AND kind = ''instalments'')',
        TG_TABLE_SCHEMA) INTO has_instalments USING NEW.id;
    IF has_instalments THEN
        RAISE EXCEPTION 'offer % version % offers instalments and has no missed_payment policy',
            NEW.offer_id, NEW.version USING ERRCODE = 'check_violation';
    END IF;
    RETURN NULL;
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
        CONTINUE WHEN to_regclass(format('%I.offer_version_payment_plans', s)) IS NULL;

        -- count parts, due every cadence; surcharge_pct, a percentage to two
        -- places, is added to the price. Only instalments carry these, and an
        -- instalments plan always has its count and cadence.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_version_payment_plans
                DROP CONSTRAINT offer_version_payment_plans_kind_check,
                ADD CONSTRAINT offer_version_payment_plans_kind_check
                    CHECK (kind IN ('one_time', 'percentage_of_sales', 'instalments')),
                ADD COLUMN count integer
                    CONSTRAINT offer_version_payment_plans_count_check CHECK (count BETWEEN 2 AND 52),
                ADD COLUMN cadence text
                    CONSTRAINT offer_version_payment_plans_cadence_check
                    CHECK (cadence IN ('weekly', 'monthly', 'quarterly')),
                ADD COLUMN surcharge_pct numeric
                    CONSTRAINT offer_version_payment_plans_surcharge_pct_check
                    CHECK (surcharge_pct >= 0 AND surcharge_pct <= 100 AND scale(surcharge_pct) <= 2),
                ADD CONSTRAINT offer_version_payment_plans_instalments_fields CHECK (
                    CASE WHEN kind = 'instalments' THEN count IS NOT NULL AND cadence IS NOT NULL
                         ELSE count IS NULL AND cadence IS NULL AND surcharge_pct IS NULL END
                )
        $f$, s);

        EXECUTE format($f$
            CREATE CONSTRAINT TRIGGER offer_versions_instalments_need_missed_payment
                AFTER INSERT OR UPDATE OF published_at ON %I.offer_versions
                DEFERRABLE INITIALLY DEFERRED
                FOR EACH ROW EXECUTE FUNCTION registry.offer_version_instalments_need_missed_payment()
        $f$, s);

        -- Instalments buy seats, as one_time does: a child may hold two
        -- sessions of one offer on instalments at once, so they are not
        -- schedule phases. priceops-entitlement-one-phase's exclusion,
        -- default-named as clone_schema names it.
        CONTINUE WHEN to_regclass(format('%I.entitlements', s)) IS NULL;
        EXECUTE format($f$
            ALTER TABLE %1$I.entitlements
                DROP CONSTRAINT entitlements_coalesce_offer_id_in_effect_excl,
                ADD CONSTRAINT entitlements_coalesce_offer_id_in_effect_excl EXCLUDE USING gist (
                    (coalesce(holder_user_id, holder_family_member_id, holder_tenant_id)) WITH =,
                    offer_id WITH =,
                    in_effect WITH &&
                ) WHERE (plan_kind NOT IN ('one_time', 'instalments'))
        $f$, s);
    END LOOP;
END $$;

COMMIT;
