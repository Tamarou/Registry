#!/usr/bin/env perl
# ABOUTME: A refund on a direct charge is made on the seller's account and keeps the platform fee.
# ABOUTME: Pins that refund_async sends neither reverse_transfer nor refund_application_fee, for any seller.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Async qw( settle );
use Test::Registry::PricingProbe qw(solo_linked_tenant);
use Registry::DAO::Payment;
use Registry::Service::Stripe;  # load package before glob replacement
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;     # Mojo::Pg::Database

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_refund_tests';

# A tenant linked to the revenue-share plan, with a Connect account of its own.
my $tenant_slug = solo_linked_tenant($db);
$db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
    'acct_refund_tenant', $tenant_slug );

# The platform tenant sells like any other seller.
my $platform = Test::Registry::Fixtures::platform_seller($db);

my $user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('refund_fee_test', 'nohash')
    RETURNING id
})->hash->{id};

my $n = 0;
sub a_payment ( $slug, %over ) {
    $n++;
    return Registry::DAO::Payment->create( $db, {
        user_id                  => $user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => "pi_refund_fee_$n",
        metadata                 => { tenant_slug => $slug },
        %over,
    } );
}

# Stubs only the HTTP-facing call, recording the params and the account of the
# client that sent them. refund_async's own guards run for real.
sub capturing_stripe ( $calls, @replies ) {
    return sub ( $client, $params ) {
        push @$calls, { %$params, _account => $client->stripe_account };
        my $reply = shift(@replies) // { id => 're_' . scalar(@$calls), status => 'succeeded' };
        return ref $reply eq 'HASH' ? Mojo::Promise->resolve($reply) : Mojo::Promise->reject($reply);
    };
}

sub no_fee_or_transfer_flags ( $call, $label ) {
    ok !exists $call->{reverse_transfer},       "$label: no reverse_transfer";
    ok !exists $call->{refund_application_fee}, "$label: no refund_application_fee";
}

subtest 'tenant refund is sent on the tenant account without fee or transfer flags' => sub {
    my $payment = a_payment($tenant_slug);
    my @calls;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );
        settle( $payment->refund_async($db) );
    }

    is scalar @calls, 1, 'one refund request';
    is $calls[0]{_account}, 'acct_refund_tenant', 'sent by a client bound to the tenant account';
    no_fee_or_transfer_flags( $calls[0], 'tenant refund' );
    is $calls[0]{payment_intent}, $payment->stripe_payment_intent_id, 'against the payment intent';
    is $calls[0]{amount}, 10000, 'for the full amount';

    my $row = $db->select( 'payments', '*', { id => $payment->id } )->expand->hash;
    is $row->{status}, 'refunded', 'the refund is recorded';
};

subtest 'platform seller refund is sent on its account without fee or transfer flags' => sub {
    my $payment = a_payment($platform);
    my @calls;
    {
        no warnings 'redefine';
        local *Registry::Service::Stripe::create_refund_async = capturing_stripe( \@calls );
        settle( $payment->refund_async($db) );
    }

    is scalar @calls, 1, 'one refund request';
    is $calls[0]{_account}, 'acct_platform_test', 'sent by a client bound to the platform seller account';
    no_fee_or_transfer_flags( $calls[0], 'platform seller refund' );
};

done_testing;
