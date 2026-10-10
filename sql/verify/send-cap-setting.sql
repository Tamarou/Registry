-- Verify registry:send-cap-setting on pg

BEGIN;
SET search_path TO registry, public;

SELECT 1/count(*) FROM platform_settings
 WHERE key = 'unverified_tenant_daily_mail_cap';

ROLLBACK;
