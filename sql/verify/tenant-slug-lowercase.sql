-- ABOUTME: Verify the lowercase-slug constraint exists and actually refuses one.
-- ABOUTME: Presence alone would not prove the predicate is the intended one.

-- Verify registry:tenant-slug-lowercase

BEGIN;

DO $$
BEGIN
    PERFORM 1 FROM pg_constraint
      WHERE conname = 'tenants_slug_is_lowercase'
        AND conrelid = 'registry.tenants'::regclass;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'tenants_slug_is_lowercase constraint is missing';
    END IF;

    -- Presence is not behaviour. Prove it refuses.
    BEGIN
        INSERT INTO registry.tenants (name, slug) VALUES ('Verify Probe', 'MixedCase');
        RAISE EXCEPTION 'a mixed-case slug was accepted';
    EXCEPTION WHEN check_violation THEN
        NULL;  -- expected
    END;
END $$;

ROLLBACK;
