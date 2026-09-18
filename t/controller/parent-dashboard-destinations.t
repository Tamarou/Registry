# ABOUTME: Controller tests that every link the parent dashboard offers reaches a real page.
# ABOUTME: Follows the hrefs the templates actually render -- drop, transfer, and browse programs.
BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Helpers qw(authenticate_as import_all_workflows days_from_now);
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Mojolicious::Routes::Match;
use Mojo::URL;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;
$ENV{DB_URL} = $test_db->uri;
import_all_workflows($dao);

my $t = Test::Registry::Mojo->new('Registry');
# Pin the controller's dao() to the seeded test schema regardless of tenant.
$t->app->helper(dao => sub { $dao });

# --- Seed one published program a parent can browse and enrol in -----------
my $location = $dao->create(Location => {
    name => 'Kiln Room', slug => 'kiln-room',
    address_info => { street => '2 Elm', city => 'Orlando', state => 'FL' },
    metadata => {},
});
my $program = $dao->create(Project => {
    status => 'published', name => 'Wheel Throwing Camp',
    program_type_slug => 'summer-camp', metadata => {},
});
my $teacher = $dao->create(User => { username => 'dest_teacher', user_type => 'staff' });
my $session = $dao->create(Session => {
    name => 'Wheel Week 1',
    start_date => days_from_now(-30), end_date => days_from_now(30),
    status => 'published', capacity => 12, metadata => {},
});
my $event = $dao->create(Event => {
    time => days_from_now(-3) . ' 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 12, metadata => {},
});
$session->add_events($dao->db, $event->id);

my $parent = $dao->create(User => {
    username => 'dest_parent', name => 'Destination Parent',
    user_type => 'parent', email => 'dest@example.com',
});
my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
    child_name => 'Destination Kid', birth_date => '2017-01-01', grade => '4',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

authenticate_as($t, $parent);

# The links under test are rendered by the templates, so the test follows what
# the page actually offers rather than a URL copied out of the source.
sub link_named ($label) {
    my $dom = $t->tx->res->dom;
    my ($a) = grep { $_->all_text =~ /\Q$label\E/ } $dom->find('a')->each;
    return $a ? $a->attr('href') : undef;
}

# Where the router sends a GET for this href: the controller, action and
# captures Mojolicious resolves, so a link is checked against the app's own
# routing table rather than against a URL copied out of the source.
sub dispatch_of ($href) {
    my $c     = $t->app->build_controller;
    my $match = Mojolicious::Routes::Match->new( root => $t->app->routes );
    $match->find( $c, { method => 'GET', path => Mojo::URL->new($href)->path->to_string } );
    return $match->stack->[-1] // {};
}

subtest 'empty dashboard sends a parent to the storefront, not the removed /school' => sub {
    $t->get_ok('/parent/dashboard')->status_is(200)
      ->content_like(qr/No Active Enrollments/, 'parent has nothing enrolled yet');

    my $href = link_named('Browse Programs');
    ok $href, 'empty state offers a Browse Programs link';

    # A missing link must not pass by default, so an absent href is routed as a
    # path that cannot match the storefront.
    my $to = dispatch_of( $href // '/no-link-was-rendered' );
    is $to->{controller}, 'workflows', 'link routes to the workflow controller';
    is $to->{action},     'index',     'link routes to a storefront index';
    is $to->{workflow},   undef,
      'link is the storefront root, not a named page such as the removed /school';

    $t->get_ok($href)->status_is(200)
      ->element_exists('div.landing-page', 'destination renders the storefront landing page');
};

subtest 'waitlist status page renders and its storefront link works' => sub {
    $t->get_ok('/waitlist/status')->status_is(200)
      ->content_like(qr/No Active Waitlists/, 'waitlist status page rendered its empty state');

    my $href = link_named('Browse Programs');
    ok $href, 'waitlist empty state offers a Browse Programs link';

    my $to = dispatch_of( $href // '/no-link-was-rendered' );
    is $to->{controller}, 'workflows', 'link routes to the workflow controller';
    is $to->{action},     'index',     'link routes to a storefront index';
    is $to->{workflow},   undef,
      'link is the storefront root, not a named page such as the removed /school';

    $t->get_ok($href)->status_is(200)
      ->element_exists('div.landing-page', 'destination renders the storefront landing page');
};

# --- Now give the parent something to drop or transfer ---------------------
my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
    session_id       => $session->id,
    family_member_id => $child->id,
    parent_id        => $parent->id,
    status           => 'active',
});

