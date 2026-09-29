#!/usr/bin/env perl
# ABOUTME: A plan's instalment offer is declared in pricing_configuration and resolved, not branched on.
# ABOUTME: The split must preserve every cent: three ways of $100 is 33/33/34, never 33/33/33.

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use experimental qw(defer signatures);
use Test::More import => [qw( done_testing is ok is_deeply subtest note )];
defer { done_testing };

use Test::Registry::DB;
use Registry::DAO::PricingPlan;

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;
my $db   = $dao->db;

# A plan is a row, but the schedule is a property of its declared configuration,
# so these exercise the configuration rather than the database where they can.
sub plan_with ( $config ) {
    return Registry::DAO::PricingPlan->new(
        id                    => '00000000-0000-0000-0000-000000000001',
        session_id            => undef,
        plan_name             => 'Probe',
        amount_cents          => 30000,
        currency              => 'USD',
        created_at            => '2026-01-01',
        updated_at            => '2026-01-01',
        pricing_configuration => $config,
    );
}

subtest 'a plan with no declared schedule offers no instalments' => sub {
    my $plan = plan_with( {} );
    is $plan->payment_schedule, undef, 'no schedule declared';
    is $plan->instalment_schedule( 30000 ), undef, 'and none resolved';

    # Not a boolean column and a branch. A plan that says nothing about being
    # paid in parts is paid in one, and the code asks the configuration rather
    # than asking what kind of plan it is -- which is what lets a new payment
    # shape ship as data (#427, Pillar 4).
    ok !Registry::DAO::PricingPlan->can('installments_allowed'),
        'and there is no installments_allowed flag left to branch on';
};

subtest 'a declared schedule resolves to dated instalments' => sub {
    my $plan = plan_with( { schedule => { count => 3, cadence => 'monthly' } } );

    my $declared = $plan->payment_schedule;
    is $declared->{count},   3,         'the count is read from the configuration';
    is $declared->{cadence}, 'monthly', 'and the cadence';

    my $parts = $plan->instalment_schedule( 30000, first_due => '2026-06-01' );
    is scalar(@$parts), 3, 'three instalments';

    is_deeply [ map { $_->{amount_cents} } @$parts ], [ 10000, 10000, 10000 ],
        'an evenly divisible total splits evenly';
    is_deeply [ map { $_->{due_date} } @$parts ],
        [ '2026-06-01', '2026-07-01', '2026-08-01' ],
        'one month apart, starting at enrolment';
};

# The arithmetic that loses money if it is wrong. The method this replaces did
# int($amount / $count) for every instalment and said so in a comment: "the
# installments can sum to less than the plan price".
subtest 'no cent is lost to the division' => sub {
    my $plan = plan_with( { schedule => { count => 3, cadence => 'monthly' } } );

    my $parts = $plan->instalment_schedule( 10000, first_due => '2026-06-01' );
    is_deeply [ map { $_->{amount_cents} } @$parts ], [ 3333, 3333, 3334 ],
        '$100 in three is 33.33 / 33.33 / 33.34';

    my $sum = 0;
    $sum += $_->{amount_cents} for @$parts;
    is $sum, 10000, 'and the parts sum to the whole';

    # The remainder goes on the LAST instalment, not the first: a parent
    # comparing the checkout total to the first charge should see the round
    # number they were quoted.
    is $parts->[0]{amount_cents}, 3333, 'the first charge is the even share';
};

subtest 'a cent more than the parts can hold still balances' => sub {
    my $plan = plan_with( { schedule => { count => 7, cadence => 'monthly' } } );
    my $parts = $plan->instalment_schedule( 100, first_due => '2026-06-01' );

    my $sum = 0;
    $sum += $_->{amount_cents} for @$parts;
    is $sum, 100, 'seven ways of a dollar still sums to a dollar';
    note join ' / ', map { $_->{amount_cents} } @$parts;
};

# Declared, so it can be changed without touching this code -- which is the
# whole point of putting it in the configuration.
subtest 'the surcharge is declared, and defaults to nothing' => sub {
    my $free = plan_with( { schedule => { count => 3, cadence => 'monthly' } } );
    is $free->payment_schedule->{surcharge_pct}, 0,
        'a schedule that says nothing about a surcharge has none';

    my $parts = $free->instalment_schedule( 30000, first_due => '2026-06-01' );
    my $sum = 0;
    $sum += $_->{amount_cents} for @$parts;
    is $sum, 30000, 'so paying in parts costs exactly what paying at once costs';

    my $surcharged = plan_with(
        { schedule => { count => 3, cadence => 'monthly', surcharge_pct => 10 } } );
    my $more = $surcharged->instalment_schedule( 30000, first_due => '2026-06-01' );
    my $more_sum = 0;
    $more_sum += $_->{amount_cents} for @$more;
    is $more_sum, 33000, 'and a declared surcharge is applied to the total';
};

subtest 'a schedule that makes no sense is refused, not quietly honoured' => sub {
    for my $bad (
        { count => 1,    cadence => 'monthly' },
        { count => 0,    cadence => 'monthly' },
        { count => 3,    cadence => 'fortnightly' },
        { cadence => 'monthly' },
    ) {
        my $plan = plan_with( { schedule => $bad } );
        is $plan->payment_schedule, undef,
            'refused: ' . join( ',', map { "$_=" . ( $bad->{$_} // 'undef' ) } sort keys %$bad );
    }

    # One instalment is not an instalment plan, and a cadence nothing can
    # schedule is worse than none -- both would otherwise reach Stripe as a
    # subscription nobody meant to create.
};

$t_db->cleanup_test_database;
