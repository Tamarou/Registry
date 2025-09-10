#!/usr/bin/env perl

use 5.40.2;
use lib qw(lib t/lib);
use experimental qw( try );

use Test::More;
use Test::Registry::DB;
use Registry::DAO::UserPreference;
use Registry::DAO::User;
use JSON qw( decode_json );

my $db_helper = Test::Registry::DB->new;
my $dao = $db_helper->setup_test_database;
my $db = $dao->db;

# Deploy the notifications schema - schema already deployed in Test::Registry::DB->new()
# $db_helper->deploy_sqitch_changes(['notifications-and-preferences']);

subtest 'UserPreference creation and basic operations' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser1',
        passhash => 'fake_hash'
    });

    # Test creating a preference
    my $preference = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'test_setting',
        preference_value => { enabled => 1, level => 'high' }
    });

    isa_ok($preference, 'Registry::DAO::UserPreference');
    is($preference->user_id, $user->id, 'User ID set correctly');
    is($preference->preference_key, 'test_setting', 'Preference key set correctly');
    is_deeply($preference->preference_value, { enabled => 1, level => 'high' }, 'Preference value set correctly');

    # Test get_value method
    is_deeply($preference->get_value, { enabled => 1, level => 'high' }, 'get_value returns correct value');
    is_deeply($preference->get_value('default'), { enabled => 1, level => 'high' }, 'get_value with default returns actual value');

    # Test setting new value
    $preference->set_value($db, { enabled => 0, level => 'low' });
    is_deeply($preference->get_value, { enabled => 0, level => 'low' }, 'set_value updates value correctly');
};

subtest 'get_or_create functionality' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser2',
        passhash => 'fake_hash'
    });

    # Test creating new preference
    my $new_pref = Registry::DAO::UserPreference->get_or_create(
        $db, $user->id, 'new_setting', { default => 'value' }
    );

    isa_ok($new_pref, 'Registry::DAO::UserPreference');
    is($new_pref->preference_key, 'new_setting', 'New preference created with correct key');
    is_deeply($new_pref->preference_value, { default => 'value' }, 'New preference has default value');

    # Test getting existing preference
    my $existing_pref = Registry::DAO::UserPreference->get_or_create(
        $db, $user->id, 'new_setting', { different => 'default' }
    );

    is($existing_pref->id, $new_pref->id, 'get_or_create returns existing preference');
    is_deeply($existing_pref->preference_value, { default => 'value' }, 'Existing value not overwritten');
};

subtest 'Notification preferences' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser3',
        passhash => 'fake_hash'
    });

    # Test getting default notification preferences
    my $prefs = Registry::DAO::UserPreference->get_notification_preferences($db, $user->id);

    is_deeply($prefs, {
        attendance_missing => { email => 1, in_app => 1 },
        attendance_reminder => { email => 1, in_app => 1 }
    }, 'Default notification preferences set correctly');

    # Test wants_notification method
    ok(Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'attendance_missing', 'email'
    ), 'User wants email notifications for attendance_missing by default');

    ok(Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'attendance_reminder', 'in_app'
    ), 'User wants in_app notifications for attendance_reminder by default');

    ok(!Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'non_existent_type', 'email'
    ), 'User does not want notifications for non-existent type');

    # Test updating notification preferences
    Registry::DAO::UserPreference->update_notification_preferences($db, $user->id, {
        attendance_missing => { email => 0, in_app => 1 },
        new_type => { email => 1, in_app => 0 }
    });

    # Check updated preferences
    ok(!Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'attendance_missing', 'email'
    ), 'Email notifications disabled for attendance_missing');

    ok(Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'attendance_missing', 'in_app'
    ), 'In-app notifications still enabled for attendance_missing');

    ok(Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'new_type', 'email'
    ), 'New notification type preferences set correctly');

    # Original reminder preferences should be preserved
    ok(Registry::DAO::UserPreference->wants_notification(
        $db, $user->id, 'attendance_reminder', 'email'
    ), 'Original attendance_reminder email preference preserved');
};

