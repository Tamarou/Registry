-- ABOUTME: The platform becomes one tenant row: the all-zeros row, renamed to slug registry.
-- ABOUTME: Moves everything that named the old registry row onto it first, then deletes that row.

-- Deploy registry:collapse-platform-tenant to pg
-- requires: workflow-step-label

BEGIN;

SET client_min_messages = 'warning';

-- Until now the platform was two rows: `registry` (a random uuid, owner of the
-- `registry` schema) and the all-zeros `registry-platform` (no schema; holds the
-- platform owner's membership and the platform's pricing_relationships).  The
-- all-zeros row is the one kept, because its id is what create-default-pricing-
-- relationships and every platform relationship already point at; the `registry`
-- schema simply becomes its schema, which works because a schema is found by
-- slug.
--
-- slug is UNIQUE, so the old row is deleted before the kept row takes its slug,
-- and everything naming the old row is moved first.  tenant_domains is ON DELETE
-- CASCADE: deleting first would lose the domains rather than move them.
DO $$
DECLARE
    kept CONSTANT uuid := '00000000-0000-0000-0000-000000000000';
    old  registry.tenants%ROWTYPE;
    col  record;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM registry.tenants WHERE id = kept) THEN
        RAISE EXCEPTION 'collapse-platform-tenant: there is no all-zeros platform row to keep';
    END IF;

    SELECT * INTO old FROM registry.tenants WHERE slug = 'registry' AND id <> kept;

    IF FOUND THEN
        -- Memberships.  The key is (tenant_id, user_id), so a user who belongs to
        -- both rows keeps the kept row's membership, made primary if either was.
        UPDATE registry.tenant_users k
           SET is_primary = true
          FROM registry.tenant_users d
         WHERE k.tenant_id = kept
           AND d.tenant_id = old.id
           AND d.user_id   = k.user_id
           AND d.is_primary;

        DELETE FROM registry.tenant_users d
         WHERE d.tenant_id = old.id
           AND EXISTS (SELECT 1 FROM registry.tenant_users k
                        WHERE k.tenant_id = kept AND k.user_id = d.user_id);

        UPDATE registry.tenant_users SET tenant_id = kept WHERE tenant_id = old.id;

        -- The profile.  One per tenant (tenant_id is the key), so where both rows
        -- have one, the kept profile's values stand and the old one fills its
        -- gaps -- the same rule the tenants columns get below.
        UPDATE registry.tenant_profiles k
           SET description       = COALESCE(k.description,       d.description),
               billing_email     = COALESCE(k.billing_email,     d.billing_email),
               billing_phone     = COALESCE(k.billing_phone,     d.billing_phone),
               billing_address   = COALESCE(k.billing_address,   d.billing_address),
               organization_type = COALESCE(k.organization_type, d.organization_type)
          FROM registry.tenant_profiles d
         WHERE k.tenant_id = kept
           AND d.tenant_id = old.id;

        DELETE FROM registry.tenant_profiles
         WHERE tenant_id = old.id
           AND EXISTS (SELECT 1 FROM registry.tenant_profiles WHERE tenant_id = kept);

        UPDATE registry.tenant_profiles SET tenant_id = kept WHERE tenant_id = old.id;

        -- Domains.  domain is globally UNIQUE, so the two rows cannot share one;
        -- what can collide is idx_tenant_domains_primary, one primary per tenant.
        -- The kept row's primary stays primary.
        UPDATE registry.tenant_domains
           SET is_primary = false
         WHERE tenant_id = old.id
           AND is_primary
           AND EXISTS (SELECT 1 FROM registry.tenant_domains
                        WHERE tenant_id = kept AND is_primary);

        UPDATE registry.tenant_domains SET tenant_id = kept WHERE tenant_id = old.id;

        -- Relationships the platform offers.
        UPDATE registry.pricing_relationships SET provider_id = kept WHERE provider_id = old.id;

        -- Every other uuid column in the registry schema named like a tenant id,
        -- whether or not a foreign key binds it: an unbound one would survive the
        -- delete below still holding an id that no longer exists.  At the time of
        -- writing this finds only subscription_events.tenant_id (FK-bound); there
        -- is no unbound one.  Discovered rather than listed so a column added
        -- before this runs in production is not missed.
        FOR col IN
            SELECT c.table_name, c.column_name
              FROM information_schema.columns c
              JOIN information_schema.tables t
                ON t.table_schema = c.table_schema AND t.table_name = c.table_name
             WHERE c.table_schema = 'registry'
               AND t.table_type   = 'BASE TABLE'
               AND c.data_type    = 'uuid'
               AND c.column_name LIKE '%tenant\_id'
               AND c.table_name NOT IN ('tenant_users', 'tenant_profiles', 'tenant_domains')
        LOOP
            EXECUTE format('UPDATE registry.%I SET %I = $1 WHERE %I = $2',
                           col.table_name, col.column_name, col.column_name)
              USING kept, old.id;
        END LOOP;

        DELETE FROM registry.tenants WHERE id = old.id;
    END IF;

    -- The kept row takes the slug, and the old row's configuration where it has
    -- none of its own.  A value already on the kept row is never overwritten.
    -- The two Stripe readiness flags are NOT NULL, so "none of its own" cannot be
    -- read off them; they describe the Connect account, and travel with it.
    -- platform_pricing_plan_id is deliberately left alone: clearing the
    -- platform's own plan is a separate change.
    UPDATE registry.tenants k
       SET slug                      = 'registry',
           canonical_domain          = COALESCE(k.canonical_domain, old.canonical_domain),
           created_from_ip           = COALESCE(k.created_from_ip,  old.created_from_ip),
           stripe_connect_account_id = COALESCE(k.stripe_connect_account_id, old.stripe_connect_account_id),
           stripe_charges_enabled    = CASE WHEN k.stripe_connect_account_id IS NULL
                                             AND old.stripe_connect_account_id IS NOT NULL
                                            THEN old.stripe_charges_enabled
                                            ELSE k.stripe_charges_enabled END,
           stripe_details_submitted  = CASE WHEN k.stripe_connect_account_id IS NULL
                                             AND old.stripe_connect_account_id IS NOT NULL
                                            THEN old.stripe_details_submitted
                                            ELSE k.stripe_details_submitted END
     WHERE k.id = kept;
END $$;

COMMIT;
