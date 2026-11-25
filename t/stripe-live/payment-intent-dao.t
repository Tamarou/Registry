#!/usr/bin/env perl
# ABOUTME: Gated real-Stripe test of Payment's own create_payment_intent and process_payment, on a seller account.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_); skips entirely without one. Moved here from t/dao/payments.t.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw( give_tenant_terms );

use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Registry::DAO::Payment;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $slug  = "pay_dao_live_$$";
my $admin = Registry::DAO::User->create( $db, {
    username => "pay_dao_admin_$$", email => "pay_dao_admin_$$\@test.example",
    name => 'Payment DAO Admin', user_type => 'admin' } );
Registry::DAO::Tenant->provision( $db, { name => "Payment DAO $$", slug => $slug, users => [$admin] } );
my $tdb = $dao->connect_schema($slug)->db;

note 'Waiting for charges_enabled on ready Stripe test account (up to 180s)...';
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, 'ready account id obtained';
$db->query(
    'UPDATE registry.tenants SET stripe_connect_account_id = $1, stripe_charges_enabled = TRUE,
            stripe_details_submitted = TRUE WHERE slug = $2', $acct, $slug );
give_tenant_terms( $db, $slug, { rate => '0.025' } );

my $user = Registry::DAO::User->create( $tdb, {
    username => "pay_dao_parent_$$", email => "pay_dao_parent_$$\@test.example",
    name => 'Payment DAO Parent', user_type => 'parent' } );

# Payment->create seeds a fresh idempotency token per row, so each run's
# intent is created under its own key.
sub seller_payment ($amount_cents) {
    return Registry::DAO::Payment->create( $tdb, {
        user_id => $user->id, amount_cents => $amount_cents,
        metadata => { tenant_slug => $slug } } );
}

subtest 'Create payment intent' => sub {
    my $payment = seller_payment(5000);

    my $intent_data = $payment->create_payment_intent( $tdb, {
        description   => 'Test Payment',
        receipt_email => $user->email,
    } );

    ok $intent_data->{client_secret}, 'Client secret returned';
    like $intent_data->{payment_intent_id}, qr/^pi_/, 'Payment intent ID returned';

    $payment = Registry::DAO::Payment->find( $tdb, { id => $payment->id } );
    is $payment->stripe_payment_intent_id, $intent_data->{payment_intent_id},
        'Intent ID saved to payment';
};

subtest 'Process payment with an intent Stripe does not know' => sub {
    my $payment = seller_payment(2500);

    my $result = $payment->process_payment( $tdb, "pi_does_not_exist_$$" );

    ok !$result->{success}, 'Invalid intent fails';
    like $result->{error}, qr/resource_missing|No such payment_intent/,
        'Stripe refused the intent, not some other failure';
    is $payment->status, 'failed', 'Payment status updated to failed';
};

done_testing;
