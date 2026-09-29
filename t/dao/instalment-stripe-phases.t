#!/usr/bin/env perl
# ABOUTME: Turning an instalment list into Stripe subscription-schedule phases, fee and all.
# ABOUTME: Unequal amounts are the norm -- the odd cent lands on one charge, so phases must differ.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok like is_deeply subtest note )];
defer { done_testing };

use Registry::DAO::Payment;

sub phases_for ( @amounts ) {
    my $parts = [ map { { amount_cents => $_, due_date => '2026-06-01' } } @amounts ];
    return Registry::DAO::Payment::instalment_phases( $parts, 'usd', 'Summer Camp' );
}

subtest 'equal instalments collapse into one phase' => sub {
    my $phases = phases_for( 10000, 10000, 10000 );

    is scalar(@$phases), 1, 'one phase';
    is $phases->[0]{iterations},   3,     'charged three times';
    is $phases->[0]{unit_amount},  10000, 'at the same amount each time';

    # Not three phases of one. Stripe bills a phase per iteration, so collapsing
    # is not cosmetic -- it is the difference between one price object and three.
};

subtest 'the odd cent gets its own phase' => sub {
    my $phases = phases_for( 3333, 3333, 3334 );

    is scalar(@$phases), 2, 'two phases: the even share, then the remainder';
    is_deeply [ map { $_->{iterations} }  @$phases ], [ 2, 1 ], 'twice, then once';
    is_deeply [ map { $_->{unit_amount} } @$phases ], [ 3333, 3334 ], 'and the last differs';

    my $total = 0;
    $total += $_->{unit_amount} * $_->{iterations} for @$phases;
    is $total, 10000, 'the phases still bill the whole amount';
};

subtest 'a single charge is a single phase' => sub {
    my $phases = phases_for( 5000 );
    is scalar(@$phases), 1, 'one phase';
    is $phases->[0]{iterations}, 1, 'billed once';
};

# The whole request, as it goes to Stripe. This is the shape that decides where
# the money lands, so it is asserted rather than trusted.
subtest 'the schedule routes the money to the tenant and our fee to us' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer           => 'cus_probe',
        payment_method     => 'pm_probe',
        connect_account    => 'acct_probe',
        revenue_share_pct  => 2.5,
        currency           => 'usd',
        description        => 'Summer Camp',
        product            => 'prod_probe',
        instalments        => [
            { amount_cents => 3333, due_date => '2026-07-01' },
            { amount_cents => 3334, due_date => '2026-08-01' },
        ],
    } );

    is $params->{customer}, 'cus_probe', 'billed to the customer';
    is $params->{end_behavior}, 'cancel',
        'and it stops when the instalments are done, rather than renewing forever';

    # Destination charges, the same model the one-off path uses: the tenant is
    # the merchant and our share is the application fee. A schedule that omitted
    # these would settle every instalment into the PLATFORM's balance.
    is $params->{'default_settings[transfer_data][destination]'}, 'acct_probe',
        'each charge settles in the tenant account';
    is $params->{'default_settings[application_fee_percent]'}, 2.5,
        'with the revenue share taken as the application fee';
    is $params->{'default_settings[collection_method]'}, 'charge_automatically',
        'charged automatically -- nobody is present for instalment three';
    is $params->{'default_settings[default_payment_method]'}, 'pm_probe',
        'against the card saved at checkout';

    # First charge on the first due date, not now: instalment one was already
    # taken on-session at enrolment, and this schedule covers what is left.
    like $params->{start_date}, qr/^\d+$/, 'start_date is an epoch second';
    ok $params->{start_date} > 0, 'and it is set';

    is $params->{'phases[0][items][0][price_data][unit_amount]'}, 3333,
        'the first phase bills the even share';
    is $params->{'phases[1][items][0][price_data][unit_amount]'}, 3334,
        'and the second the remainder';
    is $params->{'phases[0][items][0][price_data][recurring][interval]'}, 'month',
        'monthly';
    is $params->{'phases[0][items][0][price_data][currency]'}, 'usd',
        'in the cart currency';

    # A product id, not inline product_data: Stripe refuses the latter inside a
    # schedule phase, which is the kind of thing only the real API tells you.
    is $params->{'phases[0][items][0][price_data][product]'}, 'prod_probe',
        'against a product the caller created';
};

subtest 'a tenant with no revenue share still gets its money' => sub {
    my $params = Registry::DAO::Payment::instalment_schedule_params( {
        customer          => 'cus_probe',
        payment_method    => 'pm_probe',
        connect_account   => 'acct_probe',
        revenue_share_pct => 0,
        currency          => 'usd',
        description       => 'Free Ride',
        product           => 'prod_probe',
        instalments       => [ { amount_cents => 100, due_date => '2026-07-01' } ],
    } );

    is $params->{'default_settings[transfer_data][destination]'}, 'acct_probe',
        'still a destination charge';
    ok !exists $params->{'default_settings[application_fee_percent]'},
        'and no application fee key at all, rather than a zero Stripe may reject';
};

# No database anywhere in this file: every one of these is a pure translation,
# which is the point of it being a function rather than a method on a row.
