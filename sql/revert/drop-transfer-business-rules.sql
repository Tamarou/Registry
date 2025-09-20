BEGIN;

SET search_path TO registry, public;

-- Remove drop and transfer tracking fields from enrollments
ALTER TABLE enrollments
  DROP COLUMN IF EXISTS transfer_status,
  DROP COLUMN IF EXISTS transfer_to_session_id,
  DROP COLUMN IF EXISTS refund_amount,
  DROP COLUMN IF EXISTS refund_status,
  DROP COLUMN IF EXISTS dropped_by,
  DROP COLUMN IF EXISTS dropped_at,
  DROP COLUMN IF EXISTS drop_reason;

-- Remove indexes
DROP INDEX IF EXISTS idx_enrollments_drop_status;
DROP INDEX IF EXISTS idx_transfer_requests_status;
DROP INDEX IF EXISTS idx_transfer_requests_enrollment_id;
DROP INDEX IF EXISTS idx_drop_requests_status;
DROP INDEX IF EXISTS idx_drop_requests_enrollment_id;

-- Drop tables
DROP TABLE IF EXISTS transfer_requests;
DROP TABLE IF EXISTS drop_requests;

-- Propagate schema changes to tenant schemas
DO
$$
DECLARE
    s name;
BEGIN
   FOR s IN SELECT slug FROM registry.tenants WHERE slug != 'registry' LOOP
       -- Remove indexes
       EXECUTE format('DROP INDEX IF EXISTS %I.idx_enrollments_drop_status;', s);
       EXECUTE format('DROP INDEX IF EXISTS %I.idx_transfer_requests_status;', s);
       EXECUTE format('DROP INDEX IF EXISTS %I.idx_transfer_requests_enrollment_id;', s);
       EXECUTE format('DROP INDEX IF EXISTS %I.idx_drop_requests_status;', s);
       EXECUTE format('DROP INDEX IF EXISTS %I.idx_drop_requests_enrollment_id;', s);

       -- Drop tables
       EXECUTE format('DROP TABLE IF EXISTS %I.transfer_requests;', s);
       EXECUTE format('DROP TABLE IF EXISTS %I.drop_requests;', s);

       -- Remove columns from enrollments
       EXECUTE format('ALTER TABLE %I.enrollments
         DROP COLUMN IF EXISTS transfer_status,
         DROP COLUMN IF EXISTS transfer_to_session_id,
         DROP COLUMN IF EXISTS refund_amount,
         DROP COLUMN IF EXISTS refund_status,
         DROP COLUMN IF EXISTS dropped_by,
         DROP COLUMN IF EXISTS dropped_at,
         DROP COLUMN IF EXISTS drop_reason;', s);
   END LOOP;
END
$$ LANGUAGE plpgsql;

COMMIT;