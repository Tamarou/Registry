#!/usr/bin/env perl
# ABOUTME: Returning the platform's fee on a payment, the exception to keeping it on a refund.
# ABOUTME: Refusals made before any Stripe call and the plan made on the fee Stripe returns; Stripe itself is in t/stripe-live/
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::PricingProbe qw(solo_linked_tenant);
use Registry::DAO::Payment;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;     # Mojo::Pg::Database

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

# Every refusal here is made before any Stripe call: the method dies as it is
# called, before it builds a client. What Stripe answers is proved against
# real Stripe test mode in t/stripe-live/platform-fee-refund-exception.t.
sub fee_refund_error ( $payment, $args = {} ) {
    return eval { $payment->refund_platform_fee_async( $db, $args ); 1 } ? undef : $@;
}

subtest 'payment without intent is not sent' => sub {
    my $err = fee_refund_error( a_payment( stripe_payment_intent_id => undef ) );

    like $err, qr/REFUND_NOT_SENT/, 'refused as not sent';
    is( Registry::DAO::Payment->classify_refund_failure($err), 'not_sent',
        'classified as certainly not sent' );
};

subtest 'invalid fee refund amount is refused' => sub {
    for my $amount ( 0, -100, 1.5, '50abc' ) {
        like fee_refund_error( a_payment(), { amount_cents => $amount } ),
            qr/REFUND_NOT_SENT.*not a positive whole number/s, "amount $amount refused as not sent";
    }
};

# The decision made on the fee Stripe returns, with no Stripe call at all.
subtest 'fee refund plan' => sub {
    my $payment = a_payment();
    my $fee = sub (%over) {
        { id => 'fee_plan', charge => 'ch_plan', account => 'acct_fee_tenant',
          amount => 250, amount_refunded => 0, %over };
    };
    my $plan = sub ( $f, $charge, $asked ) { $payment->platform_fee_refund_plan( $f, $charge, $asked ) };

    is_deeply $plan->( $fee->(), 'ch_plan', 250 ), { send => 250 }, 'the recorded amount is sent';
    is_deeply $plan->( $fee->(), 'ch_plan', undef ), { send => 250 }, 'no amount sends what is left';
    is_deeply $plan->( $fee->( amount_refunded => 250 ), 'ch_plan', 250 ), { returned => 250 },
        'a fee already returned in full sends nothing';
    is_deeply $plan->( $fee->( amount_refunded => 200 ), 'ch_plan', 150 ), { send => 50 },
        'a request above what is left is capped at what is left';

    my %refused = (
        'more than the whole fee'  => [ $fee->(), 'ch_plan', 251, qr/more than the 250-cent fee/ ],
        'a fee on another charge'  => [ $fee->(), 'ch_other', 250, qr/charge/ ],
        'a fee from another account' => [ $fee->( account => 'acct_other' ), 'ch_plan', 250, qr/account/ ],
    );
    for my $case ( sort keys %refused ) {
        my ( $f, $charge, $asked, $why ) = $refused{$case}->@*;
        ok !eval { $plan->( $f, $charge, $asked ); 1 }, "refused: $case";
        like $@, qr/REFUND_NOT_SENT/, "as not sent: $case";
        like $@, $why, "saying why: $case";
    }
};

done_testing;
