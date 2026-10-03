-- Deploy registry:magic-link-expiry-one-hour to pg
-- requires: platform-settings

BEGIN;

SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- A magic link is a live credential, and the only place it reliably sits for as
-- long as it is valid is the recipient's mailbox. Twenty-four hours was the
-- original default; #450 settled on one, which is the window the exposure
-- actually has (browser history and an inbox) rather than the one the issue was
-- filed about (platform request logs, which do not exist for this service).
--
-- Still per-tenant: Controller::Auth reads tenants.magic_link_expiry_hours, so a
-- tenant who wants longer sets it. This changes what they get by default.
ALTER TABLE tenants ALTER COLUMN magic_link_expiry_hours SET DEFAULT 1;

-- Existing rows carry the old default explicitly, so the new one would never
-- reach them. Only rows still on 24 are moved: a tenant who has chosen a window
-- has chosen it.
UPDATE tenants SET magic_link_expiry_hours = 1 WHERE magic_link_expiry_hours = 24;

COMMENT ON COLUMN tenants.magic_link_expiry_hours IS
  'How long a magic link stays redeemable, in hours. Default 1 (#450): the link '
  'is a credential and it sits in a mailbox. Registry::DAO::MagicLinkToken and '
  'Registry::DAO::Tenant carry the same default as a fallback; '
  't/dao/magic-link-expiry-default.t asserts the three agree.';

COMMIT;
