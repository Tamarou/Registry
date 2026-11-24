# ABOUTME: An approved drop refund actually moves money, and only then says it did.
# ABOUTME: ProcessDropRefund used to return refund_status 'pending' and touch nothing at all.
#
# #286. An admin could approve a refund, the parent was shown "pending", and no
# money ever left -- worse than not offering refunds. The money machinery was
# already there and proven (Payment->refund_async accumulates refunded_cents,
# re-checks capacity debt, refunds on the seller's account); what was missing was a
# caller.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Fixtures;
use Test::Registry::Async qw( settle );
use Registry::DAO;
use Registry::DAO::Family;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::ProcessDropRefund;
use Registry::Service::Stripe;
use Mojo::IOLoop;
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_drop_refund';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create( User => {
    username => 'dr_parent', name => 'DR Parent', user_type => 'parent',
    email => 'dr@test.local' } );

# A Connect-ready tenant, because the payment is a direct charge on the
# tenant's account: the refund is made there too, and the tenant -- not the
# platform -- bears it.
my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Refunding Studio', slug => 'refunding_studio' } );
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE id = ?',
    'acct_drop_refund', $tenant->id );
state_platform_terms( $db, 'refunding_studio', { rate => 0 } );

my $n = 0;
sub a_child () {
    $n++;
    return Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => "DR Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } } );
}

sub a_session () {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, {
        name => "DR Loc $n$$", slug => "dr_loc_$n$$", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "DR Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} } );
    my $teacher = $dao->create( User => {
        username => "dr_t_$n$$", name => 'DR T', user_type => 'staff',
        email => "dr_t_$n$$\@test.local" } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => 10, metadata => {} } );
    my $s = Registry::DAO::Session->create( $db, {
        name => "DR Session $n$$", status => 'published', capacity => 10, metadata => {} } );
    $s->add_events( $db, $event->id );
    return $s;
}

# A cart with two children, because that is the case the refund has to get
# right: one PaymentIntent covers both, so dropping one is a PARTIAL refund of
# a shared intent.
sub a_paid_cart () {
    my $session = a_session();
    my @kids    = ( a_child(), a_child() );
    my $each    = 5000;

    my $payment = Registry::DAO::Payment->create( $db, {
        user_id => $parent->id, amount_cents => $each * @kids,
        status => 'completed',
        metadata => {
            tenant_slug      => 'refunding_studio',
            enrollment_items =>
                [ map { { session_id => $session->id, child_id => $_->id } } @kids ] },
    } );
    $db->update( 'payments',
        { stripe_payment_intent_id => 'pi_drop_' . $payment->id, completed_at => \'NOW()' },
        { id => $payment->id } );

    my @enrollments = map {
        Registry::DAO::Enrollment->create( $db, {
            session_id => $session->id, student_id => $_->id,
            parent_id  => $parent->id,  payment_id => $payment->id,
            status     => 'active' } )
    } @kids;

    return ( Registry::DAO::Payment->find( $db, { id => $payment->id } ), @enrollments );
}

# The step under test, driven the way the workflow drives it.
my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Drop Refund Test', slug => "drop_refund_$$",
    description => 'drives ProcessDropRefund', first_step => 'process-refund' } );
my $step_row = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'process-refund',
    description => 'Process refund if requested',
    class => 'Registry::DAO::WorkflowSteps::ProcessDropRefund' } );

sub run_step ( %data ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, \%data );
    my $step = Registry::DAO::WorkflowSteps::ProcessDropRefund->new(
        id => $step_row->id, workflow_id => $workflow->id,
        slug => 'process-refund', description => 'Process refund if requested',
        class => 'Registry::DAO::WorkflowSteps::ProcessDropRefund' );
    return settle( $step->process( $db, {}, $run ) );
}

sub refund_status_of ($enrollment) {
    return $db->query( 'SELECT refund_status FROM enrollments WHERE id = ?',
        $enrollment->id )->hash->{refund_status};
}
sub refunded_cents_of ($payment) {
    return $db->query( 'SELECT refunded_cents FROM payments WHERE id = ?',
        $payment->id )->hash->{refunded_cents};
}

