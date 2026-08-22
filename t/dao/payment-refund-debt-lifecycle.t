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
    is reload($payment)->metadata->{refund_owed_cents}, 10000, 'and recorded';

    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
            push @refunds, $p;
            Mojo::Promise->resolve({ id => 're_dbt', status => 'succeeded' });
        };
        settle( reload($payment)->refund_async($db, {
            amount_cents    => 10000,
            idempotency_key => 'refund:capacity:test',
        }) );
    }

    is scalar @refunds, 1, 'the refund is issued once';
    ok !defined reload($payment)->metadata->{refund_owed_cents},
        'and the debt marker is cleared once it is paid';
};

subtest 'a child already waitlisted does not create a second debt' => sub {
    # finalize_enrollment recomputes from scratch on every delivery. Without a
    # transition check, a Stripe redelivery re-owes for a child who was demoted
    # and refunded on the first pass.
    my $session = a_session(1);
    my $payment = a_paid_cart({ session => $session, child => a_child() });
    occupy($session, 1);

    is finalize($payment), 10000, 'first pass owes the lost seat';

    # Clear the debt as a successful refund would, then deliver again.
    $db->query(q{UPDATE payments SET metadata = metadata - 'refund_owed_cents'
                  WHERE id = ?}, $payment->id);

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
    my $meta = $db->select('payments', ['metadata'], { id => $payment->id })
        ->expand->hash->{metadata};
    is $meta->{refund_owed_cents}, undef,
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
    my $full  = a_session(1);
    my $kid_a = a_child();
    my $payment = a_paid_cart({ session => $full, child => $kid_a });
    occupy($full, 1);

    finalize($payment);
    my $key_one = reload($payment)->capacity_refund_key;
    like $key_one, qr/\Q@{[ $kid_a->id ]}\E/, 'the key names the child it owes for';

    # A larger obligation -- a second child added to the same debt -- is a
    # different refund and must not replay the first refund's key.
    my %meta = %{ reload($payment)->metadata };
    $db->update('payments', {
        metadata => { -json => { %meta,
            refund_owed_cents    => 20000,
            refund_owed_children => [ $kid_a->id, a_child()->id ] } },
    }, { id => $payment->id });

    isnt reload($payment)->capacity_refund_key, $key_one,
        'a different set of owed children gets a different key';
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

    is reload($payment)->metadata->{refund_owed_cents}, 10000,
        'the debt survives a failed refund so the runbook can find it';
    is reload($payment)->status, 'refund_pending', 'and the row stays refund_pending';
};

done_testing;
