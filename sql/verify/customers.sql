-- Verify sacregistry:customers on pg

BEGIN;

SELECT id, first_name, last_name, email, phone, notes
FROM registry.customers
WHERE FALSE;

ROLLBACK;