# The newest run of a workflow is the one the request under test just started.
sub latest_run_for ($slug) {
    my ($workflow) = $dao->find( Workflow => { slug => $slug } );
    return $workflow->latest_run( $dao->db );
}

# Both links are followed to the page they open, not just checked against the
# routing table: the first step of either workflow reads the acting user off the
# run, which nothing but the controller can put there.
subtest 'Drop link enters the drop workflow on the enrollment it names' => sub {

    $t->get_ok('/parent/dashboard')->status_is(200)
      ->content_like(qr/Wheel Week 1/, 'dashboard lists the active enrollment');

    my $href = link_named('Drop');
    ok $href, 'dashboard offers a Drop link';

    my $to = dispatch_of($href);
    is $to->{controller}, 'workflows',           'Drop link routes to the workflow controller';
    is $to->{action},     'index',               'Drop link starts a workflow rather than resuming a step';
    is $to->{workflow},   'parent-drop-request', 'Drop link names the drop workflow';

    # The enrollment has to travel with the link: the first step reads it from
    # the run data the query string seeds.
    is Mojo::URL->new($href)->query->param('enrollment_id'), $enrollment->id,
      'Drop link carries this enrollment id';

    $t->get_ok($href)->status_is(200)
      ->text_is( 'h1' => 'Select Enrollment to Drop',
        'Drop destination renders the first step of the drop workflow' );

    # child_name is the step's own work: it comes from the family_members row
    # the ownership check matched, and no part of the request carried it.
    my $run = latest_run_for('parent-drop-request');
    is $run->data->{enrollment_id}, $enrollment->id,
      'run is positioned on the enrollment the link named';
    is $run->data->{child_name}, 'Destination Kid',
      'first step resolved the child through its ownership check';
};

subtest 'Transfer link enters the transfer workflow on the enrollment it names' => sub {
    $t->get_ok('/parent/dashboard')->status_is(200);

    my $href = link_named('Transfer');
    ok $href, 'dashboard offers a Transfer link';

    my $to = dispatch_of($href);
    is $to->{controller}, 'workflows',               'Transfer link routes to the workflow controller';
    is $to->{action},     'index',                   'Transfer link starts a workflow rather than resuming a step';
    is $to->{workflow},   'parent-transfer-request', 'Transfer link names the transfer workflow';

    is Mojo::URL->new($href)->query->param('enrollment_id'), $enrollment->id,
      'Transfer link carries this enrollment id';

    $t->get_ok($href)->status_is(200)
      ->text_is( 'h1' => 'Select Enrollment to Transfer',
        'Transfer destination renders the first step of the transfer workflow' );

    my $run = latest_run_for('parent-transfer-request');
    is $run->data->{enrollment_id}, $enrollment->id,
      'run is positioned on the enrollment the link named';
    is $run->data->{child_name}, 'Destination Kid',
      'first step resolved the child through its ownership check';
};

# The acting user is derived from the session, so a request that names a
# different one has to be ignored -- the drop step uses it as the family_id its
# ownership check matches on. user[id] is the form the bracket rebuild would
# turn back into that hashref, which is why it is sent alongside user_id.
subtest 'a request cannot act on another family by naming its owner' => sub {
    my $other_parent = $dao->create(User => {
        username => 'other_parent', name => 'Other Parent',
        user_type => 'parent', email => 'other@example.com',
    });
    my $other_child = Registry::DAO::Family->add_child($dao->db, $other_parent->id, {
        child_name => 'Other Kid', birth_date => '2017-01-01', grade => '4',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });
    my $other_enrollment = Registry::DAO::Enrollment->create($dao->db, {
        session_id       => $session->id,
        family_member_id => $other_child->id,
        parent_id        => $other_parent->id,
        status           => 'active',
    });

    # A fresh visit, so the workflow starts a new run instead of resuming the
    # one the Drop subtest left in the session.
    $t->reset_session;
    my $url = Mojo::URL->new('/parent-drop-request')->query(
        enrollment_id => $other_enrollment->id,
        user_id       => $other_parent->id,
        'user[id]'    => $other_parent->id,
    );
    $t->get_ok($url)->status_is(200)
      ->content_unlike(qr/Enrollment selected/,
        'the page never confirms a selection it refused');

    my $run = latest_run_for('parent-drop-request');
    is $run->data->{user}{id}, $parent->id,
      'run acts as the signed-in parent, not the owner the request named';
    is $run->data->{enrollment_id}, undef,
      'the other family enrollment was never selected';
};

done_testing;
