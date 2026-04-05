#!/usr/bin/env perl
# ABOUTME: Security tests for cross-tenant data isolation.
# ABOUTME: Verifies that tenants cannot see each other's enrollments, users, or sessions.

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

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

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;

# ============================================================
# Create two tenants with separate schemas
# ============================================================

my $tenant_a = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Tenant Alpha',
    slug => 'tenant_alpha',
});

my $tenant_b = Test::Registry::Fixtures::create_tenant($dao, {
    name => 'Tenant Beta',
    slug => 'tenant_beta',
});

ok $tenant_a, 'Tenant Alpha created';
ok $tenant_b, 'Tenant Beta created';

# Create DAOs scoped to each tenant
my $dao_a = Registry::DAO->new(url => $test_db->uri, schema => 'tenant_alpha');
my $dao_b = Registry::DAO->new(url => $test_db->uri, schema => 'tenant_beta');

# ============================================================
# Populate Tenant A with data
# ============================================================

my $loc_a = Registry::DAO::Location->create($dao_a->db, {
    name => 'Alpha Studio', slug => 'alpha-studio',
    address_info => { city => 'Orlando' }, metadata => {},
});

my $prog_a = Registry::DAO::Project->create($dao_a->db, {
    name => 'Alpha Camp', metadata => {},
});

my $teacher_a = Registry::DAO::User->create($dao_a->db, {
    username => 'alpha_teacher', user_type => 'staff',
});

my $session_a = Registry::DAO::Session->create($dao_a->db, {
    name => 'Alpha Week 1', start_date => '2026-06-01', end_date => '2026-06-05',
    status => 'published', capacity => 16, metadata => {},
});

my $event_a = Registry::DAO::Event->create($dao_a->db, {
    time => '2026-06-01 09:00:00', duration => 420,
    location_id => $loc_a->id, project_id => $prog_a->id,
    teacher_id => $teacher_a->id, capacity => 16, metadata => {},
});
$session_a->add_events($dao_a->db, $event_a->id);

my $parent_a = Registry::DAO::User->create($dao_a->db, {
    username => 'alpha_parent', name => 'Alpha Parent',
    user_type => 'parent', email => 'alpha@test.com',
});

my $child_a = Registry::DAO::Family->add_child($dao_a->db, $parent_a->id, {
    child_name => 'Alpha Kid', birth_date => '2018-01-01', grade => '3',
    medical_info => {}, emergency_contact => { name => 'P', phone => '555' },
});

my $enrollment_a = Registry::DAO::Enrollment->create($dao_a->db, {
    session_id => $session_a->id, family_member_id => $child_a->id,
    parent_id => $parent_a->id, status => 'active',
});

# ============================================================
# Populate Tenant B with different data
# ============================================================

my $loc_b = Registry::DAO::Location->create($dao_b->db, {
    name => 'Beta Studio', slug => 'beta-studio',
    address_info => { city => 'Tampa' }, metadata => {},
});

my $prog_b = Registry::DAO::Project->create($dao_b->db, {
    name => 'Beta Camp', metadata => {},
});

my $teacher_b = Registry::DAO::User->create($dao_b->db, {
    username => 'beta_teacher', user_type => 'staff',
});

my $session_b = Registry::DAO::Session->create($dao_b->db, {
    name => 'Beta Week 1', start_date => '2026-07-01', end_date => '2026-07-05',
    status => 'published', capacity => 10, metadata => {},
});

my $parent_b = Registry::DAO::User->create($dao_b->db, {
    username => 'beta_parent', name => 'Beta Parent',
    user_type => 'parent', email => 'beta@test.com',
});

# ============================================================
# Tests: Tenant A cannot see Tenant B's data
# ============================================================

subtest 'Tenant A cannot see Tenant B sessions' => sub {
    my $found = Registry::DAO::Session->find($dao_a->db, { name => 'Beta Week 1' });
    ok !$found, 'Tenant A cannot find Tenant B session by name';

    my $by_id = Registry::DAO::Session->find($dao_a->db, { id => $session_b->id });
    ok !$by_id, 'Tenant A cannot find Tenant B session by ID';
};

subtest 'Tenant B cannot see Tenant A sessions' => sub {
    my $found = Registry::DAO::Session->find($dao_b->db, { name => 'Alpha Week 1' });
    ok !$found, 'Tenant B cannot find Tenant A session by name';
};

subtest 'Tenant A cannot see Tenant B users' => sub {
    my $found = Registry::DAO::User->find($dao_a->db, { username => 'beta_parent' });
    ok !$found, 'Tenant A cannot find Tenant B user';
};

subtest 'Tenant B cannot see Tenant A users' => sub {
    my $found = Registry::DAO::User->find($dao_b->db, { username => 'alpha_parent' });
    ok !$found, 'Tenant B cannot find Tenant A user';
};

subtest 'Tenant A cannot see Tenant B locations' => sub {
    my $found = Registry::DAO::Location->find($dao_a->db, { slug => 'beta-studio' });
    ok !$found, 'Tenant A cannot find Tenant B location';
};

subtest 'Tenant A cannot see Tenant B enrollments' => sub {
    my $found = Registry::DAO::Enrollment->find($dao_a->db, { parent_id => $parent_b->id });
    ok !$found, 'Tenant A cannot find Tenant B enrollments';
};

subtest 'Tenant B cannot see Tenant A enrollments' => sub {
    my $found = Registry::DAO::Enrollment->find($dao_b->db, { id => $enrollment_a->id });
    ok !$found, 'Tenant B cannot find Tenant A enrollment by ID';
};

subtest 'Tenant A programs isolated from Tenant B' => sub {
    my $found = Registry::DAO::Project->find($dao_a->db, { name => 'Beta Camp' });
    ok !$found, 'Tenant A cannot find Tenant B program';
};

subtest 'Enrollment counts are tenant-scoped' => sub {
    my $count_a = Registry::DAO::Enrollment->count_for_session(
        $dao_a->db, $session_a->id, ['active', 'pending']
    );
    is $count_a, 1, 'Tenant A sees 1 enrollment in Alpha session';

    my $count_b = Registry::DAO::Enrollment->count_for_session(
        $dao_b->db, $session_a->id, ['active', 'pending']
    );
    is $count_b, 0, 'Tenant B sees 0 enrollments in Alpha session (different schema)';
};

subtest 'Family members isolated between tenants' => sub {
    my $children_a = Registry::DAO::Family->list_children($dao_a->db, $parent_a->id);
    ok scalar @$children_a >= 1, 'Tenant A parent has children';

    # Parent A ID doesn't exist in Tenant B schema
    my $children_cross = Registry::DAO::Family->list_children($dao_b->db, $parent_a->id);
    is scalar @$children_cross, 0, 'Tenant B has no children for Tenant A parent ID';
};

done_testing;
