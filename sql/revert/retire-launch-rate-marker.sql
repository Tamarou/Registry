-- ABOUTME: Put back the metadata retire-launch-rate-marker stripped, by id.
-- ABOUTME: Drops the table the deploy kept it in afterwards.

-- Revert registry:retire-launch-rate-marker from pg

BEGIN;

ALTER TABLE registry.pricing_plans DISABLE TRIGGER pricing_plans_terms_immutable;
UPDATE registry.pricing_plans p SET metadata = m.metadata
  FROM public.launch_rate_marker_metadata m
 WHERE p.id = m.id;
ALTER TABLE registry.pricing_plans ENABLE TRIGGER pricing_plans_terms_immutable;

DROP TABLE public.launch_rate_marker_metadata;

COMMIT;
