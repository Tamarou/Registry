#!/usr/bin/env perl
# ABOUTME: The Free-plan removal is a data change, invisible to the schema revert harness.
# ABOUTME: Asserts it deletes only the platform default plan, refuses while anything references it, and reverts by id.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture_stderr );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'remove-free-platform-plan';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', "$CHANGE^" ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub free_rows {
    return $db->query(
        q{SELECT * FROM registry.pricing_plans
           WHERE plan_scope = 'platform' AND metadata->>'default' = 'true'
           ORDER BY id}
    )->hashes->to_array;
}

my $free = free_rows();
is scalar @$free, 1, 'the parent holds exactly one platform default (Free) plan';
my $free_id = $free->[0]{id};

sub stash_exists () {
    return $db->query(q{SELECT to_regclass('public.removed_free_platform_plan') IS NOT NULL AS x})
        ->hash->{x};
}

# The deploy must refuse while $plant is in place, deleting and recording
# nothing; $cleanup then removes the fixture.
sub refused_while ( $what, $plant, $cleanup ) {
    $plant->();
    my $stderr = capture_stderr {
        dies_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) }
            "the deploy refuses while $what";
    };
    like $stderr, qr/remove-free-platform-plan refused: .*references the Free plan/,
        'and says why';
    is_deeply free_rows(), $free, 'the Free row is kept';
    ok !stash_exists(), 'no kept-rows table is left behind';
    is $db->query( q{SELECT count(*) FROM sqitch.changes WHERE change = ?}, $CHANGE )->array->[0], 0,
        'the refused deploy recorded no change';
    # Cleanup goes under the deletes' own triggers and keys: published rows
    # are append-only, and these are fixtures, not history.
    $db->query(q{SET session_replication_role = replica});
    $cleanup->();
    $db->query(q{SET session_replication_role = DEFAULT});
}

# A tenant schema, as provisioning makes one, so the guard is shown to look
# beyond registry.
$db->query(q{SELECT registry.clone_schema('freefx')});
my $tenant_id = $db->query(
    q{INSERT INTO registry.tenants (name, slug) VALUES ('Free Fixture', 'freefx') RETURNING id}
)->hash->{id};
my $user_id = $db->query(
    q{INSERT INTO registry.users (username) VALUES ('free-fixture') RETURNING id})->hash->{id};
$db->query( q{INSERT INTO freefx.users (id, username) VALUES (?, 'free-fixture')}, $user_id );

subtest 'free row kept while a payment stamps it' => sub {
    for my $schema (qw( registry freefx )) {
        my $payment;
        refused_while(
            "a $schema payment stamps the Free plan's id as its platform terms",
            sub {
                $payment = $db->query(
                    qq{INSERT INTO $schema.payments (user_id, platform_offer_version_id)
                       VALUES (?, ?) RETURNING id}, $user_id, $free_id )->hash->{id};
            },
            sub { $db->query( qq{DELETE FROM $schema.payments WHERE id = ?}, $payment ) },
        );
    }

    my $payment;
    refused_while(
        "a payment item names the Free plan",
        sub {
            $payment = $db->query( q{INSERT INTO registry.payments (user_id) VALUES (?) RETURNING id},
                $user_id )->hash->{id};
            $db->query(
                q{INSERT INTO registry.payment_items (payment_id, description, pricing_plan_id)
                  VALUES (?, 'fixture', ?)}, $payment, $free_id );
        },
        sub {
            $db->query( q{DELETE FROM registry.payment_items WHERE payment_id = ?}, $payment );
            $db->query( q{DELETE FROM registry.payments WHERE id = ?}, $payment );
        },
    );
};

subtest 'free row kept while an entitlement references it' => sub {
    my ( $offer, $resource );
    my $plant_version = sub ($publish) {
        $resource = $db->query(
            q{INSERT INTO registry.resources (name, kind) VALUES ('free fixture', 'unbounded')
              RETURNING id})->hash->{id};
        $offer = $db->query(
            q{INSERT INTO registry.offers (name) VALUES ('Free fixture') RETURNING id})->hash->{id};
        $db->query(
            q{INSERT INTO registry.offer_versions
                  (id, offer_id, version, resource_id, price_cents, units_per_acceptance,
                   per_booking_cap, policies)
              VALUES (?, ?, 1, ?, 0, 1, 1, '{"refund": {"kind": "none"}}')},
            $free_id, $offer, $resource );
        return unless $publish;
        $db->query(
            q{INSERT INTO registry.offer_version_payment_plans (offer_version_id, id, kind)
              VALUES (?, 'once', 'one_time')}, $free_id );
        $db->query( q{UPDATE registry.offer_versions SET published_at = now() WHERE id = ?},
            $free_id );
    };
    my $cleanup = sub {
        $db->query( q{DELETE FROM registry.entitlements WHERE offer_version_id = ?}, $free_id );
        $db->query( q{DELETE FROM registry.offer_version_payment_plans WHERE offer_version_id = ?},
            $free_id );
        $db->query( q{DELETE FROM registry.offer_versions WHERE id = ?}, $free_id );
        $db->query( q{DELETE FROM registry.offers WHERE id = ?},    $offer );
        $db->query( q{DELETE FROM registry.resources WHERE id = ?}, $resource );
    };

    refused_while( 'an offer version carries the Free plan\'s id', sub { $plant_version->(0) },
        $cleanup );

    refused_while(
        'an entitlement is held under it',
        sub {
            $plant_version->(1);
            $db->query(
                q{INSERT INTO registry.entitlements
                      (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
                  VALUES (?, ?, 'once', tstzrange(now(), NULL, '[)'))}, $tenant_id, $free_id );
        },
        $cleanup,
    );
};

subtest 'only the free row is deleted' => sub {
    # Each sits one condition outside the Free plan's predicate.
    $db->query(
        q{INSERT INTO registry.pricing_plans (plan_name, plan_scope, metadata) VALUES
              ('Platform, unmarked',          'platform', '{}'),
              ('Platform, default false',     'platform', '{"default": false}'),
              ('Customer, marked default',    'customer', '{"default": true}'),
              ('Tenant, marked default',      'tenant',   '{"default": true}')});
    my $others = sub {
        $db->query(
            q{SELECT * FROM registry.pricing_plans WHERE id <> ? ORDER BY id}, $free_id
        )->hashes->to_array;
    };
    my $before = $others->();

    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the deploy runs';
    is_deeply $others->(), $before, 'every other plan row is untouched';
    is_deeply $db->query(q{SELECT id FROM public.removed_free_platform_plan})->arrays->flatten->to_array,
        [$free_id], 'and only the Free row is kept for the revert';

    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }
        'the revert runs';
    is_deeply $others->(), $before, 'the revert touches no other plan row';
};

subtest 'free platform plan row is deleted' => sub {
    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', $CHANGE ) } 'the deploy runs';
    is_deeply free_rows(), [], 'no platform-scope plan marked default remains';

    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }
        'the revert runs';
    is_deeply free_rows(), $free, 'the revert re-inserts the Free row by id, as it was';
};

done_testing;
