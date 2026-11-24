#!/usr/bin/env perl
# ABOUTME: platform-entitlement-replaces-plan-link gives every Solo-linked tenant a Solo v1 entitlement and drops the link.
# ABOUTME: Deploys to the change's parent to plant links, so it reads the dropped column only at its own point in history.
use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::Fixtures;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use Registry::DAO::PricingPlan;

my $CHANGE  = 'platform-entitlement-replaces-plan-link';
my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

my $pgsql = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri   = $pgsql->uri;
# Held, and on registry's search_path, as Registry::DAO sets it, for create_tenant.
my $pg    = Mojo::Pg->new($uri)->search_path( [ 'registry', 'public' ] );
my $db    = $pg->db;

sub deploy (@to) {
    # Sqitch's exception says only that psql failed; the migration's message is on stderr.
    my ( undef, $err, $ok ) = capture {
        eval { App::Sqitch->new->run( 'sqitch', 'deploy', '-t', $uri, @to ? ( '--to', @to ) : () ); 1 };
    };
    die $err unless $ok;
}

lives_ok { deploy("$CHANGE^") } 'deploy to the parent change succeeds';

my $solo = Registry::DAO::PricingPlan->find( $db, { plan_name => 'Solo', superseded_at => undef } );
ok $solo && $solo->metadata->{launch_rate}, 'the seed holds Solo, marked as the launch plan';
my $solo_v1_plan = $solo->id;
my $solo_v2_plan = $solo->revise( $db, { pricing_configuration => { percentage => 0.03 } } )->id;

sub tenant_linked_to ( $slug, $plan_id ) {
    Test::Registry::Fixtures::create_tenant( $db, { name => $slug, slug => $slug } );
    $db->query( 'UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE slug = ?', $plan_id, $slug );
    return $db->query( 'SELECT id FROM registry.tenants WHERE slug = ?', $slug )->hash->{id};
}

my %tenant = (
    solo_v1    => tenant_linked_to( 'linked_solo_v1',    $solo_v1_plan ),
    solo_later => tenant_linked_to( 'linked_solo_later', $solo_v2_plan ),
    unlinked   => tenant_linked_to( 'linked_nothing',    undef ),
);

sub platform_entitlements ($tenant_id) {
    return $db->query( q{
        SELECT e.offer_version_id, e.payment_plan_id, e.state,
               e.in_effect @> now() AS in_effect_now
          FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE e.holder_tenant_id = ? AND r.name = 'payment processing'
    }, $tenant_id )->hashes->to_array;
}

my $studio_plan = $db->query( q{SELECT id FROM registry.pricing_plans WHERE plan_name = 'Studio'} )->hash->{id};
my $studio_linked = tenant_linked_to( 'linked_studio', $studio_plan );

throws_ok { deploy($CHANGE) } qr/linked_studio.*\Q$studio_plan\E/s,
    'a tenant linked to a plan outside the Solo family fails the deploy, naming the tenant and plan';

$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = NULL WHERE slug = 'linked_studio'} );
lives_ok { deploy($CHANGE) } 'the change deploys once no tenant is linked outside Solo';

subtest 'backfill grants solo v1 and drops the link' => sub {
    for my $which (qw( solo_v1 solo_later )) {
        is_deeply platform_entitlements( $tenant{$which} ),
            [ { offer_version_id => $SOLO_V1, payment_plan_id => 'revenue_share',
                state => 'active', in_effect_now => 1 } ],
            "the tenant linked to $which holds Solo v1, in effect now";
    }
    is_deeply platform_entitlements( $tenant{unlinked} ), [], 'the unlinked tenant holds none';
    ok !$db->query( q{SELECT 1 FROM information_schema.columns WHERE table_schema = 'registry'
                       AND table_name = 'tenants' AND column_name = 'platform_pricing_plan_id'} )->rows,
        'tenants.platform_pricing_plan_id no longer exists';
};

done_testing;
