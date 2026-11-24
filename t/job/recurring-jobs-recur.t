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

done_testing;
