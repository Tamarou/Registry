# ABOUTME: End-to-end integration test for a tenant's paid session checkout.
# ABOUTME: Strings together the Stripe Connect readiness gate, the cart's one intent, the Connect webhook, the run driver and idempotency.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::Service::Stripe;
use Test::Registry::Async qw( settle );
use Test::Registry::DB;
use Test::Registry::Mojo;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::SessionCheckout qw( post_succeeded drive );
use Mojo::Promise;

local $ENV{STRIPE_SECRET_KEY}             = 'sk_test_dummy';
local $ENV{STRIPE_WEBHOOK_SECRET}         = 'whsec_e2e_paid';
local $ENV{STRIPE_CONNECT_WEBHOOK_SECRET} = 'whsec_e2e_paid_connect';

# ---------------------------------------------------------------------------
# 1. A fresh tenant, not yet ready for Stripe, with a $150 session on sale and
#    a parent whose child's seat is held: the cart is at its payment step.
# ---------------------------------------------------------------------------

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = 'e2e_paid_' . $$;
my $admin = Registry::DAO::User->create( $db, {
    username => "e2e_admin_$$", email => "e2e_admin_$$\@test.example", name => 'E2E Admin', user_type => 'admin' } );
my $tenant = Registry::DAO::Tenant->provision( $db, { name => "E2E Paid Tenant $$", slug => $slug, users => [$admin] } );
ok $tenant, 'tenant provisioned';

my $tdao = Registry::DAO->new( url => $test_db->uri, schema => $slug );
my $tdb  = $tdao->db;

my $PRICE_CENTS = 15_000;
my $session = make_session($tdb);
my $version = session_offer( $tdb, $session, price_cents => $PRICE_CENTS );
my $parent  = Registry::DAO::User->create( $tdb, {
    email => "e2e_parent_$$\@example.com", username => "e2e_parent_$$", name => 'E2E Parent', user_type => 'parent' } );
my $child = Registry::DAO::FamilyMember->create( $tdb,
    { family_id => $parent->id, child_name => 'E2E Child', birth_date => '2018-03-15' } );
my ( $run, $step ) = held_cart( $tdao, $parent->id, [ $child->id, $session->id, $version->id, 'pay' ] );

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub ( $c, $tenant = undef ) {
    defined $tenant ? Registry::DAO->new( url => $test_db->uri, schema => $tenant ) : $dao } );

# ---------------------------------------------------------------------------
# 2. Gate refusal: tenant NOT ready -> nothing charged, zero payments.
# ---------------------------------------------------------------------------

subtest 'gate refusal: unready tenant blocks the paid checkout' => sub {
    ok !$tenant->stripe_connect_ready, 'precondition: tenant stripe_connect_ready is false';

    my @warnings;
    my $result = do {
        local $SIG{__WARN__} = sub { push @warnings, @_ };
        settle( $step->process( $tdb, {}, $run ) );
    };
    like "@warnings", qr/payment refused: tenant '\Q$slug\E' is not Stripe Connect ready/, 'the refusal is logged';
    is_deeply $result->{errors}, ['This payment cannot be taken right now. Nothing has been charged.'],
        'the parent is told nothing was charged';
    is $tdb->select( 'payments', ['id'], { user_id => $parent->id } )->rows, 0, 'no payment row in the tenant schema';
    is $db->select( 'registry.payments', ['id'], { user_id => $parent->id } )->rows, 0, 'nor in registry';
};

# ---------------------------------------------------------------------------
# 3. Ready tenant: the payment step makes one intent, a direct charge on the
#    tenant's account carrying the platform fee and the metadata the webhook reads.
# ---------------------------------------------------------------------------

$db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
                    stripe_details_submitted = TRUE WHERE slug = $2', 'acct_e2e', $slug );
my $STATED_RATE = '0.0137';
give_tenant_terms( $db, $slug, { rate => $STATED_RATE } );

