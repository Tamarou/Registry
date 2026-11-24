#!/usr/bin/env perl
# ABOUTME: Only the platform tenant may hold an offer the platform makes to itself (holder_is_offerer).
# ABOUTME: The database refuses anyone else in registry, so no accept or checkout flow can hand one out.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

use constant PLATFORM => '00000000-0000-0000-0000-000000000000';
my $PAST    = '2020-01-01T00:00:00Z';
my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';
my $REFUSED = qr/holder_is_offerer/;

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'Self Offer Studio', slug => 'self_offer_studio',
} );

# The published self-offer version buying resource $name, and its one plan.
sub self_offer ($name) {
    return $db->query( q{
        SELECT v.id, p.id AS plan FROM registry.offer_versions v
          JOIN registry.resources r ON r.id = v.resource_id
          JOIN registry.offer_version_payment_plans p ON p.offer_version_id = v.id
         WHERE r.name = ? AND v.published_at IS NOT NULL
           AND v.conditions @> '[{"kind": "holder_is_offerer"}]'
    }, $name )->hash;
}

sub entitle ( %holder_and_version ) {
    my %row = %holder_and_version;
    my $v   = self_offer( delete $row{resource} );
    return Registry::DAO::Entitlement->create( $db, {
        offer_version_id => $v->{id}, payment_plan_id => $v->{plan},
        starts_at => $PAST, ends_at => '2021-01-01T00:00:00Z', %row,
    } );
}

for my $resource ( 'operator', 'payment processing', 'email sending' ) {
    subtest "tenant refused the $resource self offer" => sub {
        throws_ok { entitle( holder_tenant_id => $studio->id, resource => $resource ) } $REFUSED,
            "a tenant cannot hold the platform's $resource offer to itself";
    };
}

subtest 'platform tenant may hold self offers' => sub {
    for my $resource ( 'operator', 'payment processing', 'email sending' ) {
        lives_ok { entitle( holder_tenant_id => PLATFORM, resource => $resource ) }
            "the platform may hold its $resource offer to itself";
    }
};

subtest 'tenant may hold solo v1' => sub {
    lives_ok {
        Registry::DAO::Entitlement->create( $db, {
            holder_tenant_id => $studio->id, offer_version_id => $SOLO_V1,
            payment_plan_id  => 'revenue_share', starts_at => $PAST,
        } );
    } 'Solo carries no holder_is_offerer, so a tenant may hold it';
};

subtest 'person held self offer refused' => sub {
    my $sam = $db->insert( 'registry.users', { username => 'self_offer_sam' }, { returning => 'id' } )
        ->hash->{id};
    throws_ok { entitle( holder_user_id => $sam, resource => 'email sending' ) } $REFUSED,
        "a person cannot hold the platform's offer to itself";
};

subtest 'create surfaces the refusal' => sub {
    my $v = self_offer('operator');
    throws_ok { entitle( holder_tenant_id => $studio->id, resource => 'operator' ) }
        qr/offer version \Q$v->{id}\E is the platform's offer to itself \(holder_is_offerer\)/,
        'Entitlement->create dies naming the version and the condition';
    is $db->query( 'SELECT count(*) FROM registry.entitlements WHERE holder_tenant_id = ?', $studio->id )
        ->array->[0], 1, 'and records nothing beyond the Solo entitlement';
};

subtest 'tenant schema offers are the tenant own' => sub {
    my $own   = $dao->connect_schema( $studio->slug )->db;
    my $sam   = $own->insert( 'users', { username => 'own_sam' }, { returning => 'id' } )->hash->{id};
    my $res   = Registry::DAO::Resource->create( $own, { name => 'studio time', kind => 'unbounded' } );
    my $offer = Registry::DAO::Offer->create( $own, { name => 'Studio to itself' } )->draft( $own,
        offer_terms( $res->id, conditions => [ { kind => 'holder_is_offerer' } ] ) )->publish($own);
    lives_ok {
        Registry::DAO::Entitlement->create( $own, {
            holder_user_id => $sam, offer_version_id => $offer->id,
            payment_plan_id => 'pay', starts_at => $PAST,
        } );
    } 'the registry rule does not reach a tenant schema';
};

done_testing;
