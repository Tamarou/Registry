#!/usr/bin/env perl
# ABOUTME: Controller test for reopening the attendance register after marks exist.
# ABOUTME: Asserts the page renders and carries each child's previously-marked status.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers;

use Registry::DAO;
use Registry::DAO::Attendance;
use Registry::DAO::Enrollment;
use Registry::DAO::Family;
use Registry::DAO::MagicLinkToken;
use DateTime;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');
$t->app->helper( dao => sub { $dao } );

# --- Test data: a teacher, an event, and two enrolled children ---

my $location = $dao->create( Location => {
    name => 'Register Studio', slug => 'register-studio',
    address_info => { street => '1 Main', city => 'Orlando', state => 'FL' },
    metadata => {},
} );

my $program = $dao->create( Project => {
    status => 'published', name => 'Register Camp',
    program_type_slug => 'summer-camp', metadata => {},
} );

my $teacher = $dao->create( User => {
    username => 'ms_okoye', name => 'Ms Okoye',
    user_type => 'staff', email => 'okoye@test.com',
} );

my $parent = $dao->create( User => {
    username => 'reg_parent', name => 'Reg Parent',
    user_type => 'parent', email => 'reg_parent@test.com',
} );

my $session = $dao->create( Session => {
    name => 'Register Week 1',
    start_date => days_from_now(-2), end_date => days_from_now(2),
    status => 'published', capacity => 16, metadata => {},
} );

my $event = $dao->create( Event => {
    time        => DateTime->today->ymd . ' 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 16,
    metadata    => {},
} );
$session->add_events( $dao->db, $event->id );

my %child;
for my $name (qw( Ada Bo )) {
    $child{$name} = Registry::DAO::Family->add_child( $dao->db, $parent->id, {
        child_name => $name, birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'Reg Parent', phone => '555' },
    } );
    Registry::DAO::Enrollment->create( $dao->db, {
        session_id       => $session->id,
        family_member_id => $child{$name}->id,
        parent_id        => $parent->id,
        status           => 'active',
    } );
}

# Authenticate as the teacher via magic link
my ( undef, $teacher_token ) = Registry::DAO::MagicLinkToken->generate( $dao->db, {
    user_id => $teacher->id, purpose => 'login', expires_in => 24,
} );
$t->get_ok("/auth/magic/$teacher_token")->status_is(200);
$t->post_ok("/auth/magic/$teacher_token/complete")->status_is(302);

# The register Amara already took: mixed statuses, so a page that renders one
# blanket status for everyone fails here too.
my %marked = ( Ada => 'present', Bo => 'absent' );
for my $name ( sort keys %marked ) {
    Registry::DAO::Attendance->mark_attendance(
        $dao->db, $event->id, $child{$name}->id, $marked{$name}, $teacher->id,
    );
}

subtest 'register reopens with the marks already on it' => sub {
    $t->get_ok( '/teacher/attendance/' . $event->id )->status_is(200);

    my $dom = $t->tx->res->dom;
    for my $name ( sort keys %marked ) {
        my $row = $dom->at( 'student-attendance-row[student-id="' . $child{$name}->id . '"]' );
        ok $row, "$name has a row on the reopened register"
            or next;
        is $row->attr('status'), $marked{$name},
            "$name still shows as $marked{$name}";
    }
};

done_testing;
