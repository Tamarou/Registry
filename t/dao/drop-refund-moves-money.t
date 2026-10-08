# ABOUTME: An approved drop refund actually moves money, and only then says it did.
# ABOUTME: ProcessDropRefund used to return refund_status 'pending' and touch nothing at all.
#
# #286. An admin could approve a refund, the parent was shown "pending", and no
# money ever left -- worse than not offering refunds. The money machinery was
# already there and proven (Payment->refund_async accumulates refunded_cents,
# re-checks capacity debt, sends reverse_transfer); what was missing was a
# caller.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
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

# A Connect-ready tenant, because the refund has to reverse the transfer: the
# platform took an application fee on the way in, and the tenant -- not the
# platform -- bears the refund. Without a tenant_slug and a connect account
# _refund_connect_params returns nothing, and the assertion below would pass
# against an empty hash.
my $tenant = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Refunding Studio', slug => 'refunding_studio' } );
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE id = ?',
    'acct_drop_refund', $tenant->id );

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
        push @$calls, $params;
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
    is $calls[0]{reverse_transfer}, 'true',
        'reversing the transfer, so the tenant bears it rather than the platform';
    like $calls[0]{_idempotency_key}, qr/\Qrefund:drop:\E/,
        'under an idempotency key, so a retry cannot double-refund';

    is $result->{refund_processed}, 1, 'the step reports the refund processed';
    is refund_status_of($dropped), 'processed',
        'and the enrollment says processed -- the status that had no writer at all';
    is refunded_cents_of($payment), 5000, 'the payment records what went back';
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
    is $result->{refund_processed}, 0, 'the step does not claim success';
    ok $result->{error}, 'the failure is reported rather than swallowed';
    is refund_status_of($dropped), 'pending',
        'the enrollment still owes the money -- processed would be a lie';
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
