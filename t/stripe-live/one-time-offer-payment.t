# ABOUTME: Gated real-Stripe proof that a one-time offer payment is a direct charge on the seller's connected account.
# ABOUTME: One intent however often the step runs, the revenue-share application fee on it, and the run handed on when paid.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;
use Registry::DAO::WorkflowRun;
use Registry::DAO::Offer;
use Registry::DAO::Resource;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "otp_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "otp_live_admin_$$", email => "otp_live_admin_$$\@test.example",
    name => 'OTP Live Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "OTP Live $$", slug => $slug, users => [$admin] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $resource = Registry::DAO::Resource->create( $tdb, { name => 'Studio seat', kind => 'unbounded' } );
my $version  = Registry::DAO::Offer->create( $tdb, { name => 'Drop-in' } )
    ->draft( $tdb, offer_terms( $resource->id ) )->publish($tdb);
my $buyer = Registry::DAO::User->create( $tdb, {
    username => "otp_live_buyer_$$", email => "otp_live_buyer_$$\@test.example",
    name => 'OTP Live Buyer', user_type => 'parent' } );

my $wf = Registry::DAO::Workflow->create( $tdb, {
    name => 'OTP Live', slug => "otp-live-$$", description => 'one-time payment live test' } );
$wf->add_step( $tdb, { slug => $_->[0], class => $_->[1] } ) for
    [ before => 'Registry::DAO::WorkflowStep' ],
    [ pay    => 'Registry::DAO::WorkflowSteps::OneTimePayment' ],
    [ after  => 'Registry::DAO::WorkflowStep' ];
my $pay = $wf->get_step( $tdb, { slug => 'pay' } );

my $run = $wf->new_run( $tdb, {} );
$run->process( $tdb, $wf->first_step($tdb), {} );
$run->update_data( $tdb, {
    user_id       => $buyer->id,
    __tenant_slug => $slug,
    owed_payment  => {
        offer_version_id => $version->id, payment_plan => 'pay', amount_cents => 1060,
        description => 'Change fee', purpose => 'change_fee',
    },
} );

sub payment_of_run () {
    my $id = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data->{owed_payment_id};
    return Registry::DAO::Payment->find( $tdb, { id => $id } );
}

subtest 'the charge lands on the connected account with the revenue-share fee' => sub {
    my $first = settle( $run->process( $tdb, $pay, {} ) );
    ok $first->{stay}, 'the step waits for the card';
    like $first->{template_data}{step_data}{client_secret}, qr/^pi_/, 'with a client secret';
    is $first->{template_data}{step_data}{stripe_account}, $acct, "for the seller's account";

    my $intent = payment_of_run()->stripe_payment_intent_id;
    like $intent, qr/^pi_/, 'a real intent was created';

    settle( $run->process( $tdb, $pay, {} ) );
    is payment_of_run()->stripe_payment_intent_id, $intent,
        'processing again replays the same intent under the same idempotency key';
    is $tdb->query( q{SELECT count(*) FROM payments WHERE metadata->>'workflow_run_id' = ?},
        $run->id )->array->[0], 1, 'and keeps one payment row';

    is Test::Registry::StripeConfirm::confirm( $intent, undef, $acct )->{status}, 'succeeded',
        'Stripe takes the payment on the connected account';

    settle( $run->process( $tdb, $pay, { payment_intent_id => $intent } ) );
    is Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->latest_step($tdb)->slug, 'pay',
        'the return hands the run on past the payment';
    is payment_of_run()->status, 'completed', 'the payment is completed';

    my $charge = Test::Registry::StripeConfirm::charge_for_settled( $intent, $acct );
    is $charge->{amount}, 1060, 'the charge is for the amount owed';
    my $fraction = platform_terms_for_tenant( $db, $slug )->{fraction};
    is $charge->{application_fee_amount},
        Registry::DAO::Payment::application_fee_cents( 1060, $fraction ),
        "the application fee is the tenant's revenue share of it";
    ok !$charge->{on_behalf_of}, 'no on_behalf_of on a direct charge';
    ok !$charge->{transfer_data}, 'and no transfer_data';
    is payment_of_run()->platform_fee_cents, $charge->{application_fee_amount},
        'the fee Stripe took is recorded on the payment';
};

done_testing;
