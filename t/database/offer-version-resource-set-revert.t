#!/usr/bin/env perl
# ABOUTME: Reverting offer-version-resource-set leaves every tenant writable, including one cloned after deploy.
# ABOUTME: Also: the revert refuses an empty set draft by name, before the restored check would.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use experimental 'signatures';

my $CHANGE = 'offer-version-resource-set';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;

# Sqitch's exception says only that psql failed; the migration's message is on stderr.
sub sqitch (@args) {
    my ( undef, $err, $ok ) = capture { eval { App::Sqitch->new->run( 'sqitch', @args ); 1 } };
    die $err unless $ok;
}
sub deploy () { sqitch( 'deploy', '-t', $uri, '--to', $CHANGE ) }
sub revert () { sqitch( 'revert', '-t', $uri, '--to', "$CHANGE^", '-y' ) }

lives_ok { sqitch( 'deploy', '-t', $uri, '--to', "$CHANGE^" ) } 'deploy to the parent succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub provision ($slug) {
    $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', $slug, $slug );
    $db->query( 'SELECT registry.clone_schema(dest_schema => ?)', $slug );
}

# Slugs ending in "registry" (slug_for_name makes "Kids Registry" kidsregistry)
# contain the text the rebuild strips; one provisioned before deploy, the
# others after, so clone_schema copies the set-aware guards into them.
provision('kidsregistry');
lives_ok { deploy() } 'deploy to the change succeeds';
provision($_) for qw( late xregistry );
my @TENANTS = qw( late kidsregistry xregistry );
my @GUARDS  = qw( entitlement_one_platform_term offer_versions_keep_platform_offer
                  resources_keep_platform_offer_name );

subtest 'revert refuses an empty set draft by name' => sub {
    my $offer = $db->query(q{INSERT INTO registry.offers (name) VALUES ('Empty') RETURNING id})->array->[0];
    my $draft = $db->query( q{
        INSERT INTO registry.offer_versions
            (offer_id, version, price_cents, units_per_acceptance, per_booking_cap, policies)
        VALUES (?, 1, 0, 1, 1, '{}') RETURNING id
    }, $offer )->array->[0];
    throws_ok { revert() } qr/\Q$draft\E.*buys neither a resource nor a class/s,
        'the refusal names the draft and why';
    $db->query( 'DELETE FROM registry.offer_versions WHERE id = ?', $draft );
    $db->query( 'DELETE FROM registry.offers WHERE id = ?', $offer );
};

lives_ok { revert() } 'the revert runs';

for my $slug (@TENANTS) {
    subtest "tenant $slug still writes after revert" => sub {
        # As the app connects to a tenant: its own schema first.
        my $own = Mojo::Pg->new($uri)->search_path( [$slug] )->db;
        my $resource = $own->query(
            q{INSERT INTO resources (name, kind) VALUES ('payment processing', 'unbounded') RETURNING id})->array->[0];
        lives_ok { $own->query( q{UPDATE resources SET name = 'renamed' WHERE id = ?}, $resource ) }
            'a resource is renamed';

        my $tenant  = $own->query(q{INSERT INTO tenants (name, slug) VALUES ('Me', 'me') RETURNING id})->array->[0];
        my $offer   = $own->query(q{INSERT INTO offers (name) VALUES ('Own') RETURNING id})->array->[0];
        my $tx      = $own->begin;
        my $version = $own->query( q{
            INSERT INTO offer_versions
                (offer_id, version, resource_id, price_cents, units_per_acceptance, per_booking_cap, policies)
            VALUES (?, 1, ?, 0, 1, 1, '{"refund": {"kind": "none"}}') RETURNING id
        }, $offer, $resource )->array->[0];
        $own->query( q{INSERT INTO offer_version_payment_plans (offer_version_id, id, kind) VALUES (?, 'pay', 'one_time')},
            $version );
        $own->query( 'UPDATE offer_versions SET published_at = now() WHERE id = ?', $version );
        $tx->commit;
        lives_ok {
            $own->query( q{
                INSERT INTO entitlements (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
                VALUES (?, ?, 'pay', tstzrange(now(), NULL, '[)'))
            }, $tenant, $version )
        } 'an entitlement is recorded';
    };
}

subtest 'rebuilt guards match a fresh clone and land nowhere else' => sub {
    provision('fresh');
    my $body = sub ( $schema, $fn ) {
        $db->query( q{SELECT p.prosrc FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                       WHERE n.nspname = ? AND p.proname = ?}, $schema, $fn )->array->[0];
    };
    for my $fn (@GUARDS) {
        is $body->( $_, $fn ), $body->( 'fresh', $fn ), "$_.$fn is byte for byte a fresh clone's" for @TENANTS;
    }
    is_deeply $db->query( q{
        SELECT n.nspname || '.' || p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname NOT IN ('registry', 'fresh', 'pg_catalog', 'information_schema')
           AND n.nspname <> ALL (?::text[])
           AND EXISTS (SELECT 1 FROM unnest(?::text[]) g WHERE p.proname LIKE '%' || g)
    }, \@TENANTS, \@GUARDS )->arrays->flatten->to_array, [], 'no guard copy, under any prefix, strays into another schema';
};

lives_ok { deploy() } 'the redeploy runs';

done_testing;
