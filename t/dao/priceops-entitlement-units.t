#!/usr/bin/env perl
# ABOUTME: Discrete entitlements hold named units of a finite resource, and holds occupy units for a while.
# ABOUTME: Capacity is read live under a lock on the resource, so racing grants and holds never overrun it.
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

my $SLUG = 'seat_house';
Registry::DAO::Tenant->create( $db, { name => 'Seat House', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $PAST   = '2020-01-01T00:00:00Z';
my $FUTURE = '2099-01-01T00:00:00Z';

my $people = 0;
sub person ($name = 'p' . ++$people) {
    return $studio->insert( 'users', { username => "$name-$people" }, { returning => 'id' } )
        ->hash->{id};
}

# A finite resource of $capacity units and a published version that buys it.
sub seats ( $capacity = 10 ) {
    my $resource = Registry::DAO::Resource->create( $studio,
        { name => 'Wheel seats', kind => 'finite', capacity => $capacity } );
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class' } )
        ->draft( $studio, offer_terms( $resource->id ) )->publish($studio);
    return ( $resource, $version );
}

# What every grant of $version's units to $holder needs besides the units.
sub sale ( $version, $holder, %more ) {
    return {
        holder_user_id   => $holder,
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        resource_id      => $version->resource_id,
        starts_at        => $PAST,
        %more,
    };
}

subtest 'entitlement holds named units of a resource' => sub {
    my ( $resource, $version ) = seats(10);
    my $e = Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) );

    is_deeply $e->units( $studio, $resource->id ), [ 1, 2 ],
        'the grant records the two specific units it holds';
    my $named = Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), unit_numbers => [7] ) );
    is_deeply $named->units( $studio, $resource->id ), [7], 'or the unit the sale names';
};

subtest 'holder check names the resource' => sub {
    my ( $resource, $version ) = seats(10);
    my ( $sam, $pat ) = ( person(), person() );
    Registry::DAO::Entitlement->grant( $studio, sale( $version, $sam, units => 2 ) );

    ok Registry::DAO::Entitlement->holds_unit_of( $studio, $sam, $resource->id ),
        'the holder holds a unit of the resource';
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $pat, $resource->id ),
        'another person does not';
    my ( $other ) = seats(10);
    ok !Registry::DAO::Entitlement->holds_unit_of( $studio, $sam, $other->id ),
        'and the holder holds no unit of another resource';
};

subtest 'free units count held entitlements' => sub {
    my ( $resource, $version ) = seats(10);
    is $resource->free_units($studio), 10, 'an empty resource has all its units free';

    Registry::DAO::Entitlement->grant( $studio, sale( $version, person(), units => 2 ) );
    is $resource->free_units($studio), 8, 'two units held by an in-effect entitlement leave 8';

    Registry::DAO::Entitlement->grant( $studio,
        sale( $version, person(), units => 1, starts_at => $FUTURE ) );
    is $resource->free_units($studio), 7, 'a future-dated entitlement occupies its unit too';
};

done_testing;
