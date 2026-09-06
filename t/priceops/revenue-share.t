#!/usr/bin/env perl
# ABOUTME: Tests for Registry::PriceOps::RevenueShare — tenant-to-fraction resolver.
# ABOUTME: Covers backfilled plan, NULL FK fallback, search_path isolation, and die cases.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::PriceOps::RevenueShare qw(revenue_share_fraction_for_tenant);

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

# Determine the slug of a seeded (backfilled) tenant. Both seeded tenants use the
# Revenue Share plan; pick one that has the column set.
my $seeded_slug = $db->query(q{
    SELECT t.slug
      FROM registry.tenants t
      JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
     WHERE p.pricing_model_type = 'percentage'
       AND p.plan_scope = 'tenant'
     LIMIT 1
})->hash->{slug};

ok $seeded_slug, "found a seeded tenant backfilled to the revenue-share plan (slug=$seeded_slug)";

# The rate this tenant's plan carries. The subtests below are about mechanisms --
# DAO coercion, search_path isolation -- and pinning them to a literal made them
# fail on a rate change for reasons that have nothing to do with what they test.
my $seeded_rate = $db->query(q{
    SELECT (p.pricing_configuration->>'percentage')::numeric
      FROM registry.tenants t
      JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
     WHERE t.slug = ?
}, $seeded_slug)->array->[0];

# Against the plan's own row, not a literal. A test that hardcodes the rate
# fails the day the rate moves, and the obvious repair is to edit the number --
# which is exactly the drift that let three different rates be live at once.
subtest 'a linked tenant is charged its plan rate' => sub {
    my $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug);
    ok defined $fraction, 'got a defined fraction';

    my $on_the_plan = $db->query(q{
        SELECT (p.pricing_configuration->>'percentage')::numeric
          FROM registry.tenants t
          JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
         WHERE t.slug = ?
    }, $seeded_slug)->array->[0];

    cmp_ok abs($fraction - $on_the_plan), '<', 1e-9,
        "the resolver returns what the plan carries (got $fraction)";
};

# The launch rate is a decision, and a decision belongs in one named place.
# revenue_share_fraction_for_tenant answers "what is THIS tenant charged";
# platform_launch_fraction answers "what does the platform sell", which is what
# the marketing copy quotes. platform_default_fraction is neither -- it is the
# no-plan fallback, and reading the launch rate off it returns the Free plan's
# zero, which is how the copy came to promise a rate nothing charged.
subtest 'the launch rate has one named source' => sub {
    # Only one assertion here, deliberately. platform_launch_fraction dies on
    # zero marked plans, on more than one, and on a rate that is undefined,
    # non-numeric or outside [0,1] -- so `defined $launch` and a count of marked
    # plans both restate its die conditions, and any state that would fail them
    # kills the subtest before they run. A zero rate is inside the accepted
    # range, so this is the one thing the function can return that is wrong.
    my $launch = Registry::PriceOps::RevenueShare::platform_launch_fraction($db);
    cmp_ok $launch, '>', 0,
        'the launch rate is not the Free-plan zero';
};

# The whole point of naming it: displayed and charged cannot drift apart.
subtest 'a tenant on the launch plan is charged the launch rate' => sub {
    my $launch  = Registry::PriceOps::RevenueShare::platform_launch_fraction($db);
    my $charged = revenue_share_fraction_for_tenant($db, $seeded_slug);
    cmp_ok abs($charged - $launch), '<', 1e-9,
        'what the seeded tenant is charged is what the platform advertises';
};

subtest 'Registry::DAO coercion - accepts DAO object as well as raw db handle' => sub {
    my $fraction = revenue_share_fraction_for_tenant($dao, $seeded_slug);
    cmp_ok abs($fraction - $seeded_rate), '<', 1e-9,
        "coercion works: DAO->db transparently";
};

subtest 'NULL platform_pricing_plan_id falls back to Free plan (0.00)' => sub {
    # Null the FK for our seeded tenant, test, then restore.
    my $saved = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = ?
    }, $seeded_slug);

    my $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug);
    cmp_ok abs($fraction - 0.00), '<', 1e-9, "NULL FK -> Free plan -> 0.00 (got $fraction)";

    # Restore
    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved, $seeded_slug);
};

subtest 'search_path isolation - resolver works when search_path excludes registry' => sub {
    # Set search_path to public only (NOT registry) to prove all queries are
    # fully qualified and do not depend on the connection's search_path.
    $db->query("SET search_path TO public");
    my $fraction;
    eval { $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug) };
    ok !$@, "no error when search_path = public: $@";
    cmp_ok abs($fraction - $seeded_rate), '<', 1e-9,
        "correct fraction even with search_path=public";
    # Restore search_path
    $db->query("SET search_path TO registry, public");
};

