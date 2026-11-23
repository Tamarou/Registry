-- ABOUTME: Gives the all-zeros row its registry-platform slug back and re-creates a registry row.
-- ABOUTME: It cannot un-merge: everything the deploy moved stays on the all-zeros row.

-- Revert registry:collapse-platform-tenant from pg

BEGIN;

SET client_min_messages = 'warning';

-- The deploy moved memberships, the profile, domains, pricing relationships and
-- every tenant_id that named the old registry row onto the all-zeros row, merged
-- duplicates, and copied configuration across.  Nothing records which rows came
-- from where, so this restores the two-row shape -- the slugs, and a fresh
-- `registry` row with a new id and the seed's name -- and no more.  The moved
-- rows, and the configuration the kept row took, stay where the deploy put them.
UPDATE registry.tenants
   SET slug = 'registry-platform'
 WHERE id = '00000000-0000-0000-0000-000000000000';

INSERT INTO registry.tenants (name, slug)
VALUES ('Registry System', 'registry')
ON CONFLICT (slug) DO NOTHING;

COMMIT;
