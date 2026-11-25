#!/usr/bin/env perl
# ABOUTME: The second half of a change: once the fee is paid, CompleteChange moves the entitlement onto the held target.
# ABOUTME: Settled by payment_intent.succeeded on the Connect endpoint, whose job drives the run with nobody present.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::StripeWebhook;

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Payment;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;
use Registry::PriceOps::Hold;

local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_local_change_fee';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_local_change_fee_connect';

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );
my $minion = $t->app->minion;

# A seller with a Stripe account and platform terms, so a fee can be charged.
my $SLUG    = "ccm_$$";
my $ACCOUNT = "acct_ccm_$$";
my $admin   = Registry::DAO::User->create( $db, {
    username => "ccm_admin_$$", email => "ccm_admin_$$\@test.example",
    name => 'CCM Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, {
    name => "CCM $$", slug => $SLUG, users => [$admin],
    stripe_connect_account_id => $ACCOUNT, stripe_charges_enabled => 1, stripe_details_submitted => 1 } );
give_tenant_terms( $db, $SLUG, { rate => '0.025' } );
my $studio = $dao->connect_schema($SLUG)->db;

my %WINDOW = ( kind => 'window', window_hours => 48, fee_cents => 1000, targets => 'same_offer' );
my $made   = 0;

sub person () {
    return $studio->insert( 'users', { username => "ccm-p-$$-" . ++$made }, { returning => 'id' } )->hash->{id};
}

# A class whose occurrences start $hours from now, each with four seats, and
# a published class offer version covering them with change policy $change
# and end-of-occurrence expiry. Returns the version and the resources.
sub occurrences ( $change, @hours ) {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
            { returning => 'id' } )->hash->{id};
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => \"now() + interval '$_ hours'", duration => 90, capacity => 4,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } @hours;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, policies => {
            refund => { kind => 'none' }, change => $change, expiry => { kind => 'end_of_occurrence' } } ) )
        ->publish($studio);
    return ( $version, @resources );
}

# An entitlement under $version holding $units seats of $resource, in effect
# until that occurrence ends, as end-of-occurrence expiry stamps it.
sub booking ( $version, $resource, $units = 1 ) {
    my ( undef, $ends ) = $resource->occurrence_window($studio);
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => $units,
    } );
}

my $workflow = Registry::DAO::Workflow->create( $studio,
    { slug => 'change-fee-test', name => 'Change fee test', description => 'change completion under test' } );
$workflow->add_step( $studio, { slug => $_->[0], class => $_->[1] } ) for
    [ 'choose-target' => 'Registry::DAO::WorkflowSteps::ChooseChangeTarget' ],
    [ 'hold-target'   => 'Registry::DAO::WorkflowSteps::HoldChangeTarget' ],
    [ 'pay'           => 'Registry::DAO::WorkflowSteps::OneTimePayment' ],
    [ 'complete'      => 'Registry::DAO::WorkflowSteps::CompleteChange' ];

sub step ($slug) { $workflow->get_step( $studio, { slug => $slug } ) }

sub reload ($run) { Registry::DAO::WorkflowRun->find( $studio, { id => $run->id } ) }

# A run that chose to change $entitlement and holds $target for it.
sub held_run ( $entitlement, $target ) {
    my $run = $workflow->new_run( $studio, {} );
    $run->update_data( $studio, { user_id => $entitlement->holder_user_id, __tenant_slug => $SLUG } );
    $run->process( $studio, step('choose-target'), { entitlement_id => $entitlement->id } );
    my $held = $run->process( $studio, step('hold-target'), { target_occurrence_id => $target->id } );
    die 'hold refused: ' . explain $held->{errors} if $held->{errors};
    return reload($run);
}

# The fee payment this run started, with the intent Stripe answered recorded,
# named on the run as OneTimePayment names it.
sub fee_payment ( $run, $amount = $run->data->{change_hold}{fee_cents} ) {
    my $payment = Registry::DAO::Payment->create( $studio, {
        user_id          => $run->data->{user_id},
        amount_cents     => $amount,
        offer_version_id => $run->data->{change_hold}{offer_version_id},
        metadata         => { workflow_id => $workflow->id, workflow_run_id => $run->id,
                              tenant_slug => $SLUG, payment_plan_id => 'pay', description => 'Change fee' },
    } );
    $payment->_record_intent( $studio, { id => 'pi_ccm_' . $payment->id, client_secret => 'x_secret' } );
    $run->update_data( $studio, { owed_payment_id => $payment->id } );
    return $payment;
}

