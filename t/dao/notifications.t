use 5.40.2;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest like )];
defer { done_testing };

use Registry::DAO;
use Registry::DAO::Notification;
use Registry::DAO::UserPreference;
use Registry::Job::AttendanceCheck;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;

subtest 'Notification DAO exists and has required methods' => sub {
    ok(Registry::DAO::Notification->can('create'), 'Notification DAO has create method');
    ok(Registry::DAO::Notification->can('send_attendance_missing'), 'Has send_attendance_missing method');
    ok(Registry::DAO::Notification->can('send_attendance_reminder'), 'Has send_attendance_reminder method');
    ok(Registry::DAO::Notification->can('get_user_notifications'), 'Has get_user_notifications method');
    ok(Registry::DAO::Notification->can('get_unread_count'), 'Has get_unread_count method');
};

subtest 'UserPreference DAO exists and has required methods' => sub {
    ok(Registry::DAO::UserPreference->can('create'), 'UserPreference DAO has create method');
    ok(Registry::DAO::UserPreference->can('wants_notification'), 'Has wants_notification method');
    ok(Registry::DAO::UserPreference->can('get_notification_preferences'), 'Has get_notification_preferences method');
    ok(Registry::DAO::UserPreference->can('update_notification_preferences'), 'Has update_notification_preferences method');
};

subtest 'AttendanceCheck Job exists' => sub {
    ok(Registry::Job::AttendanceCheck->can('run'), 'AttendanceCheck job has run method');
    ok(Registry::Job::AttendanceCheck->can('find_events_missing_attendance'), 'Has find_events_missing_attendance method');
    ok(Registry::Job::AttendanceCheck->can('find_events_starting_soon'), 'Has find_events_starting_soon method');
    ok(Registry::Job::AttendanceCheck->can('check_tenant_attendance'), 'Has check_tenant_attendance method');
};

subtest 'Database migration files exist' => sub {
    ok(-f 'sql/deploy/notifications-and-preferences.sql', 'Deploy migration exists');
    ok(-f 'sql/revert/notifications-and-preferences.sql', 'Revert migration exists');
    ok(-f 'sql/verify/notifications-and-preferences.sql', 'Verify migration exists');
};