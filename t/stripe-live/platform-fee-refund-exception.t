# ABOUTME: Gated real-Stripe proof of Solo's fee-refund exception: after a refunded direct charge, the platform
# ABOUTME: admin's workflow returns the application fee once, on the platform account; a second press adds none.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Mojo::File ();
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Helpers qw( join_tenant );
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;
use Registry::DAO::Workflow;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;

my $slug  = "fee_exception_live_$$";
my $owner = Registry::DAO::User->create( $db, {
    username => "fee_live_owner_$$", email => "fee_live_owner_$$\@test.example",
    name => 'Fee Live Owner', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "Fee Live $$", slug => $slug, users => [$owner] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
# Solo's terms: 2.5% of each sale, the fee kept on a refund unless the platform's admin returns it.
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $parent = Registry::DAO::User->create( $tdb, {
    username => "fee_live_parent_$$", email => "fee_live_parent_$$\@test.example",
    name => 'Fee Live Parent', user_type => 'parent' } );

my $admin = Registry::DAO::User->create( $db, {
    username => "fee_live_platform_admin_$$", email => "fee_live_platform_admin_$$\@test.example",
    name => 'Fee Live Platform Admin', user_type => 'admin' } );
join_tenant( $db, $admin, 'admin', 'registry' );

my $workflow = Registry::DAO::Workflow->from_yaml( $dao,
    Mojo::File::path('workflows/platform-fee-refund-exception.yml')->slurp );

# The workflow walked as the platform admin, acting as registry, on $payment:
# find, record the reason, and return the fee. Returns the $until step's result.
sub apply_exception ( $payment, $until = 'apply' ) {
    my $run  = $workflow->new_run($db);
    my %as   = ( __tenant_slug => 'registry', user_id => $admin->id );
    my $step = $workflow->first_step($db);
    for my $form (
        { payment_tenant => $slug, payment_id => $payment->id },
        { reason => 'The platform charged the family twice' },
        {},
    ) {
        my $result = $run->process( $db, $step, { %$form, %as } );
        $result = settle($result) if $result isa Mojo::Promise;
        return $result if $step->slug eq $until || $result->{errors};
        $step = $step->next_step($db);
    }
}

sub reread ($payment) { Registry::DAO::Payment->find( $tdb, { id => $payment->id } ) }

# A real $50 direct charge under Solo, refunded to the family with the fee
# kept. Returns the payment and its application fee's id.
sub refunded_charge () {
    my $payment = Registry::DAO::Payment->create( $tdb, {
        user_id => $parent->id, amount_cents => 5000, metadata => { tenant_slug => $slug } } );
    settle( $payment->create_payment_intent_async( $tdb, { description => 'Fee exception live' } ) );
    $payment = reread($payment);
    my $intent = $payment->stripe_payment_intent_id;
    is Test::Registry::StripeConfirm::confirm( $intent, undef, $acct )->{status}, 'succeeded',
        'a real direct charge on the tenant account';
    settle( $payment->process_payment_async( $tdb, $intent ) );
    $payment = reread($payment);
    is $payment->platform_fee_cents, 125, 'the 2.5% fee is recorded on the payment';

    my $fee_id = Test::Registry::StripeConfirm::charge_for_settled( $intent, $acct )->{application_fee};
    like $fee_id, qr/^fee_/, 'the charge carried an application fee';

    settle( $payment->refund_async($tdb) );
    $payment = reread($payment);
    is $payment->status, 'refunded', 'the family was refunded';
    is Test::Registry::StripeConfirm::_get("/application_fees/$fee_id")->{amount_refunded}, 0,
        'and the platform kept its fee';
    return ( $payment, $fee_id );
}

my ( $payment, $fee_id ) = refunded_charge();

subtest 'exception returns the fee once on the platform account' => sub {
    my $result = apply_exception($payment);
    ok !$result->{errors}, 'the exception was applied' or diag explain $result->{errors};
    like $result->{fee_refund}{id}, qr/^fr_/, 'Stripe answered with a fee refund';

    my $fee = Test::Registry::StripeConfirm::_get("/application_fees/$fee_id");
    is $fee->{amount_refunded}, 125, 'the whole fee is returned';
    is scalar @{ $fee->{refunds}{data} }, 1, 'in one fee refund';
    is reread($payment)->platform_fee_refunded_cents, undef,
        'recorded only when Stripe reports it, so a second press reads Stripe';
};

subtest 'applying again adds no second fee refund' => sub {
    my $result = apply_exception($payment);
    ok !$result->{errors}, 'answered' or diag explain $result->{errors};
    is $result->{fee_refund}{already_returned_cents}, 125, 'with the fee Stripe already shows returned';
    is reread($payment)->platform_fee_refunded_cents, 125, "and Stripe's figure is recorded on the payment";

    my $fee = Test::Registry::StripeConfirm::_get("/application_fees/$fee_id");
    is $fee->{amount_refunded}, 125, 'the fee returned is unchanged';
    is scalar @{ $fee->{refunds}{data} }, 1, 'still one fee refund';
};

subtest 'fee partly returned elsewhere: apply returns the rest' => sub {
    my ( $part, $part_fee ) = refunded_charge();
    ok !apply_exception( $part, 'confirm' )->{errors}, 'the request is recorded';
    is reread($part)->metadata->{platform_fee_refund_exception}{amount_cents}, 125, 'for the whole fee';

    # Returned by hand on the platform account, before apply is pressed.
    Test::Registry::StripeConfirm::_post( "/application_fees/$part_fee/refunds", { amount => 50 } );

    my $result = apply_exception($part);
    ok !$result->{errors}, 'apply is not refused' or diag explain $result->{errors};
    is $result->{fee_refund}{amount_cents}, 75, 'and sends only the 75 cents left';

    my $fee = Test::Registry::StripeConfirm::_get("/application_fees/$part_fee");
    is $fee->{amount_refunded}, 125, 'the whole fee is returned';
    is scalar @{ $fee->{refunds}{data} }, 2, 'in the hand refund and the one apply sent';
};

done_testing;
