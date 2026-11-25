-- ABOUTME: Verify no registry pricing plan carries launch_rate, display_order or featured.
-- ABOUTME: Fails by division by zero otherwise; also checks the stripped metadata is kept for the revert.

-- Verify registry:retire-launch-rate-marker on pg

BEGIN;

SELECT 1/(COUNT(*) = 0)::int FROM registry.pricing_plans
 WHERE metadata ?| array['launch_rate', 'display_order', 'featured'];

SELECT id, metadata FROM public.launch_rate_marker_metadata WHERE FALSE;

ROLLBACK;
