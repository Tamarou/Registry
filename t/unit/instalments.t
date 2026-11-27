#!/usr/bin/env perl
# ABOUTME: Instalment cadence arithmetic: due dates, the parts a total splits into, and whether a plan ends by a last day.
# ABOUTME: Pure functions shared by session-setup, checkout, holds and schedules; no database.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Registry::PriceOps::Instalments qw( due_dates parts fits );

subtest 'weekly due dates are seven days apart' => sub {
    is_deeply due_dates( { count => 3, cadence => 'weekly' }, '2027-05-31' ), [qw( 2027-05-31 2027-06-07 2027-06-14 )];
};

subtest 'quarterly due dates clamp to the end of the month' => sub {
    is_deeply due_dates( { count => 2, cadence => 'quarterly' }, '2027-11-30' ), [qw( 2027-11-30 2028-02-29 )];
};

subtest 'monthly due dates anchor to the first, not the one before' => sub {
    is_deeply due_dates( { count => 4, cadence => 'monthly' }, '2027-01-31' ),
        [qw( 2027-01-31 2027-02-28 2027-03-31 2027-04-30 )], 'as Stripe bills a schedule anchored on the 31st';
    is_deeply due_dates( { count => 3, cadence => 'quarterly' }, '2027-08-31' ),
        [qw( 2027-08-31 2027-11-30 2028-02-29 )], 'quarterly across a year end and a leap day';
};

subtest 'parts split evenly with the remainder on the last' => sub {
    is_deeply parts( 10000, { count => 3, cadence => 'monthly' }, '2027-01-31' ), [
        { amount_cents => 3333, due_date => '2027-01-31' },
        { amount_cents => 3333, due_date => '2027-02-28' },
        { amount_cents => 3334, due_date => '2027-03-31' },
    ], 'each part with its due date, each a whole number of months from the first';
};

subtest 'a surcharge is added before the split' => sub {
    is_deeply [ map { $_->{amount_cents} } parts( 10000, { count => 2, cadence => 'monthly', surcharge_pct => '5' }, '2027-01-01' )->@* ],
        [ 5250, 5250 ];
    is_deeply [ map { $_->{amount_cents} } parts( 999, { count => 2, cadence => 'weekly', surcharge_pct => '2.5' }, '2027-01-01' )->@* ],
        [ 512, 512 ], 'a fractional percent rounds half up, in whole cents (999 * 1.025 = 1023.975)';
};

subtest 'a plan that ends by the last day fits' => sub {
    ok fits( { count => 2, cadence => 'weekly' }, '2027-06-01', '2027-06-11' );
    ok fits( { count => 2, cadence => 'weekly' }, '2027-06-01', '2027-06-08' ), 'the last payment on the last day fits';
};

subtest 'a weekly plan past the last day does not fit' => sub {
    ok !fits( { count => 4, cadence => 'weekly' }, '2027-06-01', '2027-06-11' );
};

done_testing;
