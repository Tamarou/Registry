#!/usr/bin/env perl
# ABOUTME: Pins what Stripe test mode does with a Stripe-Account header naming the API key's own (platform) account.
# ABOUTME: Decides whether the shared payment step must omit the header when the seller is the Connect platform.
#
# RESULT: 2026-11-23, Stripe API 2024-12-18.acacia, test mode: a Stripe-Account header naming the key's own
# (platform) account is ACCEPTED for POST payment_intents (confirmed, succeeded), POST customers and
# GET payment_intents/:id; the intent is retrievable without the header, so it is on the platform
# account. A header naming acct_doesnotexist is refused. No special case is needed for the platform.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::StripeConnect;

plan skip_all => 'STRIPE_SECRET_KEY (sk_test_) not set'
    unless Test::Registry::StripeConnect::available();

my $BASE    = 'https://api.stripe.com/v1';
my $VERSION = '2024-12-18.acacia';    # Service/Stripe.pm's pinned API version

sub call ( $method, $path, %opt ) {
    my $key = Test::Registry::StripeConnect::_key();    # dies unless sk_test_
    my %h   = ( Authorization => "Bearer $key", 'Stripe-Version' => $VERSION );
    $h{'Stripe-Account'} = $opt{account} if $opt{account};
    my $ua = Test::Registry::StripeConnect::_ua();
    my $tx = $method eq 'GET'
        ? $ua->get( "$BASE$path" => \%h )
        : $ua->post( "$BASE$path" => \%h => form => $opt{form} // {} );
    return ( $tx->res->code, $tx->res->json // {} );
}

my ( $code, $me ) = call( GET => '/account' );
my $platform = $me->{id};
BAIL_OUT("could not read the key's own account (HTTP $code)") unless $platform;
note "platform account: $platform";

my $intent_form = {
    amount                                       => 500,
    currency                                     => 'usd',
    payment_method                               => 'pm_card_visa',
    confirm                                      => 'true',
    'automatic_payment_methods[enabled]'         => 'true',
    'automatic_payment_methods[allow_redirects]' => 'never',
    'metadata[purpose]'                          => 'registry-test-suite',
};

my $own_intent;
subtest 'own account header outcome is pinned' => sub {
    my ( $pi_code, $pi ) = call( POST => '/payment_intents', account => $platform, form => $intent_form );
    note "payment_intents with own header: HTTP $pi_code " . ( $pi->{error} ? "$pi->{error}{type}/" . ( $pi->{error}{code} // '' ) . ": $pi->{error}{message}" : $pi->{status} );
    is $pi_code, 200, 'a payment intent naming the platform account is accepted';
    is $pi->{status}, 'succeeded', 'and the charge succeeds';
    $own_intent = $pi->{id};

    my ( $cu_code, $cu ) = call( POST => '/customers', account => $platform, form => { 'metadata[purpose]' => 'registry-test-suite' } );
    note "customers with own header: HTTP $cu_code " . ( $cu->{error} ? $cu->{error}{message} : $cu->{id} );
    is $cu_code, 200, 'a customer naming the platform account is accepted';

    my ( $get_code, $got ) = call( GET => "/payment_intents/$own_intent", account => $platform );
    is $get_code, 200, 'retrieving with the own-account header is accepted';
    is $got->{id}, $own_intent, 'and returns the same intent';
};

subtest 'own account intent is retrievable without header' => sub {
    my ( $get_code, $got ) = call( GET => "/payment_intents/$own_intent" );
    is $get_code, 200, 'retrievable with no Stripe-Account header';
    is $got->{id}, $own_intent, 'so it is on the platform account itself';
};

subtest 'nonexistent account header is refused by stripe' => sub {
    my ( $c, $r ) = call( POST => '/customers', account => 'acct_doesnotexist' );
    isnt $c, 200, 'a header naming no account is refused';
    is $r->{error} && $r->{error}{code}, 'account_invalid',
        'because of the account, so the header is checked rather than ignored';
};

subtest 'live key makes the probe refuse to run' => sub {
    local $ENV{STRIPE_SECRET_KEY} = 'sk' . '_live_' . 'x' x 24;
    my $sent = 0;
    my $ok = eval {
        no warnings 'redefine';
        local *Mojo::UserAgent::start = sub { $sent++; die "request sent\n" };
        call( GET => '/account' );
        1;
    };
    ok !$ok, 'the probe dies before calling Stripe';
    is $sent, 0, 'and no request was sent';
};

done_testing;
