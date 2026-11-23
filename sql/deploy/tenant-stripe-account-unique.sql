-- ABOUTME: A Stripe account id belongs to one tenant at most: Connect events are routed by it.
-- ABOUTME: Refuses, naming the account, if two tenants already share one, so a person decides which keeps it.

-- Deploy registry:tenant-stripe-account-unique to pg
-- requires: waitlist-offer-notification-types

BEGIN;

SET client_min_messages = 'warning';

DO $$
DECLARE
    dup text;
BEGIN
    SELECT stripe_connect_account_id INTO dup
      FROM registry.tenants
     WHERE stripe_connect_account_id IS NOT NULL
     GROUP BY stripe_connect_account_id
    HAVING count(*) > 1
     LIMIT 1;
    IF dup IS NOT NULL THEN
        RAISE EXCEPTION 'tenant-stripe-account-unique: Stripe account % is held by more than one tenant; clear it from all but one and deploy again', dup;
    END IF;
END $$;

CREATE UNIQUE INDEX tenants_stripe_connect_account_id_key
    ON registry.tenants (stripe_connect_account_id)
 WHERE stripe_connect_account_id IS NOT NULL;

COMMIT;
