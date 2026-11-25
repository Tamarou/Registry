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
    # An admin of the tenant asks, as the workflow's chooser lets them.
    $run->update_data( $tdb, { refund_entitlement_id => $entitlement->id, user => { id => $admin->id, role => 'admin' } } );
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

# Stripe's answer to a refund sent under $key, written as refund_async writes it.
sub stripe_answered ( $payment, $refund_id, $status, $key, $cents ) {
    fresh($payment)->_apply_refund_result( $tdb, { id => $refund_id, status => $status }, $cents,
        'requested_by_customer', 0, $key );
}

# A seat sold under a 24-hour full refund cutoff on an occurrence 48 hours off.
sub refundable ( $paid = payment(5000), $share = 3000 ) {
    my $occurrence = occurrence();
    my $version    = version( $occurrence, { kind => 'full_until_cutoff', cutoff_hours => 24 } );
    return ( booking( $version, $occurrence, $paid, $share ), $paid, $occurrence );
}

subtest 'honoured request asks stripe for entitlement amount once' => sub {
    my $paid = payment(5000);
    my ($e)       = refundable( $paid, 3000 );
    my ($sibling) = refundable( $paid, 2000 );

    apply($e);
    is_deeply request_on( $paid, $e ), { amount_cents => 3000, idempotency_key => key_for($e) },
        "the refund asked for is this entitlement's 3000 cents, not the cart's 5000";
    is request_on( $paid, $sibling ), undef, 'and nothing for the other entitlement on the payment';

    # Stripe answered the first request; the next one under the same key sends nothing.
    stripe_answered( $paid, 're_once', 'succeeded', key_for($e), 3000 );
    my $again = apply($e);
    ok !$again->{errors}, 'asked again, nothing is sent' or diag explain $again->{errors};
    is $again->{refund_requested}{refund_id}, 're_once', "the first refund is Stripe's answer";
    is reread($e)->state, 'active', "and ending the entitlement is left to Stripe's report";
};

subtest 'step does not end entitlement' => sub {
    my ( $e, $paid, $occurrence ) = refundable();
    stripe_answered( $paid, 're_done', 'succeeded', key_for($e), 3000 );

    my $result = apply($e);
    is $result->{refund_requested}{status}, 'succeeded', 'the refund request succeeds';
    my $after = reread($e);
    is $after->state, 'active', 'the entitlement is still active';
    is_deeply $after->units( $tdb, $occurrence->id ), [1], 'and still holds its seat';
    is $occurrence->free_units($tdb), 3, 'which is not freed';
};

subtest 'ended or fully refunded entitlement refused' => sub {
    my ( $ended, $ended_paid ) = refundable();
    $ended->end( $tdb, 'refunded', 're_dashboard' );
    like apply($ended)->{refund_refused}, qr/has ended/, 'an ended entitlement is refused';
    is request_on( $ended_paid, $ended ), undef, 'and no refund is requested';

    my ( $spent, $spent_paid ) = refundable();
    $spent->record_refund( $tdb, { amount_cents => 3000, stripe_refund_id => 're_partials' } );
    like apply($spent)->{refund_refused}, qr/already been refunded/, 'one refunded in full is refused';
    is request_on( $spent_paid, $spent ), undef, 'and no refund is requested';
};

subtest 'unrecognised policy refused' => sub {
    my $occurrence = occurrence();
    # The database refuses an unknown kind and a published version with no
    # refund policy, so what can reach the step is a full refund with no
    # cutoff, written past draft's check as only a bypass could, and the
    # platform's keep-the-fee term, which the fee-refund exception applies.
    my $draft = Registry::DAO::Offer->create( $tdb, { name => 'Odd ' . ++$made } )
        ->draft( $tdb, offer_terms( $occurrence->id ) );
    $tdb->query( q{UPDATE offer_versions SET policies = '{"refund":{"kind":"full_until_cutoff"}}' WHERE id = ?},
        $draft->id );
    my $odd = booking( $draft->publish($tdb), $occurrence, my $odd_paid = payment(), 2000 );
    like apply($odd)->{refund_refused}, qr/no refund policy this step applies/, 'a full refund with no cutoff is refused';
    is request_on( $odd_paid, $odd ), undef, 'never treated as a full refund';

    my $fee = booking( version( $occurrence, { kind => 'keep_fee_with_admin_exception' } ), $occurrence,
        my $fee_paid = payment(), 2000 );
    like apply($fee)->{refund_refused}, qr/keeps the platform fee.*admin.*fee-refund exception/,
        'keep the fee is refused here, pointing to the fee-refund exception an admin applies';
    is request_on( $fee_paid, $fee ), undef, 'and no refund is requested';
};

