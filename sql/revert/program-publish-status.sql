-- Revert registry:program-publish-status from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

ALTER TABLE projects DROP COLUMN IF EXISTS status;

DROP INDEX IF EXISTS idx_locations_contact_person;
ALTER TABLE locations DROP COLUMN IF EXISTS contact_person_id;

DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        EXECUTE format(
            'ALTER TABLE %I.projects DROP COLUMN IF EXISTS status;', s
        );
        EXECUTE format(
            'DROP INDEX IF EXISTS %I.idx_locations_contact_person;', s
        );
        EXECUTE format(
            'ALTER TABLE %I.locations DROP COLUMN IF EXISTS contact_person_id;',
            s
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
