#!/usr/bin/env perl
# ABOUTME: When the seat is gone at capture, the child is waitlisted and the payment owes a refund.
# ABOUTME: The demotion survives an existing active row, which a plain insert would not.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_capacity_demotion';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'DEM Studio', slug => 'dem-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'DEM Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'dem_teacher', name => 'T', user_type => 'staff',
    email => 'demt@test.local',
});
my $parent = $dao->create(User => {
    username => 'dem_parent', name => 'DEM Parent', user_type => 'parent',
    email => 'dem@test.local',
});

my $seq = 0;
sub a_child () {
    $seq++;
    return Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "DEM Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
}

sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "DEM Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {},
    });
    my $e = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:%02d:00', $seq % 24, $seq % 60),
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
    $db->update('payments', { stripe_payment_intent_id => 'pi_dem_' . $p->id },
        { id => $p->id });
    # Line items are what refund_share_for resolves a per-child share from.
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

sub enrollment_status ($payment, $session) {
    my $row = $db->select('enrollments', ['status'],
        { payment_id => $payment->id, session_id => $session->id })->hash;
    return $row ? $row->{status} : undef;
}

subtest 'a seat lost during payment is waitlisted, not enrolled' => sub {
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    occupy($session, 1);    # the seat goes while the parent is paying

    my $tx    = $db->begin;
    my $owed  = $payment->finalize_enrollment($db);
    $tx->commit;

    is enrollment_status($payment, $session), 'waitlisted',
        'the loser is waitlisted rather than enrolled';
    is $owed, 10000, 'and the payment owes that child\'s share back';

    my $after = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $after->status, 'refund_pending', 'the payment is marked refund_pending';
    is $after->metadata->{refund_owed_cents}, 10000, 'with the owed amount recorded';
};

subtest 'a demotion over an existing active row actually changes it' => sub {
    # create_for_payment's arbiter is DO NOTHING on
    # (session_id, student_id, payment_id), which is exactly the triple a prior
    # pass wrote. A plain waitlisted insert here is a silent no-op and the child
    # stays enrolled in a session that has no room.
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_paid_cart({ session => $session, child => $child });

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active', payment_id => $payment->id,
    });
    is enrollment_status($payment, $session), 'active', 'the active row exists first';

    occupy($session, 1);

    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    is enrollment_status($payment, $session), 'waitlisted',
        'the existing row is updated, not skipped by the conflict arbiter';
    is $owed, 10000, 'and the refund is still owed';
};

subtest 'a cart that fits owes nothing and stays completed' => sub {
    my $session = a_session(5);
    my $payment = a_paid_cart({ session => $session, child => a_child() });

    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    is enrollment_status($payment, $session), 'active', 'the child is enrolled';
    is $owed, 0, 'nothing is owed';

    my $after = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $after->status, 'completed', 'and the payment is left completed';
};

subtest 'a mixed cart enrolls what fits and refunds only what does not' => sub {
    my $roomy  = a_session(5);
    my $full   = a_session(1);
    my $kid_in = a_child();
    my $kid_out = a_child();
    my $payment = a_paid_cart(
        { session => $roomy, child => $kid_in },
        { session => $full,  child => $kid_out },
    );

    occupy($full, 1);

    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    is enrollment_status($payment, $roomy), 'active',  'the child with room is enrolled';
    is enrollment_status($payment, $full),  'waitlisted', 'the child without is waitlisted';
    is $owed, 10000, 'only the lost seat is owed back, not the whole cart';
};

done_testing;
