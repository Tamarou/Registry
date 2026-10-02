#!/usr/bin/env perl
# ABOUTME: Accepting a waitlist offer prices the seat and sends the parent to the normal checkout.
# ABOUTME: It used to write the enrolment itself and charge nothing, so every freed seat was given away.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';
use Test::Registry::DB;
use Test::Registry::Helpers qw( days_from_now );
use Registry::DAO::Workflow;
use Registry::DAO::Waitlist;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;
use Registry::DAO::PricingPlan;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::User;
use Mojo::Home;
use YAML::XS qw(Load);

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_offer_to_checkout';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# The real registration workflow, because the point is that acceptance hands the
# parent to it rather than to a second payment path.
for my $file ( Mojo::Home->new->child('workflows')->list_tree->grep(qr/\.ya?ml$/)->each ) {
    next if Load( $file->slurp )->{draft};
    Registry::DAO::Workflow->from_yaml( $dao, $file->slurp );
}

my $loc = $dao->create(Location => {
    name => 'Checkout Studio', slug => 'checkout-studio',
    address_info => {}, metadata => {} });
my $prog = $dao->create(Project => {
    status => 'published', name => 'Checkout Camp',
    program_type_slug => 'summer-camp', metadata => {} });
my $teacher = $dao->create(User => {
    username => 'co_teacher', name => 'T', user_type => 'staff',
    email => 'cot@test.local' });
my $parent = $dao->create(User => {
    username => 'co_parent', name => 'CO Parent', user_type => 'parent',
    email => 'co@test.local' });

my $seq = 0;
sub a_child () {
    $seq++;
    Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => "CO Kid $seq", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } });
}

sub a_session ( $cents ) {
    $seq++;
    my $s = $dao->create(Session => {
        name => "CO Week $seq", start_date => days_from_now(30),
        end_date => days_from_now(37), status => 'published',
        capacity => 5, metadata => {} });
    my $e = $dao->create(Event => {
        time => days_from_now(30) . sprintf(' %02d:00:00', 8 + ($seq % 12)),
        duration => 60, location_id => $loc->id, project_id => $prog->id,
        teacher_id => $teacher->id, capacity => 5, metadata => {} });
    $s->add_events($db, $e->id);
    Registry::DAO::PricingPlan->create($db, {
        session_id => $s->id, plan_name => "Plan $seq",
        amount_cents => $cents, currency => 'USD' });
    return $s;
}

sub an_offer ( $session, $child ) {
    my $entry = Registry::DAO::Waitlist->create($db, {
        session_id => $session->id, location_id => $loc->id,
        student_id => $child->id, parent_id => $parent->id,
        status => 'waiting' });
    $db->query(
        q{UPDATE waitlist SET status = 'offered', offered_at = NOW(),
                 expires_at = NOW() + INTERVAL '48 hours' WHERE id = ?},
        $entry->id );
    return Registry::DAO::Waitlist->find($db, { id => $entry->id });
}

subtest 'a priced seat goes to the registration checkout' => sub {
    my $session = a_session(5000);
    my $child   = a_child();
    my $offer   = an_offer( $session, $child );

    ok $offer->requires_payment($db), 'the offer is for a seat that costs money';

    my $checkout = $offer->checkout_run( $db, 'registry' );
    ok $checkout, 'acceptance produces a checkout to send the parent to';
    is $checkout->{workflow}, 'summer-camp-registration',
        'the registration workflow, not a second payment path';

    my $data = $checkout->{run}->data;
    is $data->{user_id}, $parent->id, 'the run belongs to the parent';
    is_deeply $data->{enrollment_items},
        [ { child_id => $child->id, session_id => $session->id } ],
        'with the offered seat as the whole cart';
    is_deeply $data->{session_selections}, { $child->id => $session->id },
        'and the selection the pricing walks';
    is $data->{children}[0]{id}, $child->id, 'the child is snapshotted for pricing';
    is_deeply $data->{accepted_offer_ids}, [ $offer->id ],
        'and the offer is named, so settlement can close it';

    # Nothing has been given away yet: the seat is still only promised, and the
    # enrolment is the settlement's job.
    my $after = Registry::DAO::Waitlist->find( $db, { id => $offer->id } );
    is $after->status, 'offered', 'the offer is still open, not accepted';
    is $db->query(
        'SELECT COUNT(*) FROM enrollments WHERE session_id = ? AND student_id = ?',
        $session->id, $child->id )->array->[0], 0,
        'and no enrolment exists before anybody has paid';
};

