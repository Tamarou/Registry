-- ABOUTME: Drop imported_sha256 from every template so import re-stamps them correctly.
-- ABOUTME: The first stamps were computed from bytes; the fixed import compares characters.

-- Deploy registry:clear-template-import-stamps to pg
-- requires: seed-tier-pricing-options

BEGIN;

SET client_min_messages = 'warning';

-- import_from_file stamps each row with a hash of the content it wrote, and
-- refuses to overwrite a row whose content no longer hashes to its stamp --
-- that is how a customisation is told apart from a stale platform template.
--
-- The first release computed that hash from Mojo::File->slurp's BYTES, while
-- the value read back out of the database is a character string. The two hash
-- differently by construction, so every stamped row would look customised on
-- the next import and never be updated again. 29 of 131 production rows were
-- stamped before this was caught.
--
-- Clearing the key returns those rows to the unstamped state, which import
-- treats as "predates stamping, the file may carry it forward". The next run
-- re-stamps every row from the corrected comparison, and in doing so also
-- rewrites content that the old byte path had double-encoded.
--
-- Nothing is lost: no row has been customised through the editor, and every
-- one is reproducible from templates/.
UPDATE registry.templates
   SET metadata = metadata - 'imported_sha256'
 WHERE metadata ? 'imported_sha256';

-- clone_schema copies registry at call time, so new tenants pick this up for
-- free. Existing tenant schemas have to be walked.
DO $$
DECLARE
    s text;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.schemata WHERE schema_name = s
        );
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.tables
             WHERE table_schema = s AND table_name = 'templates'
        );
        EXECUTE format(
            'UPDATE %I.templates SET metadata = metadata - %L WHERE metadata ? %L',
            s, 'imported_sha256', 'imported_sha256' );
    END LOOP;
END $$;

COMMIT;
