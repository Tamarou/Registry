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
use Registry::PriceOps::Instalments ();

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

# One product per thing being sold. It lives on the tenant's account, with
# the schedule that bills against it.
my $product = $stripe->_await( $stripe->create_product_async({
    name                => 'Summer Camp',
    'metadata[purpose]' => 'registry-test-suite',
}) );
like $product->{id}, qr/^prod_/, 'a product for the session being sold';

# Registry's request for a child's parts after the first, made on the
# tenant's account as schedule_instalments_for makes it: from the checkout
# date $first, with the entitlement it bills for. $parts defaults to $100 in
# $count on $cadence -- the uneven case, 33.33 / 33.33 / 33.34 for three.
my $ENTITLEMENT = '00000000-0000-4000-8000-0000000000e1';
sub made_schedule ( $cadence, $first, $count = 3, $parts = undef ) {
    $parts //= Registry::PriceOps::Instalments::parts( 10000,
        { count => $count, cadence => $cadence }, $first );
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product           => $product->{id},
        customer          => $customer->{id},
        payment_method    => $pm->{id},
        revenue_share_pct => 2.5,
        currency          => 'usd',
        description       => 'Summer Camp',
        cadence           => $cadence,
        entitlement_id    => $ENTITLEMENT,
        first_date        => $first,
        instalments       => [ @{$parts}[ 1 .. $#$parts ] ],
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

# Each phase's [ start, end ] as UTC dates, as Stripe worked them out: a
# phase's start is the day it charges.
sub ymd ($epoch) { my @t = gmtime $epoch; sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] }
sub phase_dates ( $schedule ) {
    return [ map { [ ymd( $_->{start_date} ), ymd( $_->{end_date} ) ] } @{ $schedule->{phases} // [] } ];
}

my $schedule;
subtest 'stripe accepts a weekly schedule on a connected account' => sub {
    $schedule = made_schedule( 'weekly', '2027-01-31' ) or return;

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
    is_deeply stored_prices($schedule), [ [ 0, 'week', 1 ], [ 3333, 'week', 1 ], [ 3334, 'week', 1 ] ],
        'a $0 week for the part paid at checkout, then the even share and the remainder, every week';
    is_deeply phase_dates($schedule),
        [ [qw( 2027-01-31 2027-02-07 )], [qw( 2027-02-07 2027-02-14 )], [qw( 2027-02-14 2027-02-21 )] ],
        'charging on the stored due dates';
};

subtest 'stripe accepts a quarterly schedule on a connected account' => sub {
    my $quarterly = made_schedule( 'quarterly', '2027-01-31' ) or return;
    is_deeply stored_prices($quarterly), [ [ 0, 'month', 3 ], [ 3333, 'month', 3 ], [ 3334, 'month', 3 ] ],
        'billed every three months, not every month';
    is_deeply phase_dates($quarterly),
        [ [qw( 2027-01-31 2027-04-30 )], [qw( 2027-04-30 2027-07-31 )], [qw( 2027-07-31 2027-10-31 )] ],
        'on the stored due dates, back to the 31st after April 30';
};

# Distinct amounts, so each part is its own phase and every charge date shows.
subtest 'stripe charges month-end instalments on their stored due dates' => sub {
    my $monthly = made_schedule( 'monthly', '2027-01-31', 4, [
        { amount_cents => 2999, due_date => '2027-01-31' },
        { amount_cents => 3000, due_date => '2027-02-28' },
        { amount_cents => 3001, due_date => '2027-03-31' },
        { amount_cents => 3002, due_date => '2027-04-30' },
    ] ) or return;
    is_deeply phase_dates($monthly), [
        [qw( 2027-01-31 2027-02-28 )], [qw( 2027-02-28 2027-03-31 )],
        [qw( 2027-03-31 2027-04-30 )], [qw( 2027-04-30 2027-05-31 )],
    ], 'Feb 28, Mar 31 and Apr 30, as Instalments::due_dates has them';
};

# The job runs after checkout, so the checkout date's noon is often already
# past: the schedule is backdated into its $0 period.
subtest 'stripe accepts a schedule backdated to the checkout date' => sub {
    my $first = ymd( time - 86400 );
    my $parts = Registry::PriceOps::Instalments::parts( 10000, { count => 3, cadence => 'weekly' }, $first );
    my $backdated = made_schedule( 'weekly', $first, 3, $parts ) or return;
    is_deeply [ map { $_->[0] } @{ phase_dates($backdated) } ], [ map { $_->{due_date} } @$parts ],
        'each phase still starts on its stored due date';
};

subtest 'stripe accepts fifty-two weekly parts' => sub {
    my $first = '2027-01-31';
    my $parts = Registry::PriceOps::Instalments::parts( 5200, { count => 52, cadence => 'weekly' }, $first );
    my $weekly = made_schedule( 'weekly', $first, 52, $parts ) or return;
    is scalar @{ $weekly->{phases} }, 2, 'in two phases: the $0 week and fifty-one equal parts';
    is_deeply phase_dates($weekly)->[1],
        [ $parts->[1]{due_date}, ymd( Registry::DAO::Payment::_epoch_for_date( $parts->[-1]{due_date} ) + 7 * 86400 ) ],
        'from the second due date to a week after the last';
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

# A studio can release Registry's schedule in its dashboard; the subscription
# it lets go of bills on alone, so Registry cancels that subscription as
# Payment::_cancel_released asks.
subtest 'stripe cancels the subscription a released schedule let go of' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params({
        product => $product->{id}, customer => $customer->{id}, payment_method => $pm->{id},
        revenue_share_pct => 2.5, currency => 'usd', description => 'Summer Camp',
        cadence => 'monthly', entitlement_id => $ENTITLEMENT,
        instalments => [ { amount_cents => 3333, due_date => '2027-07-01' } ],
    });
    $params->{start_date} = 'now';    # so there is a subscription to release
    my $made = eval { $stripe->create_subscription_schedule($params) };
    ok $made, 'a started schedule' or do { diag $@; return };
    push @schedules, $made->{id};

    my $released = $stripe->_await( $stripe->_request_async( 'POST', "subscription_schedules/$made->{id}/release" ) );
    is $released->{status}, 'released', 'released, as a studio could';
    @schedules = grep { $_ ne $made->{id} } @schedules;    # a released schedule cannot be cancelled
    my $sub = $released->{released_subscription};
    like $sub, qr/^sub_/, 'letting go of its subscription';

    my $key = "cancel_subscription:$ENTITLEMENT:$$:" . time;
    my $cancelled = $stripe->cancel_subscription( $sub, { _idempotency_key => $key } );
    is $cancelled->{status}, 'canceled', 'the cancel Registry sends is accepted';
    is $stripe->cancel_subscription( $sub, { _idempotency_key => $key } )->{status}, 'canceled',
        'and a retry under the same key answers the same';
};

subtest 'schedule is not on the platform account' => sub {
    my $id = $schedule && $schedule->{id}
        or plan skip_all => 'no schedule was created';
    ok !eval { $platform->retrieve_subscription_schedule($id); 1 },
        'the platform account, with no Stripe-Account, does not find it';
    like $@, qr/No such subscription schedule.*resource_missing/, 'because it does not exist there';
};

done_testing;
