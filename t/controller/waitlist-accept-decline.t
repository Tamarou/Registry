#!/usr/bin/env perl
# ABOUTME: Controller tests for waitlist accept, decline, and expired offer flows.
# ABOUTME: Tests HTTP routes for /waitlist/:id/accept, /waitlist/:id/decline with auth.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Family;
use Registry::DAO::FamilyMember;
use Registry::DAO::Enrollment;
use Registry::DAO::Waitlist;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Test Data Setup ---

my $location = $dao->create(Location => {
    name         => 'Waitlist Studio',
    address_info => { street => '100 Main', city => 'Orlando', state => 'FL' },
    metadata     => {},
});

my $teacher = $dao->create(User => { username => 'wl_teacher', user_type => 'staff' });

my $program = $dao->create(Project => {
    name              => 'Waitlist Camp',
    program_type_slug => 'summer-camp',
    metadata          => {},
});

# Full session (capacity 2)
my $session = $dao->create(Session => {
    name       => 'Week 3 - Full',
    start_date => '2026-06-15',
    end_date   => '2026-06-19',
    status     => 'published',
    capacity   => 2,
    metadata   => {},
});

my $event = $dao->create(Event => {
    time        => '2026-06-15 09:00:00',
    duration    => 420,
    location_id => $location->id,
    project_id  => $program->id,
    teacher_id  => $teacher->id,
    capacity    => 2,
    metadata    => {},
});
$session->add_events($dao->db, $event->id);

# Fill the session to capacity
my $filler1 = $dao->create(User => {
    username => 'wl_filler1', name => 'Filler 1', user_type => 'parent', email => 'wlf1@example.com',
});
my $filler_child1 = Registry::DAO::Family->add_child($dao->db, $filler1->id, {
    child_name => 'Filler Kid 1', birth_date => '2017-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555-0001' },
});
$dao->db->insert('enrollments', {
    session_id => $session->id, student_id => $filler1->id,
    family_member_id => $filler_child1->id, status => 'active',
});

my $filler2 = $dao->create(User => {
    username => 'wl_filler2', name => 'Filler 2', user_type => 'parent', email => 'wlf2@example.com',
});
my $filler_child2 = Registry::DAO::Family->add_child($dao->db, $filler2->id, {
    child_name => 'Filler Kid 2', birth_date => '2017-06-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555-0002' },
});
$dao->db->insert('enrollments', {
    session_id => $session->id, student_id => $filler2->id,
    family_member_id => $filler_child2->id, status => 'active',
});

# Helper to create a Test::Mojo with auth for a specific user
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
# 3.1 Accept Path
# ============================================================
subtest 'accept waitlist offer' => sub {
    # Parent A joins waitlist
    my $parent_a = $dao->create(User => {
        username => 'wl_parent_a', name => 'Parent A',
        user_type => 'parent', email => 'wl_a@example.com',
    });
    my $child_a = Registry::DAO::Family->add_child($dao->db, $parent_a->id, {
        child_name => 'Child A', birth_date => '2018-03-15', grade => '2',
        medical_info => {}, emergency_contact => { name => 'Parent A', phone => '555-1111' },
    });

    my $entry_a = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $child_a->id,
        family_member_id => $child_a->id,
        parent_id        => $parent_a->id,
        status           => 'waiting',
        position         => 1,
    });
    ok $entry_a, 'Waitlist entry created for Parent A';
    is $entry_a->status, 'waiting', 'Status is waiting';
    is $entry_a->position, 1, 'Position is 1';

    # Admin cancels one enrollment to open a spot
    $dao->db->update('enrollments',
        { status => 'cancelled' },
        { session_id => $session->id, family_member_id => $filler_child1->id },
    );

    # Process waitlist to offer spot to Parent A
    my $offered = Registry::DAO::Waitlist->process_waitlist($dao->db, $session->id);
    ok $offered, 'Waitlist processed, offer made';

    # Reload entry to get updated status
    ($entry_a) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_a->id });
    is $entry_a->status, 'offered', 'Entry status changed to offered';
    ok $entry_a->expires_at, 'Offer has expiration timestamp';

    # POST /waitlist/:id/accept via HTTP (JSON API)
    my $t = authed_mojo($parent_a);
    $t->post_ok("/waitlist/${\$entry_a->id}/accept")
      ->status_is(200, 'Accept returns 200 (not 500)')
      ->json_is('/success', 1, 'Response indicates success');

    # Verify enrollment was created
    my $enrollment = Registry::DAO::Enrollment->find($dao->db, {
        family_member_id => $child_a->id,
        session_id       => $session->id,
    });
    ok $enrollment, 'Enrollment created after accept';
    is $enrollment->status, 'pending', 'Enrollment status is pending (from waitlist)';

    # Verify waitlist entry status updated
    ($entry_a) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_a->id });
    is $entry_a->status, 'declined', 'Waitlist entry marked as declined (accepted convention)';
};

