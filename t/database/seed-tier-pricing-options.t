#!/usr/bin/env perl
# ABOUTME: The tier seeding is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it seeds by stamp, refuses a name it did not create, and reverts only its own rows.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';
use constant CHANGE        => 'seed-tier-pricing-options';

# CONTRIBUTING requires a data-only change to carry its own round-trip test,
# because the schema dump cannot see it and @CHANGES would buy an assertion that
# cannot fail. This file exists for that, and every fixture below kills a
# specific mutation of the deploy or revert scripts.

my $pgsql  = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE . '^' ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub tier_rows {
    return $db->query(q{
        SELECT plan_name, metadata->>'created_by_migration' AS by
          FROM registry.pricing_plans
         WHERE plan_scope = 'tenant'
           AND metadata->>'coming_soon' = 'true'
         ORDER BY plan_name
    })->hashes->to_array;
}

subtest 'the deploy seeds both anchors and stamps them' => sub {
    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) }
        'deploy succeeds';

    my $rows = tier_rows();
    is scalar @$rows, 2, 'two anchor tiers exist';
    is_deeply [ map { $_->{plan_name} } @$rows ], [qw( Empire Studio )],
        'Studio and Empire, by name';
    is scalar( grep { ( $_->{by} // '' ) eq CHANGE } @$rows ), 2,
        'and both carry this change as their provenance';
};

subtest 'the revert removes only what the deploy created' => sub {
    # An operator's own anchor tier, with no stamp. The revert deleted every
    # unreferenced coming-soon tenant plan at one point, which took this row
    # with it -- and did so on a FAILED deploy, because deploy.verify is on and
    # sqitch reverts what it could not verify.
    $db->query(q{
        INSERT INTO registry.pricing_plans (
            plan_scope, plan_name, plan_type, pricing_model_type,
            amount_cents, currency, pricing_configuration, metadata
        ) VALUES (
            'tenant', 'Operator Tier', 'standard', 'hybrid', 4900, 'USD',
            '{"percentage": 0.03}'::jsonb,
            '{"coming_soon": true, "display_order": 9}'::jsonb
        )
    });

    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', CHANGE . '^', '-y' ) }
        'revert succeeds';

    my $rows = tier_rows();
    is_deeply [ map { $_->{plan_name} } @$rows ], ['Operator Tier'],
        "the operator's tier survives; only the seeded pair is removed";

    is $db->query(q{
        SELECT COUNT(*) FROM registry.pricing_relationships
         WHERE metadata->>'created_by_migration' = ?
    }, CHANGE)->array->[0], 0, 'and their relationships go with them';

    # The rate change owns the name; reverting the tier change must hand it back
    # rather than leave the plan called Solo with no tier ladder around it.
    is $db->query(q{
        SELECT plan_name FROM registry.pricing_plans
         WHERE metadata->>'launch_rate' = 'true'
    })->array->[0], 'Registry Revenue Share',
        'and the buyable plan is handed back to the previous change';
};

subtest 'the deploy refuses a name it did not create' => sub {
    # 'Operator Tier' is still present from the subtest above; give it the name
    # the change wants. Adopting it silently would leave it without a
    # relationship, which the verify reads as a missing anchor -- and then
    # deploy.verify reverts, which is how the row got deleted before.
    $db->query(
        q{UPDATE registry.pricing_plans SET plan_name = 'Studio'
           WHERE plan_name = 'Operator Tier'} );

    dies_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) }
        'the deploy fails rather than adopting a plan it does not own';

    is $db->query(
        q{SELECT COUNT(*) FROM registry.pricing_plans WHERE plan_name = 'Studio'}
    )->array->[0], 1, 'and the operator row is still there afterwards';
};

done_testing;
