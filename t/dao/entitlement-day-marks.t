#!/usr/bin/env perl
# ABOUTME: Attendance as a present or absent mark per day: an occurrence's event or one of a session's days.
# ABOUTME: A second mark of a day replaces the first; in-studio record_use is a present mark on its occurrence's event.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Exception;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Test::Registry::Sessions qw( make_session );
use Registry::DAO::Resource;
use Registry::DAO::Offer;
use Registry::DAO::Entitlement;

my $test_db = Test::Registry::DB->new;
my $db      = $test_db->db->db;
my $made = 0;

sub person () { Test::Registry::Fixtures::create_user( $db, { username => 'mark-' . ++$made } )->id }

my $teacher = person();

# An entitlement holding one seat of $resource under use policy $use, in
# effect until the resource's last day ends.
sub booking ( $resource, $use = { kind => 'optional_attendance' } ) {
    my $version = Registry::DAO::Offer->create( $db, { name => 'Marked ' . ++$made } )
        ->draft( $db, offer_terms( $resource->id, policies => { refund => { kind => 'none' }, use => $use } ) )
        ->publish($db);
    my ( undef, $ends ) = $resource->occurrence_window($db);
    return Registry::DAO::Entitlement->grant( $db, {
        holder_user_id   => person(),
        offer_version_id => $version->id,
        payment_plan_id  => 'pay',
        starts_at        => '2020-01-01T00:00:00Z',
        ends_at          => $ends,
        resource_id      => $resource->id,
        units            => 1,
    } );
}

sub occurrence () {
    my $class = Test::Registry::Fixtures::create_project( $db, { name => 'Class ' . ++$made, slug => "class-$made" } );
    my $room  = Test::Registry::Fixtures::create_location( $db,
        { name => 'Room ' . ++$made, slug => "room-$made", time_zone => 'America/New_York' } );
    my $event = $db->insert( 'events', {
        project_id => $class->id, location_id => $room->id, teacher_id => $teacher,
        time       => \"now() + interval '24 hours'", duration => 90, capacity => 4,
    }, { returning => 'id' } )->hash->{id};
    return Registry::DAO::Resource->for_occurrence( $db, $event );
}

# Its marks, or what dying said, so one subtest's failure leaves the rest to run.
sub marks ($e) { eval { $e->day_marks($db) } // "died: $@" }

subtest 'a session day can be marked absent' => sub {
    my $session = make_session($db);
    my ( undef, $day2 ) = $session->session_days($db)->@*;
    my $makeups = Registry::DAO::Offer->create( $db, { name => 'Make-up day ' . ++$made } );
    my $e = booking( $session, { kind => 'makeup', offer_id => $makeups->id, credit_days => 30 } );
    lives_ok { $e->mark_day( $db, $day2->{id}, 'absent', $teacher ) } 'day 2 is marked absent';
    is_deeply marks($e), { $day2->{id} => 'absent' }, 'day 2 is marked absent, and nothing else';
};

subtest 'a second mark replaces the first' => sub {
    my $session = make_session($db);
    my ( undef, $day2 ) = $session->session_days($db)->@*;
    my $e = booking($session);
    lives_ok { $e->mark_day( $db, $day2->{id}, 'absent',  $teacher ) } 'marked absent';
    lives_ok { $e->mark_day( $db, $day2->{id}, 'present', $teacher ) } 'then present';
    is_deeply marks($e), { $day2->{id} => 'present' }, 'replaced, not added';
};

subtest 'in-studio record_use records present on the occurrence event' => sub {
    my $o = occurrence();
    my $e = booking($o);
    lives_ok { $e->record_use( $db, $o->id, $teacher ) } 'the in-studio use is recorded';
    is_deeply marks($e), { $o->event_id => 'present' }, "present on the occurrence's event";
};

done_testing;