# Stubs the Stripe call and records what it was asked to do. Only the async
# method is replaced: refund_async's own guards must run for real.
sub capturing_stripe ( $calls, %opt ) {
    return sub ( $self, $params ) {
        push @$calls, { %$params, _account => $self->stripe_account };
        return Mojo::Promise->reject( $opt{fail} ) if $opt{fail};
        return Mojo::Promise->resolve( {
            id     => 'rf_' . scalar(@$calls),
            amount => $params->{amount},
            status => 'succeeded',
        } );
    };
}

subtest 'no refund requested moves no money and claims nothing' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    my $result = run_step(
        enrollment_id => $dropped->id, refund_requested => 0 );

    is scalar @calls, 0, 'Stripe was not called';
    is $result->{refund_processed}, 0, 'the step says no refund was processed';
    is refunded_cents_of($payment), 0, 'and nothing was refunded';
};

subtest 'an approved refund actually moves the money' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    my $result = run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is scalar @calls, 1, 'Stripe was asked for exactly one refund';
    is $calls[0]{amount}, 5000, 'for the approved amount, not the whole cart';
    is $calls[0]{payment_intent}, 'pi_drop_' . $payment->id, 'against the right intent';
    like $calls[0]{_idempotency_key}, qr/\Qrefund:drop:\E/,
        'under an idempotency key, so a retry cannot double-refund';

    is $result->{refund_processed}, 1, 'the step reports the refund processed';
    is refund_status_of($dropped), 'processed',
        'and the enrollment says processed -- the status that had no writer at all';
    is refunded_cents_of($payment), 5000, 'the payment records what went back';
};

subtest 'drop refund is made on the tenant account without reverse transfer' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is scalar @calls, 1, 'one refund request';
    is $calls[0]{_account}, 'acct_drop_refund', 'sent on the tenant account';
    ok !exists $calls[0]{reverse_transfer}, 'no transfer to reverse on a direct charge';
    ok !exists $calls[0]{refund_application_fee}, 'and the platform fee is kept';
};

subtest 'a refund with no amount refuses rather than refunding the whole cart' => sub {
    # refund_async defaults a missing amount to the FULL payment, and one intent
    # covers several children. Defaulting here would refund a sibling's seat.
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments', { refund_status => 'pending' }, { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    my $result = run_step( enrollment_id => $dropped->id, refund_requested => 1 );

    is scalar @calls, 0, 'no refund was attempted';
    is $result->{refund_processed}, 0, 'and the step says so';
    is refund_status_of($dropped), 'pending',
        'the obligation stays pending rather than being written off';
    is refunded_cents_of($payment), 0, 'the sibling seat is untouched';
};

subtest 'a refund Stripe refuses stays pending, never processed' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async =
        capturing_stripe( \@calls, fail => "card_declined\n" );

    my $result = run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is scalar @calls, 1, 'Stripe was asked';
    ok !$result->{refund_processed}, 'the step does not claim success';
    ok $result->{errors}, 'the failure is reported rather than swallowed';
    is refund_status_of($dropped), 'pending',
        'the enrollment still owes the money -- processed would be a lie';
};

# Driven through the run, not the bare step: whether the run advances is
# decided by WorkflowRun::_persist_step_result, and that is where a failed
# refund used to slip through to the waitlist and notification steps.
sub drive_run ( %data ) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, \%data );
    my $step = Registry::DAO::WorkflowSteps::ProcessDropRefund->new(
        id => $step_row->id, workflow_id => $workflow->id,
        slug => 'process-refund', description => 'Process refund if requested',
        class => 'Registry::DAO::WorkflowSteps::ProcessDropRefund' );
    my $result = settle( $run->process( $db, $step, {} ) );
    my $latest = $db->query( 'SELECT latest_step_id FROM workflow_runs WHERE id = ?',
        $run->id )->hash->{latest_step_id};
    return ( $result, $latest );
}

sub last_refund_failure_of ($payment) {
    return $db->query( q{SELECT metadata->'refund_last_failure' AS f
                           FROM payments WHERE id = ?}, $payment->id )->expand->hash->{f};
}

