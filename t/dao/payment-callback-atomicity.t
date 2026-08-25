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
use Mojo::Pg;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_callback_atomicity';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
my $uri     = $test_db->uri;

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

subtest 'the settlement holds the payment row while it decides' => sub {
    # The lock tests elsewhere call Payment->find with { for => 'update' } from
    # the test itself, which proves Postgres honours FOR UPDATE and nothing
    # about whether production asks for it. Mutation testing showed both locks
    # could be deleted with the whole suite green. This probes from inside the
    # real settlement instead: if _lock_and_refresh is doing its job, a second
    # backend cannot take the row while finalize_enrollment runs.
    # Its own child: the shared one is already enrolled in this session by the
    # subtest above, and enrollments_session_student_type_unique would reject a
    # second row for the pair before the probe ever ran.
    my $probe_child = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'CB Lock Kid', birth_date => '2017-05-05', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id,
                                    child_id   => $probe_child->id } ],
            tenant_slug => undef },
    });
    my $run = run_for($payment);
    my ( $payment_locked, $session_locked );

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };

    # Probe at the seam -- immediately after each lock method returns, before
    # anything in the transaction has written the row it locked.
    #
    # Probing later (from inside finalize_enrollment, as an earlier version of
    # this test did) proves nothing: by then mark_completed's UPDATE has
    # row-locked the payment, and create_for_payment's INSERT has made the
    # enrollments_session_id_fkey FK take FOR KEY SHARE on the session, which
    # conflicts with FOR UPDATE. The probe reported "locked" whether or not the
    # explicit locks existed -- confirmed by deleting both and watching the test
    # stay green.
    my $held = sub ($sql, @bind) {
        my $other = Mojo::Pg->new($uri)->db;
        # NOWAIT turns "would block" into an immediate error, so a genuinely
        # held row cannot hang the suite.
        return !eval { $other->query( $sql, @bind ); 1 };
    };

    my $real_lock = \&Registry::DAO::Payment::_lock_and_refresh;
    local *Registry::DAO::Payment::_lock_and_refresh = sub ($self, $ldb) {
        my $out = $real_lock->( $self, $ldb );
        # //= because the method may be called more than once per settlement;
        # only the first observation is at the clean seam.
        $payment_locked //= $held->(
            'SELECT id FROM registry.payments WHERE id = ? FOR UPDATE NOWAIT',
            $payment->id );
        return $out;
    };

    my $real_sessions = \&Registry::DAO::Payment::_lock_cart_sessions;
    local *Registry::DAO::Payment::_lock_cart_sessions = sub ($self, $sdb, $items) {
        my $out = $real_sessions->( $self, $sdb, $items );
        $session_locked //= $held->(
            'SELECT id FROM registry.sessions WHERE id = ? FOR UPDATE NOWAIT',
            $session->id );
        return $out;
    };

    settle( $step->handle_payment_callback( $db, $run, {
        payment_intent_id => 'pi_cb_locked',
    } ) );

    ok $payment_locked,
        'the payment row is held by the settlement, not merely read';
    ok $session_locked,
        'and so is the session whose capacity it is about to decide on';
};

# The parent-return path's post-COMMIT refund loop was dead to the entire suite:
# a bare `die` at the top of it failed nothing, in any file. Every test that
# reaches handle_payment_callback builds a capacity 10-20 session, so no child
# is ever demoted, no debt is ever recorded, and the loop never runs. This is
# the ordinary-card path, not just 3DS.
subtest 'the parent-return path refunds each increment separately' => sub {
    # Its own child. enrollments_session_student_type_unique is payment-blind
    # (issue #315), and the shared $child is already enrolled in $session by an
    # earlier subtest, so reusing it makes finalize_enrollment raise for a
    # reason that has nothing to do with refunds.
    my $kid = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'CB Refund Kid', birth_date => '2018-02-02', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
    my $payment = Registry::DAO::Payment->create($db, {
        user_id => $parent->id, amount_cents => 10000, status => 'pending',
        metadata => {
            enrollment_items => [ { session_id => $session->id, child_id => $kid->id } ],
            tenant_slug      => undef },
    });
    my $run = run_for($payment);

    # A debt whose refund never settled, plus a second one -- two increments
    # with DIFFERENT amounts, because a fixture where they coincide cannot say
    # whether the code sent the increment or the balance.
    $payment->record_capacity_obligation( $db, 4000, ['kid-a'] );
    $payment->record_capacity_obligation( $db, 2500, ['kid-b'] );
    $db->update('payments',
        { stripe_payment_intent_id => 'pi_cb_refund_' . $payment->id },
        { id => $payment->id });

    my @refunds;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async =
        sub { Mojo::Promise->resolve( intent_for($payment) ) };
    local *Registry::Service::Stripe::create_refund_async = sub ($s, $p) {
        push @refunds, $p;
        Mojo::Promise->resolve({ id => 're_cb_' . scalar(@refunds), status => 'succeeded' });
    };

    settle( $step->handle_payment_callback( $db, $run, {
        payment_intent_id => 'pi_cb_refund',
    } ) );

    is scalar @refunds, 2, 'one Stripe call per unsettled increment';
    is_deeply [ sort { $a <=> $b } map { $_->{amount} } @refunds ], [ 2500, 4000 ],
        'each for its own amount, never the 6500 balance';

    my %keys = map { $_->{_idempotency_key} // '' => 1 } @refunds;
    is scalar( keys %keys ), 2, 'under distinct per-increment keys';

    my $done = Registry::DAO::Payment->find($db, { id => $payment->id });
    is $done->refund_owed_cents, 0, 'and the debt is discharged';
    is $done->refunded_cents, 6500,
        'with exactly what reached Stripe recorded as returned -- counted once, '
        . 'on the composed refund_async/_apply_refund_result/settle path';
};

done_testing;
