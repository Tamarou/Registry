-- ABOUTME: Strip the launch_rate marker, and the display_order and featured keys of the retired tier ladder, from registry's pricing plans.
-- ABOUTME: What the platform sells is its current published offer version; the stripped metadata is kept in public.launch_rate_marker_metadata for the revert.

-- Deploy registry:retire-launch-rate-marker to pg
-- requires: holds-lifetime

BEGIN;

SET client_min_messages = 'warning';

-- RevenueShare::platform_offered_fraction reads the platform's current
-- published offer version, so a later Solo version moves the quote with no
-- migration. No metadata marker names a platform plan any more. Registry only:
-- a tenant's own plans live in its schema. Outside registry, so clone_schema
-- does not copy it.
CREATE TABLE public.launch_rate_marker_metadata AS
SELECT id, metadata FROM registry.pricing_plans
 WHERE metadata ?| array['launch_rate', 'display_order', 'featured'];

-- Metadata only, not terms: the immutability trigger guards a plan's terms,
-- and a marker no code reads names nothing a holder agreed to.
ALTER TABLE registry.pricing_plans DISABLE TRIGGER pricing_plans_terms_immutable;
UPDATE registry.pricing_plans p
   SET metadata = p.metadata - 'launch_rate' - 'display_order' - 'featured'
  FROM public.launch_rate_marker_metadata m
 WHERE p.id = m.id;
ALTER TABLE registry.pricing_plans ENABLE TRIGGER pricing_plans_terms_immutable;

COMMIT;