# payment_intent.succeeded on the Connect endpoint for $payment, as Stripe sends it.
sub succeeded ($payment) {
    return Test::Registry::StripeWebhook::post_connect( $t, {
        type    => 'payment_intent.succeeded',
        account => $ACCOUNT,
        data    => { object => {
            id       => $payment->stripe_payment_intent_id,
            amount   => $payment->amount_cents,
            metadata => { payment_id => $payment->id, tenant_slug => $SLUG },
        } },
    } );
}

# Has Minion's worker perform every queued job.
sub drive () { $minion->perform_jobs }

# The run's hold lapses, as the clock would make it.
sub lapse ($run) {
    $studio->query( q{UPDATE holds SET expires_at = clock_timestamp() - interval '1 second'
                       WHERE workflow_run_id = ?}, $run->id );
}

sub hold_is_live ($run) {
    my $live = Registry::PriceOps::Hold->live_sql('holds');
    $studio->query( "SELECT $live FROM holds WHERE id = ?", reload($run)->data->{change_hold}{hold_id} )
        ->array->[0];
}

sub payments_of ($run) {
    $studio->query( q{SELECT * FROM payments WHERE metadata->>'workflow_run_id' = ?}, $run->id )
        ->hashes->to_array;
}

sub hold_state ($run) {
    $studio->select( 'holds', 'state', { id => reload($run)->data->{change_hold}{hold_id} } )->array->[0];
}

subtest 'paid change moves entitlement once' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );
    my $e   = booking( $version, $from, 2 );
    my $run = held_run( $e, $to );

    is_deeply { reload($run)->data->{owed_payment}->%{qw( amount_cents offer_version_id payment_plan hold_id )} }, {
        amount_cents     => 1000,
        offer_version_id => $version->id,
        payment_plan     => 'pay',
        hold_id          => reload($run)->data->{change_hold}{hold_id},
    }, 'the hold step owes the stamped fee, under the entitlement\'s plan, for the hold';

    succeeded( fee_payment($run) )->status_is(200);
    drive();

    is_deeply $e->units( $studio, $to->id ), [ 1, 2 ], 'the entitlement holds the target\'s seats';
    is_deeply $e->units( $studio, $from->id ), [], 'and none of the old occurrence\'s';
    is $from->free_units($studio), 4, 'whose seats are free again';
    is $to->free_units($studio), 2, 'the target has its two other seats free';
    is hold_state($run), 'converted', 'the hold is converted';
    ok reload($run)->completed($studio), 'the run is complete';

    my ( undef, $from_ends ) = $from->occurrence_window($studio);
    my ( undef, $to_ends )   = $to->occurrence_window($studio);
    ok Registry::DAO::Entitlement->in_effect_at( $studio,
        $studio->query( q{SELECT ?::timestamptz + interval '1 hour'}, $from_ends )->array->[0],
        { id => $e->id } ), 'it stays in effect past the old occurrence\'s end';
    is $studio->query( 'SELECT upper(in_effect) = ?::timestamptz FROM entitlements WHERE id = ?',
        $to_ends, $e->id )->array->[0], 1, 'until the target occurrence ends';
    is $studio->select( 'entitlements', 'count(*)', { offer_version_id => $version->id } )->array->[0], 1,
        'no second entitlement is made';
};

subtest 'failed charge or lapsed hold releases hold' => sub {
    my ( $version, $from, $to ) = occurrences( \%WINDOW, 72, 96 );

    my $e   = booking( $version, $from );
    my $run = held_run( $e, $to );
    my $payment = fee_payment($run);
    $payment->_record_intent_failure_write( $studio, 'Your card was declined.' );    # as a decline records it
    ok $run->process( $studio, step('complete'), {} )->{errors}, 'a failed charge does not complete the change';
    lapse($run);
    ok !hold_is_live($run), 'its hold lapses, which releases it';
    is $to->free_units($studio), 4, 'so the target keeps every seat';
    is_deeply $e->units( $studio, $from->id ), [1], 'and the entitlement stays where it was';

    $e   = booking( $version, $from );
    $run = held_run( $e, $to );
    lapse($run);
    my $paid = $run->process( $studio, step('pay'), {} );
    like "@{ $paid->{errors} // [] }", qr/lapsed/, 'a hold that lapsed before the charge refuses the charge';
    is_deeply payments_of($run), [], 'and no payment is started';
    is hold_state($run), 'released', 'the hold is released';
    is $to->free_units($studio), 4, 'the target keeps every seat';
    is scalar $e->units( $studio, $from->id )->@*, 1, 'and the entitlement stays where it was';
};

done_testing;
