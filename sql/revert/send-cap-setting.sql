-- Revert registry:send-cap-setting from pg

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

DELETE FROM platform_settings WHERE key = 'unverified_tenant_daily_mail_cap';

COMMIT;
