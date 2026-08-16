#!/usr/bin/env perl
# ABOUTME: A partly-fitting sibling group fills the seats that exist instead of refunding whole.
# ABOUTME: And an unpriced child cannot take a captured settlement down with them.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Payment;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_partial_fit';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $loc = $dao->create(Location => {
    name => 'PF Studio', slug => 'pf-studio', address_info => {}, metadata => {} });
my $prog = $dao->create(Project => {
    status => 'published', name => 'PF Camp',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => {
    username => 'pf_teacher', name => 'T', user_type => 'staff',
    email => 'pft@test.local' });
my $parent = $dao->create(User => {
    username => 'pf_parent', name => 'PF Parent', user_type => 'parent',
    email => 'pf@test.local' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "PF Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}
sub a_session ($capacity) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "PF Week $seq", start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => $capacity, metadata => {} });
    my $e = $dao->create(Event => {
        time => sprintf('2026-06-15 %02d:%02d:00', $seq % 24, $seq % 60),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => $capacity, metadata => {} });
    $s->add_events($db, $e->id);
    return $s;
}
sub occupy ($session, $n) {
    Registry::DAO::Enrollment->create($db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' }) for 1 .. $n;
}

# $priced controls whether each child gets a payment_items row. An unpriced
# child is not hypothetical: calculate_enrollment_total skips any child whose
# plan returns no price, so they ride along in enrollment_items with no line
# item behind them.
sub a_cart ($session, $children, $priced = 1) {
    my $p = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000 * scalar @$children,
        status => 'completed',
        metadata => {
            enrollment_items => [ map { { session_id => $session->id, child_id => $_->id } }
                                  @$children ],
            tenant_slug => undef } });
    $db->update('payments', { stripe_payment_intent_id => 'pi_pf_' . $p->id },
        { id => $p->id });
    if ($priced) {
        for my $c (@$children) {
            $db->insert('payment_items', {
                payment_id => $p->id, description => 'seat', amount_cents => 10000,
                metadata => { -json => { child_id => $c->id, session_id => $session->id } } });
        }
    }
    return Registry::DAO::Payment->find($db, { id => $p->id });
}

sub finalize ($payment) {
    my $tx   = $db->begin;
    my $owed = eval { $payment->finalize_enrollment($db) };
    my $err  = $@;
    $err ? $tx->rollback : $tx->commit;
    return ( $owed, $err );
}

sub statuses_for ($payment) {
    my %n;
    $n{ $_->{status} }++
        for @{ $db->select('enrollments', ['status'], { payment_id => $payment->id })->hashes };
    return \%n;
}

subtest 'two siblings into one free seat fill it, rather than both losing it' => sub {
    # Capacity 10, nine taken, two siblings arriving together. The gate must
    # stop the pair overselling -- but refunding both leaves a seat that
    # existed unsold and returns money for a place the family could have had.
    my $session = a_session(10);
    occupy($session, 9);
    my @kids = ( a_child(), a_child() );
    my $payment = a_cart($session, \@kids);

    my ($owed, $err) = finalize($payment);
    is $err, '', 'the settlement completes';

    my $seats = statuses_for($payment);
    is $seats->{active},     1, 'one sibling takes the remaining seat';
    is $seats->{waitlisted}, 1, 'the other is waitlisted';
    is $owed, 10000, 'and only the waitlisted child is refunded';

    my $filled = $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND status IN ('active','pending')},
        $session->id)->array->[0];
    is $filled, 10, 'the session ends up full, not one short';
};

subtest 'a sibling group that cannot fit at all is refunded whole' => sub {
    my $session = a_session(10);
    occupy($session, 10);
    my @kids = ( a_child(), a_child() );
    my $payment = a_cart($session, \@kids);

    my ($owed) = finalize($payment);
    is statuses_for($payment)->{waitlisted}, 2, 'both are waitlisted';
    is $owed, 20000, 'and both shares are owed';
};

subtest 'an unpriced child does not take the settlement down with them' => sub {
    # refund_share_for refuses when no line item matches, which is right -- a
    # silent fallback to the cart total refunds every sibling. But raising
    # inside the settlement transaction rolls back the paying sibling's
    # enrollment too, and every Stripe retry reproduces it identically: money
    # captured, nobody enrolled, nothing refunded, forever.
    my $session = a_session(1);
    occupy($session, 1);
    my $kid = a_child();
    my $payment = a_cart($session, [$kid], 0);   # no line items

    my ($owed, $err) = finalize($payment);
    is $err, '', 'the settlement does not die';
    is statuses_for($payment)->{waitlisted}, 1, 'the child is still waitlisted';

    my $meta = $db->select('payments', ['metadata'], { id => $payment->id })
        ->expand->hash->{metadata};
    ok $meta->{refund_manual_review},
        'and the unresolvable share is flagged for a human instead';
};

done_testing;
