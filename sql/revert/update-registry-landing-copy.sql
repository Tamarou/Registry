-- Revert update-registry-landing-copy from pg
-- No-op: previous copy version is not preserved.
BEGIN;
SELECT 1;
COMMIT;
