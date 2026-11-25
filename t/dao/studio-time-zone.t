#!/usr/bin/env perl
# ABOUTME: A studio (a locations row) stores its IANA time zone, and an occurrence
# ABOUTME: (an events row) reports its local start and local date in that zone.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::Tenant;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

my %studio;
for my $slug (qw( east_studio west_studio )) {
    Registry::DAO::Tenant->create( $dao->db, { name => $slug, slug => $slug } );
    $dao->db->query( 'SELECT clone_schema(dest_schema => ?)', $slug );
    $studio{$slug} = Registry::DAO->new( url => $dao->url, schema => $slug )->db;
}
my $db = $studio{east_studio};

my $made = 0;

# A location in $handle with $zone; returns the DAO.
sub location_in ( $handle, $zone ) {
    ++$made;
    return Registry::DAO::Location->create( $handle,
        { name => "Room $made", slug => "room-$made", time_zone => $zone } );
}

# An occurrence at $location starting at instant $time; returns the DAO.
sub occurrence_at ( $handle, $location, $time ) {
    my $class   = $handle->insert( 'projects', { name => 'Class ' . ++$made, slug => "class-$made" },
        { returning => 'id' } )->hash->{id};
    my $teacher = $handle->insert( 'users', { username => 'teacher-' . ++$made }, { returning => 'id' } )
        ->hash->{id};
    return Registry::DAO::Event->create( $handle, {
        project_id => $class, location_id => $location->id, teacher_id => $teacher,
        time => $time, duration => 60,
    } );
}

subtest 'local start and date across the spring DST change' => sub {
    my $room = location_in( $db, 'America/New_York' );
    is $room->time_zone, 'America/New_York', 'the studio stores its zone';

    my $before = occurrence_at( $db, $room, '2027-03-14T06:30:00Z' )->local_start($db);
    is $before->{start},      '2027-03-14 01:30', 'before the change: 01:30 local';
    is $before->{date},       '2027-03-14',       'before the change: local date';
    is $before->{utc_offset}, '-05:00',           'before the change: EST';
    is $before->{time_zone},  'America/New_York', 'reports the zone it read';

    my $after = occurrence_at( $db, $room, '2027-03-14T07:30:00Z' )->local_start($db);
    is $after->{start},      '2027-03-14 03:30', 'after the change: 03:30 local';
    is $after->{date},       '2027-03-14',       'after the change: same local date';
    is $after->{utc_offset}, '-04:00',           'after the change: EDT';
};

subtest 'an invalid zone is refused at write time' => sub {
    ok !eval { location_in( $db, 'Not/AZone' ); 1 }, 'an unknown zone is refused on create';
    like $@, qr/time_zone/, '... by the time zone check';

    my $room = location_in( $db, 'America/New_York' );
    ok !eval { $room->update( $db, { time_zone => 'Not/AZone' } ); 1 }, 'an unknown zone is refused on update';
    is scalar( Registry::DAO::Location->find( $db, { id => $room->id } ) )->time_zone, 'America/New_York',
        'the stored zone is unchanged';
};

subtest 'two studios report different local dates for one instant near midnight UTC' => sub {
    my $instant = '2027-06-01T02:00:00Z';
    my $east    = occurrence_at( $db, location_in( $db, 'America/New_York' ), $instant )->local_start($db);
    my $tokyo   = occurrence_at( $db, location_in( $db, 'Asia/Tokyo' ), $instant )->local_start($db);
    is $east->{date},  '2027-05-31', 'New York is still on the previous day';
    is $tokyo->{date}, '2027-06-01', 'Tokyo is on the same day';
    is $east->{start},  '2027-05-31 22:00', 'New York local start';
    is $tokyo->{start}, '2027-06-01 11:00', 'Tokyo local start';
};

done_testing;
