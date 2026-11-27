#!/usr/bin/env perl
# ABOUTME: A tenant's right to run a workflow is an entitlement it holds from registry, one run resource per slug.
# ABOUTME: Deploys the backfill over planted workflows: registry is granted its own; a studio with copies refuses it.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use App::Sqitch;
use Capture::Tiny qw( capture );
use Test::PostgreSQL;
use Mojo::Pg;
use Test::Registry::Offers qw( published_as_migrated );
use Registry::DAO::Tenant;
use Registry::DAO::Resource;
use Registry::DAO::Entitlement;

my $CHANGE   = 'workflow-run-entitlements';
my $REGISTRY = '00000000-0000-0000-0000-000000000000';
my $PAST     = '2020-01-01T00:00:00Z';

# 01a20417-11f6's product-design run rights: slug => [resource id, entitlement id].
my %SEEDED = map {
    my ( $slug, $n ) = @$_;
    $slug => [ "00000000-0000-0000-0001-0000000000$n", "00000000-0000-0000-0004-0000000000$n" ]
} [ 'offer-publishing', 11 ], [ 'program-creation', 12 ], [ 'program-setup', 13 ],
  [ 'session-creation', 14 ], [ 'event-creation', 15 ];
my @PLATFORM = ( sort( keys %SEEDED ), qw( attendance-check tenant-signup workflow-creation ) );

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

# On registry's search_path, as Registry::DAO sets it.
my $pg = Mojo::Pg->new($uri)->search_path( [ q{registry}, q{public} ] );
my $db = $pg->db;

# A connection on tenant $slug's own schema first, as the app connects to a tenant.
my %pg_for;
sub own ($slug) { ( $pg_for{$slug} //= Mojo::Pg->new($uri)->search_path( [$slug] ) )->db }

sub provision ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT registry.clone_schema(dest_schema => ?)', $slug );
    return $tenant;
}

sub plant_workflow ( $schema, $slug ) {
    $db->query( "INSERT INTO \"$schema\".workflows (slug, name) VALUES (?, ?)", $slug, $slug );
}

sub may_run ( $tenant_id, $slug ) { Registry::DAO::Entitlement->may_run( $db, $tenant_id, $slug ) }

# The registry rows the backfill reads, as workflow import leaves them.
plant_workflow( 'registry', $_ ) for @PLATFORM;

# Studios provisioned before step 6 hold copies of registry's workflows.
provision($_) for qw( early_studio kidsregistry );
plant_workflow( 'early_studio', 'event-creation' );
plant_workflow( 'kidsregistry', 'program-setup' );

subtest 'deploy refused while a studio holds workflow copies' => sub {
    throws_ok { deploy() } qr/early_studio.*kidsregistry|kidsregistry.*early_studio/s,
        'the refusal names each studio holding copies';
    is $db->query(q{SELECT count(*) FROM registry.resources WHERE name = 'run:attendance-check'})->array->[0], 0,
        'and grants nothing';
    $db->query("DELETE FROM \"$_\".workflows") for qw( early_studio kidsregistry );
    lives_ok { deploy() } 'the change deploys once no studio holds copies';
};

subtest 'the platform tenant holds a run right for each of its workflows' => sub {
    ok may_run( $REGISTRY, $_ ), "registry may run $_" for @PLATFORM;
    for my $slug (@PLATFORM) {
        is $db->query( q{
            SELECT count(*) FROM registry.entitlements e
              JOIN registry.offer_versions v ON v.id = e.offer_version_id
              JOIN registry.resources r ON r.id = v.resource_id
             WHERE e.holder_tenant_id = ? AND r.name = ? AND e.state = 'active'
        }, $REGISTRY, "run:$slug" )->array->[0], 1, "one active run right to $slug";
    }
    ok !may_run( $REGISTRY, 'never-imported' ), 'none for a workflow registry does not hold';
};

subtest 'backfill creates no second product-design run right' => sub {
    for my $slug ( sort keys %SEEDED ) {
        is_deeply $db->query( 'SELECT id FROM registry.resources WHERE name = ?', "run:$slug" )
            ->arrays->flatten->to_array, [ $SEEDED{$slug}[0] ], "run:$slug is the seeded resource alone";
        is_deeply $db->query( q{
            SELECT e.id FROM registry.entitlements e
              JOIN registry.offer_versions v ON v.id = e.offer_version_id
             WHERE v.resource_id = ? AND e.holder_tenant_id = ?
        }, $SEEDED{$slug}[0], $REGISTRY )->arrays->flatten->to_array, [ $SEEDED{$slug}[1] ],
            "registry holds the seeded run right to $slug alone";
    }
};

# A platform set version buying run rights (ADR 004 ruling (a)), as 6c2f will
# publish through offer-publishing; built here to prove the set path. Its id.
my $made = 0;
sub run_resource ($slug) {
    my ($id) = $db->query( 'SELECT id FROM registry.resources WHERE name = ?', "run:$slug" )->arrays->flatten->each;
    return $id // Registry::DAO::Resource->create( $db, { name => "run:$slug", kind => 'unbounded' } )->id;
}
sub run_set (@slugs) {
    return published_as_migrated( $db, 'Run set ' . ++$made,
        resource_ids => [ map { run_resource($_) } @slugs ], price_cents => 0 );
}
sub grant ( $tenant, $version, %period ) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $tenant->id, offer_version_id => $version,
        payment_plan_id  => 'pay',       starts_at        => $PAST, %period,
    } );
}