subtest 'a drop refund Stripe refuses stops the run on the refund step and is recorded' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async =
        capturing_stripe( \@calls, fail => "card_declined\n" );

    my ( $result, $latest ) = drive_run( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is scalar @calls, 1, 'Stripe was asked';
    ok !defined $latest || $latest ne $step_row->id,
        'the run did not advance past the refund step';
    like( ( $result->{errors} // [] )->[0] // '', qr/refund/i,
        'the admin is shown why' ) or diag explain $result;
    is( ( last_refund_failure_of($payment) // {} )->{classification}, 'unknown',
        'the runbook has a record, classified as unknown' );
    is refund_status_of($dropped), 'pending', 'the enrollment still owes the money';
};

subtest 'a drop refund refused before sending stops the run on the refund step and is recorded' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    # Past the 10000 captured: refund_async refuses this synchronously.
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 10001 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    my ( $result, $latest ) = eval { drive_run( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 10001 ) };
    is $@, '', 'the guard does not escape as a 500';

    is scalar @calls, 0, 'nothing reached Stripe';
    ok !defined $latest || $latest ne $step_row->id,
        'the run did not advance past the refund step';
    like( ( $result->{errors} // [] )->[0] // '', qr/REFUND_NOT_SENT/,
        'the admin is shown why' ) or diag explain $result;
    is( ( last_refund_failure_of($payment) // {} )->{classification}, 'not_sent',
        'the runbook has a record, classified as not sent' );
    is refund_status_of($dropped), 'pending', 'the enrollment still owes the money';
};

# `error` (singular) is not a stop signal to _persist_step_result, so these two
# used to advance the run to the waitlist and notifications with the refund
# still owed and nothing on the admin's screen.
subtest 'a drop refund with no approved amount stops the run on the refund step' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments', { refund_status => 'pending' }, { id => $dropped->id } );

    my ( $result, $latest ) = drive_run( enrollment_id => $dropped->id, refund_requested => 1 );

    ok !defined $latest || $latest ne $step_row->id,
        'the run did not advance past the refund step';
    like( ( $result->{errors} // [] )->[0] // '', qr/no refund amount/,
        'the admin is shown why' ) or diag explain $result;
    is refund_status_of($dropped), 'pending', 'the enrollment still owes the money';
};

subtest 'a drop refund for an enrollment with no payment stops the run on the refund step' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000, payment_id => undef },
        { id => $dropped->id } );

    my ( $result, $latest ) = drive_run( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    ok !defined $latest || $latest ne $step_row->id,
        'the run did not advance past the refund step';
    like( ( $result->{errors} // [] )->[0] // '', qr/no payment/,
        'the admin is shown why' ) or diag explain $result;
    is refund_status_of($dropped), 'pending', 'the enrollment still owes the money';
};

# The runbook reads refund_last_failure first; once a retry has paid, a record
# left behind tells the operator money is still owed when it is not.
subtest 'a drop refund that succeeds on retry clears the recorded failure' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );
    my %drop = ( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    no warnings 'redefine';
    {
        local *Registry::Service::Stripe::create_refund_async =
            capturing_stripe( [], fail => "card_declined\n" );
        drive_run(%drop);
    }
    ok last_refund_failure_of($payment), 'the failed attempt is recorded';

    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( [] );
    drive_run(%drop);

    is refund_status_of($dropped), 'processed', 'the retry paid';
    is last_refund_failure_of($payment), undef, 'and the failure record is gone';
};

subtest 'a pending refund leaves the recorded failure in place' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $payment->record_refund_failure( $db, "card_declined\n" );

    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ( $self, $params ) {
        Mojo::Promise->resolve( { id => 'rf_pending', amount => $params->{amount},
            status => 'pending' } );
    };
    run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    ok last_refund_failure_of($payment),
        'a refund that may still fail does not clear the record';
};

