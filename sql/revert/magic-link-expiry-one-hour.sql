-- Revert registry:magic-link-expiry-one-hour from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE tenants ALTER COLUMN magic_link_expiry_hours SET DEFAULT 24;

-- Only the rows this change moved. A tenant who picked something else since
-- keeps it.
UPDATE tenants SET magic_link_expiry_hours = 24 WHERE magic_link_expiry_hours = 1;

COMMENT ON COLUMN tenants.magic_link_expiry_hours IS NULL;

COMMIT;
