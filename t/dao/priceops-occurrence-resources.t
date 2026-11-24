#!/usr/bin/env perl
# ABOUTME: Each occurrence (an events row) is its own finite resource, and a class offer covers its class's occurrences.
# ABOUTME: An entitlement under a class offer holds units of one covered occurrence; the others are its change targets.
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
use Registry::DAO::Project;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my %studio;
for my $slug (qw( wheel_house kiln_house )) {
    Registry::DAO::Tenant->create( $db, { name => $slug, slug => $slug } );
    $db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    $studio{$slug} = Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}
my $studio = $studio{wheel_house};

my $made = 0;

# A class (a projects row) in $handle; returns its id.
sub class_in ( $handle = $studio, %more ) {
    return $handle->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made", %more },
        { returning => 'id' } )->hash->{id};
}

# An occurrence of $class at $time for $duration minutes; returns its id.
sub event_of ( $class, $time = '2099-03-0' . ( $made % 9 + 1 ) . 'T10:00:00Z', %more ) {
    my $handle  = delete $more{handle} // $studio;
    my $teacher = $handle->insert( 'users', { username => 'teacher-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
    my $where = $handle->insert( 'locations', { name => "Room $made", slug => "room-$made" },
        { returning => 'id' } )->hash->{id};
    return $handle->insert( 'events', {
        project_id  => $class,
        location_id => $where,
        teacher_id  => $teacher,
        time        => $time,
        duration    => 90,
        capacity    => 10,
        %more,
    }, { returning => 'id' } )->hash->{id};
}

# Whether two instants, as Postgres or ISO 8601 text, are the same instant.
sub same_instant ( $got, $want ) {
    return $studio->query( 'SELECT ?::timestamptz = ?::timestamptz', $got, $want )->array->[0];
}

subtest 'an occurrence is its own finite resource' => sub {
    my $event    = event_of( class_in(), '2099-03-01T10:00:00Z', duration => 90, capacity => 10 );
    my $resource = Registry::DAO::Resource->for_occurrence( $studio, $event );
    is $resource->kind,     'finite', 'finite';
    is $resource->capacity, 10,       "the event's seats";
    is $resource->event_id, $event,   'bound to its event';

    my ( $starts, $ends ) = $resource->occurrence_window($studio);
    ok same_instant( $starts, '2099-03-01T10:00:00Z' ), "starts at the event's time";
    ok same_instant( $ends,   '2099-03-01T11:30:00Z' ), 'ends duration minutes later';
};

# The published class offer version for $class, with day-one terms.
sub class_offer ( $class, %more ) {
    return Registry::DAO::Offer->create( $studio, { name => 'Wheel class ' . ++$made } )
        ->draft( $studio, offer_terms( undef, class_project_id => $class, %more ) )->publish($studio);
}

# Occurrence-resource ids, sorted, for comparing sets.
sub ids (@resources) { [ sort map { $_->id } @resources ] }

subtest 'class offer covers current and later occurrences' => sub {
    my $c = class_in( $studio, seats_per_occurrence => 12 );
    is( Registry::DAO::Project->find( $studio, { id => $c } )->seats_per_occurrence, 12,
        'the class record holds its default seats per occurrence' );

    my @now   = map { Registry::DAO::Resource->for_occurrence( $studio, event_of($c) ) } 1 .. 2;
    my $other = Registry::DAO::Resource->for_occurrence( $studio, event_of( class_in() ) );
    my $offer = class_offer($c);
    is $offer->resource_id, undef, 'a class offer names no single resource';

    my $later = Registry::DAO::Resource->for_occurrence( $studio, event_of($c) );
    is_deeply ids( $offer->covered_resources($studio)->@* ), ids( @now, $later ),
        "covers the class's occurrences, the later one too";
    ok $offer->buys( $studio, $_->id ), 'buys ' . $_->name for @now, $later;
    ok !$offer->buys( $studio, $other->id ), 'not an occurrence of another class';
    is( Registry::DAO::OfferVersion->find( $studio, { offer_id => $offer->offer_id } )->version, 1,
        'with no new version' );
};

done_testing;
