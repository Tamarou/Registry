#!/usr/bin/env perl
# ABOUTME: solo-grants-session-workflows publishes Solo v3: v2's terms and set plus the four session workflows' run rights.
# ABOUTME: Each active v2 holder moves onto v3 on identical terms, and the change refuses if v3's terms would differ from v2's.

use 5.42.0;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Capture::Tiny qw( capture_stderr );
use App::Sqitch;
use Test::PostgreSQL;
use Mojo::Pg;
use Registry::DAO::Entitlement;
use experimental 'signatures';

my $CHANGE   = 'solo-grants-session-workflows';
my $SOLO     = '00000000-0000-0000-0002-000000000001';
my @SESSION  = qw( session-setup session-checkout entitlement-decision makeup-booking );

my $sqitch = App::Sqitch->new();

# A database deployed to the change's parent, where Solo v2 is current.
sub at_parent () {
    my $pg = Test::PostgreSQL->new() or die $Test::PostgreSQL::errstr;
    $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', "$CHANGE^" );
    return ( $pg, Mojo::Pg->new( $pg->uri )->db );
}

sub deploy ($pg) { $sqitch->run( 'sqitch', 'deploy', '-t', $pg->uri, '--to', $CHANGE ) }

sub solo_current ($db) {
    return $db->query( q{SELECT v.*, p.fraction FROM registry.offer_versions v
                           JOIN registry.offer_version_payment_plans p
                             ON p.offer_version_id = v.id AND p.id = 'revenue_share'
                          WHERE v.offer_id = ? AND v.published_at IS NOT NULL AND v.superseded_at IS NULL}, $SOLO )
        ->hash;
}

sub set_names ( $db, $version_id ) {
    return $db->query( q{SELECT r.name FROM registry.offer_version_resources s
                           JOIN registry.resources r ON r.id = s.resource_id
                          WHERE s.offer_version_id = ? ORDER BY r.name}, $version_id )->arrays->flatten->to_array;
}

sub listed ( $db, $version_id, $name ) { scalar grep { $_ eq $name } set_names( $db, $version_id )->@* }

sub tenant_holding ( $db, $version_id, $slug ) {
    my $tenant = $db->query( 'INSERT INTO registry.tenants (name, slug) VALUES (?, ?) RETURNING id', "T $slug", $slug )
        ->array->[0];
    my $e = $db->query( q{INSERT INTO registry.entitlements
                              (holder_tenant_id, offer_version_id, payment_plan_id, in_effect, terms_version)
                          VALUES (?, ?, 'revenue_share', tstzrange(now() - interval '1 day', NULL, '[)'), '2026-11-01')
                          RETURNING id}, $tenant, $version_id )->array->[0];
    return ( $tenant, $e );
}

subtest 'solo v3 lists the session workflows and supersedes v2' => sub {
    my ( $pg, $db ) = at_parent();
    my $v2 = solo_current($db);
    is $v2->{version}, 2, 'Solo v2 is current at the parent';

    lives_ok { deploy($pg) } 'the deploy runs';
    lives_ok { $sqitch->run( 'sqitch', 'verify', '-t', $pg->uri ) } 'every verify passes';

    my $v3 = solo_current($db) or return fail 'no current Solo version';
    is $v3->{version}, 3, 'Solo v3 is current';
    ok $db->query( 'SELECT superseded_at IS NOT NULL FROM registry.offer_versions WHERE id = ?', $v2->{id} )
        ->array->[0], 'Solo v2 is superseded';
    ok listed( $db, $v3->{id}, "run:$_" ), "lists $_" for @SESSION;
    ok listed( $db, $v3->{id}, 'run:in-studio-booking' ), 'keeps v2 set';
    is_deeply set_names( $db, $v3->{id} ), [ sort( set_names( $db, $v2->{id} )->@*, map {"run:$_"} @SESSION ) ],
        'its set is exactly v2\'s plus the four';
    is_deeply [ $v3->@{qw( price_cents fraction )} ], [ 0, '0.025' ], 'price 0 and fraction 0.025';
    is_deeply [ $v3->@{qw( currency policies conditions units_per_acceptance per_booking_cap )} ],
        [ $v2->@{qw( currency policies conditions units_per_acceptance per_booking_cap )} ], 'the rest of v2\'s terms';
    undef $db;
};

subtest 'a tenant holding v2 is moved to v3 on identical terms' => sub {
    my ( $pg, $db ) = at_parent();
    my $v2 = solo_current($db);
    my ( $tenant_id, $old_id ) = tenant_holding( $db, $v2->{id}, 'holds_v2' );
    ok !Registry::DAO::Entitlement->may_run( $db, $tenant_id, 'session-checkout' ), 'v2 grants no session-checkout';

    lives_ok { deploy($pg) } 'the deploy runs';
    my $v3  = solo_current($db);
    my $old = $db->query( 'SELECT * FROM registry.entitlements WHERE id = ?', $old_id )->hash;
    is $old->{state},        'expired',               'the v2 entitlement ended expired';
    is $old->{ended_reason}, 'superseded by Solo v3', 'superseded by Solo v3';

    my $moved = $db->query( q{SELECT *, lower(in_effect) = ? AS from_end FROM registry.entitlements
                               WHERE holder_tenant_id = ? AND state = 'active'}, $old->{ended_at}, $tenant_id )->hash;
    is $moved->{offer_version_id}, $v3->{id},       'the tenant holds v3';
    is $moved->{payment_plan_id},  'revenue_share', 'on the same plan';
    is $moved->{terms_version},    '2026-11-01',    'under the terms version it agreed to';
    ok $moved->{from_end}, 'from the instant v2 ended';
    ok Registry::DAO::Entitlement->may_run( $db, $tenant_id, 'session-checkout' ), 'it may run session-checkout';
    ok Registry::DAO::Entitlement->may_run( $db, $tenant_id, 'in-studio-booking' ), 'and still v2\'s workflows';
    undef $db;
};

done_testing;
