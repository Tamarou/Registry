#!/usr/bin/env perl
# ABOUTME: The hybrid-plan retirement is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it suspends the seeded tenant offer, spares customer plans, and reverts by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

# Deploy up to this change's parent so fixtures can be planted before it runs.
# 'NAME^' is sqitch's one-before offset.  Naming the change under test rather
# than whichever change happens to precede it keeps this correct when a later
# leg appends to the plan.  lives_ok, not a bare run: App::Sqitch->run dies on
# a non-zero exit, and an unwrapped die reports as 'test exited with 2' rather
# than naming the step that broke.  t/database/migration-verification.t:40 uses
# the same wrapper for the same reason.
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan^' ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

# Every fixture below exists to kill a specific mutation of the three scripts.
# The table in the prose above says which.  Do not drop one without checking it.

# A customer-scoped hybrid plan is something a tenant can author through
# PricingPlanBasics.  The migration must leave it alone.
my $customer_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type)
      VALUES ('Tenant-authored hybrid', 'hybrid', 'hybrid')
      RETURNING id}
)->hash->{id};

# A tenant-scoped hybrid plan, but offered by a reseller rather than by the
# platform.  PricingPlanBasics.pm:88-92 lets any author pick 'tenant', and
# PriceOps::PricingRelationships::create passes provider_id straight through,
# so this row is reachable from the product.  It is outside the platform's
# signup menu and must survive.
my $b2b_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type, plan_scope)
      VALUES ('Reseller tenant-scoped hybrid', 'hybrid', 'hybrid', 'tenant')
      RETURNING id}
)->hash->{id};

# The Studio/Empire shape: plan_type 'standard', pricing_model_type 'hybrid'.
# If the predicate ever drifts to pricing_model_type, this row goes dark.
my $standard_plan_id = $db->query(
    q{INSERT INTO registry.pricing_plans (plan_name, plan_type, pricing_model_type, plan_scope)
      VALUES ('Studio-shaped tier', 'standard', 'hybrid', 'tenant')
      RETURNING id}
)->hash->{id};

# The seeded Plus plan -- the one thing this change exists to retire.  Find it
# by the migration's own predicate rather than by name or by hard-coded id.
my $plus_plan_id = $db->query(
    q{SELECT pp.id FROM registry.pricing_plans pp
        JOIN registry.pricing_relationships pr ON pr.pricing_plan_id = pp.id
       WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = 'tenant'
         AND pr.provider_id = ? AND pr.status = 'active'
       LIMIT 1}, PLATFORM_UUID
)->hash->{id};
ok $plus_plan_id, 'the seed still contains a platform-offered tenant-scoped hybrid plan';

# A reseller tenant, so a relationship can carry a provider that is not the
# platform.  Created outright rather than found, so the fixture does not depend
# on which other tenants the seed happens to contain.
my $reseller_id = $db->query(
    q{INSERT INTO registry.tenants (name, slug) VALUES ('Reseller Fixture', 'reseller_fixture')
      RETURNING id}
)->hash->{id};

# provider_id references tenants(id) and consumer_id references users(id)
# (consolidate-pricing-relationships.sql:12-13), so consumer_id is copied off a
# seeded row rather than inventing a user.  provider defaults to the platform.
sub plant_relationship ($plan_id, %opt) {
    # exists, not //: `metadata => undef` is the whole point of one caller below,
    # and `$opt{metadata} // '{}'` would silently turn that NULL into '{}' and
    # leave the COALESCE mutation alive.  Defaulting an explicit undef away is
    # the bug this fixture exists to catch.
    my $metadata = exists $opt{metadata} ? $opt{metadata} : '{}';
    return $db->query(
        q{INSERT INTO registry.pricing_relationships
              (provider_id, consumer_id, pricing_plan_id, status, metadata)
          SELECT ?, consumer_id, ?, 'active', ?::jsonb
            FROM registry.pricing_relationships
           ORDER BY id LIMIT 1
          RETURNING id},
        $opt{provider} // PLATFORM_UUID, $plan_id, $metadata
    )->hash->{id};
}

my $customer_rel_id = plant_relationship($customer_plan_id);
my $standard_rel_id = plant_relationship($standard_plan_id);
my $b2b_rel_id      = plant_relationship( $b2b_plan_id, provider => $reseller_id );

# Squarely inside the predicate, but with metadata explicitly NULL.  Without
# COALESCE in the deploy, `NULL || '{...}'::jsonb` is NULL, so this row would be
# suspended without a stamp and the revert could never find it again.
my $null_meta_rel_id = plant_relationship( $plus_plan_id, metadata => undef );

