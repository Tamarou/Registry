#!/usr/bin/env perl
# ABOUTME: Regression test for tenant schema search_path quoting in AttendanceCheck steps.
# ABOUTME: A tenant schema whose name contains a hyphen must not break SET search_path.

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor;
use Registry::DAO::WorkflowSteps::AttendanceCheck::UpcomingEventProcessor;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A tenant schema with a hyphen -- e.g. the real "registry-platform" tenant.
# An unquoted identifier here ("SET search_path TO registry-platform, ...")
# is a syntax error in PostgreSQL, so the schema must be quoted.
my $schema = 'test-hyphen-tenant';
$db->query(qq{CREATE SCHEMA IF NOT EXISTS "$schema"});

my $workflow = Registry::DAO::Workflow->create($db, {
    name        => 'Attendance Check',
    slug        => 'attendance-check-test',
    description => 'Test workflow for attendance check steps',
});

Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'missing',
    class       => 'Registry::DAO::WorkflowSteps::AttendanceCheck::MissingAttendanceProcessor',
    description => 'Missing attendance processor',
});

Registry::DAO::WorkflowStep->create($db, {
    workflow_id => $workflow->id,
    slug        => 'upcoming',
    class       => 'Registry::DAO::WorkflowSteps::AttendanceCheck::UpcomingEventProcessor',
    description => 'Upcoming event processor',
});

$workflow->update($db, { first_step => 'missing' }, { id => $workflow->id });

subtest 'MissingAttendanceProcessor handles a hyphenated tenant schema' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { tenant_schemas => [$schema] });

    my $step = $workflow->get_step($db, { slug => 'missing' });
    $step->process($db, {}, $run);

    my $data = $workflow->latest_run($db)->data;
    is( $data->{missing_attendance_processed}, 1,
        'hyphenated schema processed (search_path did not error)' );
};

subtest 'UpcomingEventProcessor handles a hyphenated tenant schema' => sub {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { tenant_schemas => [$schema] });

    my $step = $workflow->get_step($db, { slug => 'upcoming' });
    $step->process($db, {}, $run);

    my $data = $workflow->latest_run($db)->data;
    is( $data->{upcoming_events_processed}, 1,
        'hyphenated schema processed (search_path did not error)' );
};

done_testing;
