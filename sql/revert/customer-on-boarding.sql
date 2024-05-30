-- Revert registry:customer-on-boarding from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

DROP TABLE IF EXISTS customer_users;
DROP TABLE IF EXISTS customer_profiles;
DROP TABLE IF EXISTS customers;

COMMIT;
