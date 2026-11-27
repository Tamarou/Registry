#!/usr/bin/env perl
# ABOUTME: The session-setup screens over HTTP: an admin creates a program, adds its sessions, and says how they may be paid.
# ABOUTME: Staff are refused; a week with no chosen weekday, a last day before the first, or a queue without hours stays on the step.
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
use Registry::DAO::Resource;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
my $db      = $dao->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my %user;
for my $role (qw( admin staff parent )) {
    $user{$role} = Test::Registry::Fixtures::create_user( $dao,
        { username => "session_$role", name => "Session \u$role", email => "$role\@session.test", user_type => $role } );
    join_tenant( $dao, $user{$role}, $role );
}
my $site = Test::Registry::Fixtures::create_location( $db, { name => 'Camp field', slug => 'camp-field' } );

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

# Posts %fields through the page's form, each of which it must offer, and
# follows the redirect or reads the page it stays on. Returns the URL shown.
sub submit_step ( $t, $screen, %fields ) {
    my $form = $t->tx->res->dom->at('#workflow-content form');
    ok $form, "$screen has a form" or return '';
    ok $form->at(qq{[name="$_"]}), "$screen asks for $_" for sort keys %fields;
    my $action = $form->attr('action');
    $t->post_ok( $action => form => \%fields );
    my $shown = $action;
    if ( $t->tx->res->code == 302 ) {
        $shown = $t->tx->res->headers->location;
        $t->get_ok($shown);
    }
    $t->status_is(200);
    check_screen( $t, $screen );
    return $shown;
}

my %WEEK = (
    name     => 'Camp week 1', first_day => '2027-06-07', last_day => '2027-06-11', weekdays => [ 1 .. 5 ],
    start    => '09:00', minutes => 420, capacity => 12, waitlist => 'queue', offer_hold_hours => 48,
);

# A client on the sessions step of a new run, with its program created.
sub on_sessions ( $program, $location = $site ) {
    my $t = client( $user{admin} );
    $t->get_ok('/session-setup')->status_is(200);
    check_screen( $t, 'program' );
    like submit_step( $t, 'program', program_mode => 'create', program_name => $program, location_id => $location->id ),
        qr{/sessions\z}, 'on to the sessions';
    return $t;
}

sub sessions_named ($name) {
    return [ Registry::DAO::Resource->find( $db, { name => $name } ) ];
}

