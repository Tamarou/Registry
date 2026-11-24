#!/usr/bin/env perl
# ABOUTME: The operator right is an entitlement the platform tenant holds in registry, read through one seam.
# ABOUTME: Only registry's in-effect entitlement to the operator resource grants it; the interim table is gone.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Mojo;
use Test::Registry::Helpers qw( authenticate_as );
use Test::Registry::OperatorRight qw( revoke_operator restore_operator grant_in_schema );
use Registry::DAO::Tenant;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $platform = Registry::DAO::Tenant->platform($db);

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Operator Entitlement Studio', slug => 'operator_entitlement_studio',
} );

# registry's entitlements to the resource named operator, in effect now.
sub operator_holders () {
    my $in_effect = Registry::DAO::Entitlement->in_effect_sql( 'e', q{tstzrange(now(), now(), '[]')} );
    return $db->query( qq{
        SELECT e.holder_tenant_id, v.id AS version_id, v.offer_id, v.price_cents,
               (SELECT array_agg(p.kind) FROM registry.offer_version_payment_plans p
                 WHERE p.offer_version_id = v.id) AS plan_kinds
          FROM registry.entitlements e
          JOIN registry.offer_versions v ON v.id = e.offer_version_id
          JOIN registry.resources r      ON r.id = v.resource_id
         WHERE r.name = 'operator' AND $in_effect
    } )->hashes->to_array;
}

subtest 'registry holds the operator right as an entitlement' => sub {
    my $holders = operator_holders();
    is scalar @$holders, 1, 'one in-effect entitlement to the operator resource';
    is $holders->[0]{holder_tenant_id}, $platform->id, 'held by the registry tenant';
    is $holders->[0]{price_cents}, 0, 'bought at $0';
    is_deeply $holders->[0]{plan_kinds}, ['one_time'], 'under one explicit one-time plan';

    my $zero_percent = $db->query( q{
        SELECT v.offer_id FROM registry.offer_versions v
          JOIN registry.resources r ON r.id = v.resource_id
         WHERE r.name = 'payment processing'
           AND v.conditions @> '[{"kind": "holder_is_offerer"}]'
    } )->hash->{offer_id};
    isnt $holders->[0]{offer_id}, $zero_percent, "its own offer, not the 0% self offer";

    ok !Registry::DAO::Tenant->holds( $db, $studio->id, 'operator' ), 'an ordinary tenant does not';
};

subtest 'interim operator storage removed' => sub {
    ok !$db->query(q{SELECT to_regclass('registry.tenant_resources')})->array->[0],
        'registry.tenant_resources no longer exists';
    ok !$db->query(q{SELECT to_regclass('operator_entitlement_studio.tenant_resources')})->array->[0],
        'and a newly provisioned tenant gets no copy of it';
};

subtest 'read method answers from entitlements' => sub {
    ok Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ), 'registry holds operator';
    my $held = revoke_operator($db);
    ok !Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'without its entitlement it does not';
    restore_operator( $db, $held );
    ok Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ), 'and with it back, it does';
};

my $alex = $platform->primary_user($db);

sub app_as ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper( dao => sub { $dao } );
    authenticate_as( $t, $user );
    return $t;
}

# Which tenant $user's request asking to act as $slug is served as.
sub acting_as ( $t, $user, $slug ) {
    my $c = $t->app->build_controller;
    $c->session( user_id => $user->id );
    $c->req->headers->header( 'X-As-Tenant' => $slug );
    return $c->tenant;
}

subtest 'ending the entitlement closes operator surfaces' => sub {
    my $t = app_as($alex);
    is acting_as( $t, $alex, $studio->slug ), $studio->slug, 'while in effect Alex may act as the studio';
    $t->get_ok('/platform/jobs')->status_is( 200, 'and is served the job queue' );

    my ($entitlement) = Registry::DAO::Entitlement->find( $db, {
        id => $db->query( q{
            SELECT e.id FROM registry.entitlements e
              JOIN registry.offer_versions v ON v.id = e.offer_version_id
              JOIN registry.resources r      ON r.id = v.resource_id
             WHERE r.name = 'operator' AND e.holder_tenant_id = ?
        }, $platform->id )->array->[0],
    } );
    $entitlement->end( $db, 'expired', 'operator right withdrawn' );

    ok !Registry::DAO::Tenant->holds( $db, $platform->id, 'operator' ),
        'an ended entitlement is not the right';
    isnt acting_as( $t, $alex, $studio->slug ), $studio->slug, 'Alex may no longer act as the studio';
    $t->get_ok('/platform/jobs')->status_is( 403, 'the job queue is refused' );
    $t->get_ok('/platform/revenue')->status_is( 403, 'the revenue view is refused' );
};

done_testing;