my ( $captured_params, $captured_account );
my $captured_stripe_called = 0;
my $result;
{
    no warnings 'redefine';
    local *Registry::Service::Stripe::create_payment_intent_async = sub ( $self_stripe, $params ) {
        $captured_stripe_called++;
        ( $captured_params, $captured_account ) = ( $params, $self_stripe->stripe_account );
        return Mojo::Promise->resolve( { id => 'pi_e2e', client_secret => 'cs_e2e' } );
    };
    $result = settle( $step->process( $tdb, {}, $run ) );
}

subtest 'ready tenant: payment step passes gate and creates payment' => sub {
    ok !$result->{errors}, 'no gate error when tenant is Stripe Connect ready' or diag explain $result->{errors};
    is $captured_stripe_called, 1, 'Stripe create_payment_intent_async was called exactly once';
    is $tdb->select( 'payments', ['id'], { user_id => $parent->id } )->rows, 1, 'exactly one payment row in the tenant schema';
    ok !$db->select( 'registry.payments', ['id'], { user_id => $parent->id } )->hash, 'payment row NOT present in registry schema';
};

subtest 'paid checkout is a direct charge on the tenant account' => sub {
    is $captured_account, 'acct_e2e', 'the intent is created by a client bound to the tenant account';
    ok !exists $captured_params->{'transfer_data[destination]'}, 'no transfer_data[destination]';
    ok !exists $captured_params->{'on_behalf_of'}, 'no on_behalf_of';
};

subtest 'Stripe params carry the platform fee and metadata keys' => sub {
    is $captured_params->{amount}, $PRICE_CENTS, "the amount is the cart's one charge";
    # The amount from the fixture, the rate as this test stated it: neither is
    # read back through the resolver, so a bug there cannot move both sides together.
    my $expected_fee = Registry::DAO::Payment::application_fee_cents( $PRICE_CENTS, $STATED_RATE );
    cmp_ok $expected_fee, '>', 0, 'the tenant carries a chargeable rate, not the Free-plan zero';
    is $captured_params->{application_fee_amount}, $expected_fee, "application_fee_amount is the tenant's stated rate";
    ok exists $captured_params->{'metadata[payment_id]'}, 'metadata[payment_id] bracket key present';
    is $captured_params->{'metadata[tenant_slug]'}, $slug, 'metadata[tenant_slug] names the tenant';
};

# ---------------------------------------------------------------------------
# 4. The webhook Stripe sends for that intent, built from the params sent,
#    completes the payment and, through the run's driver, the booking, all in
#    the tenant schema.
# ---------------------------------------------------------------------------

my $payment_id = $captured_params->{'metadata[payment_id]'};
my $payment    = Registry::DAO::Payment->find( $tdb, { id => $payment_id } );

sub entitlements () { $tdb->select( 'entitlements', '*', { payment_id => $payment_id } )->hashes }

subtest 'webhook completes the payment and books the child in the tenant schema' => sub {
    post_succeeded( $t, $payment, 'acct_e2e' )->status_is(200);
    drive( $t->app->minion );

    is Registry::DAO::Payment->find( $tdb, { id => $payment_id } )->status, 'completed', 'payment status is completed';
    my $es = entitlements();
    is scalar @$es, 1, 'exactly one entitlement in the tenant schema';
    is $es->[0]{holder_family_member_id}, $child->id, 'held by the child';
    is $es->[0]{payer_user_id}, $parent->id, 'paid by the parent';
    is $es->[0]{state}, 'active', 'active';
    ok !$db->select( 'registry.entitlements', ['id'], { payment_id => $payment_id } )->hash,
        'no entitlement in the registry schema';
};

subtest 'completion is idempotent: a second delivery and drive yield exactly one entitlement' => sub {
    post_succeeded( $t, $payment, 'acct_e2e' )->status_is(200);
    drive( $t->app->minion );
    is scalar @{ entitlements() }, 1, 'still exactly one entitlement';
};

$test_db->cleanup_test_database;
done_testing;