subtest 'a set version grants a studio its run rights' => sub {
    my $studio = provision('set_studio');
    grant( $studio, run_set(qw( event-creation attendance-check )) );
    ok may_run( $studio->id, 'event-creation' ),   'a listed slug';
    ok may_run( $studio->id, 'attendance-check' ), 'each listed slug';
    ok !may_run( $studio->id, 'program-setup' ), 'not one the set leaves out';
};

subtest 'ended or future entitlement does not grant run' => sub {
    my $studio = provision('timed_studio');
    grant( $studio, run_set('program-setup') )->end( $db, 'expired', 'test', '2021-01-01T00:00:00Z' );
    ok !may_run( $studio->id, 'program-setup' ), 'an ended right';
    grant( $studio, run_set('session-creation'), starts_at => '2999-01-01T00:00:00Z' );
    ok !may_run( $studio->id, 'session-creation' ), 'a right not yet begun';
};

subtest 'run right granted by a non platform tenant ignored' => sub {
    my $studio = provision('self_granting');
    my $own    = own(q{self_granting});
    $own->insert( 'tenants', { id => $studio->id, name => $studio->name, slug => $studio->slug } );
    my $r = Registry::DAO::Resource->create( $own, { name => 'run:program-creation', kind => 'unbounded' } );
    my $v = published_as_migrated( $own, 'Own run', resource_id => $r->id, price_cents => 0 );
    Registry::DAO::Entitlement->create( $own,
        { holder_tenant_id => $studio->id, offer_version_id => $v, payment_plan_id => 'pay', starts_at => $PAST } );
    ok !may_run( $studio->id, 'program-creation' ), 'a right the studio records in its own schema';
    ok !Registry::DAO::Entitlement->may_run( $own, $studio->id, 'program-creation' ), 'even on its own connection';
};

subtest 'another tenants entitlement does not count' => sub {
    my ( $a, $b ) = map { provision($_) } qw( holder_a holder_b );
    grant( $a, run_set('offer-publishing') );
    ok may_run( $a->id, 'offer-publishing' ),  'the holder may run it';
    ok !may_run( $b->id, 'offer-publishing' ), 'another tenant may not';
};

subtest 'check reads live rows after revocation' => sub {
    my $studio = provision('revoked_studio');
    my $right  = grant( $studio, run_set('workflow-creation') );
    ok may_run( $studio->id, 'workflow-creation' ), 'held';
    $right->end( $db, 'refunded', 'test' );
    ok !may_run( $studio->id, 'workflow-creation' ), 'not once ended, in the same process';
};

subtest 'slug match is exact not pattern' => sub {
    my $studio = provision('exact_studio');
    grant( $studio, run_set('event-creation') );
    ok may_run( $studio->id, 'event-creation' ), 'the exact slug';
    ok !may_run( $studio->id, $_ ), "not '$_'" for 'Event-Creation', 'event-creation ', 'event%', 'event_creation',
        '%', 'no-such-workflow', '';
    ok !may_run( $studio->id, undef ), 'nor no slug';
    ok !may_run( undef, 'event-creation' ), 'nor no tenant';
};

subtest 'second overlapping run entitlement refused' => sub {
    my $studio = provision('doubled_studio');
    grant( $studio, run_set(qw( tenant-signup attendance-check )) );
    throws_ok { grant( $studio, run_set('attendance-check') ) }
        qr/already holds an active run right to run:attendance-check/,
        'a second offer covering the same workflow refused by the run-right rule';
    lives_ok { grant( $studio, run_set('program-creation') ) } 'a different workflow is not';

    my $count = sub { $db->query(q{SELECT count(*) FROM registry.entitlements WHERE holder_tenant_id = ?}, $REGISTRY)
        ->array->[0] };
    my $before = $count->();
    lives_ok { revert(); deploy() } 'the backfill reverts and redeploys';
    is $count->(), $before, 'and creates no duplicate run rights';
};

subtest 'run right regranted after the old one ends' => sub {
    my $studio = provision('regranted_studio');
    my $old    = grant( $studio, run_set('session-creation') );
    $old->end( $db, 'expired', 'test' );
    lives_ok { grant( $studio, run_set('session-creation') ) } 'a new right once the old has ended';
    ok may_run( $studio->id, 'session-creation' ), 'and it is held';
};

subtest 'a tenant cloned after deploy still writes after revert' => sub {
    my $late = provision('xregistry');
    revert();
    my $own = own(q{xregistry});
    $own->insert( 'tenants', { id => $late->id, name => $late->name, slug => $late->slug } );
    my $r = Registry::DAO::Resource->create( $own, { name => 'own', kind => 'unbounded' } );
    # Written as this test's partial deploy stands; OfferVersion follows the head schema.
    my $v = published_as_migrated( $own, 'Own', resource_id => $r->id, price_cents => 0 );
    lives_ok {
        Registry::DAO::Entitlement->create( $own,
            { holder_tenant_id => $late->id, offer_version_id => $v, payment_plan_id => 'pay', starts_at => $PAST } )
    } 'an entitlement is recorded';
    is_deeply $db->query(q{SELECT n.nspname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
                            WHERE p.proname LIKE '%one_run_right'})->arrays->flatten->to_array, [],
        'no copy of the run-right guard is left in any schema';
    lives_ok { deploy() } 'the change redeploys';
};

done_testing;
