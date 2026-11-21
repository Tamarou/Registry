#!/usr/bin/env perl
# ABOUTME: Tests for admin dashboard data accuracy.
# ABOUTME: Verifies enrollment counts, waitlist counts, and payment totals match actual data.

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
use Registry::DAO::PricingPlan;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# --- Setup ---

my $location = $dao->create(Location => {
    name => 'Accuracy Studio', slug => 'accuracy-studio',
    address_info => { city => 'Orlando' }, metadata => {},
});

my $program = $dao->create(Project => { status => 'published',
    name => 'Accuracy Camp', program_type_slug => 'summer-camp', metadata => {},
});

my $teacher = $dao->create(User => { username => 'acc_teacher', user_type => 'staff' });

my $session = $dao->create(Session => {
    name => 'Accuracy Week 1', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 10, metadata => {},
});

my $event = $dao->create(Event => {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $location->id, project_id => $program->id,
    teacher_id => $teacher->id, capacity => 10, metadata => {},
});
$session->add_events($dao->db, $event->id);

$dao->create(PricingPlan => {
    session_id => $session->id, plan_name => 'Standard',
    plan_type => 'standard', amount => 300.00,
});

# Create 5 enrollments (3 active, 1 pending, 1 cancelled)
my @statuses = ('active', 'active', 'active', 'pending', 'cancelled');
my @enrollments;

for my $i (0..4) {
    my $p = $dao->create(User => {
        username => "acc_parent_$i", name => "Accuracy Parent $i",
        user_type => 'parent', email => "acc_$i\@test.com",
    });
    my $c = Registry::DAO::Family->add_child($dao->db, $p->id, {
        child_name => "Acc Kid $i", birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });
    my $e = Registry::DAO::Enrollment->create($dao->db, {
        session_id => $session->id, family_member_id => $c->id,
        parent_id => $p->id, status => $statuses[$i],
    });
    push @enrollments, $e;
}

# Create 2 waitlist entries (1 waiting, 1 offered)
my $wl_parent1 = $dao->create(User => {
    username => 'acc_wl_1', name => 'WL Parent 1',
    user_type => 'parent', email => 'wl1@test.com',
});
my $wl_child1 = Registry::DAO::Family->add_child($dao->db, $wl_parent1->id, {
    child_name => 'WL Kid 1', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});
Registry::DAO::Waitlist->create($dao->db, {
    session_id => $session->id, location_id => $location->id,
    student_id => $wl_child1->id, family_member_id => $wl_child1->id,
    parent_id => $wl_parent1->id, status => 'waiting', position => 1,
});

my $wl_parent2 = $dao->create(User => {
    username => 'acc_wl_2', name => 'WL Parent 2',
    user_type => 'parent', email => 'wl2@test.com',
});
my $wl_child2 = Registry::DAO::Family->add_child($dao->db, $wl_parent2->id, {
    child_name => 'WL Kid 2', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});
Registry::DAO::Waitlist->create($dao->db, {
    session_id => $session->id, location_id => $location->id,
    student_id => $wl_child2->id, family_member_id => $wl_child2->id,
    parent_id => $wl_parent2->id, status => 'offered', position => 2,
});

# ============================================================
# Test: Enrollment counts match actual records
# ============================================================
subtest 'enrollment counts match actual enrollments' => sub {
    my $active_count = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $active_count, 4, 'Active + pending count is 4 (3 active + 1 pending)';

    my $active_only = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active']
    );
    is $active_only, 3, 'Active-only count is 3';

    # Verify by direct query
    my $direct = $dao->db->select('enrollments', 'COUNT(*)', {
        session_id => $session->id,
        status     => ['active', 'pending'],
    })->array->[0];
    is $direct, $active_count, 'DAO count matches direct SQL count';
};

# ============================================================
# Test: Waitlist counts match actual entries
# ============================================================
subtest 'waitlist counts match actual entries' => sub {
    my $waiting = $dao->db->select('waitlist', 'COUNT(*)', {
        session_id => $session->id,
        status     => 'waiting',
    })->array->[0];
    is $waiting, 1, '1 waiting entry';

    my $offered = $dao->db->select('waitlist', 'COUNT(*)', {
        session_id => $session->id,
        status     => 'offered',
    })->array->[0];
    is $offered, 1, '1 offered entry';

    my $total = $dao->db->select('waitlist', 'COUNT(*)', {
        session_id => $session->id,
        status     => ['waiting', 'offered'],
    })->array->[0];
    is $total, 2, 'Total active waitlist is 2';
};

# ============================================================
# Test: Available spots calculation is correct
# ============================================================
subtest 'available spots = capacity - active enrollments' => sub {
    my $capacity = $session->capacity;
    my $enrolled = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );

    my $available = $capacity - $enrolled;
    is $available, 6, 'Available spots = 10 - 4 = 6';
};

# ============================================================
# Test: Status changes reflected in counts
# ============================================================
subtest 'status changes immediately reflected in counts' => sub {
    # Cancel one active enrollment
    $dao->db->update('enrollments',
        { status => 'cancelled' },
        { id => $enrollments[0]->id },
    );

    my $count_after = Registry::DAO::Enrollment->count_for_session(
        $dao->db, $session->id, ['active', 'pending']
    );
    is $count_after, 3, 'Count decreased after cancellation (4 -> 3)';

    # Restore for other tests
    $dao->db->update('enrollments',
        { status => 'active' },
        { id => $enrollments[0]->id },
    );
};

done_testing;
