#!/usr/bin/env perl
# ABOUTME: Pins the application_fee_percent precision Stripe accepts on a subscription schedule, and that keyed creates repeat.
# ABOUTME: Requires STRIPE_SECRET_KEY (sk_test_); skips without one and refuses a live key.
#
# RESULT: 2026-11-23, Stripe API 2024-12-18.acacia, test mode, on the key's own (platform) account
# named in a Stripe-Account header: default_settings[application_fee_percent] = 2.875 is REFUSED with
# "Invalid decimal: 2.875; must contain at maximum two decimal places." 2.5 and 2.88 pass that check
# and are refused only because a fee needs a payment on behalf of ANOTHER account ("You can only apply
# `default_settings[application_fee_percent]` when the request is attempting a direct payment on
# behalf of another account ... or destination payment"). So Stripe takes at most two decimals.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;
use Registry::Service::Stripe;
use Registry::DAO::Payment;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

# from_env refuses an sk_live_ key outside production; available() already
# refused anything that is not sk_test_.
my $platform = Registry::Service::Stripe->from_env;
my $acct = $platform->_await( $platform->_request_async( GET => 'account' ) )->{id};
BAIL_OUT('could not read the key\'s own account') unless $acct;
my $stripe = $platform->for_account($acct);

my ( @schedules, @customers );
END {
    local $?;
    return unless $stripe;
    for my $id (@schedules) {
        eval { $stripe->cancel_subscription_schedule($id); 1 }
            or warn "# could not cancel $id: $@";
    }
    for my $id (@customers) {
        eval { $stripe->_await( $stripe->delete_customer_async($id) ); 1 }
            or warn "# could not delete $id: $@";
    }
}

my $customer = $stripe->create_customer( {
    payment_method                             => 'pm_card_visa',
    'invoice_settings[default_payment_method]' => 'pm_card_visa',
    'metadata[purpose]'                        => 'registry-test-suite',
} );
push @customers, $customer->{id};
my $card = $stripe->_await( $stripe->list_customer_payment_methods_async( $customer->{id} ) )
    ->{data}[0]{id};

# One run per test process, so a key from an earlier run cannot answer for this one.
my $run = "fee-precision-$$-" . time;

my $product = $stripe->create_product( {
    name                => 'Fee precision probe',
    'metadata[purpose]' => 'registry-test-suite',
    _idempotency_key    => "$run:product",
} );
like $product->{id}, qr/^prod_/, 'a product for the schedule';

sub schedule_params ( $pct ) {
    return Registry::DAO::Payment::instalment_schedule_params( {
        customer          => $customer->{id},
        payment_method    => $card,
        revenue_share_pct => $pct,
        currency          => 'usd',
        product           => $product->{id},
        cadence           => 'monthly',
        entitlement_id    => '00000000-0000-4000-8000-0000000000f1',
        instalments       => [ { amount_cents => 3333, due_date => '2027-07-01' } ],
    } );
}

# The error Stripe gives a schedule with this fee, or '' when it makes one.
sub refusal_for ( $params ) {
    my $schedule = eval { $stripe->create_subscription_schedule($params) };
    if ($schedule) { push @schedules, $schedule->{id}; return '' }
    return $@;
}

subtest 'stripe refuses a fee percent with three decimals' => sub {
    my $params = schedule_params(1);
    $params->{'default_settings[application_fee_percent]'} = '2.875';
    like refusal_for($params), qr/at maximum two decimal places/,
        '2.875 is refused for its precision';
};

subtest 'stripe accepts the precision of a two decimal fee percent' => sub {
    for my $pct ( '2.5', '2.88' ) {
        my $params = schedule_params(1);
        $params->{'default_settings[application_fee_percent]'} = $pct;
        unlike refusal_for($params), qr/decimal/, "$pct passes the precision check";
    }
};

subtest 'the formatter sends a precision stripe accepts' => sub {
    my $params = schedule_params(2.875);
    unlike refusal_for($params), qr/decimal/,
        "a 2.875% plan is sent as $params->{'default_settings[application_fee_percent]'}";
};

subtest 'a repeated keyed schedule create makes one schedule' => sub {
    my $params = schedule_params(0);
    $params->{_idempotency_key} = "$run:schedule";

    my $first = $stripe->create_subscription_schedule( {%$params} );
    push @schedules, $first->{id};
    my $again = $stripe->create_subscription_schedule( {%$params} );

    like $first->{id}, qr/^sub_sched_/, 'the first create makes a schedule';
    is $again->{id}, $first->{id}, 'and the retry gets the same one back';
    is $stripe->create_product( {
        name                => 'Fee precision probe',
        'metadata[purpose]' => 'registry-test-suite',
        _idempotency_key    => "$run:product",
    } )->{id}, $product->{id}, 'as does a retried product create';
};

done_testing;
