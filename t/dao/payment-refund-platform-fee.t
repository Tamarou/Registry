#!/usr/bin/env perl
# ABOUTME: Returning the platform's fee on a payment, the exception to keeping it on a refund.
# ABOUTME: The fee is found on the seller's charge and refunded on the platform's own account.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Async qw( settle );
use Test::Registry::PricingProbe qw(solo_linked_tenant);
use Registry::DAO::Payment;
use Registry::Service::Stripe;  # load package before glob replacement
use Mojo::Promise;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;     # Mojo::Pg::Database

local $ENV{STRIPE_SECRET_KEY} = 'sk_test_fake_for_fee_refund_tests';

my $tenant_slug = solo_linked_tenant($db);
$db->query( 'UPDATE registry.tenants SET stripe_connect_account_id = ? WHERE slug = ?',
    'acct_fee_tenant', $tenant_slug );

my $user_id = $db->query(q{
    INSERT INTO registry.users (username, passhash)
    VALUES ('fee_refund_test', 'nohash')
    RETURNING id
})->hash->{id};

my $n = 0;
sub a_payment (%over) {
    $n++;
    return Registry::DAO::Payment->create( $db, {
        user_id                  => $user_id,
        amount_cents             => 10000,
        status                   => 'completed',
        stripe_payment_intent_id => "pi_fee_refund_$n",
        metadata                 => { tenant_slug => $tenant_slug },
        %over,
    } );
}

# Stubs only the HTTP-facing calls, recording each with the account of the
# client that made it. The Payment method's own logic runs for real.
# %reply overrides the charge (latest_charge), the fee, or makes a call reject.
sub with_stripe ( $calls, $code, %reply ) {
    my $record = sub ( $what, $client, @args ) {
        push @$calls, { call => $what, account => $client->stripe_account, args => \@args };
    };
    my $answer = sub ($value) {
        ref $value eq 'HASH' ? Mojo::Promise->resolve($value) : Mojo::Promise->reject($value);
    };
    no warnings 'redefine';
    local *Registry::Service::Stripe::retrieve_payment_intent_async = sub ( $client, @args ) {
        $record->( 'intent', $client, @args );
        return $answer->( exists $reply{intent} ? $reply{intent} : {
            id            => $args[0],
            latest_charge => $reply{charge} // {
                id => 'ch_fee', application_fee => 'fee_abc123', application_fee_amount => 250,
            },
        } );
    };
    local *Registry::Service::Stripe::retrieve_application_fee_async = sub ( $client, @args ) {
        $record->( 'fee', $client, @args );
        return $answer->( $reply{fee} // { id => $args[0], amount => 250, amount_refunded => 0 } );
    };
    local *Registry::Service::Stripe::create_application_fee_refund_async = sub ( $client, @args ) {
        $record->( 'refund', $client, @args );
        return $answer->( { id => 'fr_' . scalar(@$calls), amount => $args[1]{amount} } );
    };
    $code->();
}

sub calls_of ( $calls, $what ) { [ grep { $_->{call} eq $what } @$calls ] }

subtest 'fee is found on the seller charge and refunded on the platform' => sub {
    my $payment = a_payment();
    my @calls;
    with_stripe( \@calls, sub {
        settle( $payment->refund_platform_fee_async( $db,
            { amount_cents => 100, idempotency_key => 'fee-refund:1' } ) );
    } );

    my ($intent) = @{ calls_of( \@calls, 'intent' ) };
    is $intent->{account}, 'acct_fee_tenant', 'the charge is read on the seller account';
    is $intent->{args}[0], $payment->stripe_payment_intent_id, 'through the payment intent';
    is_deeply $intent->{args}[1], { 'expand[]' => 'latest_charge' }, 'with its charge expanded';

    my $refunds = calls_of( \@calls, 'refund' );
    is scalar @$refunds, 1, 'one fee refund request';
    is $refunds->[0]{account}, undef, 'made by the platform, on no connected account';
    is $refunds->[0]{args}[0], 'fee_abc123', 'for the charge application fee';
    is $refunds->[0]{args}[1]{amount}, 100, 'for the given amount';
    is $refunds->[0]{args}[1]{_idempotency_key}, 'fee-refund:1', 'with the given idempotency key';
};

subtest 'without an amount the whole remaining fee is refunded' => sub {
    my $payment = a_payment();
    my @calls;
    with_stripe( \@calls, sub { settle( $payment->refund_platform_fee_async($db) ) },
        fee => { id => 'fee_abc123', amount => 250, amount_refunded => 50 } );

    my $refunds = calls_of( \@calls, 'refund' );
    is scalar @$refunds, 1, 'one fee refund request';
    is $refunds->[0]{args}[1]{amount}, 200, 'for what is left of the fee';
};

done_testing;
