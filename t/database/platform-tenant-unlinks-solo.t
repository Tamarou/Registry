#!/usr/bin/env perl
# ABOUTME: platform-tenant-unlinks-solo clears only the platform row's plan link, whatever plan it names.
# ABOUTME: Deploys to the change's parent and back, so it reads the link column only at its own point in history.

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

# 'NAME^' is sqitch's one-before offset; naming the change under test keeps
# this right when a later change is appended to the plan.
lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'platform-tenant-unlinks-solo^' ) }
    'deploy to the parent change succeeds';

my $db = Mojo::Pg->new($uri)->db;

sub plan_id_named ($name) {
    return $db->query( q{SELECT id FROM registry.pricing_plans WHERE plan_name = ? ORDER BY created_at LIMIT 1}, $name )
        ->hash->{id};
}

sub link_of ($id) {
    return $db->query( q{SELECT platform_pricing_plan_id FROM registry.tenants WHERE id = ?}, $id )
        ->hash->{platform_pricing_plan_id};
}

my $solo_id   = plan_id_named('Solo');
my $studio_id = plan_id_named('Studio');
ok $solo_id && $studio_id, 'the seed holds the Solo and Studio plans';

my $solo_before = $db->query( q{SELECT id, pricing_configuration->>'percentage' AS pct FROM registry.pricing_plans WHERE id = ?}, $solo_id )->hash;

# Not Solo: the deploy must clear the platform's link whatever it names.
$db->query( q{UPDATE registry.tenants SET platform_pricing_plan_id = ? WHERE id = ?}, $studio_id, PLATFORM_UUID );

my $solo_tenant = $db->query(
    q{INSERT INTO registry.tenants (name, slug, platform_pricing_plan_id) VALUES ('Solo Studio', 'solo_studio', ?) RETURNING id},
    $solo_id )->hash->{id};
my $unlinked_tenant = $db->query(
    q{INSERT INTO registry.tenants (name, slug, platform_pricing_plan_id) VALUES ('Unlinked Studio', 'unlinked_studio', NULL) RETURNING id}
)->hash->{id};

lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $uri, '--to', 'platform-tenant-unlinks-solo' ) }
    'the change deploys';

subtest 'the registry link is cleared whatever plan it names' => sub {
    is link_of(PLATFORM_UUID), undef, 'the platform row links no plan, though it named Studio';
};

subtest 'the migration changes no other tenant link' => sub {
    is link_of($solo_tenant), $solo_id, 'the Solo tenant still names Solo';
    is link_of($unlinked_tenant), undef, 'the unlinked tenant is still unlinked';

    # Read through the link as the resolver of this point in history did;
    # today's resolver reads entitlements, which do not exist yet here.
    cmp_ok $db->query( q{SELECT (p.pricing_configuration->>'percentage')::numeric FROM registry.tenants t
                          JOIN registry.pricing_plans p ON p.id = t.platform_pricing_plan_id
                         WHERE t.slug = 'solo_studio'} )->array->[0], '==', 0.025,
        'and the Solo tenant still links the Solo rate';
};

subtest 'the solo plan row is unchanged by clearing the link' => sub {
    my $after = $db->query( q{SELECT id, pricing_configuration->>'percentage' AS pct FROM registry.pricing_plans WHERE id = ?}, $solo_id )->hash;
    is_deeply $after, $solo_before, 'same id, same rate';
};

lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $uri, '--to', 'platform-tenant-unlinks-solo^', '-y' ) }
    'the revert runs';
is link_of(PLATFORM_UUID), $solo_id, 'the revert re-links the platform to Solo';
is link_of($solo_tenant), $solo_id, 'and leaves the Solo tenant on Solo';

done_testing;
