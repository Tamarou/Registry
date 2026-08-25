#!/usr/bin/env perl
# ABOUTME: A capacity refund debt is owed once, paid once, and cleared when paid.
# ABOUTME: A second settlement does not re-owe for a child already waitlisted.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_refund_debt';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'DBT Studio', slug => 'dbt-studio', address_info => {}, metadata => {} });
my $prog = $dao->create(Project => {
    status => 'published', name => 'DBT Camp',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => {
    username => 'dbt_teacher', name => 'T', user_type => 'staff',
    email => 'dbtt@test.local' });
my $parent = $dao->create(User => {
    username => 'dbt_parent', name => 'DBT Parent', user_type => 'parent',
    email => 'dbt@test.local' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "DBT Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}
sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "DBT Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {} });
    my $e = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => $capacity, metadata => {} });
    $s->add_events($db, $e->id);
    return $s;
}
sub a_paid_cart (@pairs) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000 * scalar @pairs,
        status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $_->{session}->id,
                                          child_id   => $_->{child}->id } } @pairs ],
            tenant_slug => undef } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_dbt_' . $p->id },
        { id => $p->id });
    for my $pair (@pairs) {
        $db->insert('payment_items', {
            payment_id => $p->id, description => 'seat', amount_cents => 10000,
            metadata => { -json => { child_id   => $pair->{child}->id,
                                     session_id => $pair->{session}->id } } });
    }
    return Registry::DAO::Payment->find($db, { id => $p->id });
}
sub occupy ($session, $n) {
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' }) for 1 .. $n;
}
sub reload ($payment) { Registry::DAO::Payment->find($db, { id => $payment->id }) }

sub finalize ($payment) {
    my $tx   = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;
    return $owed;
}

subtest 'a paid debt is cleared, so a later settlement does not pay it again' => sub {
    my $session = a_session(1);
    my $payment = a_paid_cart({ session => $session, child => a_child() });
    occupy($session, 1);

    is finalize($payment), 10000, 'the lost seat is owed';
    is reload($payment)->refund_owed_cents, 10000, 'and recorded';

    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, $p;
            Mojo::Promise->resolve({ id => 're_dbt', status => 'succeeded' });
        };
        # The production shape: one call per unsettled increment, then settle
        # that increment. refund_async no longer discharges anything -- it
        # records the Stripe reference, and settle_refund_increment subtracts
        # exactly the increment it settles.
        my $p   = reload($payment);
        my $due = $p->unsettled_refund_increments($db);
        for my $inc (@$due) {
            settle( $p->refund_async($db, {
                amount_cents    => $inc->{cents},
                idempotency_key => $p->capacity_refund_key( $inc->{seq} ),
            }) );
            $p->settle_refund_increment( $db, $inc->{seq}, { id => 're_dbt' } );
        }
    }

    is scalar @refunds, 1, 'the refund is issued once';
    is $refunds[0]{amount}, 10000, 'for the increment amount, not a running total';
    ok !reload($payment)->refund_owed_cents,
        'and the debt marker is cleared once it is paid';
    is reload($payment)->refunded_cents, 10000,
        'with the cumulative total returned recorded, which jsonb never was';
};

subtest 'a child already waitlisted does not create a second debt' => sub {
    # finalize_enrollment recomputes from scratch on every delivery. Without a
    # transition check, a Stripe redelivery re-owes for a child who was demoted
    # and refunded on the first pass.
    my $session = a_session(1);
    my $payment = a_paid_cart({ session => $session, child => a_child() });
    occupy($session, 1);

    is finalize($payment), 10000, 'first pass owes the lost seat';

    # Clear the debt the way a successful refund does: settle the increment.
    # Deleting the jsonb key was the old shape and is now a no-op, so the debt
    # survived and the assertion below passed only because it read that same
    # dead key.
    my ($inc) = @{ reload($payment)->unsettled_refund_increments($db) };
    reload($payment)->settle_refund_increment( $db, $inc->{seq}, { id => 're_paid' } );

    finalize(reload($payment));

    # Asserted on the row, not on finalize_enrollment's return value: neither
    # caller reads that return (Webhooks.pm re-reads the committed row, and the
    # workflow step re-reads it too), so a return-value assertion grades
    # something no production code consults.
    #
    # The row is still refund_pending from the first pass. That status is
    # deliberately NOT in _money_returned, so the second delivery is not refused
    # by the gate -- it runs, and the already-waitlisted child is skipped inside
    # the loop instead.
    # Read off the column. metadata.refund_owed_cents has had no writer in lib/
    # since the obligation became typed, so asserting it is undef is
    # unconditionally true and grades nothing.
    is reload($payment)->refund_owed_cents, 0,
        'a second delivery owes nothing for a child already waitlisted';
    is $db->query(q{SELECT COUNT(*) FROM enrollments
                     WHERE payment_id = ? AND status IN ('active','pending')},
        $payment->id)->array->[0], 0,
        'and seats nobody against the money it already owes back';

    # The two assertions above are satisfied by "the second delivery did
    # nothing at all" just as well as by "it adjudicated and owed nothing" --
    # an early return leaves metadata and enrollments untouched too. That is
    # exactly the regression this subtest exists to catch, and an earlier
    # rewrite of it lost the distinction: putting refund_pending back into
    # _money_returned left this file green. Graded directly, so the classifier
    # cannot drift without something here going red.
    ok !Registry::DAO::Payment->_money_returned('refund_pending'),
        'a refund_pending row is not treated as money already returned';
    ok Registry::DAO::Payment->_money_returned($_),
        "$_ is treated as money already returned"
        for qw( refunded partially_refunded );
};

