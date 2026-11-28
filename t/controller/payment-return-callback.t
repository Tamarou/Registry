#!/usr/bin/env perl
# ABOUTME: Stripe returns the browser from confirmPayment with a GET, so the GET handler
# ABOUTME: must settle the session cart's charge and move on instead of re-rendering the card form.
use 5.42.0;
use warnings;
use utf8;
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows days_from_now );
use Test::Registry::PricingProbe qw( state_platform_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Registry::DAO::Entitlement;
use Registry::DAO::FamilyMember;
use Test::Registry::Async;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::Service::Stripe;
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $seller = Test::Registry::Fixtures::platform_seller($db);
$db->query( q{UPDATE registry.tenants SET stripe_charges_enabled = TRUE, stripe_details_submitted = TRUE
               WHERE slug = ?}, $seller );
state_platform_terms( $db, $seller, { rate => 0 } );
local $ENV{STRIPE_SECRET_KEY} = 'sk_test_placeholder_not_real';

my $t = Test::Registry::Mojo->new('Registry');
# Do not follow redirects: the response itself is the evidence that the run
# advanced past payment rather than re-rendering the card form.
$t->ua->max_redirects(0);

# The parent the runs belong to: a run answers only to its own user.
my $parent = Test::Registry::Fixtures::create_user( $dao, { username => 'return_parent', name => 'Return Parent',
    email => 'return_parent@example.com', user_type => 'parent' } );
authenticate_as( $t, $parent );
my $kids = 0;

# A cart whose charge was started, as it is when the parent is sent to Stripe:
# the run, and the payment holding the intent Registry created.
sub run_awaiting_payment () {
    my $kid = Registry::DAO::FamilyMember->create( $db, {
        family_id => $parent->id, child_name => 'Kid ' . ++$kids, birth_date => '2016-01-01' } );
    my $s = make_session( $db, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my ( $run, $pay ) = held_cart( $dao, $parent->id,
        [ $kid->id, $s->id, session_offer( $db, $s, price_cents => 10000 )->id, 'pay' ] );
    my $payment = $pay->owed_payment( $db, $run )->{payment};
    $payment->_record_intent( $db, { id => "pi_returned_$kids", client_secret => 's' } );
    return ( $run, $payment );
}

my $retrieved = 0;
sub succeeded ($payment) {
    sub ( $s, $id ) {
        $retrieved++;
        Mojo::Promise->resolve( { id => $id, status => 'succeeded', amount => 10000,
            payment_method => 'pm_card', metadata => { payment_id => $payment->id } } );
    };
}

sub step_of ($run) { Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->latest_step($db)->slug }

subtest 'Stripe return GET completes the run instead of re-rendering payment' => sub {
    my ( $run, $payment ) = run_awaiting_payment();
    my $intent = $payment->stripe_payment_intent_id;

    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = succeeded($payment);

    # Stripe's own redirect params, appended to return_url; a plain GET.
    $t->get_ok( "/session-checkout/@{[ $run->id ]}/payment?payment_intent=$intent"
            . "&payment_intent_client_secret=${intent}_secret&redirect_status=succeeded" )
      ->content_unlike( qr/Due today/, 'the payment page is not shown again' );

    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->status, 'completed',
        'the returned intent settled the charge';
    # Past payment, the controller completes the checkout at once: it has
    # nothing to ask until the cart is booked.
    is step_of($run), 'complete', 'and the run moved past its payment and booked the cart';
    is Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->next_step($db)->slug, 'done',
        'leaving the done page to show';
};

subtest 'an ordinary GET with no Stripe params still renders the form' => sub {
    my ($run) = run_awaiting_payment();
    $t->get_ok("/session-checkout/@{[ $run->id ]}/payment")->status_is(200)
      ->content_like( qr/Due today/, 'the payment page' );
};

subtest 'the Stripe params alone do not advance a non-payment step' => sub {
    # The dispatch is keyed on the step handling payment callbacks, not on the
    # query string. Otherwise any step URL could be advanced by appending
    # ?payment_intent=... to a GET.
    my ( $run, $payment ) = run_awaiting_payment();
    $retrieved = 0;
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = succeeded($payment);

    $t->get_ok( "/session-checkout/@{[ $run->id ]}/hold?payment_intent=pi_forged&redirect_status=succeeded" )
      ->status_is(200);
    is $retrieved, 0, 'no intent is looked up';
    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->status, 'pending', 'nothing is settled';
    is step_of($run), 'hold', 'and the run stays where it was';
};

# Two children in a two-seat session; the second's hold lapsed while the parent
# paid and another family took the seat. The return settles the charge, and the
# controller completes the checkout: Kid is booked, Sib's line is refunded.
subtest 'a line refund that fails on the return is driven again until it is made' => sub {
    my ( $kid, $sib ) = map { Registry::DAO::FamilyMember->create( $db, {
        family_id => $parent->id, child_name => "$_ $$", birth_date => '2016-01-01' } ) } qw( Kid Sib );
    my $s = make_session( $db, capacity => 2, days => [ map { days_from_now($_) } 30 .. 32 ] );
    my $v = session_offer( $db, $s, price_cents => 10000 );
    my ( $run, $pay ) = held_cart( $dao, $parent->id, map { [ $_->id, $s->id, $v->id, 'pay' ] } $kid, $sib );
    my $payment = $pay->owed_payment( $db, $run )->{payment};
    $payment->_record_intent( $db, { id => "pi_returned_lost_$$", client_secret => 's' } );
    $db->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second' WHERE id::text = ?},
        Registry::DAO::WorkflowRun->find( $db, { id => $run->id } )->data->{cart_holds}{ $sib->id . ':' . $s->id } );
    my $other = Test::Registry::Fixtures::create_user( $db, { username => "return_other_$$" } );
    Registry::DAO::Entitlement->grant( $db, { holder_family_member_id => Registry::DAO::FamilyMember->create( $db, {
            family_id => $other->id, child_name => 'Other', birth_date => '2016-01-01' } )->id,
        offer_version_id => $v->id, payment_plan_id => 'pay', starts_at => 'now', resource_id => $s->id, units => 1 } );

    my $minion = $t->app->minion;
    my sub drivers () {
        scalar grep { $_->{args}[0]{run_id} eq $run->id }
            $minion->backend->list_jobs( 0, 100, { tasks => ['continue_workflow_run'], states => ['inactive'] } )->{jobs}->@*;
    }
    my @refunds;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $self, $id ) {
            Mojo::Promise->resolve( { id => $id, status => 'succeeded', amount => 20000,
                payment_method => 'pm_card', metadata => { payment_id => $payment->id } } );
        };
        local *Registry::Service::Stripe::create_refund_async = sub ( $self, $p ) {
            push @refunds, $p;
            Mojo::Promise->reject("Stripe api_error: try later\n");
        };
        $t->get_ok( "/session-checkout/@{[ $run->id ]}/payment?payment_intent=pi_returned_lost_$$"
            . "&payment_intent_client_secret=s&redirect_status=succeeded" );
        # The refund may run on after the response; give the loop time to finish it.
        for ( 1 .. 40 ) { Mojo::IOLoop->timer( 0.05 => sub { } ); Mojo::IOLoop->one_tick }
    }
    is scalar @refunds, 1, 'the return asked Stripe for the refund, which failed';
    is drivers(), 1, "and queued the run's driver to try it again";

    # S2: the page says who is booked, and what is being refunded.
    $t->get_ok("/session-checkout/@{[ $run->id ]}/complete")->status_is(200)
      ->content_like( qr/Kid $$/, 'Kid is listed as booked' )
      ->content_like( qr/Sib $$.*?\$100\.00/s, "Sib's refund is listed" )
      ->content_unlike( qr/Nothing could be booked/, 'and it does not say nothing was booked' );
    my $step = $dao->find( Workflow => { slug => 'session-checkout' } )->get_step( $db, { slug => 'complete' } );
    my $again = do {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ( $self, $p ) { Mojo::Promise->reject("down\n") };
        Test::Registry::Async::settle( $step->process( $db, {}, Registry::DAO::WorkflowRun->find( $db, { id => $run->id } ) ) );
    };
    like $again->{errors}[0], qr/Kid $$ is booked\. Sib $$ could not be booked; \$100\.00 for Sib $$ is being refunded\./,
        'a failed retry says so, not that nothing was booked';

    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = sub ( $self, $p ) {
            push @refunds, $p;
            Mojo::Promise->resolve( { id => 're_returned_lost', status => 'succeeded' } );
        };
        my $jobs = $minion->jobs( { tasks => ['continue_workflow_run'], states => ['inactive'] } );
        while ( my $job = $jobs->next ) { $minion->perform_jobs_in_foreground( { id => $job->{id} } ) }
    }
    is $refunds[-1]{amount}, 10000, "the driver refunds Sib's line";
    is Registry::DAO::Payment->find( $db, { id => $payment->id } )->refunded_cents, 10000, 'and it is recorded';
    is step_of($run), 'done', 'the run goes on to done';
};

done_testing();
