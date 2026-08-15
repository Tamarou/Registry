#!/usr/bin/env perl
# ABOUTME: The parent-return callback settles a payment in one transaction.
# ABOUTME: A failure after the completed-write must not leave a paid row with no enrollment.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::Payment;
use Registry::DAO::Payment;
use Registry::DAO::Family;
use Registry::Service::Stripe;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_callback_atomicity';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# --- fixtures: a real payment row, because _apply_intent genuinely writes to it
my $loc = $dao->create(Location => {
    name => 'CB Studio', slug => 'cb-studio', address_info => {}, metadata => {},
});
my $prog = $dao->create(Project => {
    status => 'published', name => 'CB Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => {
    username => 'cb_teacher', name => 'T', user_type => 'staff',
    email => 'cbt@test.local',
});
my $session = $dao->create(Session => {
    name => 'CB Week', start_date => '2026-01-01', end_date => '2026-12-31',
    status => 'published', capacity => 10, metadata => {},
});
my $event = $dao->create(Event => {
    time => '2026-06-15 09:00:00', duration => 60, location_id => $loc->id,
    project_id => $prog->id, teacher_id => $teacher->id, capacity => 10, metadata => {},
});
$session->add_events($db, $event->id);

my $parent = $dao->create(User => {
    username => 'cb_parent', name => 'CB Parent', user_type => 'parent',
    email => 'cb@test.local',
});
my $child = Registry::DAO::Family->add_child($db, $parent->id, {
    child_name => 'CB Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
});

my $workflow = Registry::DAO::Workflow->create($db, {
    name => 'CB Flow', slug => 'cb_flow', description => 'minimal',
    first_step => 'payment',
});
$workflow->add_step($db, {
    slug => 'payment', description => 'Payment',
    class => 'Registry::DAO::WorkflowSteps::Payment',
});
my $step = Registry::DAO::WorkflowStep->find($db, {
    workflow_id => $workflow->id, slug => 'payment',
});

sub fresh_payment () {
    return Registry::DAO::Payment->create($db, {
        user_id => $parent->id,
        amount_cents => 10000,
        status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $child->id } ],
            tenant_slug      => undef,
        },
    });
}

sub run_for ($payment) {
    my $run = $workflow->new_run($db);
    $run->update_data($db, { user_id => $parent->id, payment_id => $payment->id });
    return $run;
}

sub enrollments_for ($payment) {
    scalar @{ $db->select('enrollments', '*', { payment_id => $payment->id })->hashes };
}

sub status_of ($payment) {
    Registry::DAO::Payment->find($db, { id => $payment->id })->status;
}

# The real _apply_intent runs against this: only the network call is faked, so
# the completed-write and the enrollment are both genuine database work.
sub intent_for ($payment) {
    return {
        id             => 'pi_cb_' . $payment->id,
        status         => 'succeeded',
        amount         => 10000,
        payment_method => 'pm_cb_test',
        # _apply_intent only honours an intent that belongs to this row: either
        # the id stored at creation, or one stamped with our payment_id. These
        # rows have no stored intent id, so the metadata stamp is what makes the
        # ownership check pass -- without it the settlement is refused before it
        # writes anything, and the test grades nothing.
        metadata       => { payment_id => $payment->id },
    };
}

subtest 'a failure after the completed-write rolls the whole settlement back' => sub {
    my $payment = fresh_payment();
    my $run     = run_for($payment);

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };
    # Fails after _apply_intent has written 'completed' and before any
    # enrollment exists -- the window this task closes.
    local *Registry::DAO::Payment::finalize_enrollment =
        sub { die "probe: finalization failed after the completed-write\n" };

    my $died = 0;
    eval { settle( $step->handle_payment_callback( $db, $run, {
        payment_intent_id => 'pi_cb_probe',
    } ) ); 1 } or $died = 1;

    ok $died, 'the callback surfaces the failure rather than swallowing it';
    is status_of($payment), 'pending',
        'the completed-write is rolled back with the enrollment that failed';
    is enrollments_for($payment), 0, 'no enrollment survives the failure';
};

subtest 'a clean settlement still completes and enrolls' => sub {
    my $payment = fresh_payment();
    my $run     = run_for($payment);

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };

    my $result = settle( $step->handle_payment_callback( $db, $run, {
        payment_intent_id => 'pi_cb_ok',
    } ) );

    is $result->{next_step}, 'complete', 'the run advances to completion';
    is status_of($payment), 'completed', 'payment is completed';
    is enrollments_for($payment), 1, 'exactly one enrollment created';
};

done_testing;
