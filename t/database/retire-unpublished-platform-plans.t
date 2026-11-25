#!/usr/bin/env perl
# ABOUTME: Retiring the migration-authored platform plans leaves Solo as the platform's only offer to tenants.
# ABOUTME: Asserts referenced rows are kept superseded, tenant rows are untouched, and the revert restores by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Registry::PriceOps::PlatformTerms qw(platform_offers_to_tenants);
use experimental 'signatures';

my $CHANGE = 'retire-unpublished-platform-plans';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$CHANGE^" ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub deploy ()  { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) }
sub revert ()  { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }
sub plans ()   { $db->query(q{SELECT * FROM registry.pricing_plans ORDER BY id})->hashes->to_array }

# The platform's plans for tenants still current: what signup could ever show.
sub current_platform_plans () {
    return $db->query(
        q{SELECT * FROM registry.pricing_plans
           WHERE plan_scope IN ('tenant', 'platform') AND superseded_at IS NULL
           ORDER BY id}
    )->hashes->to_array;
}

my %seeded = map { $_->{seeded_tier} => $_->{id} } $db->query(
    q{SELECT id, metadata->>'seeded_tier' AS seeded_tier FROM registry.pricing_plans
       WHERE metadata->>'created_by_migration' = 'seed-tier-pricing-options'}
)->hashes->@*;
is_deeply [ sort keys %seeded ], [qw( Empire Studio )], 'the parent holds the seeded Studio and Empire anchors';

my $solo = $db->query(
    q{SELECT * FROM registry.pricing_plans WHERE metadata->>'launch_rate' = 'true'})->hashes->to_array;
is scalar @$solo, 1, 'and one launch-rate (Solo) plan row';

my $user_id = $db->query(
    q{INSERT INTO registry.users (username) VALUES ('retire-fixture') RETURNING id})->hash->{id};
$db->query(q{SELECT registry.clone_schema('retirefx')});
$db->query(q{INSERT INTO registry.tenants (name, slug) VALUES ('Retire Fixture', 'retirefx')});
$db->query( q{INSERT INTO retirefx.users (id, username) VALUES (?, 'retire-fixture')}, $user_id );

subtest 'platform publishes only solo after deploy' => sub {
    my $before = plans();

    lives_ok { deploy() } 'the deploy runs';

    my $offers = platform_offers_to_tenants($db);
    is scalar @$offers, 1, 'the platform publishes exactly one offer to tenants';
    is $offers->[0]{name},         'Solo',  'and it is Solo';
    is $offers->[0]{amount_cents}, 0,       'at $0';
    is $offers->[0]{fraction},     '0.025', 'plus 2.5% of each sale';

    is_deeply current_platform_plans(), $solo,
        'no Studio, Empire, Registry Plus, Registry Standard or Free plan row remains current';
    my $after = plans();

    lives_ok { revert() } 'the revert runs';
    is_deeply plans(), $before, 'the revert restores every plan row by id, as it was';

    lives_ok { deploy() } 'the redeploy runs';
    is_deeply plans(), $after, 'and the redeploy returns to the same end state';

    lives_ok { revert() } 'back to the parent';
};

subtest 'stamped retired plan kept unoffered' => sub {
    my $before = plans();
    my %payment;
    for my $schema (qw( registry retirefx )) {
        $payment{$schema} = $db->query(
            qq{INSERT INTO $schema.payments (user_id, platform_offer_version_id)
               VALUES (?, ?) RETURNING id}, $user_id, $seeded{Studio} )->hash->{id};
    }

    lives_ok { deploy() } 'the deploy runs while payments stamp Studio';

    my $studio = $db->query( q{SELECT * FROM registry.pricing_plans WHERE id = ?}, $seeded{Studio} )->hash;
    ok $studio, 'the stamped Studio row is kept';
    ok defined $studio->{superseded_at}, 'but superseded, so it is not offered';
    ok !$db->query( q{SELECT 1 FROM registry.pricing_plans WHERE id = ?}, $seeded{Empire} )->rows,
        'the unreferenced Empire row is deleted';
    is_deeply current_platform_plans(), $solo, 'Solo is still the only current platform plan';

    for my $schema (qw( registry retirefx )) {
        is $db->query(
            qq{SELECT p.plan_name FROM $schema.payments pay
                 JOIN registry.pricing_plans p ON p.id = pay.platform_offer_version_id
                WHERE pay.id = ?}, $payment{$schema} )->array->[0],
            'Studio', "the $schema payment's stamp still resolves";
    }

    lives_ok { revert() } 'the revert runs';
    is_deeply plans(), $before, 'the revert un-supersedes the kept row and restores the deleted ones';

    # Fixtures, not history: under the stamp's fixed-once-set trigger.
    $db->query(q{SET session_replication_role = replica});
    $db->query( qq{DELETE FROM $_.payments WHERE id = ?}, $payment{$_} ) for keys %payment;
    $db->query(q{SET session_replication_role = DEFAULT});
};

subtest 'tenant offer named like a retired plan survives' => sub {
    my $plan = $db->query(
        q{INSERT INTO retirefx.pricing_plans (plan_scope, plan_name, plan_type, metadata)
          VALUES ('tenant', 'Studio', 'standard',
                  '{"coming_soon": true, "seeded_tier": "Studio",
                    "created_by_migration": "seed-tier-pricing-options"}')
          RETURNING *})->hash;
    my $offer = $db->query(
        q{INSERT INTO retirefx.offers (name) VALUES ('Studio') RETURNING *})->hash;

    lives_ok { deploy() } 'the deploy runs';
    is_deeply $db->query( q{SELECT * FROM retirefx.pricing_plans WHERE id = ?}, $plan->{id} )->hash,
        $plan, "the tenant's own plan named Studio is untouched";
    is_deeply $db->query( q{SELECT * FROM retirefx.offers WHERE id = ?}, $offer->{id} )->hash,
        $offer, "and so is its offer named Studio";

    lives_ok { revert() } 'the revert runs';
};

done_testing;
