-- Revert sacregistry:customers from pg

BEGIN;

DROP TABLE registry.customers;

COMMIT;
