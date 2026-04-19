#!/usr/bin/env perl
# ABOUTME: Program overview should return per-program session lists
# ABOUTME: so the admin dashboard can render session-level publish toggles.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO::Project;
use Registry::DAO::Session;
use Registry::DAO::Event;
use Registry::DAO::Location;
use Registry::DAO::User;
use DateTime;

my $tdb = Test::Registry::DB->new;
my $dao = $tdb->db;

my $tenant = Test::Registry::Fixtures::create_tenant($dao->db, {
    name => 'Session Overview Tenant',
    slug => 'session_overview',
});
$dao->db->query('SELECT clone_schema(?)', 'session_overview');
$dao = Registry::DAO->new(url => $tdb->uri, schema => 'session_overview');
my $db = $dao->db;

my $today     = DateTime->now;
my $tomorrow  = $today->clone->add(days => 1);
my $next_year = $today->clone->add(years => 1);

my $location = Registry::DAO::Location->create($db, {
    name => 'Session Test Location', address_info => {},
});
my $teacher = Registry::DAO::User->create($db, {
    name => 'T Teacher', username => 'sovt', email => 't@t.com',
    user_type => 'staff', password => 'x',
});

my $program = Registry::DAO::Project->create($db, {
    name   => 'Multi-Session Program',
    status => 'published',
});

# Two sessions that span CURRENT_DATE (so 'current' range includes them).
my $published_session = Registry::DAO::Session->create($db, {
    name       => 'Published Session',
    start_date => $today->ymd,
    end_date   => $next_year->ymd,
    status     => 'published',
    capacity   => 20,
});
my $draft_session = Registry::DAO::Session->create($db, {
    name       => 'Draft Session',
    start_date => $today->ymd,
    end_date   => $next_year->ymd,
    status     => 'draft',
    capacity   => 15,
});

# Events link sessions to programs. Time must be unique per
# (project_id, location_id, time).
my $event_time = $tomorrow->clone;
for my $session ($published_session, $draft_session) {
    my $event = Registry::DAO::Event->create($db, {
        session_id  => $session->id,
        time        => $event_time->iso8601,
        duration    => 60,
        location_id => $location->id,
        project_id  => $program->id,
        teacher_id  => $teacher->id,
    });
    $event_time->add(hours => 1);
}

subtest 'program overview returns sessions per program' => sub {
    my $overview = Registry::DAO::Project->get_program_overview($db, 'current');
    my ($mp) = grep { $_->{program_name} eq 'Multi-Session Program' } @$overview;
    ok($mp, 'program found in overview');

    ok($mp->{sessions}, 'sessions key exists');
    is(ref $mp->{sessions}, 'ARRAY', 'sessions is an arrayref');
    is(scalar @{$mp->{sessions}}, 2, 'both sessions listed');

    my ($pub) = grep { $_->{name} eq 'Published Session' } @{$mp->{sessions}};
    my ($drf) = grep { $_->{name} eq 'Draft Session' } @{$mp->{sessions}};

    ok($pub, 'published session present');
    is($pub->{status}, 'published', 'published session has correct status');

    ok($drf, 'draft session present');
    is($drf->{status}, 'draft', 'draft session has correct status');

    ok($pub->{id}, 'session has id for publish form submission');
};

done_testing();
