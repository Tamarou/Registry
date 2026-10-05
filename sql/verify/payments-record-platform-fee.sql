-- Verify registry:payments-record-platform-fee

SET search_path TO registry, public;

-- Both columns, and nullable: NULL is the load-bearing state here ("not
-- recorded"), so a future NOT NULL would turn every historical charge into a
-- claim that the platform took nothing.
DO $$
DECLARE
    r record;
BEGIN
    FOR r IN
        SELECT column_name, is_nullable, data_type
          FROM information_schema.columns
         WHERE table_schema = 'registry' AND table_name = 'payments'
           AND column_name IN ('platform_fee_cents', 'platform_pricing_plan_id')
    LOOP
        IF r.is_nullable <> 'YES' THEN
            RAISE EXCEPTION
              'payments.% must stay nullable: NULL means not recorded', r.column_name;
        END IF;
    END LOOP;

    IF (SELECT COUNT(*) FROM information_schema.columns
         WHERE table_schema = 'registry' AND table_name = 'payments'
           AND column_name IN ('platform_fee_cents','platform_pricing_plan_id')) <> 2
    THEN
        RAISE EXCEPTION 'both platform fee columns must exist on registry.payments';
    END IF;
END
$$;

-- The CHECK permits NULL and refuses negative. Asserted by behaviour, not by
-- reading the constraint's text.
DO $$
BEGIN
    BEGIN
        INSERT INTO payments (user_id, amount_cents, platform_fee_cents)
        VALUES ('00000000-0000-0000-0000-000000000000', 100, -1);
        RAISE EXCEPTION 'a negative platform fee was accepted';
    EXCEPTION
        WHEN check_violation THEN NULL;   -- what we want
        WHEN foreign_key_violation THEN NULL;  -- user does not exist; the check never ran
    END;
END
$$;
