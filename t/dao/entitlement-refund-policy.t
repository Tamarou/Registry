#!/usr/bin/env perl
# ABOUTME: ApplyRefundPolicy decides a refund request by the refund policy stamped on the entitlement's offer version.
# ABOUTME: Decisions and the request recorded on the payment, against real Postgres; the Stripe call is in t/stripe-live/.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Async qw( settle );
use Test::Registry::Helpers qw( import_all_workflows join_tenant publish_offer );
use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowStep;
use Registry::DAO::WorkflowSteps::ApplyRefundPolicy;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

import_all_workflows($dao);
my $slug = 'refund_policy_studio';
Test::Registry::Fixtures::create_tenant( $dao, { name => 'Refund Policy Studio', slug => $slug } );
my $tenant_dao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
my $tdb        = $tenant_dao->db;
import_all_workflows($tenant_dao);

my $admin = Test::Registry::Fixtures::create_user( $dao,
    { username => 'rp_admin', name => 'RP Admin', email => 'admin@rp.test', user_type => 'admin' } );
join_tenant( $dao, $admin, 'admin', $slug );

my $made = 0;
sub person () {
    return $tdb->insert( 'users', { username => 'rp-p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

# An occurrence four seats wide starting 48 hours from now, its own resource.
sub occurrence () {
    my $class = $tdb->insert( 'projects', { name => 'Class ' . ++$made, slug => "rp-class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $tdb->insert( 'locations', { name => 'Room ' . ++$made, slug => "rp-room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $tdb->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person(),
        time       => \"date_trunc('second', now()) + interval '48 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $tdb, $event );
}

# A completed payment of $cents. It names no seller account, so a refund it
# is asked for is refused before anything is sent to Stripe.
sub payment ( $cents = 5000 ) {
    return Registry::DAO::Payment->create( $tdb, {
        user_id => person(), amount_cents => $cents, status => 'completed',
        stripe_payment_intent_id => 'pi_rp_' . ++$made, metadata => {},
    } );
}

# A published version of a new offer on $occurrence under refund policy $refund.
sub version ( $occurrence, $refund ) {
    return Registry::DAO::Offer->create( $tdb, { name => 'Wheel ' . ++$made } )
        ->draft( $tdb, offer_terms( $occurrence->id, policies => { refund => $refund } ) )
        ->publish($tdb);
}

# An entitlement to one seat of $occurrence under $version, bought by
# $payment for $share cents (no payment when $payment is undef).
sub booking ( $version, $occurrence, $payment = undef, $share = undef ) {
    my ( undef, $ends ) = $occurrence->occurrence_window($tdb);
    return Registry::DAO::Entitlement->grant( $tdb, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => $version->payment_plans($tdb)->[0]{id},
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $occurrence->id,
        units            => 1,
        $payment ? ( payment_id => $payment->id, payment_share_cents => $share ) : (),
    } );
}

# The step, in a one-step workflow of its own, driven through a run naming
# $entitlement the way the refund workflow's chooser will.
my $workflow = Registry::DAO::Workflow->create( $tdb, {
    name => 'Refund policy test', slug => 'refund-policy-test',
    description => 'drives ApplyRefundPolicy', first_step => 'apply-refund-policy' } );
Registry::DAO::WorkflowStep->create( $tdb, {
    workflow_id => $workflow->id, slug => 'apply-refund-policy', description => 'Apply the refund policy',
    class => 'Registry::DAO::WorkflowSteps::ApplyRefundPolicy' } );
# Found, so it is inflated as its class.
my $step = Registry::DAO::WorkflowStep->find( $tdb, { workflow_id => $workflow->id, slug => 'apply-refund-policy' } );

sub apply ($entitlement) {
    my $run = $workflow->new_run($tdb);
    $run->update_data( $tdb, { refund_entitlement_id => $entitlement->id } );
    return settle( $run->process( $tdb, $step, {} ) );
}

sub reread ($e)  { Registry::DAO::Entitlement->find( $tdb, { id => $e->id } ) }
sub fresh ($p)   { Registry::DAO::Payment->find( $tdb, { id => $p->id } ) }
sub request_on ( $payment, $e ) { ( fresh($payment)->metadata->{entitlement_refund_requests} // {} )->{ $e->id } }

subtest 'none policy refuses refund' => sub {
    my $occurrence = occurrence();
    my $paid       = payment();
    my $e          = booking( version( $occurrence, { kind => 'none' } ), $occurrence, $paid, 5000 );

    my $result = apply($e);
    like $result->{refund_refused}, qr/all sales are final/i, "refused in the offer's terms";
    ok !$result->{errors}, 'a refusal, not an error';
    is request_on( $paid, $e ), undef, 'no refund is requested';
    ok !fresh($paid)->metadata->{refund_last_failure}, 'and nothing was sent to Stripe';
    is reread($e)->state, 'active', 'the entitlement is unchanged';
};

sub key_for ($e) { 'refund:entitlement:' . $e->id }
sub starts ($occurrence) { ( $occurrence->occurrence_window($tdb) )[0] }
sub hours_before ( $occurrence, $hours ) {
    $tdb->query( 'SELECT ?::timestamptz - make_interval(hours => ?)', starts($occurrence), $hours )->array->[0];
}
my $refusal = sub { Registry::DAO::WorkflowSteps::ApplyRefundPolicy->refusal( $tdb, @_ ) };

subtest 'full until cutoff honoured only before cutoff' => sub {
    my $occurrence = occurrence();
    my $version    = version( $occurrence, { kind => 'full_until_cutoff', cutoff_hours => 24 } );
    my $paid       = payment(5000);
    my $e          = booking( $version, $occurrence, $paid, 3000 );

    is $refusal->( $e, hours_before( $occurrence, 25 ) ), undef, 'an hour before the cutoff it is honoured';
    like $refusal->( $e, hours_before( $occurrence, 23 ) ), qr/24 hours before/,
        'an hour after the cutoff it is refused';

    my $result = apply($e);
    ok !$result->{refund_refused}, 'asked now, 47 hours before the start, it is not refused';
    is_deeply request_on( $paid, $e ), { amount_cents => 3000, idempotency_key => key_for($e) },
        "a refund of this entitlement's 3000 cents of the 5000-cent payment is requested, keyed on the entitlement";
    is reread($e)->state, 'active', 'and the entitlement is still active';

    my $dated = booking( version( $occurrence, { kind => 'full_until_cutoff', cutoff_at => '2020-06-01T00:00:00Z' } ),
        $occurrence, my $dated_paid = payment(2000), 2000 );
    like apply($dated)->{refund_refused}, qr/until 2020-06-01/, 'a dated cutoff that has passed is refused';
    is request_on( $dated_paid, $dated ), undef, 'and no refund is requested';
};

subtest 'a new version with another refund policy changes no existing entitlement' => sub {
    my $occurrence = occurrence();
    my $offer      = Registry::DAO::Offer->create( $tdb, { name => 'Reprice ' . ++$made } );
    my $publish    = sub ($refund) {
        $offer->draft( $tdb, offer_terms( $occurrence->id, policies => { refund => $refund } ) )->publish($tdb);
    };

    my $sold_final = booking( $publish->( { kind => 'none' } ), $occurrence, payment(), 2000 );
    my $v2         = $publish->( { kind => 'full_until_cutoff', cutoff_hours => 24 } );
    my $sold_full  = booking( $v2, $occurrence, my $full_paid = payment(), 2000 );
    $publish->( { kind => 'none' } );

    like apply($sold_final)->{refund_refused}, qr/all sales are final/,
        'sold under none, it is refused although a later version gave refunds';
    ok !apply($sold_full)->{refund_refused}, 'sold under full until cutoff, it is honoured although the current version is none';
    is +( request_on( $full_paid, $sold_full ) // {} )->{amount_cents}, 2000, 'and its refund is requested';
};

subtest 'refund against offer-publishing version honoured' => sub {
    my $occurrence = occurrence();
    my $version    = publish_offer( $dao, $slug, $admin, {
        'offer-basics'  => { resource_id => $occurrence->id, offer_name => 'Published wheel ' . ++$made },
        'offer-price'   => { price_cents => 2500, currency => 'usd', units_per_acceptance => 1, per_booking_cap => 1 },
        'refund-policy' => { refund => 'full_until_cutoff', cutoff_hours => 24 },
        'expiry-policy' => { expiry => 'end_of_occurrence' },
    } );
    is_deeply $version->policies->{refund}, { kind => 'full_until_cutoff', cutoff_hours => 24 },
        'the refund-policy step stored a 24 hour cutoff';

    my $e      = booking( $version, $occurrence, my $paid = payment(2500), 2500 );
    my $result = apply($e);
    ok !$result->{refund_refused}, 'asked before the cutoff, it is not refused as unrecognised or late'
        or diag $result->{refund_refused};
    is_deeply request_on( $paid, $e ), { amount_cents => 2500, idempotency_key => key_for($e) },
        'its refund is requested';
};

done_testing;
