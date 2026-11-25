#!/usr/bin/env perl
# ABOUTME: The attendance-check-drops-schedule-next migration takes the no-op step out of registry's and each tenant's copy.
# ABOUTME: A run that ended on it still reads as completed, now on the step before; the revert puts both back.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Mojo::File qw(path);
use YAML::XS qw(Load);

my $change = 'attendance-check-drops-schedule-next';
my $pg     = Test::PostgreSQL->new or BAIL_OUT $Test::PostgreSQL::errstr;
my $sqitch = App::Sqitch->new;
$sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', "$change^" );
my $db = Mojo::Pg->new( $pg->uri )->db;

# The workflow as the importer stored it before: four steps, schedule-next last.
my $wf = $db->query( q{INSERT INTO registry.workflows (name, slug, roles)
    VALUES ('Attendance Check', 'attendance-check', ARRAY['admin','staff']) RETURNING id} )->hash->{id};
my $prev;
for my $step (qw(process-tenants check-missing-attendance check-upcoming-events schedule-next)) {
    my $class = $step eq 'schedule-next'
        ? 'Registry::DAO::WorkflowSteps::AttendanceCheck::ScheduleNext' : 'Registry::DAO::WorkflowStep';
    $prev = $db->query( q{INSERT INTO registry.workflow_steps (slug, workflow_id, depends_on, class)
        VALUES (?, ?, ?, ?) RETURNING id}, $step, $wf, $prev, $class )->hash->{id};
}
$db->query( q{UPDATE registry.workflows SET first_step = 'process-tenants' WHERE id = ?}, $wf );
$db->query( q{INSERT INTO registry.tenants (name, slug) VALUES ('Old Copy', 'oldcopy')} );
$db->query( q{SELECT registry.clone_schema('oldcopy')} );
$db->query( q{SELECT registry.copy_workflow('oldcopy', ?)}, $wf );

# A completed run in each schema, ended on schedule-next.
for my $s (qw(registry oldcopy)) {
    $db->query( qq{INSERT INTO "$s".workflow_runs (workflow_id, latest_step_id)
        SELECT w.id, st.id FROM "$s".workflows w JOIN "$s".workflow_steps st ON st.workflow_id = w.id
         WHERE w.slug = 'attendance-check' AND st.slug = 'schedule-next'} );
}

sub steps ($s) {
    $db->query( qq{SELECT st.slug FROM "$s".workflow_steps st JOIN "$s".workflows w ON w.id = st.workflow_id
        WHERE w.slug = 'attendance-check' ORDER BY st.created_at, st.slug} )->arrays->map( sub { $_->[0] } )->to_array;
}
sub run_ended_on ($s) {
    $db->query( qq{SELECT st.slug FROM "$s".workflow_runs r JOIN "$s".workflow_steps st ON st.id = r.latest_step_id
        JOIN "$s".workflows w ON w.id = r.workflow_id WHERE w.slug = 'attendance-check'} )->array->[0];
}

my @shipped = map { $_->{slug} } @{ Load( path('workflows/attendance-check.yml')->slurp )->{steps} };

$sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', $change );
for my $s (qw(registry oldcopy)) {
    is_deeply [ sort @{ steps($s) } ], [ sort @shipped ], "$s stores the steps the YAML ships";
    is run_ended_on($s), 'check-upcoming-events', "$s run now ends on the step before";
}

$sqitch->run( 'sqitch', 'revert', '-y', '-t', $pg->uri, '--to', "$change^" );
for my $s (qw(registry oldcopy)) {
    ok scalar( grep { $_ eq 'schedule-next' } @{ steps($s) } ), "revert puts schedule-next back in $s";
    is run_ended_on($s), 'schedule-next', "and $s run ends on it again, still completed";
}

# The handle goes before the server does, or its DESTROY talks to a dead one.
undef $db;
done_testing;
