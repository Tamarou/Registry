#!/usr/bin/env perl
# ABOUTME: Unit tests for PriceOps::PricingPlan installment breakdown arithmetic.
# ABOUTME: Asserts the breakdown is integer cents and that the parts sum to the whole.
use 5.42.0;
use lib          qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing cmp_ok is like unlike subtest )];
defer { done_testing };

use Registry::DAO::PricingPlan;
use Registry::PriceOps::PricingPlan;

my $ops = Registry::PriceOps::PricingPlan->new;

sub plan_with ($count) {
    Registry::DAO::PricingPlan->new(
        id                  => '00000000-0000-0000-0000-000000000000',
        plan_name           => "Pay in $count",
        installments_allowed => 1,
        installment_count   => $count,
        created_at          => '2026-01-01',
        updated_at          => '2026-01-01',
    );
}

subtest 'evenly divisible total' => sub {
    my $b = $ops->calculate_installment_breakdown( plan_with(3), 30_000 );

    cmp_ok $b->{base_installment_amount_cents},  '==', 10_000, 'base is 10000 cents';
    cmp_ok $b->{first_installment_amount_cents}, '==', 10_000, 'first matches base when nothing is left over';
    cmp_ok $b->{total_amount_cents},             '==', 30_000, 'total carried through unchanged';
    like $b->{description}, qr/\$100\.00/, 'description quotes dollars';
    unlike $b->{description}, qr/first payment/, 'nothing to call out when the split is clean';
};

subtest 'total that does not divide evenly' => sub {
    # 10000 / 3 leaves one cent that has to land somewhere.  It rides on the
    # first installment, which the enrollment workflow charges on its own
    # PaymentIntent -- the only one whose amount is free to vary, since every
    # subscription invoice bills the same integer.
    my $b = $ops->calculate_installment_breakdown( plan_with(3), 10_000 );

    cmp_ok $b->{base_installment_amount_cents},  '==', 3_333, 'base floors to 3333 cents';
    cmp_ok $b->{first_installment_amount_cents}, '==', 3_334, 'the stray cent rides on the first payment';
    like $b->{description}, qr/first payment: \$33\.34/, 'description tells the parent which one is larger';

    my $sum = $b->{first_installment_amount_cents}
            + $b->{base_installment_amount_cents} * ( $b->{installment_count} - 1 );
    cmp_ok $sum, '==', 10_000, 'installments sum to the total, no cent lost';
};