subtest 'an admin creates a program and a five day camp week' => sub {
    my $t = on_sessions('Summer camp');
    $t->content_like( qr/Summer camp/, 'the sessions screen names the program' );
    $t->element_exists( qq{#workflow-content select[name="teacher_id"] option[value="${\ $user{staff}->id}"]},
        'the sessions screen offers the tenant\'s staff as teachers' );

    like submit_step( $t, 'sessions', %WEEK, teacher_id => $user{staff}->id, action => 'add' ), qr{/sessions\z},
        'adding a session stays on the step';
    $t->content_like( qr/Camp week 1/, 'and the page lists it' );

    my $sessions = sessions_named('Camp week 1');
    is scalar @$sessions, 1, 'one resource';
    my ($week) = @$sessions;
    is $week->kind,     'finite', 'finite';
    is $week->capacity, 12,       'of twelve seats';
    is_deeply $week->waitlist, { kind => 'queue', offer_hold_hours => 48 }, 'a queue holding a seat 48 hours';
    my $days = $week->session_days($db);
    is scalar @$days, 5, 'five days';
    is_deeply $db->query( q{
        SELECT to_char(e.time AT TIME ZONE l.time_zone, 'YYYY-MM-DD HH24:MI'), e.duration, e.project_id, e.teacher_id
          FROM events e JOIN locations l ON l.id = e.location_id
         WHERE e.session_resource_id = ? ORDER BY e.time
    }, $week->id )->arrays->map( sub { $_->[0] } )->to_array,
        [ map { "2027-06-$_ 09:00" } qw( 07 08 09 10 11 ) ], 'Monday to Friday at 09:00 in the location\'s zone';
    my $program = $db->query(q{SELECT id FROM projects WHERE name = 'Summer camp'})->hash->{id};
    is_deeply $db->query( 'SELECT DISTINCT duration, project_id, teacher_id, location_id FROM events WHERE session_resource_id = ?',
        $week->id )->arrays->to_array, [ [ 420, $program, $user{staff}->id, $site->id ] ],
        'each 420 minutes, in the program, taught by the chosen teacher, at the program\'s location';

    like submit_step( $t, 'sessions', action => 'continue' ), qr{/instalment-payment\z}, 'continuing asks about instalments';
    check_screen( $t, 'instalment-payment' );
    like submit_step( $t, 'instalment-payment', instalments => 'declined' ), qr{/complete\z},
        'declining them passes the missed-payment step and lands on the complete page';
    my $run = $db->query( q{
        SELECT r.data FROM workflow_runs r JOIN workflows w ON w.id = r.workflow_id
         WHERE w.slug = 'session-setup' ORDER BY r.created_at DESC LIMIT 1
    } )->expand->hash->{data};
    is_deeply $run->{session_program}, { project_id => $program, location_id => $site->id }, 'the run records the program';
    is_deeply $run->{sessions}, [ $week->id ], 'and the session it made';
};

subtest 'offering instalments asks what a missed one does' => sub {
    my $t = on_sessions('Instalment camp');
    submit_step( $t, 'sessions', %WEEK, name => 'Instalment week', teacher_id => $user{staff}->id, action => 'add' );
    like submit_step( $t, 'sessions', action => 'continue' ), qr{/instalment-payment\z}, 'on to instalments';
    like submit_step( $t, 'instalment-payment', instalments => 'offered', count => 3, cadence => 'monthly', surcharge_pct => '2.5' ),
        qr{/missed-payment-policy\z}, 'offering them asks about a missed one';
    check_screen( $t, 'missed-payment-policy' );
    like submit_step( $t, 'missed-payment-policy', missed_payment => 'grace', grace_days => 7 ), qr{/complete\z},
        'a grace period lands on the complete page';
};

subtest 'two groups of one program can share a week at the same time' => sub {
    my $t = on_sessions('Parallel camp');
    submit_step( $t, 'sessions', %WEEK, name => 'Group A', teacher_id => $user{staff}->id, action => 'add' );
    submit_step( $t, 'sessions', %WEEK, name => 'Group B', teacher_id => $user{admin}->id, action => 'add' );
    $t->content_like( qr/Group A/ )->content_like( qr/Group B/, 'both groups are listed' );
    is scalar $_->[0]->session_days($db)->@*, 5, 'each group has its five days'
        for map { sessions_named($_) } 'Group A', 'Group B';
};

subtest 'staff get 403 from session-setup' => sub {
    client( $user{staff} )->get_ok('/session-setup')->status_is(403);
};

# Posts the week with %changes and asserts the step refuses it with $error,
# staying on the sessions step and making no session.
sub refused ( $program, $error, %changes ) {
    my $t = on_sessions($program);
    my %week = ( %WEEK, name => "$program week", teacher_id => $user{staff}->id, action => 'add', %changes );
    like submit_step( $t, 'sessions', %week ), qr{/sessions\z}, 'the post stays on the sessions step';
    $t->content_like( $error, 'with the error' );
    is_deeply sessions_named("$program week"), [], 'and no session is made';
}

subtest 'a week with no matching weekday stays on the step' => sub {
    refused( 'Weekend camp', qr/None of the chosen weekdays falls between the first and last day/, weekdays => [ 6, 7 ] );
};

subtest 'a last day before the first is refused' => sub {
    refused( 'Backwards camp', qr/The last day is before the first/, first_day => '2027-06-11', last_day => '2027-06-07' );
};

subtest 'a queue without hours is refused' => sub {
    refused( 'Queue camp', qr/A queue needs the hours a freed seat is held for the next child/, offer_hold_hours => '' );
};

subtest 'a parent is refused as the teacher' => sub {
    refused( 'Parent camp', qr/Choose a teacher from your staff and administrators/, teacher_id => $user{parent}->id );
};

subtest 'an unknown teacher is refused' => sub {
    refused( 'Stranger camp', qr/Choose a teacher from your staff and administrators/,
        teacher_id => '6f1c1f0e-3b7a-4d6e-9a51-2f0d8c4b7e13' );
};

subtest 'a day in the spring-forward gap is shown at its shifted start' => sub {
    my $t = on_sessions('Spring camp');
    submit_step( $t, 'sessions', %WEEK, name => 'Spring weekend', first_day => '2027-03-13', last_day => '2027-03-14',
        weekdays => [ 6, 7 ], start => '02:30', minutes => 60, teacher_id => $user{staff}->id, action => 'add' );
    $t->content_like( qr/2027-03-14 02:30 starts at 2027-03-14 03:30/, 'the shifted day is reported' );
    $t->content_unlike( qr/2027-03-13 02:30 starts at/, 'the day that exists is not' );
    is scalar sessions_named('Spring weekend')->[0]->session_days($db)->@*, 2, 'and both days are made';
};

subtest 'a session that cannot be made stays on the step with a message' => sub {
    my $gone = Test::Registry::Fixtures::create_location( $db, { name => 'Gone field', slug => 'gone-field' } );
    my $t    = on_sessions( 'Gone camp', $gone );
    $db->delete( 'locations', { id => $gone->id } );
    like submit_step( $t, 'sessions', %WEEK, name => 'Gone week', teacher_id => $user{staff}->id, action => 'add' ),
        qr{/sessions\z}, 'the post stays on the sessions step';
    $t->content_like( qr/Could not add the session/, 'with a message' );
    is_deeply sessions_named('Gone week'), [], 'and no session is made';
};

done_testing;
