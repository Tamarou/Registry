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

subtest 'backfilled tenant resolves to 0.02' => sub {
    my $fraction = revenue_share_fraction_for_tenant($db, $seeded_slug);
    ok defined $fraction, 'got a defined fraction';
    cmp_ok abs($fraction - 0.02), '<', 1e-9, "fraction is 0.02 (got $fraction)";
};

subtest 'Registry::DAO coercion - accepts DAO object as well as raw db handle' => sub {
    my $fraction = revenue_share_fraction_for_tenant($dao, $seeded_slug);
    cmp_ok abs($fraction - 0.02), '<', 1e-9, "coercion works: DAO->db transparently";
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
    cmp_ok abs($fraction - 0.02), '<', 1e-9, "correct fraction even with search_path=public";
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
             amount, currency, installments_allowed, requirements,
             pricing_configuration, metadata)
        VALUES (?, 'platform', 'Registry Free', 'standard', 'percentage',
                0.00, 'USD', false, '{}',
                '{"applies_to":"customer_payments","percentage":0.00,"minimum_monthly":0}',
                '{"default":true,"description":"Platform fallback: no revenue share"}')
    }, $free_plan_id);

    $db->query(q{
        UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?
    }, $saved_plan_id, $seeded_slug);
};

done_testing;
