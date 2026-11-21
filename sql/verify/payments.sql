-- Verify registry:payments on pg

BEGIN;

SELECT id, user_id, amount, currency, status, stripe_payment_intent_id, 
       stripe_payment_method_id, metadata, created_at, updated_at, 
       completed_at, error_message
FROM registry.payments
WHERE FALSE;

SELECT id, payment_id, enrollment_id, description, amount, quantity, metadata, created_at
FROM registry.payment_items
WHERE FALSE;

ROLLBACK;