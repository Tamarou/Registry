#!/usr/bin/env perl
# ABOUTME: Controller test for the waitlist offer page's response window display.
# ABOUTME: Verifies that the rendered page shows the computed window hours from the backend.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::Waitlist;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Shared fixtures ---

my $location = $dao->create(Location => {
    name         => 'Offer Window Studio',
    address_info => { street => '1 Test St', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $teacher = $dao->create(User => { username => 'ow_teacher', user_type => 'staff' });

my $program = $dao->create(Project => {
    status            => 'published',
    name              => 'Offer Window Camp',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

my $session = $dao->create(Session => {
    name       => 'OW Week 1',
    start_date => '2026-07-01',
    end_date   => '2026-07-05',
    status     => 'published',
    capacity   => 2,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-07-01 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 2,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

# Helper to build an authed Test::Mojo for a given user
sub authed_mojo ($user) {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->app->helper(dao => sub { $dao });
    $t->app->hook(before_dispatch => sub ($c) {
        $c->stash(current_user => {
            id        => $user->id,
            username  => $user->username,
            name      => $user->name,
            user_type => $user->user_type,
        });
    });
    return $t;
}

# ============================================================
# F-28: response_window_hours is derived from the backend,
#       not hard-coded as "48 hours" in the template
# ============================================================
subtest 'offer page shows computed response window, not a hard-coded 48 hours' => sub {
    my $parent = $dao->create(User => {
        username  => 'ow_parent_a',
        name      => 'OW Parent A',
        user_type => 'parent',
        email     => 'ow_a@example.com',
    });
    my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
        child_name        => 'OW Child A',
        birth_date        => '2018-01-01',
        grade             => '2',
        medical_info      => {},
        emergency_contact => { name => 'OW Parent A', phone => '555-9999' },
    });

    # Create a waitlist entry and manually set it to 'offered' with a 24-hour window
    # (i.e. NOT 48 hours, so we can tell whether the template reads from the backend)
    my $entry = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $child->id,
        family_member_id => $child->id,
        parent_id        => $parent->id,
        status           => 'waiting',
        position         => 1,
    });

    # Set offered_at = now, expires_at = now + 24 hours
    $dao->db->query(
        "UPDATE waitlist SET status = 'offered', offered_at = NOW(), expires_at = NOW() + INTERVAL '24 hours' WHERE id = ?",
        $entry->id,
    );
    ($entry) = Registry::DAO::Waitlist->find($dao->db, { id => $entry->id });
    is $entry->status, 'offered', 'Entry is in offered status';

    my $t = authed_mojo($parent);
    $t->get_ok("/waitlist/${\$entry->id}")
      ->status_is(200, 'Offer page renders successfully');

    # The page must show the computed window (24) and must NOT hard-code 48
    $t->content_like(qr/24 hours/, 'Page shows 24-hour window derived from backend');
    $t->content_unlike(
        qr/(?<!\d)48 hours/,
        'Page does not show hard-coded 48 hours when window is 24'
    );
};

done_testing;