subtest 'the idempotency key names the children it refunds' => sub {
    # A key that is constant per payment while the amount is recomputed makes
    # Stripe reject the second, differently-priced refund with an
    # idempotency_error -- and both callers swallow it, so the refund never
    # happens at all.
    # Driven through the obligation metadata rather than two settlements: a
    # child seated by the first pass is short-circuited by the second and can no
    # longer be demoted, so two settlements cannot produce two different owed
    # sets for one payment. The property under test is the key derivation.
    # Two children, so the cart is 20000 and a second increment has room to
    # land. With a one-child cart the first pass owes the entire value and the
    # second record is refused by the headroom predicate -- the case this
    # subtest exists to exercise never happened, and the assertions passed
    # against an increment that was never created.
    # Capacity 2 with one seat taken: of the cart's two children one gets the
    # free seat and one is demoted, so the first pass owes 10000 of a 20000
    # cart and leaves headroom for a second increment to land. A one-child cart
    # -- or a full session -- owes the entire value on the first pass, the
    # second record is refused by the headroom predicate, and the assertions
    # below grade an increment that was never created.
    my $full  = a_session(2);
    my $kid_a = a_child();
    my $payment = a_paid_cart({ session => $full, child => $kid_a },
                              { session => $full, child => a_child() });
    occupy($full, 1);

    finalize($payment);
    my $p       = reload($payment);
    my ($first) = @{ $p->unsettled_refund_increments($db) };
    my $key_one = $p->capacity_refund_key( $first->{seq} );
    is $key_one, 'refund:capacity:' . $payment->id . ':1',
        'the key names the increment it pays for';

    # New debt is a different refund and must not replay the first key. It must
    # also not MOVE the first key: that is what the old child-set derivation did,
    # and it is why a lost response followed by a new demotion sent the whole
    # accumulated balance under a key Stripe had never seen.
    $p->record_capacity_obligation( $db, 5000, [ a_child()->id ] );

    is $p->capacity_refund_key( $first->{seq} ), $key_one,
        'the first increment keeps its key when the debt grows';
    isnt $p->capacity_refund_key(2), $key_one,
        'and the new increment gets its own';

    my $due = $p->unsettled_refund_increments($db);
    my $total = 0; $total += $_->{cents} for @$due;
    # Off a reloaded row, not $p. record_capacity_obligation refreshes $status
    # but not $refund_owed_cents, so comparing against the in-memory field
    # compares a fresh number to a stale one -- it passed only because the
    # unreachable-increment defect above cancelled it out.
    is $total, reload($payment)->refund_owed_cents,
        'what would reach Stripe equals what is owed -- never more';
    cmp_ok scalar @$due, '>', 1, 'and there really are two increments to sum';
};

subtest 'a failed refund leaves the debt for the runbook' => sub {
    my $session = a_session(1);
    my $payment = a_paid_cart({ session => $session, child => a_child() });
    occupy($session, 1);
    finalize($payment);

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async =
            sub { Mojo::Promise->reject('card network unavailable') };
        eval { settle( reload($payment)->refund_async($db, {
            amount_cents => 10000, idempotency_key => 'refund:capacity:fail' }) ); 1 };
    }

    is reload($payment)->refund_owed_cents, 10000,
        'the debt survives a failed refund so the runbook can find it';
    is reload($payment)->status, 'refund_pending', 'and the row stays refund_pending';
};

done_testing;
