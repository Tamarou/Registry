-- Verify registry:schema-based-multitennancy on pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Verify the copy_user function exists
SELECT has_function_privilege('registry.copy_user(text, uuid, text)', 'execute');

-- Verify the copy_workflow function exists
SELECT has_function_privilege('registry.copy_workflow(text, uuid, text)', 'execute');

-- Verify the clone_schema function exists
SELECT has_function_privilege('registry.clone_schema(text, text, boolean, boolean)', 'execute');

ROLLBACK;
