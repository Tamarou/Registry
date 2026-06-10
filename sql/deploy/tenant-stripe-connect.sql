-- Deploy registry:tenant-stripe-connect to pg
-- requires: stripe-subscription-integration

BEGIN;
SET client_min_messages = 'warning';
SET search_path TO registry, public;

-- Per-tenant Stripe Connect (Standard) account and readiness flags. The
-- booleans mirror the connected account's charges_enabled/details_submitted
-- and are refreshed by the account.updated webhook. Paid enrollment is gated
-- on all three being present/true.
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_connect_account_id TEXT;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_charges_enabled BOOLEAN NOT NULL DEFAULT FALSE;
ALTER TABLE tenants ADD COLUMN IF NOT EXISTS stripe_details_submitted BOOLEAN NOT NULL DEFAULT FALSE;

COMMIT;