# A platform offer on the retired plan that an operator has already cancelled.
# `AND pr.status = 'active'` in the deploy is the only thing keeping it out, and
# without this fixture nothing tests that: every other relationship inside the
# three-column predicate is already active at this point in the plan, so deleting
# the condition changes nothing observable.  With it, the deploy suspends and
# stamps a cancelled row and the revert then resurrects it as active.
my $cancelled_rel_id = plant_relationship($plus_plan_id);
$db->query( q{UPDATE registry.pricing_relationships SET status = 'cancelled' WHERE id = ?},
    $cancelled_rel_id );

sub rel_status ($id) {
    return $db->query( q{SELECT status FROM registry.pricing_relationships WHERE id = ?}, $id )
        ->hash->{status};
}

sub retired_ids {
    return $db->query(
        q{SELECT pr.id FROM registry.pricing_relationships pr
            JOIN registry.pricing_plans pp ON pp.id = pr.pricing_plan_id
           WHERE pp.plan_type = 'hybrid' AND pp.plan_scope = 'tenant'
             AND pr.provider_id = ? AND pr.status = 'active'
           ORDER BY pr.id}, PLATFORM_UUID
    )->arrays->flatten->to_array;
}

sub stamped_ids {
    return $db->query(
        q{SELECT id FROM registry.pricing_relationships
           WHERE metadata->>'suspended_by_migration' = 'retire-registry-plus-plan'
           ORDER BY id}
    )->arrays->flatten->to_array;
}

my $before = retired_ids();
ok scalar @$before >= 2,
    'the platform offers the seeded tenant-scoped hybrid plan plus the NULL-metadata fixture';

# --- the in-transaction pre-flight -------------------------------------------
# Subscribe a tenant to the plan about to be retired.  The deploy must refuse,
# and must leave no trace: no suspended rows, no sqitch.changes entry.
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = 'registry'},
    $plus_plan_id );

dies_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' ) }
    'the deploy refuses to run while a tenant is subscribed to the plan';
is_deeply retired_ids(), $before,
    'the refused deploy suspended nothing';
is $db->query( q{SELECT count(*) FROM sqitch.changes WHERE change = 'retire-registry-plus-plan'} )
      ->array->[0], 0,
    'the refused deploy recorded no change';

$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = 'registry'} );

# A tenant buying Registry through a reseller: its platform plan is a
# tenant-scoped hybrid plan, so it matches the pre-flight's first two conditions
# and only the EXISTS keeps it out.  Left set for the rest of the run -- the
# deploy below has to succeed with this row in place.
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE id = ?},
    $b2b_plan_id, $reseller_id );

# --- the deploy proper -------------------------------------------------------
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'retire-registry-plus-plan' ) }
    'the deploy runs once no tenant is subscribed to a platform-offered one';

is_deeply retired_ids(), [],
    'no active platform relationship offers a tenant-scoped hybrid plan';
is_deeply stamped_ids(), $before,
    'the change stamped exactly the rows it suspended';
is rel_status($customer_rel_id), 'active',
    'a tenant-authored customer-scoped hybrid plan is left active';
is rel_status($b2b_rel_id), 'active',
    "a reseller's own tenant-scoped hybrid offer is left active";
is rel_status($standard_rel_id), 'active',
    'a standard plan with pricing_model_type hybrid is left active';
ok scalar( grep { $_ eq $null_meta_rel_id } @{ stamped_ids() } ),
    'a row whose metadata was NULL comes back stamped, not NULL';
is rel_status($cancelled_rel_id), 'cancelled',
    'a relationship already cancelled on the retired plan is left cancelled';

# --- the revert --------------------------------------------------------------
# A row this change suspended, then cancelled by a human afterwards.  The
# revert's status guard must leave it cancelled: the stamp is a handle for
# finding the row, not a licence to overwrite whatever it says now.
$db->query( q{UPDATE registry.pricing_relationships SET status = 'cancelled' WHERE id = ?},
    $before->[0] );

lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'retire-registry-plus-plan^', '-y' ) }
    'the revert runs';

is rel_status( $before->[0] ), 'cancelled',
    'the revert does not resurrect a row cancelled after suspension';
is_deeply retired_ids(), [ grep { $_ ne $before->[0] } @$before ],
    'reverting re-activates every row the change suspended and no other';
# Not [] -- the cancelled row keeps its stamp, because the revert's status guard
# skips it and nothing else strips the key.  Step 4 says why that is deliberate.
# Asserting [] here would quietly re-introduce the resurrection bug: the only way
# to make it true is to drop the guard.
is_deeply stamped_ids(), [ $before->[0] ],
    'reverting strips the stamp from every row it re-activated, and only those';

done_testing;
