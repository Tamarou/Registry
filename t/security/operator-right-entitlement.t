#!/usr/bin/env perl
# ABOUTME: The operator right is an entitlement the platform tenant holds in registry, read through one seam.
# ABOUTME: Only registry's in-effect entitlement to the operator resource grants it; the interim table is gone.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
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

done_testing;