# Stripe answers some refunds 'pending': the money has not moved and may not.
# 'processed' is the parent's receipt, so it waits for refund.updated to settle
# the refund; the drop itself carries on.
subtest 'a pending drop refund waits instead of reading processed' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ( $self, $params ) {
        Mojo::Promise->resolve( { id => 'rf_drop_waits', amount => $params->{amount},
            status => 'pending' } );
    };
    my $result = run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is refund_status_of($dropped), 'pending', 'the enrollment still says pending';
    is $result->{refund_processed}, 0, 'the step does not report the refund processed';
    is $result->{refund_status}, 'pending', 'it reports it pending';
    is $result->{errors}, undef, 'and the drop carries on';
    is refunded_cents_of($payment), 0, 'nothing is counted as returned yet';
};

subtest 'a refund already processed is not refunded again' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );
    is scalar @calls, 1, 'the first run refunds';

    # The workflow can be re-driven, and Minion-free retries are a person
    # pressing a button twice. The idempotency key is the backstop; this is the
    # guard that means Stripe is not even asked.
    my $again = run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );
    is scalar @calls, 1, 'the second run does not ask Stripe again';
    is $again->{refund_processed}, 1, 'and still reports the refund as done';
    is refunded_cents_of($payment), 5000, 'the money went back exactly once';
};

# Stripe paid and the payment recorded it, but the step died before writing
# 'processed' (ProcessDropRefund's enrollment->update). The payment now reads
# partially_refunded, so refund_async's guards refuse the retry with
# REFUND_NOT_SENT and the drop would stay pending for good.
subtest 'a drop refund retried after a partial failure reaches processed without a second refund' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ( $self, $params ) {
        push @calls, $params;
        # Stripe replays the refund it already made for a key it has seen.
        return Mojo::Promise->resolve( {
            id => "rf_$params->{_idempotency_key}", amount => $params->{amount},
            status => 'succeeded' } );
    };

    # The first attempt, up to the point where the step failed: the money moved
    # and the payment recorded it, the enrollment did not.
    settle( $payment->refund_async( $db, {
        amount_cents    => 5000,
        reason          => 'requested_by_customer',
        idempotency_key => $payment->drop_refund_key( $dropped->id ),
    } ) );
    is refunded_cents_of($payment), 5000, 'the dropped seat is back with the parent';
    is refund_status_of($dropped), 'pending', 'but the enrollment never heard';

    my $retry = run_step( enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is $retry->{refund_processed}, 1, 'the retry finishes' or diag explain $retry;
    is refund_status_of($dropped), 'processed', 'and the enrollment says processed';
    is scalar @calls, 1, 'without a second refund at Stripe';
    is refunded_cents_of($payment), 5000, 'and the money is counted once';
};

# One partial refund leaves the payment partially_refunded; ruling 8a expects
# further refunds of what remains, so a second drop from the same cart must
# still be refunded for its own share.
subtest 'a second drop from the same cart is refunded after a first partial refund' => sub {
    my ( $payment, $first, $second ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => [ $first->id, $second->id ] } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    run_step( enrollment_id => $first->id,
        refund_requested => 1, refund_amount_cents => 5000 );
    is $db->select( payments => ['status'], { id => $payment->id } )->hash->{status},
        'partially_refunded', 'the first drop leaves the payment partially refunded';

    my $result = run_step( enrollment_id => $second->id,
        refund_requested => 1, refund_amount_cents => 5000 );

    is $result->{refund_processed}, 1, 'the second drop is refunded' or diag explain $result;
    is scalar @calls, 2, 'Stripe was asked once per drop';
    is $calls[1]{amount}, 5000, 'for the second child\'s own share';
    is refund_status_of($second), 'processed', 'the second enrollment says processed';
    is refunded_cents_of($payment), 10000, 'both shares are counted';
    is $db->select( payments => ['status'], { id => $payment->id } )->hash->{status},
        'refunded', 'and the payment now reads fully refunded';
};

