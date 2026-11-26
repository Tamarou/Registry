#!/usr/bin/env perl
# ABOUTME: solo-grants-workflow-set publishes the Solo version whose stored set grants payment processing and every shipped workflow's run right.
# ABOUTME: It supersedes the unheld Solo v1 on the same terms, refuses while v1 has a holder, and its revert restores v1.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Capture::Tiny qw( capture_stderr );
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Mojo::Home;
use YAML::XS ();
use Registry::WorkflowDivergence;
use experimental 'signatures';

my $CHANGE  = 'solo-grants-workflow-set';
my $SOLO    = '00000000-0000-0000-0002-000000000001';
my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';

# Every non-draft workflow shipped in workflows/, less those never copied to a tenant.
my @SHIPPED = sort grep { !Registry::WorkflowDivergence::never_copied($_) }
    map  { $_->{slug} } grep { !$_->{draft} }
    map  { YAML::XS::Load( $_->slurp ) } Mojo::Home->new->child('workflows')->list->grep(qr/\.ya?ml$/)->each;

my $sqitch = App::Sqitch->new();

# A database deployed to the change's parent.
sub at_parent () {
    my $pg = Test::PostgreSQL->new() or die $Test::PostgreSQL::errstr;
    $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', "$CHANGE^" );
    return ( $pg, Mojo::Pg->new( $pg->uri )->db );
}

sub current_solo ($db) {
    return $db->query( q{SELECT * FROM registry.offer_versions
                          WHERE offer_id = ? AND published_at IS NOT NULL AND superseded_at IS NULL}, $SOLO )
        ->hash;
}

sub set_names ( $db, $version_id ) {
    return $db->query( q{SELECT r.name FROM registry.offer_version_resources s
                           JOIN registry.resources r ON r.id = s.resource_id
                          WHERE s.offer_version_id = ? ORDER BY r.name}, $version_id )->arrays->map( sub { $_->[0] } )
        ->to_array;
}

sub plans ( $db, $version_id ) {
    return $db->query( 'SELECT id, kind, fraction FROM registry.offer_version_payment_plans
                         WHERE offer_version_id = ? ORDER BY id', $version_id )->hashes->to_array;
}

# What a holder agreed to, less the columns a new version must differ in.
sub terms ($v) {
    my %t = %$v;
    delete @t{qw( id version resource_id published_at superseded_at created_at )};
    return \%t;
}

sub resource_count ($db) { $db->query('SELECT count(*) FROM registry.resources')->array->[0] }

sub tenant_holding ( $db, $version_id, $slug ) {
    my $tenant = $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?) RETURNING id', "T $slug", $slug )
        ->array->[0];
    $db->query( q{INSERT INTO registry.entitlements (holder_tenant_id, offer_version_id, payment_plan_id, in_effect)
                  VALUES (?, ?, 'revenue_share', tstzrange(now(), NULL, '[)'))}, $tenant, $version_id );
}

ok scalar @SHIPPED > 30, scalar(@SHIPPED) . ' shipped workflows are read from workflows/';

my ( $pg, $db ) = at_parent();
my $v1         = current_solo($db);
my $v1_plans   = plans( $db, $SOLO_V1 );
my $resources  = resource_count($db);
# A run resource that already exists, as workflow-run-entitlements leaves one
# where registry held the workflow at its deploy: reused, never duplicated.
my $held_run = $db->query( q{INSERT INTO registry.resources (name, kind) VALUES ('run:admin-dashboard', 'unbounded')
                             RETURNING id} )->array->[0];