subtest 'Nested preference values' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser4',
        passhash => 'fake_hash'
    });

    # Create a preference with nested structure
    my $preference = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'nested_settings',
        preference_value => {
            ui => {
                theme => 'dark',
                layout => 'compact'
            },
            notifications => {
                email => {
                    enabled => 1,
                    frequency => 'daily'
                },
                push => {
                    enabled => 0
                }
            }
        }
    });

    # Test getting nested values
    is($preference->get_nested_value('ui.theme'), 'dark', 'Retrieved nested value correctly');
    is($preference->get_nested_value('notifications.email.frequency'), 'daily', 'Retrieved deeply nested value');
    is($preference->get_nested_value('non.existent.path', 'default'), 'default', 'Default returned for non-existent path');

    # Test setting nested values
    $preference->set_nested_value($db, 'ui.theme', 'light');
    is($preference->get_nested_value('ui.theme'), 'light', 'Nested value updated correctly');
    is($preference->get_nested_value('ui.layout'), 'compact', 'Other nested values preserved');

    # Test setting new nested path
    $preference->set_nested_value($db, 'new.deeply.nested.value', 'test');
    is($preference->get_nested_value('new.deeply.nested.value'), 'test', 'New nested path created correctly');
};

subtest 'Multiple preferences per user' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser5',
        passhash => 'fake_hash'
    });

    # Create multiple preferences
    my $pref1 = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'ui_settings',
        preference_value => { theme => 'dark' }
    });

    my $pref2 = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'notification_settings',
        preference_value => { email_enabled => 1 }
    });

    # Trigger creation of default notifications preference
    Registry::DAO::UserPreference->get_notification_preferences($db, $user->id);

    # Test getting all user preferences
    my $all_prefs = Registry::DAO::UserPreference->get_user_preferences($db, $user->id);

    is(scalar keys %$all_prefs, 3, 'Retrieved all preferences (including default notifications)');
    is_deeply($all_prefs->{ui_settings}, { theme => 'dark' }, 'UI settings retrieved correctly');
    is_deeply($all_prefs->{notification_settings}, { email_enabled => 1 }, 'Notification settings retrieved correctly');
    ok(exists $all_prefs->{notifications}, 'Default notifications preference exists');

    # Test helper methods
    ok($pref1->has_preference('theme'), 'has_preference works for existing key');
    ok(!$pref1->has_preference('non_existent'), 'has_preference works for non-existent key');

    ok(!$pref1->is_notification_preference, 'ui_settings is not notification preference');
    
    # Get the notifications preference object
    my $notif_pref = Registry::DAO::UserPreference->find($db, {
        user_id => $user->id,
        preference_key => 'notifications'
    });
    if ($notif_pref) {
        ok($notif_pref->is_notification_preference, 'notifications preference identified correctly');
    } else {
        fail('notifications preference not found');
    }
};

subtest 'JSON handling and edge cases' => sub {
    # Create a test user
    my $user = Registry::DAO::User->create($db, {
        username => 'testuser6',
        passhash => 'fake_hash'
    });

    # Test with array value
    my $array_pref = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'array_setting',
        preference_value => ['item1', 'item2', 'item3']
    });

    is_deeply($array_pref->preference_value, ['item1', 'item2', 'item3'], 'Array values handled correctly');

    # Test with simple object value  
    my $simple_pref = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'simple_setting',
        preference_value => { value => 'simple_string' }
    });

    is_deeply($simple_pref->preference_value, { value => 'simple_string' }, 'Simple object values handled correctly');

    # Test empty/null values
    my $empty_pref = Registry::DAO::UserPreference->create($db, {
        user_id => $user->id,
        preference_key => 'empty_setting'
        # preference_value will default to {}
    });

    is_deeply($empty_pref->preference_value, {}, 'Empty values default to empty hash');
};

$db_helper->cleanup_test_database;
done_testing;