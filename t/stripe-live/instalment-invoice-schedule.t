#!/usr/bin/env perl
# ABOUTME: An instalment invoice from a Registry-made schedule leads back to that schedule through its subscription.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_); skips entirely without one.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(signatures);
use Test::More;
use Test::Registry::StripeConnect;
use Registry::Service::Stripe;
use Registry::DAO::Payment;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# Set once the tenant account exists; cleanup acts on that account.
my $stripe;
my @schedules;
my @customers;
END {
    local $?;
    my $s = $stripe or return;

    # Schedules first: a customer with a live schedule cannot be deleted.
    for my $id (@schedules) {
        eval { $s->cancel_subscription_schedule($id); 1 }
            or warn "# could not cancel $id: $@";
    }
    for my $id (@customers) {
        eval { $s->_await( $s->delete_customer_async($id) ); 1 }
            or warn "# could not delete $id: $@";
    }
}

# The webhook reads the subscription on event.account, so everything lives on
# a connected account, as production's seller-bound client puts it there.
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, "a charges_enabled connected account ($acct)";
$stripe = Registry::Service::Stripe->from_env->for_account($acct);

my $customer = $stripe->create_customer({
    email               => 'instalments@tamarou.com',
    'metadata[purpose]' => 'registry-test-suite',
});
push @customers, $customer->{id};

my $pm = $stripe->_await( $stripe->create_payment_method_async({
    type => 'card', 'card[token]' => 'tok_visa' }) );
$stripe->_await( $stripe->attach_payment_method_async( $pm->{id}, $customer->{id} ) );

my $product = $stripe->_await( $stripe->create_product_async({
    name => 'Summer Camp', 'metadata[purpose]' => 'registry-test-suite' }) );

subtest "an invoice's subscription names the schedule Registry stored" => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product           => $product->{id},
        customer          => $customer->{id},
        payment_method    => $pm->{id},
        revenue_share_pct => 2.5,
        currency          => 'usd',
        description       => 'Summer Camp',
        instalments       => [
            { amount_cents => 3333, due_date => '2027-07-01' },
            { amount_cents => 3334, due_date => '2027-08-01' },
        ],
    });
    # Starting now, so Stripe makes the subscription and its first invoice at
    # once rather than on a due date months away.
    $params->{start_date} = 'now';

    my $schedule = eval { $stripe->create_subscription_schedule($params) };
    ok $schedule, 'the schedule was created' or do { diag $@; return };
    push @schedules, $schedule->{id};

    my $sub_id = $schedule->{subscription};
    like $sub_id, qr/^sub_/, 'and it has a subscription';

    # What the Connect webhook does with an invoice: read its subscription on
    # the account and take the schedule Stripe set there.
    my $subscription = $stripe->retrieve_subscription($sub_id);
    is $subscription->{schedule}, $schedule->{id},
        'the subscription names the schedule id Registry stores';

    my $invoice = $stripe->_await( $stripe->retrieve_invoice_async( $subscription->{latest_invoice} ) );
    is $invoice->{subscription}, $sub_id, "and the invoice's subscription is that subscription";
    ok !exists $invoice->{schedule} && !exists $invoice->{subscription_schedule},
        'while the invoice itself carries no schedule field';
    is $invoice->{billing_reason}, 'subscription_create',
        'and its billing_reason is one the Connect webhook accepts as an instalment';
};

done_testing;
