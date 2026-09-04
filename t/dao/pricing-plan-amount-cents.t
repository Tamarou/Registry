#!/usr/bin/env perl
# ABOUTME: pricing_plans stores money as integer cents, and the rate lives only
# ABOUTME: in pricing_configuration -- one column can no longer mean two things.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::PricingPlan;
use Registry::PriceOps::RevenueShare qw( revenue_share_fraction_for_tenant );

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

subtest 'the column is integer cents, and the old dollars column is gone' => sub {
    my $cols = $db->query(q{
        SELECT column_name, data_type
          FROM information_schema.columns
         WHERE table_schema = 'registry' AND table_name = 'pricing_plans'
           AND column_name IN ('amount', 'amount_cents')
    })->hashes->reduce(sub { $a->{ $b->{column_name} } = $b->{data_type}; $a }, {});

    is $cols->{amount_cents}, 'integer',
        'amount_cents is a true integer -- no scale to round a half-cent away';
    ok !exists $cols->{amount},
        'the dollars column is gone, so no caller can read the old units by accident';
};

subtest 'a tenant schema gets the new shape too' => sub {
    # clone_schema builds a tenant from the registry template. If the migration
    # only touched registry, every existing tenant keeps the dollars column and
    # the money path silently diverges per tenant.
    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Cents Tenant',
        slug => 'cents_tenant',
    });
    $db->query('SELECT clone_schema(?)', 'cents_tenant');

    my $cols = $db->query(q{
        SELECT column_name, data_type
          FROM information_schema.columns
         WHERE table_schema = 'cents_tenant' AND table_name = 'pricing_plans'
           AND column_name IN ('amount', 'amount_cents')
    })->hashes->reduce(sub { $a->{ $b->{column_name} } = $b->{data_type}; $a }, {});

    is $cols->{amount_cents}, 'integer', 'tenant schema has amount_cents';
    ok !exists $cols->{amount},          'tenant schema lost the dollars column';
};

subtest 'a session price round-trips as cents' => sub {
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name    => 'Standard Rate',
        plan_type    => 'standard',
        amount_cents => 50_000,
        currency     => 'USD',
    });

    is $plan->amount_cents, 50_000, '$500.00 is stored as 50000 cents';
    is $plan->formatted_price, '$500.00',
        'formatted_price renders dollars from cents';
};

subtest 'the seeded plans are backfilled by meaning, not blindly' => sub {
    my %seeded = map { $_->{plan_name} => $_ } $db->query(q{
        SELECT plan_name, pricing_model_type, amount_cents,
               pricing_configuration->>'percentage' AS rate
          FROM registry.pricing_plans
    })->hashes->@*;

    my $standard = $seeded{'Registry Standard - $200/month'};
    is $standard->{amount_cents}, 20_000,
        'a fixed $200/month plan becomes 20000 cents';

    my $plus = $seeded{'Registry Plus - $100/month + 1%'};
    is $plus->{amount_cents}, 10_000,
        'a hybrid plan\'s monthly base becomes 10000 cents';
    is $plus->{rate}, '0.01', 'and its rate stays in pricing_configuration';

    # The percentage plans never had a dollar amount -- the column was holding
    # their rate. Multiplying the rate by 100 would invent a charge out of it,
    # which is the hazard these two assertions exist for. Stated as the property
    # rather than as a number: the rate is whatever the launch decision made it,
    # and this test is about the cents conversion, not about that decision.
    my $share = $seeded{'Solo'};
    is $share->{amount_cents}, 0,
        'a percentage plan has no dollar amount, so amount_cents is 0';
    cmp_ok $share->{rate}, '>', 0,
        'its rate survives, in pricing_configuration';
    cmp_ok $share->{rate}, '<=', 1,
        'and it is still a fraction, not a rate multiplied into cents';

    my $free = $seeded{'Registry Free'};
    is $free->{amount_cents}, 0, 'the Free plan has no dollar amount either';
    is $free->{rate}, '0.00',    'and keeps its 0% rate';
};

subtest 'the revenue-share rate no longer comes from the money column' => sub {
    my $slug = $db->query(q{
        SELECT t.slug
          FROM registry.tenants t
          JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
         WHERE p.pricing_model_type = 'percentage' AND p.plan_scope = 'tenant'
         LIMIT 1
    })->hash->{slug};
    ok $slug, "found a tenant on the revenue-share plan (slug=$slug)";

    # Whatever the plan carries. The property under test is that a dollar amount
    # in the money column cannot move the rate -- not what the rate happens to
    # be, which is a launch decision this test has no business restating.
    my $before = revenue_share_fraction_for_tenant( $db, $slug );
    cmp_ok $before, '>', 0,
        'the rate resolves from pricing_configuration';

    # The whole point of the split. Put a plausible dollar amount on the plan;
    # if anything still reads this column as a rate, the fraction moves and
    # every charge for this tenant carries the wrong application fee.
    $db->query(q{
        UPDATE registry.pricing_plans SET amount_cents = 5000
         WHERE pricing_model_type = 'percentage' AND plan_scope = 'tenant'
    });

    cmp_ok abs( revenue_share_fraction_for_tenant( $db, $slug ) - $before ), '<', 1e-9,
        'a $50.00 amount_cents on the plan does not move the rate';
};

subtest 'a percentage plan with no rate in config fails loud' => sub {
    # Before the split, such a plan quietly fell back to the amount column.
    # With the fallback gone there is nothing left to guess with, and guessing
    # is the one thing a charge-time rate resolver must never do.
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name             => 'Rateless Share',
        plan_scope            => 'tenant',
        pricing_model_type    => 'percentage',
        amount_cents          => 2,
        currency              => 'USD',
        pricing_configuration => {},
    });

    my $tenant = Test::Registry::Fixtures::create_tenant($db, {
        name => 'Rateless Tenant',
        slug => 'rateless_tenant',
    });
    $db->query(
        'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?',
        $plan->id, 'rateless_tenant'
    );

    my $fraction = eval { revenue_share_fraction_for_tenant( $db, 'rateless_tenant' ) };
    ok !defined $fraction, 'no rate is invented';
    like $@, qr/percentage/i, "and the error names the missing rate: $@";
};

subtest 'a percentage discount cannot leave a fractional cent behind' => sub {
    # 1/3 off $100.00 is 6666.66... cents. Stripe takes an integer; anything
    # else is rounded by whoever touches it last, unpredictably.
    my $plan = Registry::DAO::PricingPlan->create($db, {
        plan_name    => 'Third Off',
        plan_type    => 'standard',
        amount_cents => 10_000,
        currency     => 'USD',
        requirements => { percentage_discount => 100 / 3 },
    });

    my $price = $plan->calculate_price;
    is $price, 6667, 'the discounted price is a whole number of cents';
    is $price, int($price), 'and carries no fractional part at all';
};

done_testing;
