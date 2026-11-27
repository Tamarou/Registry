#!/usr/bin/env perl
# ABOUTME: A session resource's waitlist is a first-come queue of children, ordered by when they joined.
# ABOUTME: Entries move waiting -> offered -> accepted or lapsed, or leave, against real Postgres.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Sessions qw( make_session );
use Registry::DAO;
use Registry::DAO::Family;
use Registry::DAO::WaitlistEntry;
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;

my $made = 0;
my $parent = Test::Registry::Fixtures::create_user( $db, { username => 'wl-parent' } );

sub child () {
    return Registry::DAO::Family->add_child( $db, $parent->id,
        { child_name => 'Child ' . ++$made, birth_date => '2018-01-01', grade => '3' } )->id;
}

sub queue () { make_session( $db, waitlist => { kind => 'queue', offer_hold_hours => 48 } ) }

sub join_queue ( $session, $child ) {
    return Registry::DAO::WaitlistEntry->join( $db,
        { resource_id => $session->id, family_member_id => $child, payer_user_id => $parent->id } );
}

# A fresh run holding one of $session's seats: what an offer is made with.
sub held_seat ($session) {
    my $workflow = $db->insert( 'workflows', { slug => 'wl-' . ++$made, name => "Waitlist $made" },
        { returning => 'id' } )->hash->{id};
    my $run = $db->insert( 'workflow_runs', { workflow_id => $workflow }, { returning => 'id' } )->hash->{id};
    my $hold = Registry::PriceOps::Hold->place( $db, {
        resource_id => $session->id, units => 1, workflow_run_id => $run,
        expires_at  => \"clock_timestamp() + interval '48 hours'",
    } );
    return ( $hold->id, $run );
}

subtest 'entries are first come first served' => sub {
    my $session = queue();
    my @entries = map { join_queue( $session, child() ) } 1 .. 3;
    is $_->state, 'waiting', 'each joins waiting' for @entries;
    is Registry::DAO::WaitlistEntry->waiting_count( $db, $session->id ), 3, 'three wait';
    is_deeply [ map { Registry::DAO::WaitlistEntry->position( $db, $_->id ) } @entries ], [ 1, 2, 3 ],
        'positions follow joining order';

    my $tx    = $db->begin;
    my $first = Registry::DAO::WaitlistEntry->next_waiting( $db, $session->id );
    is $first->id, $entries[0]->id, 'the first to join is next';
    $first->offer( $db, held_seat($session) );
    is Registry::DAO::WaitlistEntry->next_waiting( $db, $session->id )->id, $entries[1]->id,
        'once offered, the second is next';
    $tx->commit;
    is Registry::DAO::WaitlistEntry->waiting_count( $db, $session->id ), 2, 'two still wait';
};

subtest 'an offered entry can be accepted' => sub {
    my $session = queue();
    my $entry   = join_queue( $session, child() );
    my ( $hold, $run ) = held_seat($session);
    my $offered = $entry->offer( $db, $hold, $run );
    is $offered->state,           'offered', 'offered';
    is $offered->hold_id,         $hold,     'with its hold';
    is $offered->workflow_run_id, $run,      'and its run';
    ok $offered->offered_at, 'and when';
    is $offered->accept($db)->state, 'accepted', 'then accepted';
};

subtest 'a lapsed child may join again' => sub {
    my $session = queue();
    my $child   = child();
    my $entry   = join_queue( $session, $child );
    is $entry->offer( $db, held_seat($session) )->lapse($db)->state, 'lapsed', 'the offer lapses';
    my $again = join_queue( $session, $child );
    isnt $again->id, $entry->id, 'a new entry';
    is $again->state, 'waiting', 'waiting at the back';
};

subtest 'positions close up after a child leaves' => sub {
    my $session = queue();
    my @entries = map { join_queue( $session, child() ) } 1 .. 3;
    is $entries[0]->leave($db)->state, 'left', 'the first leaves';
    is_deeply [ map { Registry::DAO::WaitlistEntry->position( $db, $_->id ) } @entries[ 1, 2 ] ], [ 1, 2 ],
        'the rest move up';
    is Registry::DAO::WaitlistEntry->waiting_count( $db, $session->id ), 2, 'two wait';
};

done_testing;
