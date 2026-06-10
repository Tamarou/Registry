-- Revert registry:tenant-stripe-connect from pg

BEGIN;
SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE tenants DROP COLUMN IF EXISTS stripe_connect_account_id;
ALTER TABLE tenants DROP COLUMN IF EXISTS stripe_charges_enabled;
ALTER TABLE tenants DROP COLUMN IF EXISTS stripe_details_submitted;

COMMIT;
