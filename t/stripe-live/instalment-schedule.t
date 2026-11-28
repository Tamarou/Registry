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
my @clocks;
END {
    local $?;
    my $s = $stripe or return;

    # Deleting a test clock deletes its customers and their schedules.
    for my $id (@clocks) {
        eval { $s->_await( $s->_request_async( 'DELETE', "test_helpers/test_clocks/$id" ) ); 1 }
            or warn "# could not delete $id: $@";
    }

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

sub api ( $method, $path, $params = {} ) { $stripe->_await( $stripe->_request_async( $method, $path, $params ) ) }
sub noon ($ymd) { Registry::DAO::Payment::_epoch_for_date($ymd) }
sub ymd ($epoch) { my @t = gmtime $epoch; sprintf '%04d-%02d-%02d', $t[5] + 1900, $t[4] + 1, $t[3] }

# A customer with a saved card on a test clock frozen at $at, on the tenant's
# account, so Stripe's own billing can be run forward to each due date.
sub clocked_customer ($at) {
    my $clock = api( POST => 'test_helpers/test_clocks', { frozen_time => $at, name => 'registry instalments' } );
    push @clocks, $clock->{id};
    my $cus = $stripe->create_customer( { test_clock => $clock->{id}, 'metadata[purpose]' => 'registry-test-suite' } );
    my $card = api( POST => 'payment_methods', { type => 'card', 'card[token]' => 'tok_visa' } );
    api( POST => "payment_methods/$card->{id}/attach", { customer => $cus->{id} } );
    return ( $clock, $cus->{id}, $card->{id} );
}

sub advance ( $clock, $to ) {
    api( POST => "test_helpers/test_clocks/$clock->{id}/advance", { frozen_time => $to } );
    for ( 1 .. 120 ) {
        return if api( GET => "test_helpers/test_clocks/$clock->{id}" )->{status} eq 'ready';
        sleep 2;
    }
    die "test clock $clock->{id} did not reach " . ymd($to) . "\n";
}

# Registry's schedule for a child's $100 in $count on $cadence, made at 13:00
# UTC on the checkout date $first as schedule_instalments_for makes it, then
# run by a test clock past each later due date. Returns the schedule and,
# for each invoice Stripe raised other than the $0 opening one, [ its date,
# its subtotal, how many proration lines it has ].
my $ENTITLEMENT = '00000000-0000-4000-8000-0000000000e1';
my $last_customer;
sub billed ( $cadence, $first, $count = 3, $past_the_end = 0 ) {
    my $parts = Registry::PriceOps::Instalments::parts( 10000, { count => $count, cadence => $cadence }, $first );
    my $start = Registry::DAO::Payment::instalment_schedule_start( $cadence, $parts, $first );
    my ( $clock, $cus, $card ) = clocked_customer( noon($first) + 3600 );
    my $made = $stripe->create_subscription_schedule( Registry::DAO::Payment::instalment_schedule_params( {
        product => $product->{id}, customer => $cus, payment_method => $card,
        revenue_share_pct => 2.5, currency => 'usd', description => 'Summer Camp',
        cadence => $cadence, entitlement_id => $ENTITLEMENT, start => $start,
        instalments => [ @{$parts}[ 1 .. $#$parts ] ],
    } ) );
    advance( $clock, noon( $_->{due_date} ) + 2 * 3600 ) for @{$parts}[ 1 .. $#$parts ];
    # One more period on, where a schedule that had not ended would bill again.
    advance( $clock, noon( Registry::PriceOps::Instalments::due_dates(
        { count => $count + 1, cadence => $cadence }, $first )->[-1] ) + 2 * 3600 ) if $past_the_end;

    my $sub = $stripe->retrieve_subscription_schedule( $made->{id} )->{subscription};
    $sub = $sub->{id} if ref $sub;
    my $invoices = $stripe->list_invoices( { subscription => $sub, limit => 100 } )->{data} // [];
    $last_customer = $cus;
    return ( $made, $parts, [ map { [ ymd( $_->{created} ), $_->{subtotal},
                  scalar grep { $_->{proration} } @{ $_->{lines}{data} // [] } ] }
        sort { $a->{created} <=> $b->{created} }
        grep { !Registry::DAO::Payment::is_opening_invoice($_) } @$invoices ] );
}

# What the family was shown: each later part's due date and amount, unprorated.
sub shown ($parts) { [ map { [ $_->{due_date}, $_->{amount_cents}, 0 ] } @{$parts}[ 1 .. $#$parts ] ] }

# Each phase's price, as Stripe stored it: [ unit_amount, interval, interval_count ].
sub stored_prices ( $schedule ) {
    return [ map {
        my $price = $stripe->_await( $stripe->retrieve_price_async( $_->{items}[0]{price} ) );
        [ $price->{unit_amount}, $price->{recurring}{interval}, $price->{recurring}{interval_count} ]
    } @{ $schedule->{phases} // [] } ];
}

my $schedule;
subtest 'stripe accepts a weekly schedule on a connected account' => sub {
    my ( $made, $parts, $charged ) = eval { billed( weekly => '2027-01-31' ) };
    ok $made, 'the weekly schedule was created and run' or do { diag $@; return };
    $schedule = $made;

    is $made->{end_behavior}, 'cancel', 'it ends after the instalments rather than renewing';
    is $made->{metadata}{entitlement_id}, $ENTITLEMENT, "it names the child's entitlement";
    ok !$made->{default_settings}{transfer_data}, "with no transfer: each charge is already the tenant's";
    is $made->{default_settings}{application_fee_percent} + 0, 2.5, 'and our revenue share is the application fee';
    is_deeply stored_prices($made), [ [ 3333, 'week', 1 ], [ 3334, 'week', 1 ] ],
        'the even share and the remainder, every week';
    is_deeply $charged, shown($parts), 'Stripe charged each part on its stored due date, unprorated';
};

subtest 'stripe accepts a quarterly schedule on a connected account' => sub {
    my ( $made, $parts, $charged ) = eval { billed( quarterly => '2027-01-31' ) };
    ok $made, 'the quarterly schedule was created and run' or do { diag $@; return };
    is_deeply stored_prices($made), [ [ 0, 'month', 3 ], [ 3333, 'month', 3 ], [ 3334, 'month', 3 ] ],
        'a $0 opening quarter, then every three months, not every month';
    is_deeply $charged, shown($parts), 'charged Apr 30 and Jul 31, as Instalments::due_dates has them';
};

subtest 'stripe charges month-end instalments on their stored due dates' => sub {
    my ( $made, $parts, $charged ) = eval { billed( monthly => '2027-01-31', 4 ) };
    ok $made, 'started on the checkout date' or do { diag $@; return };
    is_deeply $charged, shown($parts), 'Feb 28, Mar 31 and Apr 30, unprorated';
};

# $100 in three is 33.33, 33.33, 33.34: a phase change before the last part.
subtest 'a month-end schedule bills nothing more after its last part' => sub {
    my ( $made, $parts, $charged ) = eval { billed( monthly => '2027-01-31', 3, 1 ) };
    ok $made, 'run a month past its last due date' or do { diag $@; return };
    is_deeply $charged, shown($parts), 'Feb 28 and Mar 31 only, unprorated: no invoice on Apr 30';
    is $stripe->retrieve_subscription_schedule( $made->{id} )->{status}, 'completed', 'the schedule completed';
    is $stripe->_await( $stripe->retrieve_customer_async($last_customer) )->{balance}, 0,
        'and left the family no credit or debit balance';
};

subtest 'stripe charges a mid-month plan from part two on its stored due dates' => sub {
    my ( $made, $parts, $charged ) = eval { billed( monthly => '2027-01-15' ) };
    ok $made, 'started on part two' or do { diag $@; return };
    is_deeply $charged, shown($parts), 'Feb 15 and Mar 15, unprorated';
};

subtest 'stripe accepts fifty-two weekly parts' => sub {
    my $first = '2027-01-31';
    my $parts = Registry::PriceOps::Instalments::parts( 5200, { count => 52, cadence => 'weekly' }, $first );
    my $made = eval { $stripe->create_subscription_schedule( Registry::DAO::Payment::instalment_schedule_params( {
        product => $product->{id}, customer => $customer->{id}, payment_method => $pm->{id},
        revenue_share_pct => 2.5, currency => 'usd', cadence => 'weekly', entitlement_id => $ENTITLEMENT,
        start => Registry::DAO::Payment::instalment_schedule_start( weekly => $parts, $first ),
        instalments => [ @{$parts}[ 1 .. $#$parts ] ],
    } ) ) };
    ok $made, 'it was created' or do { diag $@; return };
    push @schedules, $made->{id};
    is scalar @{ $made->{phases} }, 1, 'in one phase of fifty-one equal parts';
    is_deeply [ map { ymd($_) } @{ $made->{phases}[0] }{qw( start_date end_date )} ],
        [ $parts->[1]{due_date}, ymd( noon( $parts->[-1]{due_date} ) + 7 * 86400 ) ],
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
        Registry::DAO::Payment::instalment_cancel_params( $ENTITLEMENT, $id ) );
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
