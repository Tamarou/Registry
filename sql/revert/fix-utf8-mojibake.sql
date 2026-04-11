-- Revert fix-utf8-mojibake from pg
-- No-op: restoring Unicode characters would reintroduce mojibake.

BEGIN;
SELECT 1;
COMMIT;
