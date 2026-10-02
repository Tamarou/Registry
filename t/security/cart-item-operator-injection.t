#!/usr/bin/env perl
# ABOUTME: Proves a hashref in a cart item's child_id or session_id cannot reach a WHERE clause.
# ABOUTME: SQL::Abstract renders a hashref as an OPERATOR, so one answers about a different child's row.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::User;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_cart_item_injection';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = Registry::DAO::User->create( $db, {
    username => 'cart_parent', name => 'Cart Parent', user_type => 'parent',
    email => 'cart@test.local',
} );

my @kids = map {
    Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => $_, birth_date => '2016-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    } )
} ( 'Seated Kid', 'Other Kid' );
my ( $seated, $other ) = @kids;

my $session = Registry::DAO::Session->create( $db, {
    name => 'Injection Week', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 5, metadata => {},
} );

my $payment = Registry::DAO::Payment->create( $db, {
    user_id => $parent->id, amount_cents => 10000, status => 'completed',
    metadata => { enrollment_items => [], tenant_slug => undef },
} );

# One real seat, held by $seated under this payment.
Registry::DAO::Enrollment->create_for_payment( $db, {
    session_id => $session->id, family_member_id => $seated->id,
    parent_id => $parent->id, status => 'active', payment_id => $payment->id,
} );

# The shape a bracketed form parameter expands to. expand_form_params turns
# child_id[!=]=<id> into exactly this, and the cart is copied out of run data
# into payment metadata verbatim.
my $operator = { '!=' => $other->id };

subtest 'cart_seat_state refuses an operator where a child id belongs' => sub {
    my $answer = eval {
        Registry::DAO::Enrollment->cart_seat_state(
            $db, $payment->id, $session->id, $operator );
    };
    my $err = $@;

    ok $err, 'it is refused rather than answered';
    like $err, qr/scalar|ref/i, 'and says what was wrong with it';

    # The defect, stated as the thing that must not happen: "not Other Kid"
    # matches Seated Kid's row, so the cart is told it holds a seat for a child
    # it has nothing for -- or, through the demotion below, moves one.
    isnt $answer // '', 'seated',
        'it never answers "seated" about a row belonging to another child';
};

subtest 'cart_seat_state refuses an operator where a session id belongs' => sub {
    my $err = do {
        local $@;
        eval {
            Registry::DAO::Enrollment->cart_seat_state(
                $db, $payment->id, { '!=' => '00000000-0000-0000-0000-000000000000' },
                $seated->id );
        };
        $@;
    };
    ok $err, 'refused';
};

subtest 'demote_to_waitlisted refuses one too, and moves nobody' => sub {
    my $err = do {
        local $@;
        eval {
            Registry::DAO::Enrollment->demote_to_waitlisted( $db, {
                session_id => $session->id,
                family_member_id => $operator,
                parent_id => $parent->id,
                payment_id => $payment->id,
            } );
        };
        $@;
    };

    ok $err, 'refused';

    # The row that would have been hit. An UPDATE through an operator would
    # release a seat belonging to a child nobody asked about, and owe a refund
    # for it.
    my $row = $db->select( 'enrollments', ['status'],
        { session_id => $session->id, student_id => $seated->id } )->hash;
    is $row->{status}, 'active', "the other child's seat is untouched";

    my $queue = $db->select( 'waitlist', 'COUNT(*)',
        { session_id => $session->id } )->array->[0];
    is $queue, 0, 'and nobody was queued in their name';
};

subtest 'a plain id still works' => sub {
    is Registry::DAO::Enrollment->cart_seat_state(
        $db, $payment->id, $session->id, $seated->id ), 'seated',
        'the guard refuses structure, not ids';
};

done_testing;
