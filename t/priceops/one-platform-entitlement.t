#!/usr/bin/env perl
# ABOUTME: A tenant holds at most one active platform entitlement to payment processing at any moment.
# ABOUTME: The database refuses an overlapping one, so the fee resolver never has to pick between two.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SOLO_V1 = '00000000-0000-0000-0003-000000000001';
my $REFUSED = qr/already holds an active platform entitlement to payment processing/;

my $studio = Test::Registry::Fixtures::create_tenant( $db, {
    name => 'One Term Studio', slug => 'one_term_studio',
} );

# A second published offer to tenants for payment processing, as a later
# product would publish one.
my $processing = $db->query( q{SELECT id FROM registry.resources WHERE name = 'payment processing'} )
    ->hash->{id};
my $other = Registry::DAO::Offer->create( $db, { name => 'Other processing' } )->draft( $db,
    offer_terms( $processing, price_cents => 0,
        payment_plans => [ { id => 'revenue_share', kind => 'percentage_of_sales', fraction => 0.01 } ] ) )
    ->publish($db);

sub hold ( $version, $starts, $ends = undef ) {
    return Registry::DAO::Entitlement->create( $db, {
        holder_tenant_id => $studio->id, offer_version_id => $version,
        payment_plan_id  => 'revenue_share', starts_at => $starts, ends_at => $ends,
    } );
}

subtest 'overlapping platform entitlements refused' => sub {
    hold( $SOLO_V1, '2020-01-01T00:00:00Z', '2030-01-01T00:00:00Z' );
    throws_ok { hold( $other->id, '2025-01-01T00:00:00Z' ) } $REFUSED,
        'a second offer for payment processing overlapping the first is refused';
};

subtest 'a following platform entitlement is allowed' => sub {
    lives_ok { hold( $other->id, '2030-01-01T00:00:00Z' ) }
        'one that starts where the first ends does not overlap it';
};

subtest 'extending into another platform entitlement refused' => sub {
    throws_ok {
        $db->query( q{UPDATE registry.entitlements SET in_effect = tstzrange(lower(in_effect), NULL)
                       WHERE holder_tenant_id = ? AND offer_version_id = ?}, $studio->id, $SOLO_V1 );
    } $REFUSED, 'an active one cannot be stretched over the one after it';
};

subtest 'other tenants are not limited by it' => sub {
    my $second = Test::Registry::Fixtures::create_tenant( $db, {
        name => 'Second Term Studio', slug => 'second_term_studio',
    } );
    lives_ok {
        Registry::DAO::Entitlement->create( $db, {
            holder_tenant_id => $second->id, offer_version_id => $SOLO_V1,
            payment_plan_id  => 'revenue_share', starts_at => '2025-01-01T00:00:00Z',
        } );
    } 'another tenant holds Solo over the same period';
};

done_testing;