subtest 'missing Free fallback plan causes die' => sub {
    # Delete the platform-scope default plan and null the tenant FK, then call.
    my $saved_plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $free_plan_id = $db->query(q{
        SELECT id FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
         LIMIT 1
    })->hash->{id};

    # Null the tenant FK first (FK constraint)
    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = ?
    }, $seeded_slug);

    $db->query(q{
        DELETE FROM registry.pricing_plans WHERE id = ?
    }, $free_plan_id);

    my $result = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
    like $@, qr/Free|fallback|platform|default/i,
        'dies with informative message when Free plan is absent';

    # Restore: re-insert the Free plan, then restore the tenant FK
    $db->query(q{
        INSERT INTO registry.pricing_plans
            (id, plan_scope, plan_name, plan_type, pricing_model_type,
             amount_cents, currency, installments_allowed, requirements,
             pricing_configuration, metadata)
        VALUES (?, 'platform', 'Registry Free', 'standard', 'percentage',
                0, 'USD', false, '{}',
                '{"applies_to":"customer_payments","percentage":0.00,"minimum_monthly":0}',
                '{"default":true,"description":"Platform fallback: no revenue share"}')
    }, $free_plan_id);

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved_plan_id, $seeded_slug);
};

subtest 'linked plan with no percentage key dies rather than guessing' => sub {
    # pricing_configuration->>'percentage' is the only rate source. A plan that
    # declares no rate has no rate; there is nothing else on the row to read.
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration, amount_cents
          FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = '{}'::jsonb, amount_cents = 3
         WHERE id = ?
    }, $plan_id);

    my $fraction = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
    ok !defined $fraction, 'no fraction returned when the plan declares no rate'
        or diag "returned $fraction -- the money column was read as a rate";
    like $@, qr/percentage/i, 'dies naming the missing percentage';

    # Restore
    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = ?, amount_cents = ?
         WHERE id = ?
    }, $saved->{pricing_configuration}, $saved->{amount_cents}, $plan_id);
};

subtest 'fixed-price plan does not have its dollar amount read as a rate' => sub {
    # The seeded "Registry Standard - $200/month" plan carries a price and no
    # rate, and it is the one marked default:true -- the plan an admin is most
    # likely to pick. Reading its price as a rate would yield a 20000%
    # application fee that Stripe rejects outright.
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration, amount_cents, pricing_model_type
          FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = '{}'::jsonb,
               amount_cents          = 20000,
               pricing_model_type    = 'fixed'
         WHERE id = ?
    }, $plan_id);

    my $fraction = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
    ok !defined $fraction, 'no fraction returned for a fixed-price plan'
        or diag "returned $fraction -- a fixed plan's price was read as a rate";
    like $@, qr/percentage|rate/i,
        'dies pointing at the missing percentage rather than inventing one';

    # Restore
    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = ?, amount_cents = ?, pricing_model_type = ?
         WHERE id = ?
    }, $saved->{pricing_configuration}, $saved->{amount_cents},
       $saved->{pricing_model_type}, $plan_id);
};

subtest 'a rate outside 0..1 dies rather than reaching Stripe' => sub {
    # Backstop at the coercion boundary: "2" almost certainly means 2%, but as a
    # fraction it is a 200% fee. No legitimate revenue share sits outside [0,1],
    # so refuse it here rather than let Stripe reject the charge at capture time.
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    for my $bad (2, -0.01) {
        $db->query(q{
            UPDATE registry.pricing_plans
               SET pricing_configuration = ?::jsonb
             WHERE id = ?
        }, qq[{"percentage":$bad}], $plan_id);

        my $fraction = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
        ok !defined $fraction, "percentage $bad is refused";
        like $@, qr/between 0 and 1|fraction/i,
            "percentage $bad dies with a message naming the expected range";
    }

    # Restore
    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = ?
         WHERE id = ?
    }, $saved->{pricing_configuration}, $plan_id);
};

subtest 'malformed/non-numeric resolved value dies' => sub {
    # The linked plan's percentage is present but a non-numeric string, so it
    # must die: it cannot be coerced to a number.
    my $plan_id = $db->query(q{
        SELECT platform_pricing_plan_id FROM registry.tenants WHERE slug = ?
    }, $seeded_slug)->hash->{platform_pricing_plan_id};

    my $saved = $db->query(q{
        SELECT pricing_configuration, amount_cents
          FROM registry.pricing_plans WHERE id = ?
    }, $plan_id)->hash;

    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = '{"percentage":"abc"}'::jsonb
         WHERE id = ?
    }, $plan_id);

    my $result = eval { revenue_share_fraction_for_tenant($db, $seeded_slug) };
    like $@, qr/not numeric/i,
        'dies with informative message when resolved value is non-numeric';

    # Restore
    $db->query(q{
        UPDATE registry.pricing_plans
           SET pricing_configuration = ?, amount_cents = ?
         WHERE id = ?
    }, $saved->{pricing_configuration}, $saved->{amount_cents}, $plan_id);
};

done_testing;
