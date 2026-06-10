-- Verify registry:fix-clone-schema-identifier-quoting on pg

BEGIN;

SET search_path TO registry, public;

-- The migration redefines the three provisioning functions. Confirm each is
-- present and that copy_user / copy_workflow no longer wrap dest_schema in
-- quote_ident() for their pg_namespace existence check (which silently broke
-- copying for reserved-word schema names like "user").
DO $$
BEGIN
    IF to_regproc('registry.clone_schema') IS NULL THEN
        RAISE EXCEPTION 'registry.clone_schema is missing';
    END IF;
    IF to_regproc('registry.copy_user') IS NULL THEN
        RAISE EXCEPTION 'registry.copy_user is missing';
    END IF;
    IF to_regproc('registry.copy_workflow') IS NULL THEN
        RAISE EXCEPTION 'registry.copy_workflow is missing';
    END IF;

    IF pg_get_functiondef('registry.copy_user(text, uuid, text)'::regprocedure)
       LIKE '%nspname = quote_ident(dest_schema)%' THEN
        RAISE EXCEPTION 'copy_user still uses quote_ident(dest_schema) in its nspname check';
    END IF;
    IF pg_get_functiondef('registry.copy_workflow(text, uuid, text)'::regprocedure)
       LIKE '%nspname = quote_ident(dest_schema)%' THEN
        RAISE EXCEPTION 'copy_workflow still uses quote_ident(dest_schema) in its nspname check';
    END IF;
END $$;

SELECT 1 as verified;

ROLLBACK;
