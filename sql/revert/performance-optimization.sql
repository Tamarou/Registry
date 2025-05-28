-- Revert registry:performance-optimization from pg

BEGIN;

-- Drop performance optimization indexes
-- Note: Only dropping indexes that were specifically added for performance
-- Keeping any indexes that are required for functionality or constraints

DROP INDEX IF EXISTS registry.idx_enrollments_session_id;
DROP INDEX IF EXISTS registry.idx_enrollments_family_member_id;
DROP INDEX IF EXISTS registry.idx_enrollments_status;
DROP INDEX IF EXISTS registry.idx_enrollments_session_status;
DROP INDEX IF EXISTS registry.idx_enrollments_created_at;

DROP INDEX IF EXISTS registry.idx_events_session_id;
DROP INDEX IF EXISTS registry.idx_events_location_id;
DROP INDEX IF EXISTS registry.idx_events_start_time;
DROP INDEX IF EXISTS registry.idx_events_date_range;

DROP INDEX IF EXISTS registry.idx_attendance_event_id;
DROP INDEX IF EXISTS registry.idx_attendance_student_id;
DROP INDEX IF EXISTS registry.idx_attendance_marked_at;
DROP INDEX IF EXISTS registry.idx_attendance_event_student;

DROP INDEX IF EXISTS registry.idx_sessions_project_id;
DROP INDEX IF EXISTS registry.idx_sessions_location_id;
DROP INDEX IF EXISTS registry.idx_sessions_dates;
DROP INDEX IF EXISTS registry.idx_sessions_status;

DROP INDEX IF EXISTS registry.idx_projects_status;
DROP INDEX IF EXISTS registry.idx_projects_name;

DROP INDEX IF EXISTS registry.idx_family_members_family_id;
DROP INDEX IF EXISTS registry.idx_family_members_name;

DROP INDEX IF EXISTS registry.idx_user_profiles_user_id;
DROP INDEX IF EXISTS registry.idx_user_profiles_email;

DROP INDEX IF EXISTS registry.idx_waitlist_expires_at;

DROP INDEX IF EXISTS registry.idx_message_recipients_read_at;

DROP INDEX IF EXISTS registry.idx_messages_created_at;
DROP INDEX IF EXISTS registry.idx_messages_sent_at;
DROP INDEX IF EXISTS registry.idx_messages_scheduled_for;

DROP INDEX IF EXISTS registry.idx_payments_enrollment_id;
DROP INDEX IF EXISTS registry.idx_payments_status;
DROP INDEX IF EXISTS registry.idx_payments_created_at;
DROP INDEX IF EXISTS registry.idx_payments_amount;

DROP INDEX IF EXISTS registry.idx_notifications_user_id;
DROP INDEX IF EXISTS registry.idx_notifications_type;
DROP INDEX IF EXISTS registry.idx_notifications_created_at;
DROP INDEX IF EXISTS registry.idx_notifications_sent_at;

DROP INDEX IF EXISTS registry.idx_user_preferences_user_id;
DROP INDEX IF EXISTS registry.idx_user_preferences_preference_key;
DROP INDEX IF EXISTS registry.idx_user_preferences_user_key;

DROP INDEX IF EXISTS registry.idx_session_teachers_session_id;
DROP INDEX IF EXISTS registry.idx_session_teachers_teacher_id;
DROP INDEX IF EXISTS registry.idx_session_teachers_dates;

-- Drop composite indexes
DROP INDEX IF EXISTS registry.idx_enrollments_dashboard;
DROP INDEX IF EXISTS registry.idx_events_today;
DROP INDEX IF EXISTS registry.idx_attendance_recent;

-- Drop partial indexes
DROP INDEX IF EXISTS registry.idx_waitlist_active;
DROP INDEX IF EXISTS registry.idx_messages_unread;
DROP INDEX IF EXISTS registry.idx_notifications_pending;

COMMIT;