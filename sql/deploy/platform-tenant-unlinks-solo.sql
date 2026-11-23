-- ABOUTME: The platform tenant (slug registry) stops linking a platform pricing plan to itself.
-- ABOUTME: With no link it resolves the Free plan's 0%, so it takes no share of its own sales.

-- Deploy registry:platform-tenant-unlinks-solo to pg
-- requires: tenant-users-role

BEGIN;

SET client_min_messages = 'warning';

-- tenant-platform-pricing-plan backfilled Solo onto every tenant, the
-- platform's own rows included, and collapse-platform-tenant kept that link on
-- the surviving row. The platform would charge itself 2.5% of its own sales.
-- The link is cleared whatever plan it names: no plan is right for the
-- platform paying itself. Step 3 replaces the Free fallback with an explicit
-- 0% offer from the platform to itself.
UPDATE registry.tenants
   SET platform_pricing_plan_id = NULL
 WHERE id = '00000000-0000-0000-0000-000000000000';

COMMIT;
