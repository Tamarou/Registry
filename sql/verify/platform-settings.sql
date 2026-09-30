-- ABOUTME: Verify platform_settings exists, its value is nullable, and its keys are seeded.
-- ABOUTME: Nullability is load-bearing: NULL is "not set", which no value of a key may mean.

-- Verify registry:platform-settings on pg

BEGIN;

SELECT key, value, description, default_note, updated_at, updated_by
  FROM registry.platform_settings
 WHERE FALSE;

DO $$
DECLARE
    nullable text;
BEGIN
    SELECT is_nullable INTO nullable
      FROM information_schema.columns
     WHERE table_schema = 'registry' AND table_name = 'platform_settings'
       AND column_name = 'value';

    IF nullable <> 'YES' THEN
        RAISE EXCEPTION
            'platform_settings.value must be nullable -- NULL is "not set", which is not a value';
    END IF;

    -- Seeded, not created on first write. A key nobody has written yet must
    -- still be listable, or Alex cannot discover it.
    IF NOT EXISTS (
        SELECT 1 FROM registry.platform_settings WHERE key = 'inert_tenant_days'
    ) THEN
        RAISE EXCEPTION 'inert_tenant_days is not seeded in platform_settings';
    END IF;
END $$;

ROLLBACK;
