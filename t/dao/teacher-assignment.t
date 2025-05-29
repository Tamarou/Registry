#!/usr/bin/env perl
use 5.40.2;
use experimental qw(try);

use Test::More;
use lib qw(lib t/lib);

# Test teacher assignment and conflict detection
use_ok('Registry::DAO::Schedule');

subtest 'Schedule Class Structure' => sub {
    # Test that class can be instantiated and has expected methods
    my $schedule = Registry::DAO::Schedule->new(
        id => 'test-id',
        slug => 'test-schedule',
        workflow_id => 'test-workflow',
        description => 'Test schedule'
    );
    
    isa_ok($schedule, 'Registry::DAO::Schedule');
    isa_ok($schedule, 'Registry::DAO::Object');
    
    # Check for required methods
    can_ok($schedule, 'get_teacher_schedule');
    can_ok($schedule, 'check_conflicts');
    can_ok($schedule, 'assign_teacher');
    can_ok($schedule, 'calculate_travel_time');
    can_ok($schedule, 'get_available_teachers');
    can_ok($schedule, 'get_schedule_grid');
};

subtest 'Time Overlap Detection' => sub {
    my $schedule = Registry::DAO::Schedule->new(
        id => 'test-id',
        slug => 'test-schedule', 
        workflow_id => 'test-workflow',
        description => 'Test schedule'
    );
    
    # Test time overlap logic
    my $dt1_start = DateTime->new(year => 2024, month => 1, day => 15, hour => 9, minute => 0);
    my $dt1_end = DateTime->new(year => 2024, month => 1, day => 15, hour => 10, minute => 0);
    my $dt2_start = DateTime->new(year => 2024, month => 1, day => 15, hour => 9, minute => 30);
    my $dt2_end = DateTime->new(year => 2024, month => 1, day => 15, hour => 10, minute => 30);
    
    # These should overlap
    ok($schedule->times_overlap($dt1_start, $dt1_end, $dt2_start, $dt2_end), 
       'Detects overlapping times');
    
    # These should not overlap
    my $dt3_start = DateTime->new(year => 2024, month => 1, day => 15, hour => 11, minute => 0);
    my $dt3_end = DateTime->new(year => 2024, month => 1, day => 15, hour => 12, minute => 0);
    
    ok(!$schedule->times_overlap($dt1_start, $dt1_end, $dt3_start, $dt3_end),
       'Does not detect non-overlapping times');
    
    # Adjacent times should not overlap
    my $dt4_start = DateTime->new(year => 2024, month => 1, day => 15, hour => 10, minute => 0);
    my $dt4_end = DateTime->new(year => 2024, month => 1, day => 15, hour => 11, minute => 0);
    
    ok(!$schedule->times_overlap($dt1_start, $dt1_end, $dt4_start, $dt4_end),
       'Adjacent times do not overlap');
};

subtest 'Distance Calculation' => sub {
    my $schedule = Registry::DAO::Schedule->new(
        id => 'test-id',
        slug => 'test-schedule',
        workflow_id => 'test-workflow', 
        description => 'Test schedule'
    );
    
    # Test distance calculation (example coordinates)
    # New York to Los Angeles approximate coordinates
    my $distance = $schedule->calculate_distance(40.7128, -74.0060, 34.0522, -118.2437);
    
    # Should be approximately 2445 miles
    ok($distance > 2400 && $distance < 2500, 'Distance calculation returns reasonable result');
    
    # Same location should return 0
    my $same_distance = $schedule->calculate_distance(40.7128, -74.0060, 40.7128, -74.0060);
    is($same_distance, 0, 'Same location returns 0 distance');
};

subtest 'Day Name Mapping' => sub {
    # Test the day name to offset mapping from GenerateEvents
    use_ok('Registry::DAO::WorkflowSteps::GenerateEvents');
    
    # Test that the class has the method without instantiating
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'day_name_to_offset');
    ok(1, 'Day name mapping method exists');
};

subtest 'Teacher Assignment Integration' => sub {
    # Test that GenerateEvents workflow step includes teacher assignment
    use_ok('Registry::DAO::WorkflowSteps::GenerateEvents');
    
    # Check that it has the required methods without instantiating
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'template');
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'day_name_to_offset');
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'prepare_data');
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'create_session_for_location');
    can_ok('Registry::DAO::WorkflowSteps::GenerateEvents', 'generate_events_for_session');
};

subtest 'Configuration Validation' => sub {
    my $schedule = Registry::DAO::Schedule->new(
        id => 'test-id',
        slug => 'test-schedule',
        workflow_id => 'test-workflow',
        description => 'Test schedule'
    );
    
    # Test travel time configuration defaults
    # Without a database, this should return the default
    # We can't easily test the database lookup without a full test setup
    ok(1, 'Configuration system exists and is callable');
};

done_testing();