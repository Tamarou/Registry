#!/usr/bin/env perl
# ABOUTME: Entitlements: who holds what, who paid, under which stamped offer version and plan, and when.
# ABOUTME: The database enforces the stamp and its integrity, so raw SQL is held to it as much as the DAO.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::OfferVersion;
use Registry::DAO::Entitlement;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

# A tenant provisioned the way signup provisions one: the row, then its schema.
sub new_tenant ($slug) {
    my $tenant = Registry::DAO::Tenant->create( $db, { name => "Studio $slug", slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    return $tenant->dao($dao)->db;
}

# A person in $handle's schema; returns their id.
sub person ( $handle, $name ) {
    return $handle->insert( 'users', { username => $name }, { returning => 'id' } )->hash->{id};
}

# A child in $handle's schema whose family is $parent_id; returns its id.
sub child ( $handle, $parent_id, $name ) {
    return $handle->insert( 'family_members',
        { family_id => $parent_id, child_name => $name, birth_date => '2018-05-01' },
        { returning => 'id' } )->hash->{id};
}

# A published version 1 of a new offer in $handle's schema.
sub published_version ( $handle, $name ) {
    my $resource = Registry::DAO::Resource->create( $handle,
        { name => "$name seats", kind => 'finite', capacity => 10 } );
    my $offer = Registry::DAO::Offer->create( $handle, { name => $name } );
    return $offer->draft( $handle, offer_terms( $resource->id ) )->publish($handle);
}

my $studio = new_tenant('wheel_house');

subtest 'person held entitlement records its stamp' => sub {
    my $sam     = person( $studio, 'sam' );
    my $version = published_version( $studio, 'Drop-in wheel' );

    my $e = Registry::DAO::Entitlement->create( $studio, {
        holder_user_id   => $sam,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
    } );

    my $read = Registry::DAO::Entitlement->find( $studio, { id => $e->id } );
    is $read->holder_user_id,   $sam,         'it records its holder';
    is $read->offer_version_id, $version->id, 'the exact offer version';
    is $read->payment_plan_id,  'pay',        'and the accepted payment plan';
    ok !Registry::DAO::Entitlement->find( $db, { id => $e->id } ),
        'and lives in the tenant schema, not registry';
};

done_testing;
