#!/usr/bin/env perl
# ABOUTME: The in-studio-schedule screens over HTTP: the class setup's "Schedule occurrences" link leads to a form that generates them.
# ABOUTME: Design-system classes only; the complete page reports what was created and shifted; staff are refused.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use List::Util qw( uniq );
use Mojo::File qw( path );
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Test::Registry::Helpers qw( authenticate_as import_all_workflows join_tenant );
use Registry;
use Registry::DAO;
use Registry::DAO::Project;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "sched_$role", name => "Sched \u$role", email => "$role\@sched.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $room  = Test::Registry::Fixtures::create_location( $db, { name => 'Kiln room', slug => 'kiln-room' } );
my $class = Registry::DAO::Project->create( $db,
    { name => 'Raku', seats_per_occurrence => 6, metadata => { location_id => $room->id } } );

sub client ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    authenticate_as( $t, $user );
    return $t;
}

my $css = join '', map { path( 'public/css', $_ )->slurp } qw( theme.css app.css );

sub check_screen ( $t, $screen ) {
    my @classes = uniq map { split ' ', $_->attr('class') } $t->tx->res->dom->find('#workflow-content [class]')->each;
    is_deeply [ grep { $css !~ /\.\Q$_\E(?![\w-])/ } @classes ], [], "$screen uses design-system classes only";
}

subtest 'admin schedules a class over http' => sub {
    my $t = client( $user{admin} );
    $t->get_ok('/in-studio-schedule')->status_is(200);
    check_screen( $t, 'schedule' );
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, 'the schedule screen has a form' or return;
    $t->element_exists( qq{#workflow-content select[name="class_project_id"] option[value="${\ $class->id }"]},
        'it offers the tenant\'s classes' );
    $t->element_exists( qq{#workflow-content select[name="teacher_id"] option[value="${\ $user{staff}->id }"]},
        'and its staff as teachers' );
    $t->element_exists( '#workflow-content select[name="location_id"] option[value=""]:first-child',
        'the location defaults to the class\'s' );
    $t->element_exists( qq{#workflow-content input[name="weekdays"][value="$_"]}, "it offers $_" )
        for qw( saturday sunday );

    $t->post_ok( $form->attr('action') => form => {
        class_project_id => $class->id, location_id => '', teacher_id => $user{staff}->id,
        weekdays => [qw( saturday sunday )], start_time => '02:30', duration => 60,
        first_date => '2027-03-13', last_date => '2027-03-14',
    } )->status_is(302);
    my $next = $t->tx->res->headers->location;
    like $next, qr{/complete\z}, 'on to the complete page';
    $t->get_ok($next)->status_is(200)->content_like( qr/2 created/, 'it reports what was created' )
        ->content_like( qr/2027-03-14 02:30 starts at 2027-03-14 03:30/, 'and the start DST moved' );
    check_screen( $t, 'complete' );
    is $db->query( 'SELECT count(*) FROM events WHERE project_id = ? AND location_id = ?', $class->id, $room->id )
        ->array->[0], 2, 'two occurrences at the class\'s location';
};

subtest 'a refused schedule stays on the form with its message' => sub {
    my $t = client( $user{admin} );
    $t->get_ok('/in-studio-schedule')->status_is(200);
    my $form = $t->tx->res->dom->at('#workflow-content form');
    $t->post_ok( $form->attr('action') => form => {
        class_project_id => $class->id, location_id => '', teacher_id => $user{staff}->id,
        start_time => '10:00', duration => 60, first_date => '2027-04-01', last_date => '2027-04-30',
    } )->status_is(302);
    like my $back = $t->tx->res->headers->location, qr{/schedule\z}, 'back to the schedule form';
    $t->get_ok($back)->status_is(200)->content_like( qr/Choose at least one weekday/, 'no weekday is refused with a message' );
};

subtest 'staff are refused at the route' => sub {
    client( $user{staff} )->get_ok('/in-studio-schedule')->status_is(403);
};

done_testing;
