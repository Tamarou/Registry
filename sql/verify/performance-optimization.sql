-- Verify registry:performance-optimization on pg

BEGIN;

-- Verify that key performance indexes exist
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_enrollments_session_id' AND tablename = 'enrollments';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_enrollments_status' AND tablename = 'enrollments';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_events_project_id' AND tablename = 'events';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_events_time' AND tablename = 'events';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_attendance_event_id' AND tablename = 'attendance_records';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_sessions_name' AND tablename = 'sessions';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_family_members_family_id' AND tablename = 'family_members';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_payments_status' AND tablename = 'payments';

-- Verify composite indexes for dashboard queries
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_enrollments_dashboard' AND tablename = 'enrollments';
SELECT 1 FROM pg_indexes WHERE indexname = 'idx_waitlist_active' AND tablename = 'waitlist';

-- Verify that statistics exist
SELECT 1 FROM pg_stat_user_tables 
WHERE schemaname = 'registry' 
AND relname IN ('enrollments', 'events', 'attendance_records', 'sessions');

ROLLBACK;