subtest 'deploy publishes a Solo version listing every shipped workflow' => sub {
    is $v1->{id}, $SOLO_V1, 'Solo v1 is current at the parent';

    lives_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', $CHANGE ) } 'the deploy runs';
    lives_ok { $sqitch->run( 'sqitch', 'verify', '-t', $pg->uri ) } 'every verify passes';

    my $v2 = current_solo($db) or return fail 'no current Solo version';
    isnt $v2->{id}, $SOLO_V1, 'a new Solo version is current';
    is $v2->{version}, 2, 'it is version 2';
    is $v2->{resource_id}, undef, 'it buys a set, not one resource';
    ok $db->query( 'SELECT superseded_at IS NOT NULL FROM registry.offer_versions WHERE id = ?', $SOLO_V1 )
        ->array->[0], 'Solo v1 is superseded';
    is_deeply terms($v2), terms($v1), 'price, currency, policies, units, cap and conditions are v1\'s';
    is_deeply plans( $db, $v2->{id} ), $v1_plans, 'the revenue-share plan is v1\'s';
    is_deeply set_names( $db, $v2->{id} ), [ sort( 'payment processing', map {"run:$_"} @SHIPPED ) ],
        'its stored set is payment processing and a run right for each shipped workflow';
    ok !( grep { $_ eq 'run:tenant-signup' || $_ eq 'run:registry-storefront' } set_names( $db, $v2->{id} )->@* ),
        'never-copied workflows are not listed';
    ok $db->query( 'SELECT 1 FROM registry.offer_version_resources WHERE offer_version_id = ? AND resource_id = ?',
        $v2->{id}, $held_run )->rows, 'an existing run resource is reused by name';
    ok $db->query( q{SELECT 1 FROM registry.offer_version_resources
                      WHERE offer_version_id = ? AND resource_id = '00000000-0000-0000-0001-000000000011'},
        $v2->{id} )->rows, 'so is the bootstrap\'s run:offer-publishing';
    is $db->query( q{SELECT count(*) FROM registry.resources WHERE name LIKE 'run:%' GROUP BY name
                      ORDER BY 1 DESC LIMIT 1} )->array->[0], 1, 'no run resource is duplicated';
};

subtest 'revert restores Solo v1 as current' => sub {
    my $v2 = current_solo($db);
    lives_ok { $sqitch->run( 'sqitch', 'revert', '-t', $pg->uri, '--to', "$CHANGE^", '-y' ) } 'the revert runs';
    is current_solo($db)->{id}, $SOLO_V1, 'Solo v1 is current again';
    is_deeply current_solo($db), $v1, 'unchanged';
    is $db->query( 'SELECT count(*) FROM registry.offer_versions WHERE id = ?', $v2->{id} )->array->[0], 0,
        'the workflow-set version is gone';
    is $db->query( 'SELECT count(*) FROM registry.offer_version_resources WHERE offer_version_id = ?', $v2->{id} )
        ->array->[0], 0, 'with its set';
    is resource_count($db), $resources + 1, 'only the resources it created are removed';
    ok $db->query( 'SELECT 1 FROM registry.resources WHERE id = ?', $held_run )->rows, 'a reused one stays';
};

subtest 'deploy refuses to supersede Solo v1 while a tenant holds it' => sub {
    my ( $pg2, $db2 ) = at_parent();
    tenant_holding( $db2, $SOLO_V1, 'holds_v1' );
    my $stderr = capture_stderr {
        dies_ok { $sqitch->run( 'sqitch', 'deploy', '-t', $pg2->uri, '--to', $CHANGE ) } 'the deploy fails';
    };
    like $stderr, qr/cannot supersede Solo v1: tenants \[holds_v1\] hold it/, 'naming the holder';
    is current_solo($db2)->{id}, $SOLO_V1, 'Solo v1 is still current';
    is $db2->query( 'SELECT count(*) FROM registry.offer_versions WHERE offer_id = ?', $SOLO )->array->[0], 1,
        'no other Solo version exists';
    undef $db2;    # before its server stops
};

subtest 'revert refuses while a tenant holds the workflow-set version' => sub {
    my ( $pg3, $db3 ) = at_parent();
    $sqitch->run( 'sqitch', 'deploy', '-t', $pg3->uri, '--to', $CHANGE );
    my $v2 = current_solo($db3);
    tenant_holding( $db3, $v2->{id}, 'holds_v2' );
    my $stderr = capture_stderr {
        dies_ok { $sqitch->run( 'sqitch', 'revert', '-t', $pg3->uri, '--to', "$CHANGE^", '-y' ) } 'the revert fails';
    };
    like $stderr, qr/cannot revert solo-grants-workflow-set: tenants \[holds_v2\] hold/, 'naming the holder';
    is current_solo($db3)->{id}, $v2->{id}, 'the workflow-set version is still current';
    undef $db3;
};

undef $db;

done_testing;
