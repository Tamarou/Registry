#!/usr/bin/env perl
# ABOUTME: The capacity predicate re-checked at capture, excluding this payment's own rows.
# ABOUTME: NULL and zero capacity both mean unlimited; a sibling cart is counted whole.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_capacity_capture';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'CAP Studio', slug => 'cap-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'CAP Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'cap_teacher', name => 'T', user_type => 'staff',
    email => 'capt@test.local',
});
my $parent = $dao->create(User => {
    username => 'cap_parent', name => 'CAP Parent', user_type => 'parent',
    email => 'cap@test.local',
});

my $kid_seq = 0;
sub a_child () {
    $kid_seq++;
    return Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "CAP Kid $kid_seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
}

my $session_seq = 0;
sub a_session ($capacity) {
    # events carries a unique key on (project_id, location_id, time), so each
    # session's event needs its own slot rather than a shared literal.
    $session_seq++;
    my $s = $dao->create(Session => {
        name => "CAP Week $session_seq", start_date => '2026-01-01',
        end_date => '2026-12-31', status => 'published',
        capacity => $capacity, metadata => {},
    });
    my $e = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:00:00', $session_seq % 24),
        duration => 60, location_id => $loc->id,
        project_id => $prog->id, teacher_id => $teacher->id,
        capacity => $capacity, metadata => {},
    });
    $s->add_events($db, $e->id);
    return $s;
}

# A payment carrying a cart of (session, child) pairs, as create_payment leaves it.
sub a_payment (@pairs) {
    return Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 1000 * scalar @pairs,
        status => 'pending',
        metadata => {
            enrollment_items => [ map { { session_id => $_->{session}->id,
                                          child_id   => $_->{child}->id } } @pairs ],
            tenant_slug => undef,
        },
    });
}

# Somebody else's seat, already taken.
sub occupy ($session, $n) {
    for (1 .. $n) {
        Registry::DAO::Enrollment->create($db, {
            session_id       => $session->id,
            family_member_id => a_child()->id,
            parent_id        => $parent->id,
            status           => 'active',
        });
    }
}

subtest 'a payment whose seat was taken while it paid does not fit' => sub {
    my $session = a_session(2);
    my $payment = a_payment({ session => $session, child => a_child() });

    ok Registry::DAO::Enrollment->payment_fits_session($db, $payment, $session->id),
        'it fits while there is room';

    occupy($session, 2);    # both seats gone during the Stripe round trip

    ok !Registry::DAO::Enrollment->payment_fits_session($db, $payment, $session->id),
        'and does not once the seats are gone';
};

subtest 'the predicate excludes this payment own rows' => sub {
    # finalize_enrollment writes this payment's rows as 'active'. A re-check that
    # counted them would see the payment competing with itself and refund a seat
    # it had just been granted.
    my $session = a_session(1);
    my $child   = a_child();
    my $payment = a_payment({ session => $session, child => $child });

    Registry::DAO::Enrollment->create_for_payment($db, {
        session_id       => $session->id,
        family_member_id => $child->id,
        parent_id        => $parent->id,
        status           => 'active',
        payment_id       => $payment->id,
    });

    ok Registry::DAO::Enrollment->payment_fits_session($db, $payment, $session->id),
        'a payment already holding its seat still fits';
};

subtest 'siblings are admitted one seat at a time, not as a block' => sub {
    # Nine taken of ten, two siblings arriving together. This originally
    # asserted that neither fits -- comparing the whole cart every time, so
    # 9 + 2 > 10 on both iterations. That stopped the pair overselling but also
    # refunded a seat that existed: both children waitlisted, both refunded, the
    # tenth place left empty. The predicate now answers per child, counting the
    # siblings already placed, so the first takes the seat and only the second
    # is turned away.
    my $session = a_session(10);
    occupy($session, 9);

    my $two = a_payment(
        { session => $session, child => a_child() },
        { session => $session, child => a_child() },
    );
    ok Registry::DAO::Enrollment->payment_fits_session($db, $two, $session->id, 0),
        'the first sibling takes the last seat';
    ok !Registry::DAO::Enrollment->payment_fits_session($db, $two, $session->id, 1),
        'and the second, with that seat now taken by their sibling, does not';

    my $one = a_payment({ session => $session, child => a_child() });
    ok Registry::DAO::Enrollment->payment_fits_session($db, $one, $session->id),
        'a single child into that seat still fits';
};

subtest 'NULL and zero capacity both mean unlimited' => sub {
    # Nine live sites read capacity with a truthiness test, so 0 already means
    # unlimited everywhere else. A `defined` check here would refund every
    # capacity-0 session at capture while all nine waved the enrollment through.
    for my $capacity (undef, 0) {
        my $label   = defined $capacity ? 'zero' : 'NULL';
        my $session = a_session($capacity);
        occupy($session, 25);

        my $payment = a_payment({ session => $session, child => a_child() });
        ok Registry::DAO::Enrollment->payment_fits_session($db, $payment, $session->id),
            "a $label-capacity session is unlimited and still fits";
    }
};

subtest 'count_for_session is left alone' => sub {
    # The transfer-path callers want the unfiltered count; self-exclusion there
    # would be inert at best and wrong at worst.
    my $session = a_session(5);
    occupy($session, 3);
    is Registry::DAO::Enrollment->count_for_session($db, $session->id), 3,
        'the unfiltered count still counts everything';
};

done_testing;
