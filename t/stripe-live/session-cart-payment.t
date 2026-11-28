# ABOUTME: Gated real-Stripe proof that a session cart with an instalment child is one direct charge on the seller's account.
# ABOUTME: The charge carries the revenue-share fee and saves the card on the payer's customer there, for the later instalments.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::StripeConfirm;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );
use Test::Registry::Helpers qw( days_from_now );
use Test::Registry::Offers qw( instalment_plan );
use Test::Registry::Sessions qw( make_session session_offer held_cart );
use Test::Registry::Async qw( settle );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::FamilyMember;
use Registry::DAO::Payment;
use Registry::DAO::WorkflowRun;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "cart_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "cart_live_admin_$$", email => "cart_live_admin_$$\@test.example",
    name => 'Cart Live Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "Cart Live $$", slug => $slug, users => [$admin] } );
my $tdao = $dao->connect_schema($slug);
my $tdb  = $tdao->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $parent = Registry::DAO::User->create( $tdb, {
    username => "cart_live_parent_$$", email => "cart_live_parent_$$\@test.example",
    name => 'Cart Live Parent', user_type => 'parent' } );
my ( $kid, $sib ) = map {
    Registry::DAO::FamilyMember->create( $tdb, { family_id => $parent->id, child_name => $_, birth_date => '2016-01-01' } )
} qw( Kid Sib );

# Kid at $300 once, Sib at $270 in three weekly parts: $390 due today.
my $s = make_session( $tdb, days => [ map { days_from_now($_) } 30 .. 32 ] );
my $once  = session_offer( $tdb, $s, price_cents => 30000 );
my $parts = session_offer( $tdb, $s, price_cents => 27000,
    policies      => { refund => { kind => 'none' }, missed_payment => { kind => 'end' } },
    payment_plans => [ { id => 'pay', kind => 'one_time' }, instalment_plan( id => 'parts', count => 3, cadence => 'weekly' ) ] );
my ( $run, $pay ) = held_cart( $tdao, $parent->id,
    [ $kid->id, $s->id, $once->id, 'pay' ], [ $sib->id, $s->id, $parts->id, 'parts' ] );

sub payment_of_run () {
    my $id = Registry::DAO::WorkflowRun->find( $tdb, { id => $run->id } )->data->{owed_payment_id};
    return Registry::DAO::Payment->find( $tdb, { id => $id } );
}

subtest 'the cart is one charge that saves the card on the connected account' => sub {
    my $first = settle( $run->process( $tdb, $pay, {} ) );
    ok $first->{stay}, 'the step waits for the card';
    is $first->{template_data}{step_data}{stripe_account}, $acct, "for the seller's account";

    my $payment  = payment_of_run();
    my $intent   = $payment->stripe_payment_intent_id;
    my $customer = $payment->metadata->{stripe_customer_id};
    like $intent, qr/^pi_/, 'a real intent was created';
    like $customer, qr/^cus_/, "on a customer made for the payer";

    my $confirmed = Test::Registry::StripeConfirm::confirm( $intent, undef, $acct );
    is $confirmed->{status}, 'succeeded', 'Stripe takes the payment on the connected account';
    is $confirmed->{setup_future_usage}, 'off_session', 'and keeps the card for off-session charges';
    is $confirmed->{customer}, $customer, "on the payer's customer";
    is Test::Registry::StripeConfirm::payment_method( $confirmed->{payment_method}, $acct )->{customer}, $customer,
        'the card is saved to that customer, ready for the instalment schedule';

    settle( $run->process( $tdb, $pay, { payment_intent_id => $intent } ) );
    is payment_of_run()->status, 'completed', 'the return completes the payment';

    my $charge = Test::Registry::StripeConfirm::charge_for_settled( $intent, $acct );
    is $charge->{amount}, 39000, 'one charge for both first shares';
    is $charge->{application_fee_amount},
        Registry::DAO::Payment::application_fee_cents( 39000, platform_terms_for_tenant( $db, $slug )->{fraction} ),
        "with the tenant's revenue share of it";
    ok !$charge->{transfer_data}, 'a direct charge, with no transfer_data';
};

done_testing;
