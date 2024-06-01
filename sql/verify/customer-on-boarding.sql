-- Verify registry:customer-on-boarding on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

SELECT
    id,
    name,
    created_at
FROM customers
WHERE FALSE;

SELECT
    customer_id,
    data,
    created_at
FROM customer_profiles
WHERE FALSE;

SELECT
    customer_id,
    user_id,
    created_at
FROM customer_users
WHERE FALSE;

ROLLBACK;
