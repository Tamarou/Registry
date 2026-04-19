-- ABOUTME: Add status enum and contact person FK to support the admin
-- ABOUTME: program setup workflow. Mirrors sessions.status semantics.

-- Deploy registry:program-publish-status to pg
-- requires: summer-camp-module

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Programs (projects) need a status to match sessions. Draft programs
-- are not visible to parents in the storefront; published programs are;
-- closed programs are archived.
ALTER TABLE projects
    ADD COLUMN IF NOT EXISTS status text DEFAULT 'draft'
    CHECK (status IN ('draft', 'published', 'closed'));

-- Each location has a responsible contact person, referenced as a user
-- account rather than denormalized contact fields.
ALTER TABLE locations
    ADD COLUMN IF NOT EXISTS contact_person_id uuid REFERENCES users(id);

CREATE INDEX IF NOT EXISTS idx_locations_contact_person
    ON locations (contact_person_id);

-- Propagate the same columns to every tenant schema that exists.
-- Some tenants have slugs with hyphens or other characters that
-- clone_schema() rejects, so their schemas are not created.
DO
$$
DECLARE
    s name;
BEGIN
    FOR s IN SELECT slug FROM registry.tenants LOOP
        CONTINUE WHEN to_regnamespace(quote_ident(s)) IS NULL;

        EXECUTE format(
            'ALTER TABLE %I.projects
                ADD COLUMN IF NOT EXISTS status text DEFAULT ''draft''
                CHECK (status IN (''draft'', ''published'', ''closed''));',
            s
        );

        EXECUTE format(
            'ALTER TABLE %I.locations
                ADD COLUMN IF NOT EXISTS contact_person_id uuid
                REFERENCES %I.users(id);',
            s, s
        );

        EXECUTE format(
            'CREATE INDEX IF NOT EXISTS idx_locations_contact_person
                ON %I.locations (contact_person_id);',
            s
        );
    END LOOP;
END;
$$ LANGUAGE plpgsql;

COMMIT;
