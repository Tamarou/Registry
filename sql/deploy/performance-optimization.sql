-- Deploy registry:performance-optimization to pg

BEGIN;

-- Suppress notices for existing indexes
SET client_min_messages TO WARNING;

-- Add indexes for frequently queried columns to improve performance

-- Enrollments table indexes
CREATE INDEX IF NOT EXISTS idx_enrollments_session_id ON registry.enrollments(session_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_family_member_id ON registry.enrollments(family_member_id);
CREATE INDEX IF NOT EXISTS idx_enrollments_status ON registry.enrollments(status);
CREATE INDEX IF NOT EXISTS idx_enrollments_session_status ON registry.enrollments(session_id, status);
CREATE INDEX IF NOT EXISTS idx_enrollments_created_at ON registry.enrollments(created_at);

-- Events table indexes
CREATE INDEX IF NOT EXISTS idx_events_project_id ON registry.events(project_id);
CREATE INDEX IF NOT EXISTS idx_events_location_id ON registry.events(location_id);
CREATE INDEX IF NOT EXISTS idx_events_time ON registry.events(time);
CREATE INDEX IF NOT EXISTS idx_events_teacher_id ON registry.events(teacher_id);

-- Attendance records indexes
CREATE INDEX IF NOT EXISTS idx_attendance_event_id ON registry.attendance_records(event_id);
CREATE INDEX IF NOT EXISTS idx_attendance_student_id ON registry.attendance_records(student_id);
CREATE INDEX IF NOT EXISTS idx_attendance_marked_at ON registry.attendance_records(marked_at);
CREATE INDEX IF NOT EXISTS idx_attendance_event_student ON registry.attendance_records(event_id, student_id);

-- Sessions table indexes
CREATE INDEX IF NOT EXISTS idx_sessions_name ON registry.sessions(name);
CREATE INDEX IF NOT EXISTS idx_sessions_slug ON registry.sessions(slug);
CREATE INDEX IF NOT EXISTS idx_sessions_created_at ON registry.sessions(created_at);

-- Projects table indexes
CREATE INDEX IF NOT EXISTS idx_projects_name ON registry.projects(name);
CREATE INDEX IF NOT EXISTS idx_projects_slug ON registry.projects(slug);
CREATE INDEX IF NOT EXISTS idx_projects_program_type ON registry.projects(program_type_slug);

-- Family members table indexes
CREATE INDEX IF NOT EXISTS idx_family_members_family_id ON registry.family_members(family_id);
CREATE INDEX IF NOT EXISTS idx_family_members_name ON registry.family_members(child_name);

-- User profiles table indexes
CREATE INDEX IF NOT EXISTS idx_user_profiles_user_id ON registry.user_profiles(user_id);
CREATE INDEX IF NOT EXISTS idx_user_profiles_email ON registry.user_profiles(email);

-- Waitlist table indexes (already exist but ensure they're optimal)
CREATE INDEX IF NOT EXISTS idx_waitlist_session_id ON registry.waitlist(session_id);
CREATE INDEX IF NOT EXISTS idx_waitlist_parent_id ON registry.waitlist(parent_id);
CREATE INDEX IF NOT EXISTS idx_waitlist_status ON registry.waitlist(status);
CREATE INDEX IF NOT EXISTS idx_waitlist_position ON registry.waitlist(session_id, position);
CREATE INDEX IF NOT EXISTS idx_waitlist_expires_at ON registry.waitlist(expires_at) WHERE expires_at IS NOT NULL;

-- Message recipients table indexes (already exist but ensure they're optimal)
CREATE INDEX IF NOT EXISTS idx_message_recipients_message_id ON registry.message_recipients(message_id);
CREATE INDEX IF NOT EXISTS idx_message_recipients_recipient_id ON registry.message_recipients(recipient_id);
CREATE INDEX IF NOT EXISTS idx_message_recipients_read_at ON registry.message_recipients(read_at) WHERE read_at IS NULL;

-- Messages table indexes (already exist but ensure they're optimal)
CREATE INDEX IF NOT EXISTS idx_messages_sender_id ON registry.messages(sender_id);
CREATE INDEX IF NOT EXISTS idx_messages_created_at ON registry.messages(created_at);
CREATE INDEX IF NOT EXISTS idx_messages_sent_at ON registry.messages(sent_at);
CREATE INDEX IF NOT EXISTS idx_messages_scheduled_for ON registry.messages(scheduled_for) WHERE scheduled_for IS NOT NULL;

-- Payments table indexes
CREATE INDEX IF NOT EXISTS idx_payments_status ON registry.payments(status);
CREATE INDEX IF NOT EXISTS idx_payments_created_at ON registry.payments(created_at);
CREATE INDEX IF NOT EXISTS idx_payments_amount ON registry.payments(amount);

-- Notifications table indexes
CREATE INDEX IF NOT EXISTS idx_notifications_user_id ON registry.notifications(user_id);
CREATE INDEX IF NOT EXISTS idx_notifications_type ON registry.notifications(type);
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON registry.notifications(created_at);
CREATE INDEX IF NOT EXISTS idx_notifications_sent_at ON registry.notifications(sent_at);

-- User preferences table indexes
CREATE INDEX IF NOT EXISTS idx_user_preferences_user_id ON registry.user_preferences(user_id);
CREATE INDEX IF NOT EXISTS idx_user_preferences_preference_key ON registry.user_preferences(preference_key);
CREATE INDEX IF NOT EXISTS idx_user_preferences_user_key ON registry.user_preferences(user_id, preference_key);

-- Session teachers table indexes
CREATE INDEX IF NOT EXISTS idx_session_teachers_session_id ON registry.session_teachers(session_id);
CREATE INDEX IF NOT EXISTS idx_session_teachers_teacher_id ON registry.session_teachers(teacher_id);
CREATE INDEX IF NOT EXISTS idx_session_teachers_created_at ON registry.session_teachers(created_at);

-- Composite indexes for common dashboard queries
CREATE INDEX IF NOT EXISTS idx_enrollments_dashboard ON registry.enrollments(status, created_at) WHERE status IN ('active', 'pending');

-- Partial indexes for performance
CREATE INDEX IF NOT EXISTS idx_waitlist_active ON registry.waitlist(session_id, position) WHERE status IN ('waiting', 'offered');
CREATE INDEX IF NOT EXISTS idx_messages_unread ON registry.message_recipients(recipient_id, message_id) WHERE read_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_notifications_pending ON registry.notifications(created_at, user_id) WHERE sent_at IS NULL;

-- Statistics update to help query planner
ANALYZE registry.enrollments;
ANALYZE registry.events;
ANALYZE registry.attendance_records;
ANALYZE registry.sessions;
ANALYZE registry.projects;
ANALYZE registry.family_members;
ANALYZE registry.waitlist;
ANALYZE registry.messages;
ANALYZE registry.message_recipients;
ANALYZE registry.payments;
ANALYZE registry.notifications;

-- Reset client message level
SET client_min_messages TO NOTICE;

COMMIT;