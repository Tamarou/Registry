#!/usr/bin/env perl
# ABOUTME: The instalment schedule Registry builds is one the real Stripe API accepts.
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

my $stripe = Registry::Service::Stripe->from_env;

my @schedules;
my @customers;
END {
    local $?;
    my $s = eval { Registry::Service::Stripe->from_env } or return;

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

# A connected account Stripe has approved, so a destination charge against it is
# something the API will actually accept rather than refuse for capabilities.
my $acct = Test::Registry::StripeConnect::ready_account();
like $acct, qr/^acct_/, "a charges_enabled connected account ($acct)";

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
# One product per thing being sold. It lives on the PLATFORM account -- the
# schedule is ours, with the charges destined for the tenant -- so this is our
# clutter, not theirs.
my $product = $stripe->_await( $stripe->create_product_async({
    name                => 'Summer Camp',
    'metadata[purpose]' => 'registry-test-suite',
}) );
like $product->{id}, qr/^prod_/, 'a product for the session being sold';

subtest 'Stripe accepts the schedule for the instalments still to come' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product           => $product->{id},
        customer          => $customer->{id},
        payment_method    => $pm->{id},
        connect_account   => $acct,
        revenue_share_pct => 2.5,
        currency          => 'usd',
        description       => 'Summer Camp',
        instalments       => [
            { amount_cents => 3333, due_date => '2027-07-01' },
            { amount_cents => 3334, due_date => '2027-08-01' },
        ],
    });

    my $schedule = eval { $stripe->create_subscription_schedule($params) };
    ok $schedule, 'the schedule was created' or do { diag $@; return };
    like $schedule->{id}, qr/^sub_sched_/, 'and Stripe gave it an id';
    push @schedules, $schedule->{id};

    is $schedule->{end_behavior}, 'cancel',
        'it ends after the instalments rather than renewing';

    my $phases = $schedule->{phases} // [];
    is scalar(@$phases), 2, 'both phases survived the round trip'
        or diag explain $phases;

    # What the money does, read back from Stripe rather than from our own hash.
    is $schedule->{default_settings}{transfer_data}{destination}, $acct,
        'each charge settles in the tenant account';
    is $schedule->{default_settings}{application_fee_percent} + 0, 2.5,
        'and our revenue share is the application fee';

    # The amounts, as Stripe stored them.
    my @amounts = map { $_->{items}[0]{price} } @$phases;
    my @unit = map {
        $stripe->_await( $stripe->retrieve_price_async($_) )->{unit_amount}
    } @amounts;
    is_deeply \@unit, [ 3333, 3334 ],
        'the even share and the remainder, in that order';
};

done_testing;
