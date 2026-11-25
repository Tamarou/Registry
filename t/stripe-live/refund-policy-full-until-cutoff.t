# ABOUTME: Gated real-Stripe proof of ApplyRefundPolicy under full_until_cutoff: one refund of the entitlement's
# ABOUTME: share on the tenant's account, the application fee kept, and no second refund when asked again.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Async qw( settle );
use Test::Registry::Helpers qw( import_all_workflows );

use Registry::DAO;
use Registry::DAO::Entitlement;
use Registry::DAO::Offer;
use Registry::DAO::Payment;
use Registry::DAO::Resource;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::WorkflowStep;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

my $slug  = "refund_policy_live_$$";
my $owner = Registry::DAO::User->create( $db, {
    username => "rp_live_owner_$$", email => "rp_live_owner_$$\@test.example",
    name => 'Refund Policy Live Owner', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "Refund Policy Live $$", slug => $slug, users => [$owner] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $made = 0;
sub person () {
    return $tdb->insert( 'users', { username => "rp-live-p-$$-" . ++$made }, { returning => 'id' } )->hash->{id};
}

# An occurrence starting 48 hours from now under a 24-hour full refund cutoff.
sub offer_version () {
    my $class = $tdb->insert( 'projects', { name => 'Class ' . ++$made, slug => "rp-live-class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $tdb->insert( 'locations', { time_zone => 'America/New_York', name => 'Room ' . ++$made, slug => "rp-live-room-$made" },
        { returning => 'id' } )->hash->{id};
    my $event = $tdb->insert( 'events', {
        project_id => $class, location_id => $room, teacher_id => person(),
        time       => \"now() + interval '48 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    my $occurrence = Registry::DAO::Resource->for_occurrence( $tdb, $event );
    my $version = Registry::DAO::Offer->create( $tdb, { name => 'Live wheel ' . ++$made } )
        ->draft( $tdb, offer_terms( $occurrence->id,
            policies => { refund => { kind => 'full_until_cutoff', cutoff_hours => 24 } } ) )
        ->publish($tdb);
    return ( $version, $occurrence );
}

sub reread ($payment) { Registry::DAO::Payment->find( $tdb, { id => $payment->id } ) }

# A real $50 direct charge under 2.5% terms, settled. One entitlement of
# $share cents of it is the one refunded.
sub paid_entitlement ( $share = 3000 ) {
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id => person(), amount_cents => 5000, metadata => { tenant_slug => $slug } } );
    settle( $payment->create_payment_intent_async( $tdb, { description => 'Refund policy live' } ) );
    my $intent = reread($payment)->stripe_payment_intent_id;
    is Test::Registry::StripeConfirm::confirm( $intent, undef, $acct )->{status}, 'succeeded',
        'a real direct charge on the tenant account';
    settle( reread($payment)->process_payment_async( $tdb, $intent ) );
    is reread($payment)->status, 'completed', 'the payment is completed';

    my ( $version, $occurrence ) = offer_version();
    my ( undef, $ends ) = $occurrence->occurrence_window($tdb);
    my $e = Registry::DAO::Entitlement->grant( $tdb, {
        holder_user_id => person(), offer_version_id => $version->id, payment_plan_id => 'pay',
        starts_at => '2020-01-01T00:00:00Z', ends_at => $ends, resource_id => $occurrence->id, units => 1,
        payment_id => $payment->id, payment_share_cents => $share,
    } );
    return ( $e, $payment, $intent );
}

my $workflow = Registry::DAO::Workflow->create( $tdb, {
    name => 'Refund policy live', slug => 'refund-policy-live',
    description => 'drives ApplyRefundPolicy', first_step => 'apply-refund-policy' } );
Registry::DAO::WorkflowStep->create( $tdb, {
    workflow_id => $workflow->id, slug => 'apply-refund-policy', description => 'Apply the refund policy',
    class => 'Registry::DAO::WorkflowSteps::ApplyRefundPolicy' } );
my $step = Registry::DAO::WorkflowStep->find( $tdb, { workflow_id => $workflow->id, slug => 'apply-refund-policy' } );

sub apply ($e) {
    my $run = $workflow->new_run($tdb);
    # The tenant's owner asks, as the workflow's chooser lets an admin.
    $run->update_data( $tdb, { refund_entitlement_id => $e->id, user => { id => $owner->id, role => 'admin' } } );
    return settle( $run->process( $tdb, $step, {} ) );
}

sub refunds_of ($intent) {
    return Test::Registry::StripeConfirm::_get( "/refunds?payment_intent=$intent", $acct )->{data};
}

subtest 'one refund of the share with the fee kept, and none on a second request' => sub {
    my ( $e, $payment, $intent ) = paid_entitlement(3000);

    my $result = apply($e);
    ok !$result->{errors} && !$result->{refund_refused}, 'the request is honoured'
        or diag explain $result;
    like $result->{refund_requested}{refund_id}, qr/^re_/, 'Stripe answered with a refund';

    my $refunds = refunds_of($intent);
    is scalar @$refunds, 1, 'Stripe holds one refund';
    is $refunds->[0]{amount}, 3000, "for the entitlement's 3000 cents, not the 5000-cent payment";

    my $fee_id = Test::Registry::StripeConfirm::charge_for_settled( $intent, $acct )->{application_fee};
    is Test::Registry::StripeConfirm::_get("/application_fees/$fee_id")->{amount_refunded}, 0,
        'the application fee is not refunded';
    is Registry::DAO::Entitlement->find( $tdb, { id => $e->id } )->state, 'active',
        "the entitlement waits for Stripe's report to end it";

    my $again = apply($e);
    ok !$again->{errors}, 'a second request is answered' or diag explain $again;
    is $again->{refund_requested}{refund_id}, $refunds->[0]{id}, 'with the same refund';
    is scalar @{ refunds_of($intent) }, 1, 'and Stripe still holds one refund';
};

subtest 'stripe error leaves entitlement active' => sub {
    my ( $e, $payment ) = paid_entitlement(3000);
    $tdb->update( 'payments', { stripe_payment_intent_id => "pi_does_not_exist_$$" }, { id => $payment->id } );

    my $result = apply($e);
    like "@{ $result->{errors} // [] }", qr/No such payment_intent/, "Stripe's error surfaces";
    my $after = Registry::DAO::Entitlement->find( $tdb, { id => $e->id } );
    is $after->state, 'active', 'the entitlement stays active';
    is $after->refunded_cents($tdb), 0, 'nothing is recorded as refunded against it';
    is reread($payment)->refunded_cents, 0, 'or against the payment';
};

subtest 'the entitlement-refund walk ends with the refund requested' => sub {
    my ( $e, $payment, $intent ) = paid_entitlement(3000);
    import_all_workflows( Registry::DAO->new( url => $test_db->uri, schema => $slug ) );
    my $refund = Registry::DAO::Workflow->find( $tdb, { slug => 'entitlement-refund' } );
    my $run    = $refund->new_run($tdb);
    $run->update_data( $tdb, { user => { id => $owner->id, role => 'admin' } } );

    $run->process( $tdb, $refund->get_step( $tdb, { slug => 'choose' } ), { entitlement_id => $e->id } );
    my $result = settle( $run->process( $tdb, $refund->get_step( $tdb, { slug => 'apply' } ), {} ) );
    like $result->{refund_requested}{refund_id}, qr/^re_/, 'Stripe answered with a refund' or diag explain $result;
    $run = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } );
    is $run->next_step($tdb)->slug, 'done', 'the walk goes on to the done page';
    is scalar @{ refunds_of($intent) }, 1, 'Stripe holds one refund';
};

done_testing;