subtest 'a refund past what remains on a partially refunded payment is refused' => sub {
    my ( $payment ) = a_paid_cart();
    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    settle( $payment->refund_async( $db, { amount_cents => 5000 } ) );
    is $payment->status, 'partially_refunded', 'one seat is back';

    my $error;
    eval { settle( $payment->refund_async( $db, { amount_cents => 5001 } ) ); 1 }
        or $error = $@;
    like $error, qr/REFUND_NOT_SENT: Refund of 5001 cents .* past its 10000 captured cents/,
        'the past-captured guard refuses it';
    is scalar @calls, 1, 'before anything reaches Stripe';
    is refunded_cents_of($payment), 5000, 'and nothing more is counted';
};

# Capacity debt is money already owed back on this payment. A keyed drop
# refund that ignored it could take returned + owed past what was captured,
# and Stripe would refuse the excess only after the request went out.
subtest 'the refund cap counts capacity debt still owed' => sub {
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'payments', { status => 'refund_pending', refund_owed_cents => 5000 },
        { id => $payment->id } );
    $payment = Registry::DAO::Payment->find( $db, { id => $payment->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    my $error;
    eval { settle( $payment->refund_async( $db, {
        amount_cents    => 5001,
        idempotency_key => $payment->drop_refund_key( $dropped->id ),
    } ) ); 1 } or $error = $@;
    like $error, qr/REFUND_NOT_SENT: Refund of 5001 cents .* past its 10000 captured cents/,
        'owed plus the refund past captured is refused';
    is scalar @calls, 0, 'before anything reaches Stripe';
};

subtest 'a fully refunded payment is still refused' => sub {
    my ( $payment ) = a_paid_cart();
    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );

    settle( $payment->refund_async( $db, {} ) );
    is $payment->status, 'refunded', 'the whole cart is back';

    my $error;
    eval { settle( $payment->refund_async( $db, { amount_cents => 1 } ) ); 1 }
        or $error = $@;
    like $error, qr/REFUND_NOT_SENT: Cannot refund a payment with status 'refunded'/,
        'the status guard refuses it';
    is scalar @calls, 1, 'before anything reaches Stripe';
};

subtest 'the refund settles inside a running IOLoop' => sub {
    # The workflow runs in a web request, so the step has to defer rather than
    # block. See #284: a blocking Stripe call there can never settle.
    my ( $payment, $dropped ) = a_paid_cart();
    $db->update( 'enrollments',
        { refund_status => 'pending', refund_amount_cents => 5000 },
        { id => $dropped->id } );

    my @calls;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_refund_async = sub ( $self, $params ) {
        push @calls, $params;
        my $p = Mojo::Promise->new;
        Mojo::IOLoop->next_tick( sub {
            $p->resolve( { id => 'rf_loop', amount => $params->{amount},
                           status => 'succeeded' } );
        } );
        return $p;
    };

    my $run = $workflow->new_run($db);
    $run->update_data( $db, { enrollment_id => $dropped->id,
        refund_requested => 1, refund_amount_cents => 5000 } );
    my $step = Registry::DAO::WorkflowSteps::ProcessDropRefund->new(
        id => $step_row->id, workflow_id => $workflow->id,
        slug => 'process-refund', description => 'Process refund if requested',
        class => 'Registry::DAO::WorkflowSteps::ProcessDropRefund' );

    my ( $result, $error );
    Mojo::IOLoop->next_tick( sub {
        my $p = eval { $step->process( $db, {}, $run ) };
        if ($@) { $error = $@; Mojo::IOLoop->stop; return }
        unless ( ref $p && $p isa Mojo::Promise ) {
            $error = 'the step did not defer; it returned a plain value';
            Mojo::IOLoop->stop;
            return;
        }
        $p->then( sub { $result = shift } )->catch( sub { $error = shift } )
          ->finally( sub { Mojo::IOLoop->stop } );
    } );
    my $guard = Mojo::IOLoop->timer( 10 => sub {
        $error //= 'timed out waiting for the refund to settle';
        Mojo::IOLoop->stop;
    } );
    Mojo::IOLoop->start;
    Mojo::IOLoop->remove($guard);

    is $error, undef, 'no blocking call was made in the running loop'
        or diag "failed with: $error";
    is $result->{refund_processed}, 1, 'the refund went through';
    is refund_status_of($dropped), 'processed', 'and is recorded';
};

done_testing;