subtest 'no linked payment refused' => sub {
    my $occurrence = occurrence();
    my $e = booking( version( $occurrence, { kind => 'full_until_cutoff', cutoff_hours => 24 } ), $occurrence );
    like apply($e)->{refund_refused}, qr/not paid for/, 'an entitlement no payment bought is refused';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->'entitlement_refund_requests'->? IS NOT NULL},
        $e->id )->array->[0], 0,
        'and no refund, of zero or any amount, is requested';
};

subtest 'refund capped at remaining amount' => sub {
    my ( $e, $paid ) = refundable();
    $e->record_refund( $tdb, { amount_cents => 1000, stripe_refund_id => 're_partial' } );
    apply($e);
    is request_on( $paid, $e )->{amount_cents}, 2000,
        'with 1000 of its 3000 cents already refunded, 2000 is requested';
};

subtest 'request at or after cutoff refused' => sub {
    my ( $e, $paid, $occurrence ) = refundable();
    my $cutoff = hours_before( $occurrence, 24 );
    my $after  = $tdb->query( q{SELECT ?::timestamptz + interval '1 second'}, $cutoff )->array->[0];
    like $refusal->( $e, $after ), qr/only until 24 hours before/, 'a second after the cutoff it is refused';
    like $refusal->( $e, hours_before( $occurrence, 1 ) ), qr/only until/, 'an hour before the start it is refused';

    my $late = booking( version( $occurrence, { kind => 'full_until_cutoff', cutoff_at => '2020-06-01T00:00:00Z' } ),
        $occurrence, my $late_paid = payment(), 2000 );
    like apply($late)->{refund_refused}, qr/only until/, 'asked after a dated cutoff, the step refuses';
    is request_on( $late_paid, $late ), undef, 'and no refund is requested';
};

subtest 'request at exactly the cutoff honoured' => sub {
    # ADR 005 8b: the boundary is inclusive (now <= cutoff).
    my ( $e, $paid, $occurrence ) = refundable();
    is $refusal->( $e, hours_before( $occurrence, 24 ) ), undef, 'exactly 24 hours before, it is honoured';
    my $dated = booking( version( $occurrence, { kind => 'full_until_cutoff', cutoff_at => '2030-06-01T00:00:00Z' } ),
        $occurrence, payment(), 2000 );
    is $refusal->( $dated, '2030-06-01T00:00:00Z' ), undef, 'and so is one at exactly a dated cutoff';
};

subtest 'pending refund blocks second request' => sub {
    my ( $e, $paid ) = refundable();
    stripe_answered( $paid, 're_pending', 'pending', key_for($e), 3000 );

    # The payment names no seller account: anything sent would come back an error.
    my $result = apply($e);
    ok !$result->{errors}, 'no second refund is sent' or diag explain $result->{errors};
    is $result->{refund_requested}{refund_id}, 're_pending', 'the pending one is the answer';
    is $result->{refund_requested}{status}, 'pending', 'still pending';
    is fresh($paid)->refunded_cents, 0, 'and nothing is counted as refunded';
};

subtest 'stripe error leaves entitlement active' => sub {
    # Refused by refund_async before any request: the same failure branch a
    # Stripe error takes. A real Stripe error is in t/stripe-live/.
    my ( $e, $paid ) = refundable();
    my $result = apply($e);
    like "@{ $result->{errors} // [] }", qr/Refund not requested.*no seller Stripe account/,
        'the error is surfaced';
    is reread($e)->state, 'active', 'the entitlement stays active';
    is reread($e)->refunded_cents($tdb), 0, 'nothing is recorded as refunded against it';
    is fresh($paid)->refunded_cents, 0, 'or against the payment';
    is fresh($paid)->metadata->{refund_last_failure}{classification}, 'not_sent',
        'and the payment says nothing was sent';
};

done_testing;
