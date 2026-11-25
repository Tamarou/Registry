-- ABOUTME: Restore the platform plans this change retired, by id: un-supersede the kept ones, re-insert the deleted ones.
-- ABOUTME: Drops the table the deploy kept them in afterwards.

-- Revert registry:retire-unpublished-platform-plans from pg

BEGIN;

UPDATE registry.pricing_plans p SET superseded_at = NULL
  FROM public.retired_platform_plans r
 WHERE p.id = r.id;

INSERT INTO registry.pricing_plans
SELECT * FROM public.retired_platform_plans r
 WHERE NOT EXISTS (SELECT 1 FROM registry.pricing_plans p WHERE p.id = r.id);

DROP TABLE public.retired_platform_plans;

COMMIT;
