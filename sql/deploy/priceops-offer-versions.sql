-- ABOUTME: PriceOps resources (finite or unbounded) and offers with append-only versions.
-- ABOUTME: Built in registry and every tenant schema; clone_schema gives new tenants the same.

-- Deploy registry:priceops-offer-versions to pg
-- requires: tenant-plan-has-rate

BEGIN;

SET client_min_messages = 'warning';

-- Immutability enforced here, not in the DAO, as pricing_plan_terms_immutable
-- does: psql and fixtures are held to it too. The allowed change is a
-- subtraction, so a column added later is protected automatically. A draft
-- (published_at NULL) is editable; once published only superseded_at may move.
-- One shared function; each schema's table gets its own trigger.
CREATE OR REPLACE FUNCTION registry.offer_version_immutable() RETURNS trigger AS $t$
BEGIN
    IF OLD.published_at IS NULL THEN
        RETURN NEW;
    END IF;
    IF ( to_jsonb(NEW) - 'superseded_at' ) IS DISTINCT FROM ( to_jsonb(OLD) - 'superseded_at' ) THEN
        RAISE EXCEPTION
            'offer_versions rows are immutable once published (offer % version %): '
            'publish a new version instead. Only superseded_at may change.',
            OLD.offer_id, OLD.version;
    END IF;
    RETURN NEW;
END;
$t$ LANGUAGE plpgsql;

-- One DDL template run for registry first and then every tenant schema, so the
-- copies cannot drift. Foreign keys name the same schema as the table: no
-- foreign key crosses schemas.
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

        -- Something a tenant controls access to. Finite resources have a
        -- capacity (0 allowed: a sold-out or closed occurrence); unbounded ones
        -- are limited only by policy and must not carry one.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.resources (
                id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                name       text NOT NULL,
                kind       text NOT NULL CHECK (kind IN ('finite', 'unbounded')),
                capacity   integer,
                created_at timestamp with time zone NOT NULL DEFAULT now(),
                CONSTRAINT resources_capacity_matches_kind CHECK (
                    (kind = 'finite' AND capacity IS NOT NULL AND capacity >= 0)
                    OR (kind = 'unbounded' AND capacity IS NULL)
                )
            )
        $f$, s);

        -- An offer is the family; its terms live on its versions.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.offers (
                id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                name       text NOT NULL,
                created_at timestamp with time zone NOT NULL DEFAULT now()
            )
        $f$, s);

        -- A version is a draft while published_at is NULL, and current while
        -- published and not superseded. Policies, payment plans and conditions
        -- arrive as further columns or child rows in later changes.
        EXECUTE format($f$
            CREATE TABLE IF NOT EXISTS %1$I.offer_versions (
                id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
                offer_id      uuid NOT NULL REFERENCES %1$I.offers (id),
                version       integer NOT NULL CHECK (version > 0),
                resource_id   uuid NOT NULL REFERENCES %1$I.resources (id),
                published_at  timestamp with time zone,
                superseded_at timestamp with time zone,
                created_at    timestamp with time zone NOT NULL DEFAULT now(),
                CONSTRAINT offer_versions_offer_version_key UNIQUE (offer_id, version),
                CONSTRAINT offer_versions_superseded_only_if_published
                    CHECK (superseded_at IS NULL OR published_at IS NOT NULL)
            )
        $f$, s);

        -- "The current version" has one answer per offer.
        EXECUTE format($f$
            CREATE UNIQUE INDEX IF NOT EXISTS offer_versions_one_current_per_offer
                ON %1$I.offer_versions (offer_id)
             WHERE published_at IS NOT NULL AND superseded_at IS NULL
        $f$, s);

        EXECUTE format(
            'DROP TRIGGER IF EXISTS offer_versions_immutable ON %I.offer_versions', s);
        EXECUTE format($f$
            CREATE TRIGGER offer_versions_immutable
                BEFORE UPDATE ON %I.offer_versions
                FOR EACH ROW EXECUTE FUNCTION registry.offer_version_immutable()
        $f$, s);
    END LOOP;
END $$;

COMMIT;
