#!/usr/bin/env perl
# ABOUTME: The bootstrap seeds Solo v1, the platform's offers to itself and registry's entitlements to them.
# ABOUTME: A data change, invisible to the schema revert harness, so it deploys to its parent and back here.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;

use constant PLATFORM_UUID => '00000000-0000-0000-0000-000000000000';
use constant CHANGE        => 'bootstrap-platform-offers';

my $pgsql  = Test::PostgreSQL->new() or plan skip_all => $Test::PostgreSQL::errstr;
my $uri    = $pgsql->uri;
my $sqitch = App::Sqitch->new();

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE . '^' ) }
    'deploy to the parent change succeeds';
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', CHANGE ) }
    'deploy the bootstrap offers';

my $db = Mojo::Pg->new($uri)->db;

# The platform's current published versions offered to tenants: those not
# restricted to the platform itself by holder_is_offerer.
sub offered_to_tenants () {
    return $db->query( q{
        SELECT v.*, o.name AS offer_name, r.name AS resource_name
          FROM registry.offer_versions v
          JOIN registry.offers o    ON o.id = v.offer_id
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE v.published_at IS NOT NULL AND v.superseded_at IS NULL
           AND NOT v.conditions @> '[{"kind": "holder_is_offerer"}]'
    } )->expand->hashes->to_array;
}

sub plans_of ($version_id) {
    return $db->query( q{
        SELECT id, kind, fraction FROM registry.offer_version_payment_plans
         WHERE offer_version_id = ? ORDER BY id
    }, $version_id )->hashes->to_array;
}

subtest 'bootstrap publishes solo v1 only' => sub {
    my $offered = offered_to_tenants();
    is scalar @$offered, 1, 'the platform offers tenants exactly one current version';
    my $solo = $offered->[0];
    is $solo->{offer_name},    'Solo',               'it is Solo';
    is $solo->{version},       1,                    'version 1';
    is $solo->{resource_name}, 'payment processing', 'it buys payment processing';
    is $solo->{price_cents},   0,                    'at $0';
    is $solo->{policies}{refund}{kind}, 'keep_fee_with_admin_exception',
        'refund policy keeps the fee, with an admin exception';

    my $plans = plans_of( $solo->{id} );
    is scalar @$plans, 1, 'one payment plan';
    is $plans->[0]{kind}, 'percentage_of_sales', 'a percentage of sales';
    cmp_ok $plans->[0]{fraction}, '==', 0.025, 'at 2.5%';
};

# Entitlements in effect now, with what they bought and under which plan.
sub held_now ( $holder = PLATFORM_UUID ) {
    return $db->query( q{
        SELECT e.*, v.price_cents, v.conditions, r.name AS resource_name, r.kind AS resource_kind,
               r.capacity, p.kind AS plan_kind, p.fraction
          FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r      ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p
               ON p.offer_version_id = e.offer_version_id AND p.id = e.payment_plan_id
         WHERE e.holder_tenant_id = ? AND e.in_effect @> now()
         ORDER BY r.name
    }, $holder )->expand->hashes->to_array;
}

sub held_for ($resource) { [ grep { $_->{resource_name} eq $resource } held_now()->@* ] }

subtest 'platform holds its explicit zero percent self offer' => sub {
    my $held = held_for('payment processing');
    is scalar @$held, 1, 'registry holds one payment-processing entitlement';
    is $held->[0]{plan_kind}, 'percentage_of_sales', 'under a percentage-of-sales plan';
    ok defined $held->[0]{fraction} && $held->[0]{fraction} == 0, 'of exactly 0';
};

subtest 'platform holds uncapped email sending' => sub {
    my $held = held_for('email sending');
    is scalar @$held, 1, 'registry holds one email-sending entitlement';
    is $held->[0]{resource_kind}, 'unbounded', 'email sending is unbounded';
    is $held->[0]{capacity}, undef, 'with no capacity';
};

subtest 'self offers carry holder is offerer and solo does not' => sub {
    my $solo = $db->query( q{
        SELECT v.conditions FROM registry.offer_versions v
          JOIN registry.offers o ON o.id = v.offer_id
         WHERE o.name = 'Solo' AND v.version = 1
    } )->expand->hash;
    is_deeply $solo->{conditions}, [], 'Solo v1 carries no condition';

    my $held = held_now();
    ok scalar @$held, 'registry holds the platform offers to itself';
    is_deeply $_->{conditions}, [ { kind => 'holder_is_offerer' } ],
        "the self offer for $_->{resource_name} is restricted to the platform"
        for @$held;
};

done_testing;
