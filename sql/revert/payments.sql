-- Revert registry:payments from pg

BEGIN;

DROP TABLE IF EXISTS registry.payment_items;
DROP TABLE IF EXISTS registry.payments;

COMMIT;