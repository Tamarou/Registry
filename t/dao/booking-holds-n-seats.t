#!/usr/bin/env perl
# ABOUTME: An in-studio occurrence's capacity counts seats held (count x seats per unit), not family members.
# ABOUTME: A booking's count is checked against its offer's per-booking cap, then by the resource's one locked check.
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
use Registry::PriceOps::Hold;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $SLUG = 'seat_studio';
Registry::DAO::Tenant->create( $db, { name => 'Seat Studio', slug => $SLUG } );
$db->query( 'SELECT clone_schema(dest_schema => ?)', $SLUG );
my $studio = Registry::DAO->new( url => $dao->url, schema => $SLUG )->db;

my $made = 0;

sub person () {
    return $studio->insert( 'users', { username => 'p-' . ++$made }, { returning => 'id' } )->hash->{id};
}

sub run_id () {
    my $workflow = $studio->insert( 'workflows', { slug => 'book-' . ++$made, name => "Book $made" },
        { returning => 'id' } )->hash->{id};
    return $studio->insert( 'workflow_runs', { workflow_id => $workflow }, { returning => 'id' } )
        ->hash->{id};
}

# A class with $count occurrences of 10 seats and a published class offer
# version covering them, with %terms over offer_terms' defaults.
sub occurrences ( $count, %terms ) {
    my $class = $studio->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my $room = $studio->insert( 'locations', { name => 'Room ' . ++$made, slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    my @resources = map {
        my $event = $studio->insert( 'events', {
            project_id => $class, location_id => $room, teacher_id => person(),
            time       => "2099-03-0${_}T10:00:00Z", duration => 90, capacity => 10,
        }, { returning => 'id' } )->hash->{id};
        Registry::DAO::Resource->for_occurrence( $studio, $event );
    } 1 .. $count;
    my $version = Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . $made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, per_booking_cap => 10, %terms ) )
        ->publish($studio);
    return ( $version, @resources );
}

# The in-studio booking path's capacity call: $count of $version's units in
# $resource, held for a fresh run.
sub book ( $handle, $version, $resource, $count, $lifetime = '15 minutes' ) {
    return Registry::PriceOps::Hold->place( $handle, {
        resource_id     => $resource->id,
        units           => $version->seats_for($count),
        workflow_run_id => run_id(),
        expires_at      => \"clock_timestamp() + interval '$lifetime'",
    } );
}

# A booking already paid for: an entitlement holding $count units' seats.
sub booked ( $version, $resource, $count ) {
    return Registry::DAO::Entitlement->grant( $studio, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        resource_id      => $resource->id,
        units            => $version->seats_for($count),
    } );
}

sub holds_on ($resource) {
    return $studio->select( 'holds', 'count(*)', { resource_id => $resource->id } )->array->[0];
}

subtest 'seats held leave the rest' => sub {
    my ( $version, $seats ) = occurrences(1);
    booked( $version, $seats, 3 );
    is $seats->free_units($studio), 7, 'one booking of 3 seats leaves 7';
    throws_ok { book( $studio, $version, $seats, 8 ) } qr/7 of 10 units free: 8 asked for/, '8 more refused';
    ok book( $studio, $version, $seats, 7 ), '7 more granted';
    is $seats->free_units($studio), 0, 'and the occurrence is full';
};

done_testing;