# ============================================================
# 3.2 Decline Path
# ============================================================
subtest 'decline offer passes to next in line' => sub {
    # Cancel filler2's enrollment to open a spot for the decline test
    $dao->db->update('enrollments',
        { status => 'cancelled' },
        { session_id => $session->id, family_member_id => $filler_child2->id },
    );

    # Parent B and Parent C join waitlist
    my $parent_b = $dao->create(User => {
        username => 'wl_parent_b', name => 'Parent B',
        user_type => 'parent', email => 'wl_b@example.com',
    });
    my $child_b = Registry::DAO::Family->add_child($dao->db, $parent_b->id, {
        child_name => 'Child B', birth_date => '2018-05-01', grade => '2',
        medical_info => {}, emergency_contact => { name => 'Parent B', phone => '555-2222' },
    });

    my $parent_c = $dao->create(User => {
        username => 'wl_parent_c', name => 'Parent C',
        user_type => 'parent', email => 'wl_c@example.com',
    });
    my $child_c = Registry::DAO::Family->add_child($dao->db, $parent_c->id, {
        child_name => 'Child C', birth_date => '2018-08-01', grade => '2',
        medical_info => {}, emergency_contact => { name => 'Parent C', phone => '555-3333' },
    });

    my $entry_b = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $child_b->id,
        family_member_id => $child_b->id,
        parent_id        => $parent_b->id,
        status           => 'waiting',
        position         => 1,
    });
    my $entry_c = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $child_c->id,
        family_member_id => $child_c->id,
        parent_id        => $parent_c->id,
        status           => 'waiting',
        position         => 2,
    });

    ok $entry_b, 'Parent B on waitlist';
    ok $entry_c, 'Parent C on waitlist';

    # Process waitlist - Parent B gets offer (first in line)
    Registry::DAO::Waitlist->process_waitlist($dao->db, $session->id);
    ($entry_b) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_b->id });
    is $entry_b->status, 'offered', 'Parent B has offer';

    # Parent B declines via HTTP (JSON API)
    my $t = authed_mojo($parent_b);
    $t->post_ok("/waitlist/${\$entry_b->id}/decline")
      ->status_is(200, 'Decline returns 200 (not 500)')
      ->json_is('/success', 1, 'Response indicates success');

    # Verify Parent B's entry is declined
    ($entry_b) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_b->id });
    is $entry_b->status, 'declined', 'Parent B status is declined';

    # Verify Parent C now has the offer (decline_offer processes next automatically)
    ($entry_c) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_c->id });
    is $entry_c->status, 'offered', 'Parent C now has offer after B declined';

    # No enrollment created for Parent B
    my $enrollment_b = $dao->db->select('enrollments', '*', {
        family_member_id => $child_b->id,
        session_id       => $session->id,
    })->hash;
    ok !$enrollment_b, 'No enrollment created for Parent B';

    # Parent C can accept
    my $t_c = authed_mojo($parent_c);
    $t_c->post_ok("/waitlist/${\$entry_c->id}/accept")
       ->status_is(200, 'Parent C accept succeeds');

    my $enrollment_c = Registry::DAO::Enrollment->find($dao->db, {
        family_member_id => $child_c->id,
        session_id       => $session->id,
    });
    ok $enrollment_c, 'Enrollment created for Parent C';
};

# ============================================================
# 3.3 Expired Offer
# ============================================================
subtest 'expired offer rejected gracefully' => sub {
    # Create a new parent on the waitlist
    my $parent_d = $dao->create(User => {
        username => 'wl_parent_d', name => 'Parent D',
        user_type => 'parent', email => 'wl_d@example.com',
    });
    my $child_d = Registry::DAO::Family->add_child($dao->db, $parent_d->id, {
        child_name => 'Child D', birth_date => '2018-10-01', grade => '2',
        medical_info => {}, emergency_contact => { name => 'Parent D', phone => '555-4444' },
    });

    my $entry_d = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $child_d->id,
        family_member_id => $child_d->id,
        parent_id        => $parent_d->id,
        status           => 'waiting',
        position         => 1,
    });

    # Manually set status to 'offered' and set an already-expired timestamp
    $dao->db->query(
        "UPDATE waitlist SET status = 'offered', offered_at = NOW() - INTERVAL '72 hours', expires_at = NOW() - INTERVAL '24 hours' WHERE id = ?",
        $entry_d->id,
    );

    ($entry_d) = Registry::DAO::Waitlist->find($dao->db, { id => $entry_d->id });
    is $entry_d->status, 'offered', 'Entry status is offered (but expired)';

    # POST /waitlist/:id/accept should fail gracefully
    my $t = authed_mojo($parent_d);
    $t->post_ok("/waitlist/${\$entry_d->id}/accept");

    # Should NOT be a 500. Should be 400 (JSON error) since no Accept header
    $t->status_is(400, 'Expired offer accept returns 400 (not 500)');

    # No enrollment created
    my $enrollment_d = $dao->db->select('enrollments', '*', {
        family_member_id => $child_d->id,
        session_id       => $session->id,
    })->hash;
    ok !$enrollment_d, 'No enrollment created for expired offer';
};

done_testing;
