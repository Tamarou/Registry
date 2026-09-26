# ABOUTME: Controller tests for AdminDashboard CSV export functionality
# ABOUTME: Tests HTTP endpoints, content negotiation, and proper CSV format rendering

use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is ok subtest like diag plan )];
defer { done_testing };

use Test::Registry::Mojo;
use Registry;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as);

# Set up test database
my $test_db = Test::Registry::DB->new();
my $dao = $test_db->db;
$ENV{DB_URL} = $test_db->uri;

my $t = Test::Registry::Mojo->new('Registry');

# Signed in as an admin, because the export is behind the admin guard. Without
# this every request here answered 302 to the login page -- and `get_ok` is
# satisfied by a redirect, so a file named for CSV export functionality had
# never once reached the export.
my $admin = $dao->create(User => {
    username  => 'export_admin',
    name      => 'Export Admin',
    email     => 'export_admin@test.local',
    user_type => 'admin',
    password  => 'x',
});
authenticate_as($t, $admin);

subtest "Admin dashboard export endpoint exists" => sub {
    plan tests => 2;

    # "status doesn't matter for route existence" was the old comment, and it is
    # how this file spent its life asserting a redirect to the login page.
    $t->get_ok('/admin/dashboard/export')->status_is(200);
};

# This subtest was three bare get_ok calls and no mention of a format, under a
# name that promised content negotiation. get_ok asks only that a response came
# back, so it passed while the route answered text/html to every one of them --
# `?format=` stopped taking part in negotiation, respond_to fell through to its
# `any` branch, and a link promising a spreadsheet returned a web page.
subtest "CSV export content negotiation" => sub {
    $t->get_ok('/admin/dashboard/export?type=enrollments&format=csv')
      ->status_is(200)
      ->content_type_like(qr/csv/, 'format=csv answers as CSV, not as a web page');

    $t->get_ok('/admin/dashboard/export?type=enrollments&format=json')
      ->status_is(200)
      ->content_type_like(qr/json/, 'format=json answers as JSON');

    # `_format` is the spelling Mojolicious wants now, and one test already used
    # it. Both have to work, because the links in the template use the other.
    $t->get_ok('/admin/dashboard/export?type=enrollments&_format=json')
      ->status_is(200)
      ->content_type_like(qr/json/, '_format=json answers as JSON too');

    # No format named at all: CSV is the documented default.
    $t->get_ok('/admin/dashboard/export?type=enrollments')
      ->status_is(200)
      ->content_type_like(qr/csv/, 'the default is CSV');

    # A download, not a page to look at.
    $t->get_ok('/admin/dashboard/export?type=enrollments&format=csv')
      ->header_like('Content-Disposition', qr/attachment/, 'served as an attachment')
      ->header_like('Content-Disposition', qr/enrollments\.csv/, 'named for what it holds');

    done_testing;
};

subtest "CSV renderer functionality" => sub {
    plan tests => 4;

    # Test that the CSV renderer was registered properly
    my $app = $t->app;
    ok $app->renderer->handlers->{csv}, 'CSV renderer is registered';

    # Test CSV rendering with sample data
    my $sample_data = [
        { id => 1, name => 'Test Item', status => 'active' },
        { id => 2, name => 'Test "Quoted" Item', status => 'pending' }
    ];

    # Create a mock controller to test renderer
    my $mock_c = Mojolicious::Controller->new;
    $mock_c->app($app);

    my $output = '';
    my $options = { csv => $sample_data };

    # Call the CSV renderer directly
    $app->renderer->handlers->{csv}->($app->renderer, $mock_c, \$output, $options);

    ok $output, 'CSV renderer produces output';
    # Check that all expected headers are present (order may vary)
    like $output, qr/"name"/, 'CSV contains name header';
    like $output, qr/"Test ""Quoted"" Item"/, 'CSV properly escapes quotes';
};

