#!/usr/bin/env perl
# ABOUTME: The attendance-check workflow covers the platform tenant (registry) like any other.
# ABOUTME: Plants events in the registry schema and asserts the steps list and process them.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use DateTime;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::Event;
use Registry::DAO::UserPreference;
use Registry::DAO::WorkflowSteps::AttendanceCheck::TenantProcessor;
use Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Attendance Check',
    slug        => 'attendance-check-platform-test',
    description => 'Attendance check steps against the platform tenant',
});

Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'tenants',
    class       => 'Registry::DAO::WorkflowSteps::AttendanceCheck::TenantProcessor',
    description => 'Tenant processor',
});

Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'missing',
    class       => 'Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor',
    description => 'Missing attendance processor',
});

$workflow->update($db, { first_step => 'tenants' }, { id => $workflow->id });

# Plant, in the schema $sdb is connected to, an event that started ten minutes
# ago with an active enrollment, taught by a teacher who wants in-app
# attendance notifications. With recorded => 1 the event's attendance is taken.
my $planted = 0;
sub plant_event ($sdb, %opt) {
    my $n = ++$planted;
    my $teacher = Registry::DAO::User->create($sdb, {
        username => "platform_teacher_$n", passhash => 'x',
    });
    Registry::DAO::UserPreference->set_preference(
        $sdb, $teacher->id, 'attendance_missing', 'in_app', 1
    );
    my $student = Registry::DAO::User->create($sdb, {
        username => "platform_student_$n", passhash => 'x',
    });
    my $location = Registry::DAO::Location->create($sdb, {
        name => "Platform Location $n", slug => "platform-location-$n",
        address_info => { street => '1 Test St' },
    });
    my $project = Registry::DAO::Project->create($sdb, {
        name => "Platform Project $n", slug => "platform-project-$n",
    });
    my $session = Registry::DAO::Session->create($sdb, {
        name => "Platform Session $n", slug => "platform-session-$n",
    });
    Registry::DAO::Enrollment->create($sdb, {
        student_id => $student->id, session_id => $session->id, status => 'active',
    });
    my $event = Registry::DAO::Event->create($sdb, {
        location_id => $location->id,
        project_id  => $project->id,
        teacher_id  => $teacher->id,
        start_time  => DateTime->now->subtract(minutes => 10),
        end_time    => DateTime->now->add(minutes => 50),
        metadata    => { title => "Platform Event $n" },
    });
    $sdb->insert('session_events', {
        session_id => $session->id, event_id => $event->id,
    });
    $sdb->insert('attendance_records', {
        event_id   => $event->id,
        student_id => $student->id,
        status     => 'present',
        marked_by  => $teacher->id,
    }) if $opt{recorded};
    return $event->id;
}

# Event ids that the missing-attendance check has notified about in a schema.
sub notified_event_ids ($schema) {
    my $quoted = $db->dbh->quote_identifier($schema);
    return $db->query(
        "SELECT metadata->>'event_id' FROM $quoted.notifications WHERE type = 'attendance_missing'"
    )->arrays->map(sub { $_->[0] })->to_array;
}

sub run_check (@schemas) {
    my $run = $workflow->new_run($db);
    if (@schemas) {
        $run->update_data($db, { tenant_schemas => \@schemas });
    }
    else {
        $workflow->get_step($db, { slug => 'tenants' })->process($db, {}, $run);
    }
    $workflow->get_step($db, { slug => 'missing' })->process($db, {}, $run);
    return $workflow->latest_run($db)->data;
}

my $registry_db = $dao->connect_schema('registry')->db;

subtest 'the attendance check covers events in the registry schema' => sub {
    my $event_id = plant_event($registry_db);

    my $data = run_check();

    ok( scalar( grep { $_ eq 'registry' } @{ $data->{tenant_schemas} } ),
        'registry is among the tenant schemas' );
    cmp_ok( $data->{missing_attendance_processed}, '>=', 1,
        'the registry schema was processed' );
    ok( scalar( grep { $_ eq $event_id } @{ notified_event_ids('registry') } ),
        'the registry event missing attendance was counted' );
};

done_testing;
