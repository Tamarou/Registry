# ABOUTME: Test helper making a session, one finite resource whose days are its events, and offers selling it.
# ABOUTME: Makes the project, location and teacher it needs; tests override only what they are about.
use 5.42.0;
use warnings;

package Test::Registry::Sessions;

use Exporter 'import';
our @EXPORT_OK = qw( make_session session_offer );

use Test::Registry::Fixtures;
use Test::Registry::Offers qw( offer_terms );
use Registry::DAO::Resource;
use Registry::DAO::Offer;

my $made = 0;

# make_session($db, %overrides): a session of three days from 2027-06-07,
# 09:00 for 420 minutes, twelve seats, no waitlist. time_zone names the zone
# of the location made for it (default America/New_York).
sub make_session ( $db, %o ) {
    my $n  = ++$made;
    my $tz = delete $o{time_zone} // 'America/New_York';
    $o{project_id} //= Test::Registry::Fixtures::create_project( $db,
        { name => "Session program $n", slug => "session-program-$n" } )->id;
    $o{location_id} //= Test::Registry::Fixtures::create_location( $db,
        { name => "Session room $n", slug => "session-room-$n", time_zone => $tz } )->id;
    $o{teacher_id} //= Test::Registry::Fixtures::create_user( $db, { username => "session-teacher-$n" } )->id;
    return Registry::DAO::Resource->create_session( $db, {
        name     => "Session $n",
        capacity => 12,
        waitlist => { kind => 'none' },
        days     => [qw( 2027-06-07 2027-06-08 2027-06-09 )],
        start    => '09:00',
        minutes  => 420,
        %o,
    } );
}

# session_offer($db, $session, %terms): a published version of a new offer
# selling $session, its terms offer_terms' overridden by %terms.
sub session_offer ( $db, $session, %terms ) {
    my $n = ++$made;
    return Registry::DAO::Offer->create( $db, { name => "Session offer $n" } )
        ->draft( $db, offer_terms( $session->id, %terms ) )->publish($db);
}

1;
