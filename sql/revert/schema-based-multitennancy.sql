-- Revert registry:schema-based-multitennancy from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry,public;

DROP FUNCTION clone_schema(text, text, boolean, boolean);

COMMIT;
