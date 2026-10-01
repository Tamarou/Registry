#!/usr/bin/env perl
# ABOUTME: A child demoted at settlement lands in the waitlist table the platform actually reads.
# ABOUTME: The released seat must not block the offer that queue later makes them.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Waitlist;
use Registry::DAO::Family;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_demoted_joins_waitlist';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'DJW Studio', slug => 'djw-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'DJW Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'djw_teacher', name => 'T', user_type => 'staff',
    email => 'djwt@test.local',
});
my $parent = $dao->create(User => {
    username => 'djw_parent', name => 'DJW Parent', user_type => 'parent',
    email => 'djw@test.local',
});

my $seq = 0;

sub a_child () {
    $seq++;
    return Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "DJW Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
}

sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "DJW Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {},
    });
    my $e = $dao->create(Event => {
        time => sprintf('2026-07-15 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => $capacity, metadata => {},
    });
    $s->add_events($db, $e->id);
    return $s;
}

sub a_paid_cart (@pairs) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 10000 * scalar @pairs,
        status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $_->{session}->id,
                                          child_id   => $_->{child}->id } } @pairs ],
            tenant_slug => undef,
        },
    });
    $db->update('payments', { stripe_payment_intent_id => 'pi_djw_' . $p->id },
        { id => $p->id });
    for my $pair (@pairs) {
        $db->insert('payment_items', {
            payment_id   => $p->id,
            description  => 'seat',
            amount_cents => 10000,
            metadata     => { -json => { child_id   => $pair->{child}->id,
                                         session_id => $pair->{session}->id } },
        });
    }
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub occupy ($session, $n) {
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active',
    }) for 1 .. $n;
}

# The seat goes while the parent is paying, which is the only way to reach the
# demotion: driven through finalize_enrollment rather than by calling
# demote_to_waitlisted, so what is under test is the state a settlement leaves.
sub a_demotion () {
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    occupy($session, 1);

    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    return ( $session, $child, $payment, $owed );
}

sub queue_rows ($session, $child) {
    return $db->select('waitlist', undef,
        { session_id => $session->id, student_id => $child->id })->hashes->to_array;
}

subtest 'the demotion puts the child in the queue the platform reads' => sub {
    my ( $session, $child, $payment, $owed ) = a_demotion();

    is $owed, 10000, 'the share is still owed back';

    my $queue = Registry::DAO::Waitlist->get_session_waitlist($db, $session->id);
    is scalar @$queue, 1, 'the session has one child waiting';
    is $queue->[0]->student_id, $child->id, 'and it is the demoted child';
    is $queue->[0]->status, 'waiting', 'waiting, not some private status';
    ok $queue->[0]->position, 'with a position in the queue';
};

subtest 'the parent can see the queue entry' => sub {
    my ( $session, $child ) = a_demotion();

    my $entries = Registry::DAO::Waitlist->get_entries_for_parent($db, $parent->id);
    ok scalar( grep { $_->{session_name} eq $session->name } @$entries ),
        'the demoted child shows on the parent dashboard waitlist';
};

subtest 'the freed seat is offered to the demoted child, and can be accepted' => sub {
    my ( $session, $child ) = a_demotion();

    my $offer = Registry::DAO::Waitlist->process_waitlist($db, $session->id);
    ok $offer, 'a seat opening reaches the demoted child at all';
    is $offer->student_id, $child->id, 'the offer goes to them';

    # The reason the released seat must not stay in enrollments: accept_offer
    # inserts an enrollment, and enrollments_session_student_type_live would
    # refuse it against a row of ours that is anything but cancelled. A queue
    # entry whose acceptance dies is worse than no queue entry.
    my $accepted = eval { $offer->accept_offer($db); 1 };
    ok $accepted, 'and accepting it enrolls them rather than raising';
    diag "accept_offer died: $@" unless $accepted;
};

subtest 'a redelivery neither duplicates the entry nor re-owes the share' => sub {
    my ( $session, $child, $payment ) = a_demotion();

    my $tx    = $db->begin;
    my $again = $payment->finalize_enrollment($db);
    $tx->commit;

    is $again, 0, 'the second delivery owes nothing further';
    is scalar @{ queue_rows( $session, $child ) }, 1,
        'and the child is in the queue exactly once';

    my $after = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $after->refund_owed_cents, 10000, 'the debt is unchanged by the redelivery';
};

subtest 'a child who chose to wait is not queued twice by a demotion' => sub {
    my $session = a_session(1);
    my $child   = a_child();

    Registry::DAO::Waitlist->join_items($db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ]);

    my $payment = a_paid_cart({ session => $session, child => $child });
    occupy($session, 1);

    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    is scalar @{ queue_rows( $session, $child ) }, 1,
        'the existing queue entry is left alone';
    is $owed, 10000, 'the paid seat is still refunded';
};

subtest 'a demotion that cannot queue the child says so' => sub {
    # waitlist.location_id is NOT NULL and join_items resolves it from where the
    # session meets, so a session with no located event has nowhere to put them.
    # The release and the refund are still right; what must not happen is the
    # runbook promising an operator a queue entry that is not there.
    my $nowhere = $dao->create(Session => {
        name => 'DJW Unlocated', start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 1, metadata => {},
    });
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $nowhere, child => $child });

    occupy($nowhere, 1);

    my @warnings;
    my $owed = do {
        local $SIG{__WARN__} = sub { push @warnings, $_[0] };
        my $tx  = $db->begin;
        my $got = $payment->finalize_enrollment($db);
        $tx->commit;
        $got;
    };

    is $owed, 10000, 'the share is still owed back';
    is scalar @{ queue_rows( $nowhere, $child ) }, 0,
        'and nobody is queued, because there is nowhere to queue them';
    ok scalar( grep { /without queueing them/ } @warnings ),
        'the demotion reports that it could not queue them';
};

done_testing;
