#!/usr/bin/env perl
# ABOUTME: The hybrid-plan retirement is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it suspends the seeded tenant offer, spares customer plans, and reverts by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

# Deploy up to this change's parent so a fixture can be planted before it runs.
# 'NAME^' is sqitch's one-before offset.  Naming the change under test rather
# than whichever change happens to precede it keeps this correct when a later
# leg appends to the plan.
$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan^' );

my $db = Mojo::Pg->new($uri)->db;

# A customer-scoped hybrid plan is something a tenant can author through
# PricingPlanBasics.  The migration must leave it alone.
my $customer_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type)
      VALUES ('Tenant-authored hybrid', 'hybrid', 'hybrid')
      RETURNING id}
)->hash->{id};

my $customer_rel_id = $db->query(
    q{INSERT INTO registry.pricing_relationships
          (provider_id, consumer_id, pricing_plan_id, status)
      SELECT provider_id, consumer_id, ?, 'active'
        FROM registry.pricing_relationships
       ORDER BY id
       LIMIT 1
      RETURNING id}, $customer_plan_id
)->hash->{id};

sub active_hybrid_ids ($scope) {
    return $db->query(
        q{SELECT pr.id FROM registry.pricing_relationships pr
            JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
           WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = ? AND pr.status = 'active'
           ORDER BY pr.id}, $scope
    )->arrays->flatten->to_array;
}

sub stamped_ids {
    return $db->query(
        q{SELECT id FROM registry.pricing_relationships
           WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
           ORDER BY id}
    )->arrays->flatten->to_array;
}

my $before = active_hybrid_ids('tenant');
ok scalar @$before, 'the seed offers a tenant-scoped hybrid plan before the change runs';

$sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' );

is_deeply active_hybrid_ids('tenant'), [],
    'no active relationship offers a tenant-scoped hybrid plan';
is_deeply stamped_ids(), $before,
    'the change stamped exactly the rows it suspended';
is_deeply active_hybrid_ids('customer'), [$customer_rel_id],
    'a tenant-authored customer-scoped hybrid plan is left active';

$sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'retire-registry-plus-plan^', '-y' );

is_deeply active_hybrid_ids('tenant'), $before,
    'reverting re-activates exactly the rows the change suspended';
is_deeply stamped_ids(), [],
    'reverting removes the migration stamp';

done_testing;
