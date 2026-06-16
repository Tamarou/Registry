#!/usr/bin/env perl
# ABOUTME: Integration test that platform pricing plans are seeded and selectable.
# ABOUTME: Guards #268 — fresh deploys must offer selectable plans + a Free fallback.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;     # Registry::DAO
my $db      = $dao->db;         # Mojo::Pg::Database

my $PLATFORM = '00000000-0000-0000-0000-000000000000';

subtest 'signup offers selectable plans' => sub {
    # prepare_pricing_data selects: active platform relationship -> tenant-scoped plan.
    my $rows = $db->query(q{
        SELECT p.plan_name
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
         WHERE pr.provider_id = ?
           AND pr.status = 'active'
           AND p.plan_scope = 'tenant'
    }, $PLATFORM)->hashes;
    ok scalar(@$rows) >= 1, 'at least one selectable plan on a fresh deploy';
    ok( (grep { $_->{plan_name} =~ /Revenue Share/ } @$rows),
        'the revenue-share plan is among the selectable plans' );
};

subtest 'Free platform fallback plan exists and is not selectable' => sub {
    my $row = $db->query(q{
        SELECT amount, pricing_model_type
          FROM registry.pricing_plans
         WHERE plan_scope = 'platform'
           AND metadata->>'default' = 'true'
    })->hash;
    ok $row, 'a platform-scope default plan exists';
    is $row->{pricing_model_type}, 'percentage', 'Free plan is percentage-typed';
    cmp_ok $row->{amount} + 0, '==', 0, 'Free plan rate is 0';

    my $selectable = $db->query(q{
        SELECT COUNT(*) AS n
          FROM registry.pricing_relationships pr
          JOIN registry.pricing_plans p ON p.id = pr.pricing_plan_id
         WHERE p.plan_scope = 'platform' AND pr.provider_id = ?
    }, $PLATFORM)->hash->{n};
    is $selectable, 0, 'Free fallback has no selectable relationship';
};

done_testing;
