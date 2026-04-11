-- Verify fix-utf8-mojibake on pg

BEGIN;

SET search_path TO registry, public;

-- Verify no templates contain the raw Unicode arrow (mojibake source)
SELECT CASE WHEN count(*) = 0 THEN 1 END
FROM templates
WHERE content LIKE '%→%';

ROLLBACK;
