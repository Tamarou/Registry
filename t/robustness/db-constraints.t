#!/usr/bin/env perl
# ABOUTME: Tests for database constraint error handling.
# ABOUTME: Verifies that duplicate usernames, emails, and FK violations produce clear errors.

use 5.42.0;
use warnings;
use utf8;

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;

use Registry::DAO;
use Registry::DAO::User;
use Registry::DAO::Enrollment;
use Registry::DAO::Session;
use Registry::DAO::Location;
use Registry::DAO::Project;
use Registry::DAO::Event;
use Registry::DAO::Family;

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# ============================================================
# Test: Duplicate username produces error, not crash
# ============================================================
subtest 'duplicate username gives clear error' => sub {
    Registry::DAO::User->create($dao->db, {
        username => 'unique_user', name => 'First',
        email => 'first@test.com', user_type => 'parent',
    });

    my $dup;
    eval {
        $dup = Registry::DAO::User->create($dao->db, {
            username => 'unique_user', name => 'Second',
            email => 'second@test.com', user_type => 'parent',
        });
    };

    ok $@, 'Duplicate username throws error';
    like $@, qr/duplicate|unique|constraint|already exists/i,
        'Error message indicates uniqueness violation';
    ok !$dup, 'No duplicate user created';
};

# ============================================================
# Test: Duplicate enrollment prevented
# ============================================================
subtest 'duplicate enrollment gives clear error' => sub {
    my $location = $dao->create(Location => {
        name => 'Constraint Studio', slug => 'constraint-studio',
        address_info => {}, metadata => {},
    });

    my $program = $dao->create(Project => { status => 'published', name => 'Constraint Camp', metadata => {} });
    my $teacher = $dao->create(User => { username => 'constraint_teacher', user_type => 'staff' });

    my $session = $dao->create(Session => {
        name => 'Constraint Session', start_date => '2026-06-01',
        end_date => '2026-06-05', status => 'published', capacity => 16,
        metadata => {},
    });

    my $parent = $dao->create(User => {
        username => 'constraint_parent', name => 'Constraint Parent',
        user_type => 'parent', email => 'constraint@test.com',
    });

    my $child = Registry::DAO::Family->add_child($dao->db, $parent->id, {
        child_name => 'Constraint Kid', birth_date => '2018-01-01', grade => '3',
        medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
    });

    # First enrollment succeeds
    my $enrollment = Registry::DAO::Enrollment->create($dao->db, {
        session_id => $session->id, family_member_id => $child->id,
        parent_id => $parent->id, status => 'active',
    });
    ok $enrollment, 'First enrollment succeeds';

    # Duplicate enrollment fails
    my $dup;
    eval {
        $dup = Registry::DAO::Enrollment->create($dao->db, {
            session_id => $session->id, family_member_id => $child->id,
            parent_id => $parent->id, status => 'active',
        });
    };

    ok $@, 'Duplicate enrollment throws error';
    like $@, qr/duplicate|unique|constraint/i, 'Error indicates constraint violation';
    ok !$dup, 'No duplicate enrollment created';
};

# ============================================================
# Test: Foreign key violation on nonexistent session
# ============================================================
subtest 'enrollment with nonexistent session gives clear error' => sub {
    my $parent = Registry::DAO::User->find($dao->db, { username => 'constraint_parent' });

    my $bad;
    eval {
        $bad = $dao->db->insert('enrollments', {
            session_id       => '00000000-0000-0000-0000-000000000000',
            family_member_id => '00000000-0000-0000-0000-000000000001',
            student_id       => $parent->id,
            status           => 'active',
        });
    };

    ok $@, 'FK violation throws error';
    like $@, qr/foreign key|violates|constraint/i, 'Error indicates FK violation';
};

# ============================================================
# Test: User creation with missing required fields
# ============================================================
subtest 'user creation with missing username fails clearly' => sub {
    my $bad;
    eval {
        $bad = Registry::DAO::User->create($dao->db, {
            name => 'No Username', email => 'nousername@test.com',
            user_type => 'parent',
        });
    };

    ok $@, 'Missing username throws error';
    like $@, qr/null|not-null|required|username/i, 'Error indicates missing field';
};

done_testing;
