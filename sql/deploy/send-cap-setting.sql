-- Deploy registry:send-cap-setting to pg
-- requires: domain-notification-types
--
-- The unverified-tenant send cap, as a row Alex can change rather than a
-- constant that needs a deploy. 200/day was a placeholder I picked and perigrin
-- accepted on condition it be configurable (#21).
--
-- NULL means not set: the code default applies. That is deliberately distinct
-- from 0, which means nothing bulk goes out at all -- collapsing them either way
-- is a bug with teeth, as platform_settings.value's COMMENT says.

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

INSERT INTO platform_settings (key, value, description, default_note)
VALUES (
    'unverified_tenant_daily_mail_cap',
    NULL,
    'How many bulk messages a day a tenant may send before its own domain is verified. Announcements and updates only -- sign-in links, enrolment confirmations and emergencies are never capped. Set to 0 to hold all bulk mail from unverified tenants.',
    'Not set: 200 a day.'
)
ON CONFLICT (key) DO NOTHING;

COMMIT;
