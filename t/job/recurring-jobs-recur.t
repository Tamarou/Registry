#!/usr/bin/env perl
# ABOUTME: Every recurring sweep re-enqueues its own next run, so it recurs without a server restart.
# ABOUTME: Real Minion on real Postgres: seeded jobs are made due, performed, and the chain inspected.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;

my $test_db = Test::Registry::DB->new;
my $t       = Test::Registry::Mojo->new('Registry');
my $app     = $t->app;
my $minion  = $app->minion;
my $mdb     = $minion->backend->pg->db;

$app->log->level('fatal');
$app->import_workflows;    # attendance_check runs the attendance-check workflow

# The contract: each sweep and the delay between its runs, in seconds.
my %INTERVAL = (
    attendance_check     => 60,
    domain_verification  => 900,
    send_notifications   => 300,
    instalment_reconcile => 3600,
    waitlist_expiration  => 300,
    process_waitlist     => 600,
);

sub jobs_of ( $task, @states ) {
    return $minion->jobs( { tasks => [$task], ( @states ? ( states => \@states ) : () ) } );
}
sub queued ($task) { jobs_of( $task, 'inactive' )->total }
sub next_job ($task) { jobs_of( $task, 'inactive' )->next // {} }

# Bypass the delay: make every queued job of $task due now, then work the queue.
sub run_due ($task) {
    $mdb->query( q{UPDATE minion_jobs SET delayed = now() WHERE task = ? AND state = 'inactive'}, $task );
    $minion->perform_jobs;
}

subtest 'each sweep runs a second time' => sub {
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;

    for my $task ( sort keys %INTERVAL ) {
        is queued($task), 1, "$task seeded once";
        my $first = next_job($task)->{id};

        run_due($task);
        is $minion->job($first)->info->{state}, 'finished', "$task first run finished";
        is queued($task), 1, "$task queued its own next run";
        my $second = next_job($task)->{id};
        isnt $second, $first, "$task next run is a new job";

        run_due($task);
        is $minion->job($second)->info->{state}, 'finished', "$task ran a second time";
        is queued($task), 1, "$task queued a third run";
    }
};

subtest 'next run delayed by task interval' => sub {
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;

    for my $task ( sort keys %INTERVAL ) {
        run_due($task);
        my $next  = next_job($task);
        my $delay = $next->{delayed} - $next->{created};
        cmp_ok $delay, '>', 0, "$task next run is not enqueued with zero delay";
        cmp_ok abs( $delay - $INTERVAL{$task} ), '<', 2, "$task next run is delayed by $INTERVAL{$task}s";
    }
};

subtest 'task without interval dies' => sub {
    $minion->reset( { all => 1 } );
    require Registry::Job::Recurring;

    eval { Registry::Job::Recurring->enqueue_next( $app, 'no_such_sweep' ) };
    like $@, qr/no recurring interval.*no_such_sweep/i, 'enqueue_next dies naming the task';
    eval { Registry::Job::Recurring->interval_for('no_such_sweep') };
    like $@, qr/no recurring interval.*no_such_sweep/i, 'interval_for dies naming the task';
    is jobs_of('no_such_sweep')->total, 0, 'nothing was enqueued with a default delay';
};

# Real failures, not stand-ins: the table a sweep reads is renamed away for
# the length of one run.
sub with_table_gone ( $table, $code ) {
    $mdb->query("ALTER TABLE registry.$table RENAME TO ${table}_gone");
    $code->();
    $mdb->query("ALTER TABLE registry.${table}_gone RENAME TO $table");
}

subtest 'failed sweep schedules next run without duplicate chain' => sub {
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;
    my $first = next_job('waitlist_expiration')->{id};

    # WaitlistExpiration catches its own error and calls $job->fail.
    with_table_gone( tenants => sub { run_due('waitlist_expiration') } );
    is $minion->job($first)->info->{state}, 'failed', 'the sweep failed';
    is queued('waitlist_expiration'), 1, 'and still queued its next run';

    $app->setup_recurring_jobs;
    is queued('waitlist_expiration'), 1, 'setup_recurring_jobs again adds no second chain';
};

subtest 'dying sweep leaves exactly one next run' => sub {
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;
    my $first = next_job('domain_verification')->{id};

    # DomainVerification lets the query's exception escape the task.
    with_table_gone( tenant_domains => sub { run_due('domain_verification') } );
    my $info = $minion->job($first)->info;
    is $info->{state}, 'failed', 'the sweep died';
    like $info->{result}, qr/tenant_domains/, 'with the real error';
    is $info->{retries}, 0, 'and was not retried';
    is queued('domain_verification'), 1, 'exactly one next run is queued';
    isnt next_job('domain_verification')->{id}, $first, 'and it is a new job, not a retry';
};

subtest 'setup during running sweep leaves one next run' => sub {
    $minion->reset( { all => 1 } );
    $app->setup_recurring_jobs;
    $mdb->query(q{UPDATE minion_jobs SET delayed = now() WHERE task = 'process_waitlist'});

    my $worker = $minion->worker->register;
    my $job    = $worker->dequeue( 0, { tasks => ['process_waitlist'] } );
    is $job->info->{state}, 'active', 'the sweep is running';

    $app->setup_recurring_jobs;    # a second app process booting mid-sweep

    my $err = $job->execute;
    defined $err ? $job->fail($err) : $job->finish;
    $worker->unregister;

    is $job->info->{state}, 'finished', 'the sweep finished';
    is queued('process_waitlist'), 1, 'exactly one next run is queued, not two chains';
};

subtest 'no workflow_executor job queued' => sub {
    $minion->reset( { all => 1 } );
    $mdb->query(q{DELETE FROM registry.workflow_runs WHERE workflow_id IN
        (SELECT id FROM registry.workflows WHERE slug = 'attendance-check')});
    $app->setup_recurring_jobs;
    run_due('attendance_check');

    is jobs_of('workflow_executor')->total, 0, 'nothing enqueued the unregistered workflow_executor';
    is queued('attendance_check'), 1, 'the next run is an attendance_check job';

    my $runs = $mdb->query(q{SELECT r.data FROM registry.workflow_runs r
        JOIN registry.workflows w ON w.id = r.workflow_id
        WHERE w.slug = 'attendance-check'})->expand->hashes;
    ok $runs->size, 'the attendance-check workflow ran';
    ok !( grep { exists( ( $_->{data}{workflow_context} // {} )->{app} ) } @$runs ),
        'no run data holds an app object';
};

done_testing;
