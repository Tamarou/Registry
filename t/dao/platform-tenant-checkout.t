#!/usr/bin/env perl
# ABOUTME: The shared payment step treats the platform tenant (slug registry) as a seller like any other.
# ABOUTME: Ready, it is not refused; not ready, it is; a seller slug naming no tenant is refused and records nothing.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( state_platform_terms );
use Registry::DAO;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Session;
use Registry::DAO::PricingPlan;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::WorkflowSteps::Payment;
use Test::Registry::Async qw( settle );
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;    # the registry schema: the platform tenant's own
state_platform_terms( $db, 'registry', { rate => 0 } );

my $location = Registry::DAO::Location->create( $db, { time_zone => 'America/New_York',
    name         => 'Platform Checkout Location',
    address_info => { street_address => '1 Platform St', city => 'T', state => 'TS', postal_code => '12345' },
    metadata     => {},
} );
my $teacher = Registry::DAO::User->create( $db, {
    name => 'Platform Teacher', username => "plat_teacher_$$",
    email => "plat_teacher_$$\@test.com", user_type => 'staff',
} );
my $project = Registry::DAO::Project->create( $db, { name => 'Platform Checkout Project', metadata => {} } );
my $event   = Registry::DAO::Event->create( $db, {
    time => '2024-07-01 10:00:00', duration => 120, location_id => $location->id,
    project_id => $project->id, teacher_id => $teacher->id, metadata => {}, capacity => 20,
} );
my $session = Registry::DAO::Session->create( $db, {
    name => 'Platform Paid Session', start_date => '2024-07-02', end_date => '2024-07-09',
    status => 'published', metadata => {},
} );
$session->add_events( $db, $event->id );
Registry::DAO::PricingPlan->create( $db, {
    session_id => $session->id, plan_name => 'Standard', plan_type => 'standard', amount_cents => 15000,
} );

my $workflow = Registry::DAO::Workflow->create( $db, {
    name => 'Platform Checkout Workflow', slug => "platform-checkout-$$", description => 'Platform checkout',
} );
my $payment_row = Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'payment',
    class => 'Registry::DAO::WorkflowSteps::Payment', description => 'Payment',
} );
Registry::DAO::WorkflowStep->create( $db, {
    workflow_id => $workflow->id, slug => 'complete', class => 'Registry::DAO::WorkflowStep',
    description => 'Complete', depends_on => $payment_row->id,
} );
$workflow->update( $db, { first_step => 'payment' }, { id => $workflow->id } );

my $parent = Registry::DAO::User->create( $db, {
    email => "plat_parent_$$\@example.com", username => "plat_parent_$$",
    name => 'Platform Parent', user_type => 'parent',
} );
my $child = Registry::DAO::Family->add_child( $db, $parent->id, {
    child_name => 'Platform Child', birth_date => '2016-03-15', grade => '3',
    medical_info => {}, emergency_contact => { name => 'Emergency', phone => '555-0123' },
} );

sub paid_run ($seller) {
    my $run = $workflow->new_run($db);
    $run->update_data( $db, {
        user_id  => $parent->id,
        children => [ { id => $child->id, first_name => 'Platform', last_name => 'Child',
                        birth_date => '2016-03-15', grade => '3' } ],
        session_selections => { $child->id => $session->id },
        enrollment_items   => [ { child_id => $child->id, session_id => $session->id } ],
        __tenant_slug      => $seller,
    } );
    return $run;
}

sub set_platform_ready ($ready) {
    $db->query(
        'UPDATE registry.tenants SET stripe_connect_account_id = ?, stripe_charges_enabled = ?, stripe_details_submitted = ? WHERE slug = ?',
        $ready ? 'acct_platform_checkout' : undef, $ready ? 1 : 0, $ready ? 1 : 0, 'registry' );
}

sub payment_count { $db->select( 'payments', ['id'], { user_id => $parent->id } )->hashes->size }

# Runs the step with Stripe's intent call replaced, as payment-step-readiness-gate.t
# does: these tests are about the gate, and the container cannot reach Stripe.
sub checkout ($seller) {
    local $ENV{STRIPE_SECRET_KEY} = 'sk_test_dummy';
    my $intent_called = 0;
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent_async = sub {
        $intent_called++;
        return Mojo::Promise->resolve( { id => "pi_plat_$intent_called", client_secret => 'cs_plat' } );
    };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_ };
    my $step   = $workflow->get_step( $db, { slug => 'payment' } );
    my $result = settle( $step->process( $db, { agreeTerms => 1 }, paid_run($seller) ) );
    return ( $result, $intent_called, \@warnings );
}

my $refusal = Registry::DAO::WorkflowSteps::Payment->payment_unavailable_message;

subtest 'a ready platform tenant is not refused at payment' => sub {
    set_platform_ready(1);
    my ( $result, $intent_called ) = checkout('registry');

    ok !grep( { $_ eq $refusal } @{ $result->{errors} // [] } ), 'not refused as unready'
        or diag explain $result->{errors};
    ok $intent_called, 'the step went on to create a payment intent';
};

subtest 'a platform tenant that is not ready is refused at payment' => sub {
    set_platform_ready(0);
    my $before = payment_count();
    my ( $result, $intent_called, $warnings ) = checkout('registry');

    is_deeply $result->{errors}, [$refusal], 'refused with the step\'s own message';
    like "@$warnings", qr/checkout refused: tenant 'registry'/, 'the refusal is logged';
    ok !$intent_called, 'no payment intent was asked for';
    is payment_count(), $before, 'no payment row was created';
};

subtest 'a seller slug that resolves to no tenant is refused at payment' => sub {
    set_platform_ready(1);
    my $before = payment_count();
    my ( $result, $intent_called, $warnings ) = checkout('no_such_seller');

    is_deeply $result->{errors}, [$refusal], 'refused, rather than charged on some default account';
    like "@$warnings", qr/checkout refused: tenant 'no_such_seller'/, 'the refusal is logged';
    ok !$intent_called, 'no payment intent was asked for';
    is payment_count(), $before, 'no payment row was created';
};

done_testing;
