#!/usr/bin/env perl
# ABOUTME: Running the attendance_check job queues its next run, and the run driver takes its workflow to the end.
# ABOUTME: Real Minion on real Postgres, through Minion's own worker; nothing here takes a test-mode branch.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Mojo::File qw(path);
use YAML::XS qw(Load);

my $test_db = Test::Registry::DB->new;
my $t       = Test::Registry::Mojo->new('Registry');
my $app     = $t->app;
my $minion  = $app->minion;
my $mdb     = $minion->backend->pg->db;

$app->log->level('fatal');
$app->import_workflows;    # attendance_check runs the attendance-check workflow

sub queued ($task) { $minion->jobs( { tasks => [$task], states => ['inactive'] } ) }

$minion->reset( { all => 1 } );
$mdb->query(q{DELETE FROM registry.workflow_runs WHERE workflow_id IN
    (SELECT id FROM registry.workflows WHERE slug = 'attendance-check')});

my $id = $minion->enqueue('attendance_check');
$minion->perform_jobs_in_foreground( { id => $id } );

subtest 'the check queues its next run' => sub {
    is $minion->job($id)->info->{state}, 'finished', 'the check finished';
    is queued('attendance_check')->total, 1, 'one next attendance_check is queued';
    my $next = queued('attendance_check')->next;
    cmp_ok abs( $next->{delayed} - $next->{created} - 60 ), '<', 2, 'a minute out';
    is $minion->jobs( { tasks => ['workflow_executor'] } )->total, 0, 'nothing is queued for the retired executor';
};

subtest 'the run driver takes the run to its last step' => sub {
    my $runs = $mdb->query(q{SELECT r.data, s.slug AS stopped_at FROM registry.workflow_runs r
        JOIN registry.workflows w ON w.id = r.workflow_id
        LEFT JOIN registry.workflow_steps s ON s.id = r.latest_step_id
        WHERE w.slug = 'attendance-check'})->expand->hashes;
    is $runs->size, 1, 'the check started one run';
    my $last = Load( path('workflows/attendance-check.yml')->slurp )->{steps}[-1]{slug};
    is $runs->[0]{stopped_at}, $last, "which completed at its last step, $last";
    ok !exists $runs->[0]{data}{workflow_context}, 'and holds no job context';
    ok scalar( grep { $_ eq 'registry' } @{ $runs->[0]{data}{tenant_schemas} // [] } ),
        'it walked the platform tenant';
};

subtest 'the old executor and its command are gone' => sub {
    ok !eval { require Registry::Job::WorkflowExecutor; 1 }, 'Registry::Job::WorkflowExecutor is deleted';
    ok !eval { require Registry::Command::workflow_job; 1 }, 'the workflow_job command is deleted';
};

done_testing;