subtest 'a free seat is still just given, as it always was' => sub {
    my $session = a_session(0);
    my $child   = a_child();
    my $offer   = an_offer( $session, $child );

    ok !$offer->requires_payment($db), 'nothing to charge for';

    $offer->accept_offer($db);

    my $after = Registry::DAO::Waitlist->find( $db, { id => $offer->id } );
    is $after->status, 'accepted', 'the offer is accepted on the spot';
    ok $db->query(
        q{SELECT COUNT(*) FROM enrollments
           WHERE session_id = ? AND student_id = ? AND status IN ('active','pending')},
        $session->id, $child->id )->array->[0],
        'and the child is enrolled without a gateway';
};

subtest 'the offer closes when the settlement writes the seat' => sub {
    my $session = a_session(5000);
    my $child   = a_child();
    my $offer   = an_offer( $session, $child );

    my $checkout = $offer->checkout_run( $db, 'registry' );
    my $run      = $checkout->{run};

    # The cart the payment step would have built, settled the way the webhook
    # settles an abandoned tab -- metadata only, no run.
    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 5000, status => 'completed',
        metadata => {
            enrollment_items   => $run->data->{enrollment_items},
            accepted_offer_ids => $run->data->{accepted_offer_ids},
            tenant_slug        => undef,
        },
    } );
    $db->insert( 'payment_items', {
        payment_id => $payment->id, description => 'seat', amount_cents => 5000,
        metadata => { -json => { child_id => $child->id,
                                 session_id => $session->id } },
    } );
    $payment = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    my $tx = $db->begin;
    $payment->finalize_enrollment($db);
    $tx->commit;

    is $db->query(
        q{SELECT status FROM enrollments
           WHERE session_id = ? AND student_id = ? AND payment_id = ?},
        $session->id, $child->id, $payment->id )->array->[0], 'active',
        'the seat is written';

    is Registry::DAO::Waitlist->find( $db, { id => $offer->id } )->status,
        'accepted', 'and the offer is closed';
};

subtest 'an offer whose seat was lost at settlement stays open' => sub {
    # The capacity gate takes the seat away between acceptance and capture. The
    # offer must NOT read as accepted: this family never got the seat, and the
    # queue has to be able to offer them one again.
    my $session = a_session(5000);
    my $child   = a_child();
    my $offer   = an_offer( $session, $child );

    my $checkout = $offer->checkout_run( $db, 'registry' );

    # Fill it to capacity behind them.
    Registry::DAO::Enrollment->create( $db, {
        session_id => $session->id, family_member_id => a_child()->id,
        parent_id => $parent->id, status => 'active' } ) for 1 .. 5;

    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => 5000, status => 'completed',
        metadata => {
            enrollment_items   => $checkout->{run}->data->{enrollment_items},
            accepted_offer_ids => $checkout->{run}->data->{accepted_offer_ids},
            tenant_slug        => undef,
        },
    } );
    $db->insert( 'payment_items', {
        payment_id => $payment->id, description => 'seat', amount_cents => 5000,
        metadata => { -json => { child_id => $child->id,
                                 session_id => $session->id } },
    } );
    $payment = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    my $tx = $db->begin;
    my $owed = $payment->finalize_enrollment($db);
    $tx->commit;

    is $owed, 5000, 'the money is owed back';
    is Registry::DAO::Waitlist->find( $db, { id => $offer->id } )->status,
        'offered', 'and the offer is still open rather than falsely accepted';
};

done_testing;
