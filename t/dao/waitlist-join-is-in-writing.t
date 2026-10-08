# ABOUTME: Joining a waitlist queues a message to the parent, and the drainer sends it.
# ABOUTME: Nothing told a parent in writing, and nothing sent queued notifications at all.
#
# #421. The only waitlist message was waitlist_offer, sent when a seat opens;
# joining sent nothing, so the confirmation page was the whole record and it
# closed with the tab. Scoping it turned up the larger half: Notification->create
# writes a row and nothing ever sent one, so enrollment confirmations had never
# been delivered either.
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

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;

my $parent = $dao->create( User => {
    username => 'wj_parent', name => 'Nancy Waiting', user_type => 'parent',
    email => 'wj_parent@test.local' } );

my $n = 0;
sub a_child () {
    $n++;
    return Registry::DAO::Family->add_child( $db, $parent->id, {
        child_name => "WJ Kid $n", birth_date => '2015-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' } } );
}

sub a_session () {
    $n++;
    my $loc = Registry::DAO::Location->create( $db, {
        name => "WJ Hall $n$$", slug => "wj_loc_$n$$", address_info => {}, metadata => {} } );
    my $proj = Registry::DAO::Project->create( $db, {
        name => "WJ Proj $n$$", status => 'published',
        program_type_slug => 'summer-camp', metadata => {} } );
    my $teacher = $dao->create( User => {
        username => "wj_t_$n$$", name => 'WJ T', user_type => 'staff',
        email => "wj_t_$n$$\@test.local" } );
    my $event = Registry::DAO::Event->create( $db, {
        location_id => $loc->id, project_id => $proj->id, teacher_id => $teacher->id,
        time => \'NOW()', duration => 60, capacity => 1, metadata => {} } );
    my $s = Registry::DAO::Session->create( $db, {
        name => "WJ Session $n$$", status => 'published',
        capacity => 1, waitlist_enabled => 1, metadata => {} } );
    $s->add_events( $db, $event->id );
    return $s;
}

sub notifications_for ( $session, $type = 'waitlist_joined' ) {
    return $db->query(
        q{SELECT * FROM notifications
           WHERE user_id = ? AND type = ? AND metadata->>'session_id' = ?
           ORDER BY created_at},
        $parent->id, $type, $session->id )->expand->hashes->to_array;
}

subtest 'joining a waitlist queues a message naming the child and session' => sub {
    my $session = a_session();
    my $child   = a_child();

    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ],
        nothing_charged => 1 );

    my $queued = notifications_for($session);
    is scalar @$queued, 1, 'one notification is queued';
    my $note = $queued->[0];
    is $note->{channel}, 'email', 'to be emailed';
    like $note->{subject}, qr/\Q@{[ $session->name ]}\E/, 'the subject names the session';
    is $note->{metadata}{child_id}, $child->id, 'and it records which child';
    ok $note->{metadata}{child_name}, 'by name, so the email can use it';
    ok !defined $note->{sent_at}, 'not sent yet -- that is the drainer\'s job';

    # Position is deliberately absent: it moves, and a parent told "you are
    # 4th" reads any later movement as a broken promise.
    ok !exists $note->{metadata}{position}, 'no queue position is promised';
};

subtest 'joining twice does not queue a second message' => sub {
    my $session = a_session();
    my $child   = a_child();

    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );
    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );

    is scalar @{ notifications_for($session) }, 1,
        'settlement running twice is one email, not two';
};

subtest 'the registration path says nothing was charged; the demotion path does not' => sub {
    # The same queueing point serves a child who chose to wait (no seat, so no
    # charge) and a child demoted from a paid seat (charged, being refunded).
    # One message claiming "nothing has been charged" would be false for the
    # second, which is why the caller asserts it rather than the queue assuming.
    my $chose  = a_session();
    my $demoted = a_session();
    my ( $kid_a, $kid_b ) = ( a_child(), a_child() );

    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $chose->id, child_id => $kid_a->id } ], nothing_charged => 1 );
    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $demoted->id, child_id => $kid_b->id } ] );

    is notifications_for($chose)->[0]{metadata}{nothing_charged}, 1,
        'asserted for a child who chose to wait';
    is notifications_for($demoted)->[0]{metadata}{nothing_charged}, 0,
        'and not asserted for a released seat';

    # And the rendered email follows the flag rather than the type.
    require Registry::Email::Template;
    my $said = Registry::Email::Template->render( 'waitlist_joined',
        name => 'Nancy', child_name => 'Ada', event => 'X', location => 'Y',
        nothing_charged => 1 );
    my $silent = Registry::Email::Template->render( 'waitlist_joined',
        name => 'Nancy', child_name => 'Ada', event => 'X', location => 'Y' );
    like $said->{text}, qr/Nothing has been charged/, 'the line appears when true';
    unlike $silent->{text}, qr/Nothing has been charged/,
        'and is absent rather than wrong';
};

subtest 'a child already waiting is not re-notified' => sub {
    my $session = a_session();
    my $child   = a_child();

    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );
    my $before = scalar @{ notifications_for($session) };

    # Asking again changes nothing about their place, so it is not news.
    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );
    is scalar @{ notifications_for($session) }, $before, 'still one';
};

subtest 'the queue is drained: a queued notification is actually sent' => sub {
    # The half that makes any of this "in writing". Nothing sent queued
    # notifications at all before this -- no ->send on the enrollment path, no
    # sweep of sent_at IS NULL, no task.
    my $session = a_session();
    my $child   = a_child();
    Registry::DAO::Waitlist->join_items( $db, $parent->id,
        [ { session_id => $session->id, child_id => $child->id } ], nothing_charged => 1 );

    my $queued = notifications_for($session);
    ok !defined $queued->[0]{sent_at}, 'unsent to begin with';

    require Registry::Job::SendNotifications;
    my $counts =
      Registry::Job::SendNotifications->send_for_tenant( $dao, 'registry', _logger() );

    ok $counts->{sent} >= 1, 'the drainer sent at least one';
    ok defined notifications_for($session)->[0]{sent_at},
        'and stamped it, so the next run does not send it again';

    my $again = Registry::Job::SendNotifications->send_for_tenant( $dao, 'registry', _logger() );
    is $again->{sent}, 0, 'a second run sends nothing';
};

subtest 'an enrollment confirmation is drained too' => sub {
    # Scoping #421 found that these had never been delivered either. The
    # drainer is shared, so fixing the waitlist message fixes them.
    my $session = a_session();
    my $child   = a_child();
    Registry::DAO::Notification->ensure_enrollment_confirmation( $db, {
        user_id => $parent->id, session_id => $session->id,
        child_id => $child->id, enrollment_id => undef } );

    my $queued = notifications_for( $session, 'enrollment_confirmation' );
    is scalar @$queued, 1, 'queued';
    ok !defined $queued->[0]{sent_at}, 'and unsent, as every one of them has been';

    Registry::Job::SendNotifications->send_for_tenant( $dao, 'registry', _logger() );
    ok defined notifications_for( $session, 'enrollment_confirmation' )->[0]{sent_at},
        'the same drainer delivers it';
};

{
    package TestLogger;
    sub new   { bless { errors => [] }, shift }
    sub info  { }
    sub debug { }
    sub warn  { }
    sub error { push @{ $_[0]{errors} }, $_[1] }
    sub errors { @{ $_[0]{errors} } }
}
sub _logger () { return TestLogger->new }

done_testing;
