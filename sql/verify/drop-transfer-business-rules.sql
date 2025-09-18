BEGIN;

SET search_path TO registry, public;

-- Verify enrollments table has new columns
SELECT drop_reason, dropped_at, dropped_by, refund_status, refund_amount,
       transfer_to_session_id, transfer_status
FROM enrollments
WHERE FALSE;

-- Verify drop_requests table exists with correct structure
SELECT id, enrollment_id, requested_by, reason, refund_requested,
       refund_amount_requested, status, admin_notes, processed_by,
       processed_at, created_at, updated_at
FROM drop_requests
WHERE FALSE;

-- Verify transfer_requests table exists with correct structure
SELECT id, enrollment_id, target_session_id, requested_by, reason,
       status, admin_notes, processed_by, processed_at,
       created_at, updated_at
FROM transfer_requests
WHERE FALSE;

-- Verify indexes exist
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_drop_requests_enrollment_id';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_drop_requests_status';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_transfer_requests_enrollment_id';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_transfer_requests_status';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_enrollments_drop_status';

ROLLBACK;