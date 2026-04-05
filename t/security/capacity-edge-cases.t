#!/usr/bin/env perl
# ABOUTME: Tests for enrollment capacity edge cases.
# ABOUTME: Verifies full session error, duplicate enrollment prevention, and capacity changes.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Session;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Family;
use Registry::DAO::Enrollment;
use Registry::DAO::Waitlist;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Test Data ---

my $location = $dao->create(Location => {
    name => 'Capacity Studio', slug => 'cap-studio',
    address_info => { city => 'Orlando' }, metadata => {},
});

my $program = $dao->create(Project => {
    name => 'Capacity Camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'cap_teacher', user_type => 'staff' });

# Session with capacity 2
my $session = $dao->create(Session => {
    name => 'Tight Session', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 2, metadata => {},
});

my $event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 2, metadata => {},
});
$session->add_events($dao->db, $event->id);

# Parents and children
my @parents;
my @children;
for my $i (1..4) {
    my $p = $dao->create(User => {
        username => "cap_parent_$i", name => "Parent $i",
        user_type => 'parent', email => "cap_parent_$i\@test.com",
    });
    my $c = Registry::DAO::Family->add_child($dao->db, $p->id, {
        child_name => "Cap Kid $i", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });
    push @parents, $p;
    push @children, $c;
}

# ============================================================
# Test: Full session enrollment count
# ============================================================
subtest 'enrollment count respects capacity' => sub {
    # Enroll first two children (fills session)
    for my $i (0..1) {
        my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
            session_id       => $session->id,
            family_member_id => $children[$i]->id,
            parent_id        => $parents[$i]->id,
            status           => 'active',
        });
        ok $enrollment, "Child ${\($i+1)} enrolled";
    }

    my $count = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count, 2, 'Session has 2 active enrollments (at capacity)';
    is $count, $session->capacity, 'Enrollment count equals capacity';
};

# ============================================================
# Test: Duplicate enrollment prevented by DB constraint
# ============================================================
subtest 'duplicate enrollment prevented' => sub {
    # Try to enroll the same child in the same session again
    my $dup;
    eval {
        $dup = Registry::DAO::Enrollment->create($dao->db, {
            session_id       => $session->id,
            family_member_id => $children[0]->id,
            parent_id        => $parents[0]->id,
            status           => 'active',
        });
    };

    ok $@, 'Duplicate enrollment throws an error';
    like $@, qr/duplicate|unique|constraint/i, 'Error mentions uniqueness constraint';
    ok !$dup, 'No duplicate enrollment created';

    # Count should still be 2
    my $count = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count, 2, 'Enrollment count unchanged after duplicate attempt';
};

# ============================================================
# Test: Capacity change with existing enrollments
# ============================================================
subtest 'capacity reduction does not remove existing enrollments' => sub {
    # Reduce capacity to 1 (below current enrollment count)
    $dao->db->update('sessions', { capacity => 1 }, { id => $session->id });

    # Existing enrollments should still be there
    my $count = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count, 2, 'Existing enrollments preserved after capacity reduction';

    # Restore capacity
    $dao->db->update('sessions', { capacity => 2 }, { id => $session->id });
};

# ============================================================
# Test: Cancelled enrollment frees a spot
# ============================================================
subtest 'cancelled enrollment frees capacity' => sub {
    my $count_before = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count_before, 2, 'Session full before cancellation';

    # Cancel one enrollment
    $dao->db->update('enrollments',
        { status => 'cancelled' },
        { session_id => $session->id, family_member_id => $children[1]->id },
    );

    my $count_after = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count_after, 1, 'One spot freed after cancellation';

    # New enrollment now possible
    my $new_enrollment = Registry::DAO::Enrollment->create($dao->db, {
        session_id       => $session->id,
        family_member_id => $children[2]->id,
        parent_id        => $parents[2]->id,
        status           => 'active',
    });
    ok $new_enrollment, 'New enrollment created in freed spot';

    my $count_final = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count_final, 2, 'Session full again after new enrollment';
};

# ============================================================
# Test: Waitlist position when session is full
# ============================================================
subtest 'waitlist works when session is full' => sub {
    # Session is full (2/2). Add child 4 to waitlist.
    my $waitlist_entry = Registry::DAO::Waitlist->create($dao->db, {
        session_id       => $session->id,
        location_id      => $location->id,
        student_id       => $children[3]->id,
        family_member_id => $children[3]->id,
        parent_id        => $parents[3]->id,
        status           => 'waiting',
        position         => 1,
    });

    ok $waitlist_entry, 'Waitlist entry created';
    is $waitlist_entry->status, 'waiting', 'Status is waiting';
    is $waitlist_entry->position, 1, 'Position is 1';
};

done_testing;
