-- ABOUTME: An offer version's price, units, payment plans, policies and conditions, as declared data.
-- ABOUTME: Built in registry and every tenant schema; published versions' plans are immutable too.

-- Deploy registry:priceops-offer-policies to pg
-- requires: priceops-offer-versions

BEGIN;

SET client_min_messages = 'warning';

-- A published version's payment plans are part of its terms, but live in
-- their own rows, out of reach of offer_versions_immutable. This holds them
-- to the same rule: a plan whose version (before or after the change) is
-- published is never changed. A draft's plans stay editable, and discarding a
-- draft cascades to them because the parent row is already gone.
-- One shared function; each schema's table gets its own trigger.
CREATE OR REPLACE FUNCTION registry.offer_version_payment_plan_immutable() RETURNS trigger AS $t$
DECLARE
    old_version uuid;
    new_version uuid;
    v record;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_version := OLD.offer_version_id; END IF;
    IF TG_OP <> 'DELETE' THEN new_version := NEW.offer_version_id; END IF;
    -- FOR SHARE, so a concurrent publish waits for this change, or this one
    -- sees it. It locks only rows returned, so a draft is filtered out below.
    FOR v IN EXECUTE format(
        'SELECT offer_id, version, published_at FROM %I.offer_versions
          WHERE id IN ($1, $2) FOR SHARE', TG_TABLE_SCHEMA)
        USING old_version, new_version
    LOOP
        CONTINUE WHEN v.published_at IS NULL;
        RAISE EXCEPTION
            'offer % version % is published: its payment plans cannot be '
            'added, changed or removed. Publish a new version instead.',
            v.offer_id, v.version;
    END LOOP;
    RETURN CASE TG_OP WHEN 'DELETE' THEN OLD ELSE NEW END;
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
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );

        -- Columns on the version row are covered by offer_versions_immutable
        -- with no change to it. Nothing has been sold, so no row needs a value.
        EXECUTE format($f$
            ALTER TABLE %1$I.offer_versions
                ADD COLUMN price_cents integer NOT NULL
                    CONSTRAINT offer_versions_price_cents_check CHECK (price_cents >= 0),
                ADD COLUMN units_per_acceptance integer NOT NULL
                    CONSTRAINT offer_versions_units_per_acceptance_check CHECK (units_per_acceptance > 0),
                ADD COLUMN per_booking_cap integer NOT NULL
                    CONSTRAINT offer_versions_per_booking_cap_check CHECK (per_booking_cap > 0),
                -- { refund, change, use, expiry }, each { kind, ...its fields },
                -- validated by OfferVersion. The refund vocabulary is pinned
                -- here too, because the refund and publishing steps match on it.
                ADD COLUMN policies jsonb NOT NULL DEFAULT '{}'
                    CONSTRAINT offer_versions_policies_object CHECK (jsonb_typeof(policies) = 'object'),
                -- Requirements checked at acceptance, e.g. the sibling rate's
                -- { kind: family_holds_entitlement, offer_id }. Stored, not yet
                -- evaluated.
                ADD COLUMN conditions jsonb NOT NULL DEFAULT '[]'
                    CONSTRAINT offer_versions_conditions_array CHECK (jsonb_typeof(conditions) = 'array'),
                -- Absence is not "none": a version is published only with
                -- a refund policy someone chose.
                ADD CONSTRAINT offer_versions_published_states_refund CHECK (
                    published_at IS NULL OR policies ? 'refund'
                ),
                ADD CONSTRAINT offer_versions_refund_kind_check CHECK (
                    NOT policies ? 'refund'
                    OR coalesce(policies #>> '{refund,kind}', '') IN
                       ('none', 'full_until_cutoff', 'keep_fee_with_admin_exception')
                )
        $f$, s);

        -- The plans a customer chooses between. The id is the publisher's,
        -- unique within the version, so an entitlement can record which plan
        -- it was accepted under. A fraction is held to 4 decimal places by
        -- refusal, never rounding. A new kind is a new CHECK value plus its
        -- own columns, never a reinterpretation of these.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.offer_version_payment_plans (
                offer_version_id uuid NOT NULL
                    REFERENCES %1$I.offer_versions (id) ON DELETE CASCADE,
                id       text NOT NULL CHECK (id <> ''),
                kind     text NOT NULL CHECK (kind IN ('one_time', 'percentage_of_sales')),
                fraction numeric
                    CONSTRAINT offer_version_payment_plans_fraction_check
                    CHECK (fraction >= 0 AND fraction <= 1 AND scale(fraction) <= 4),
                PRIMARY KEY (offer_version_id, id),
                CONSTRAINT offer_version_payment_plans_fraction_matches_kind
                    CHECK ((kind = 'percentage_of_sales') = (fraction IS NOT NULL))
            )
        $f$, s);

        EXECUTE format(
            'DROP TRIGGER IF EXISTS offer_version_payment_plans_immutable ON %I.offer_version_payment_plans', s);
        EXECUTE format($f$
            CREATE TRIGGER offer_version_payment_plans_immutable
                BEFORE INSERT OR UPDATE OR DELETE ON %I.offer_version_payment_plans
                FOR EACH ROW EXECUTE FUNCTION registry.offer_version_payment_plan_immutable()
        $f$, s);
    END LOOP;
END $$;

COMMIT;
