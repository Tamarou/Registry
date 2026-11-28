#!/usr/bin/env perl
# ABOUTME: A step result that settles after another process moved the run (the run's driver) does not move it back.
# ABOUTME: A person answering an earlier step again still moves the run back to it, as before.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Test::Registry::LateStep;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowRun;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Late Result', slug => 'late-result', description => 'steps one, two, three', first_step => 'one' } );
my %step;
my $previous;
for my $slug (qw( one two three )) {
    $step{$slug} = Registry::DAO::WorkflowStep->create( $db, {
        workflow_id => $workflow->id, slug => $slug, description => $slug,
        ( $previous ? ( depends_on => $previous->id ) : () ) } );
    $previous = $step{$slug};
}
my $late = Test::Registry::LateStep->new( map { $_ => $step{two}->$_ } qw( id slug workflow_id description class ) );

sub at ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->latest_step($db)->slug }

subtest 'a result settling after the run was moved on leaves it there' => sub {
    my $run = $workflow->new_run($db);
    $run->process( $db, $step{one}, {} );
    is at($run), 'one', 'at one';

    # While step two's work is in flight, another process takes the run to three.
    my $driver = sub {
        my $other = Registry::DAO::WorkflowRun->find( $db, { id => $run->id } );
        $other->process( $db, $step{two}, {} );
        $other->process( $db, $step{three}, {} );
    };
    settle( $run->process( $db, $late, { meanwhile => $driver } ) );
    is at($run), 'three', 'it stays at three';
    ok Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{late}, "and step two's data is kept";
};

subtest 'a result settling with nobody else moving the run moves it on' => sub {
    my $run = $workflow->new_run($db);
    $run->process( $db, $step{one}, {} );
    settle( $run->process( $db, $late, {} ) );
    is at($run), 'two', 'on to two';
};

subtest 'answering an earlier step again moves the run back to it' => sub {
    my $run = $workflow->new_run($db);
    $run->process( $db, $step{$_}, {} ) for qw( one two three );
    $run->process( $db, $step{one}, {} );
    is at($run), 'one', 'back at one';
};

done_testing;
