-- ABOUTME: Drop platform_settings.
-- ABOUTME: Any value Alex set is discarded and the code defaults apply again.

-- Revert registry:platform-settings from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DROP TABLE IF EXISTS platform_settings;

COMMIT;