# Same shape as above: three get_ok calls that asked only for a response. Each
# type now has to come back as CSV, because an export of the wrong content type
# is not an export.
subtest "Export data types" => sub {
    for my $type (qw( enrollments attendance waitlist )) {
        $t->get_ok("/admin/dashboard/export?type=$type&format=csv")
          ->status_is(200)
          ->content_type_like(qr/csv/, "$type exports as CSV")
          ->header_like('Content-Disposition', qr/\Q$type\E\.csv/,
              "and is named $type.csv");
    }

    done_testing;
};

# Every subtest above runs on an empty database, so all of them pass on "No data
# available for export". This one puts a row in each table and requires it to
# come out the other end -- the difference between an endpoint that answers and
# an export that exports.
subtest "an export carries the rows it is an export of" => sub {
    my $db = $dao->db;

    my $loc = $dao->create(Location => {
        name => 'Export Studio', slug => 'export-studio',
        address_info => {}, metadata => {},
    });
    my $prog = $dao->create(Project => {
        status => 'published', name => 'Export Program',
        program_type_slug => 'summer-camp', metadata => {},
    });
    my $teacher = $dao->create(User => {
        username => 'export_teacher', name => 'T',
        user_type => 'staff', email => 'et@test.local',
    });
    my $sess = $dao->create(Session => {
        name => 'Export Week', start_date => '2026-01-01', end_date => '2026-12-31',
        status => 'published', capacity => 10, metadata => {},
    });
    my $event = $dao->create(Event => {
        time => '2026-06-15 09:00:00', duration => 60, location_id => $loc->id,
        project_id => $prog->id, teacher_id => $teacher->id, capacity => 10,
        metadata => { title => 'Export Meeting' },
    });
    $sess->add_events($db, $event->id);

    # Deliberately created with no name and no email, so it gets NO user_profiles
    # row. An inner join to that table drops this family's rows from every export
    # without saying so, which is what the queries used to do.
    my $parent = $dao->create(User => {
        username => 'export_parent_noprofile', user_type => 'parent',
    });
    require Registry::DAO::Family;
    my $child = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Exportable Child', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });

    $db->insert('enrollments', {
        session_id => $sess->id, family_member_id => $child->id,
        student_id => $child->id, parent_id => $parent->id,
        status => 'active', metadata => '{}',
    });
    $db->insert('attendance_records', {
        event_id => $event->id, student_id => $child->id,
        status => 'present', marked_by => $teacher->id,
    });
    # A sibling for the waitlist: the same child cannot be both enrolled in this
    # session and queued for it, which is join_waitlist's own rule.
    my $sibling = Registry::DAO::Family->add_child($db, $parent->id, {
        child_name => 'Exportable Child Two', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'x', phone => '5' },
    });
    require Registry::DAO::Waitlist;
    Registry::DAO::Waitlist->join_waitlist(
        $db, $sess->id, $loc->id, $sibling->id, $parent->id );

    my %expect = (
        enrollments => 'Exportable Child',
        attendance  => 'Exportable Child',
        waitlist    => 'Exportable Child Two',
    );
    for my $type (qw( enrollments attendance waitlist )) {
        $t->get_ok("/admin/dashboard/export?type=$type&format=csv")
          ->status_is(200)
          ->content_like(qr/\Q$expect{$type}\E/,
              "the $type export carries the child it is about")
          ->content_unlike(qr/No data available/,
              "and is not the empty-export placeholder");
    }

    # The column that had never existed. Named in the CSV header, so a query that
    # silently stopped selecting it would show up here rather than as a blank.
    $t->get_ok('/admin/dashboard/export?type=attendance&format=csv')
      ->content_like(qr/event_time/, 'attendance names the meeting time column')
      ->content_like(qr/Export Meeting/, 'and carries the meeting title');

    done_testing;
};

subtest "AdminDashboard controller methods exist" => sub {
    plan tests => 1;

    # Verify the export_data method exists on the controller
    ok(Registry::Controller::AdminDashboard->can('export_data'), 'AdminDashboard has export_data method');
};