# ABOUTME: A parent who asked to hear about waitlist offers and expiries is sent them.
# ABOUTME: Both types were missing from notification_type, so creating either one died.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use experimental 'signatures';

use Test::Registry::DB;
use Registry::DAO;
use Registry::DAO::Family;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Session;
use Registry::DAO::Waitlist;
use Registry::DAO::Notification;
use Registry::DAO::UserPreference;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;
use Mojo::Log;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create( User => {
    username => 'wn_parent', name => 'Nora Notified', user_type => 'parent',
    email => 'wn_parent@test.local' } );

my $n = 0;
sub a_child () {
    $n++;
    return Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => "WN Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } } );
}

sub a_session () {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, { time_zone => 'America/New_York',
        name => "WN Hall $n$$", slug => "wn_loc_$n$$", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "WN Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} } );
    my $teacher = $dao->create( User => {
        username => "wn_t_$n$$", name => 'WN T', user_type => 'staff',
        email => "wn_t_$n$$\@test.local" } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => 1, metadata => {} } );
    my $s = Registry::DAO::Session->create( $db, {
        name => "WN Session $n$$", status => 'published',
        capacity => 1, waitlist_enabled => 1, metadata => {} } );
    $s->add_events( $db, $event->id );
    return $s;
}


my $log = Mojo::Log->new( level => 'fatal' );

sub an_offer () {
    my $session = a_session();
    my $child   = a_child();
    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );
    $db->query( q{UPDATE waitlist SET status = 'offered', offered_at = now(),
                  expires_at = now() + interval '48 hours' WHERE session_id = ?}, $session->id );
    my ($entry) = Registry::DAO::Waitlist->find( $db, { session_id => $session->id } );
    return ( $session, $entry );
}

sub sent_of ( $session, $type ) {
    return $db->query(
        q{SELECT channel FROM notifications WHERE user_id = ? AND type = ? AND metadata->>'session_id' = ?
          ORDER BY channel}, $parent->id, $type, $session->id )->arrays->map( sub { $_->[0] } )->to_array;
}

for my $type (qw( waitlist_offer waitlist_expiration )) {
    Registry::DAO::UserPreference->set_preference( $db, $parent->id, $type, $_, 1 ) for qw( email in_app );
}

subtest 'a parent who wants waitlist offers is sent one' => sub {
    my ( $session, $entry ) = an_offer();
    my $ok = eval { Registry::Job::ProcessWaitlist->send_waitlist_offer_notification( $dao, $entry, $log ); 1 };
    is $@, '', 'sending the offer does not die';
    is_deeply sent_of( $session, 'waitlist_offer' ), [qw( email in_app )], 'by email and in the app';
};

subtest 'a parent who wants waitlist expiries is sent one' => sub {
    my ( $session, $entry ) = an_offer();
    my $ok = eval { Registry::Job::WaitlistExpiration->send_expiration_notification( $dao, $entry, $log ); 1 };
    is $@, '', 'sending the expiry does not die';
    is_deeply sent_of( $session, 'waitlist_expiration' ), [qw( email in_app )], 'by email and in the app';
};

done_testing;
