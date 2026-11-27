#!/usr/bin/env perl
# ABOUTME: The instalment schedule Registry builds is one the real Stripe API accepts, on the tenant's account.
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

my $platform = Registry::Service::Stripe->from_env;

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
    warn "# instalment-schedule cleanup: cancelled ("
       . join( ', ', @schedules ) . "), deleted (" . join( ', ', @customers ) . ")\n"
        if @schedules || @customers;

    # The product is left behind on purpose: Stripe refuses to delete a product
    # that has prices, and the schedule created two. It is inert.
}

# A connected account Stripe has approved, so a direct charge on it is
# something the API will actually accept rather than refuse for capabilities.
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, "a charges_enabled connected account ($acct)";

# Everything below lives on the tenant's account, as production's
# seller-bound client (Payment::stripe_client) puts it there.
$stripe = $platform->for_account($acct);

# A customer with a saved card, which is what instalments two and three are
# charged against once nobody is present to approve them.
my $customer = $stripe->create_customer({
    email       => 'instalments@tamarou.com',
    'metadata[purpose]' => 'registry-test-suite',
});
like $customer->{id}, qr/^cus_/, 'a customer to bill';
push @customers, $customer->{id};

my $pm = $stripe->_await( $stripe->create_payment_method_async({
    type            => 'card',
    'card[token]'   => 'tok_visa',
}) );
like $pm->{id}, qr/^pm_/, 'and a card';
$stripe->_await( $stripe->attach_payment_method_async( $pm->{id}, $customer->{id} ) );

# The uneven case on purpose: $100 in three is 33.33 / 33.33 / 33.34, so the
# schedule has to carry two phases. Instalment one is taken at checkout, so what
# a schedule covers is the remaining two.
# One product per thing being sold. It lives on the tenant's account, with
# the schedule that bills against it.
my $product = $stripe->_await( $stripe->create_product_async({
    name                => 'Summer Camp',
    'metadata[purpose]' => 'registry-test-suite',
}) );
like $product->{id}, qr/^prod_/, 'a product for the session being sold';

# Registry's request for a child's parts two and three on $cadence, made on
# the tenant's account, with the entitlement it bills for.
my $ENTITLEMENT = '00000000-0000-4000-8000-0000000000e1';
sub made_schedule ( $cadence ) {
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product           => $product->{id},
        customer          => $customer->{id},
        payment_method    => $pm->{id},
        revenue_share_pct => 2.5,
        currency          => 'usd',
        description       => 'Summer Camp',
        cadence           => $cadence,
        entitlement_id    => $ENTITLEMENT,
        instalments       => [
            { amount_cents => 3333, due_date => '2027-07-01' },
            { amount_cents => 3334, due_date => '2027-08-01' },
        ],
    });
    my $schedule = eval { $stripe->create_subscription_schedule($params) };
    ok $schedule, "the $cadence schedule was created" or do { diag $@; return };
    like $schedule->{id}, qr/^sub_sched_/, 'and Stripe gave it an id';
    push @schedules, $schedule->{id};
    return $schedule;
}

# Each phase's price, as Stripe stored it: [ unit_amount, interval, interval_count ].
sub stored_prices ( $schedule ) {
    return [ map {
        my $price = $stripe->_await( $stripe->retrieve_price_async( $_->{items}[0]{price} ) );
        [ $price->{unit_amount}, $price->{recurring}{interval}, $price->{recurring}{interval_count} ]
    } @{ $schedule->{phases} // [] } ];
}

my $schedule;
subtest 'stripe accepts a weekly schedule on a connected account' => sub {
    $schedule = made_schedule('weekly') or return;

    is $schedule->{end_behavior}, 'cancel',
        'it ends after the instalments rather than renewing';
    is $schedule->{metadata}{entitlement_id}, $ENTITLEMENT, "it names the child's entitlement";

    # What the money does, read back from Stripe rather than from our own hash.
    is $stripe->retrieve_subscription_schedule( $schedule->{id} )->{id}, $schedule->{id},
        'it is found on the tenant account';
    ok !$schedule->{default_settings}{transfer_data},
        'with no transfer: each charge is already the tenant\'s';
    is $schedule->{default_settings}{application_fee_percent} + 0, 2.5,
        'and our revenue share is the application fee';
    is_deeply stored_prices($schedule), [ [ 3333, 'week', 1 ], [ 3334, 'week', 1 ] ],
        'the even share and the remainder, in that order, every week';
};

subtest 'stripe accepts a quarterly schedule on a connected account' => sub {
    my $quarterly = made_schedule('quarterly') or return;
    is_deeply stored_prices($quarterly), [ [ 3333, 'month', 3 ], [ 3334, 'month', 3 ] ],
        'billed every three months, not every month';
};

subtest 'stripe updates and then cancels a schedule as Registry asks' => sub {
    my $id = $schedule && $schedule->{id}
        or plan skip_all => 'no schedule was created';
    my $updated = $stripe->_await( $stripe->update_subscription_schedule_async( $id,
        { 'metadata[purpose]' => 'registry-test-suite' } ) );
    is $updated->{metadata}{purpose}, 'registry-test-suite', 'an update is accepted';
    is $updated->{metadata}{entitlement_id}, $ENTITLEMENT, 'and keeps the entitlement';

    my $cancelled = $stripe->cancel_subscription_schedule( $id,
        Registry::DAO::Payment::instalment_cancel_params($ENTITLEMENT) );
    is $cancelled->{status}, 'canceled', 'the cancel Registry sends is accepted';
    @schedules = grep { $_ ne $id } @schedules;    # cleanup has nothing left to cancel
};

subtest 'schedule is not on the platform account' => sub {
    my $id = $schedule && $schedule->{id}
        or plan skip_all => 'no schedule was created';
    ok !eval { $platform->retrieve_subscription_schedule($id); 1 },
        'the platform account, with no Stripe-Account, does not find it';
    like $@, qr/No such subscription schedule.*resource_missing/, 'because it does not exist there';
};

done_testing;
