-- ABOUTME: Records which address provisioned a tenant, so provisioning can be rate limited durably.
-- ABOUTME: The card used to be the gate; with it gone, the count of recent clones per address is.

-- Deploy registry:tenant-created-from-ip to pg
-- requires: tenant-signup-drop-plan-page

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Signup is anonymous by necessity -- you cannot require a login to create an
-- account -- and dropping the card step removed the SetupIntent that #362 had
-- installed as the only thing bounding it. What the platform is protecting here
-- is not identity (an unverified tenant is inert: no password login exists, so
-- nobody can sign in without the admin's mailbox) but COST: every provisioning
-- runs clone_schema over every table and claims a subdomain.
--
-- Counting rows in this table is the rate limit, rather than a separate counter:
-- the thing being bounded is exactly the thing recorded, so the two cannot
-- drift. Registry::Middleware::RateLimit cannot serve here -- its counters are
-- per-process, in memory, reset on restart and not shared between instances.
--
-- inet, not text: it is an address, Postgres knows how to compare them, and a
-- text column invites '::1 ' with a trailing space counting as a different
-- client.
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS created_from_ip inet;

COMMENT ON COLUMN tenants.created_from_ip IS
    'Client address that provisioned this tenant; NULL for tenants created before this column, by CLI, or by tests. Used to rate limit provisioning.';

-- The rate-limit query is (address, recent), so both columns in that order.
CREATE INDEX IF NOT EXISTS idx_tenants_created_from_ip_created_at
    ON tenants (created_from_ip, created_at);

-- Tenant schemas carry a structural copy of every registry table, because
-- clone_schema builds them with LIKE. Keeping them identical means a schema
-- cloned before this change still matches one cloned after it.
DO $$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN to_regclass(format('%I.tenants', s)) IS NULL;
        EXECUTE format(
            'ALTER TABLE %I.tenants ADD COLUMN IF NOT EXISTS created_from_ip inet', s );
    END LOOP;
END $$;

COMMIT;
