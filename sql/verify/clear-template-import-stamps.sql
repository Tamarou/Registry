-- ABOUTME: Verify no template still carries a stamp from the byte-based comparison.
-- ABOUTME: Runs before import, so every row should be unstamped at this point.

-- Verify registry:clear-template-import-stamps

BEGIN;

DO $$
DECLARE
    stamped integer;
BEGIN
    SELECT count(*) INTO stamped
      FROM registry.templates
     WHERE metadata ? 'imported_sha256';

    IF stamped <> 0 THEN
        RAISE EXCEPTION
            'expected no template to carry imported_sha256 after this change, found %',
            stamped;
    END IF;
END $$;

ROLLBACK;
