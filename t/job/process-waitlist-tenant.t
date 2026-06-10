#!/usr/bin/env perl
# ABOUTME: Tests that the ProcessWaitlist job's global sweep iterates all tenant schemas.
# ABOUTME: Verifies fix for F-2: the sweep was blind to every tenant schema.
use 5.42.0;

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::Waitlist;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::Job::ProcessWaitlist;

# ---- database setup --------------------------------------------------------

my $t   = Test::Registry::DB->new;
my $dao = $t->db;    # registry-schema DAO

# Provision a real tenant so get_all_tenant_schemas returns it.
my $parent = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'wl_parent_' . $$,
    password  => 'pw',
    user_type => 'parent',
});

my $student = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'wl_student_' . $$,
    password  => 'pw',
    user_type => 'student',
});

my $tenant = Registry::DAO::Tenant->provision( $dao->db, {
    name  => 'WaitlistTestTenant_' . $$,
    slug  => 'wl_test_' . $$,
    users => [ $parent ],
});

my $slug  = $tenant->slug;
my $t_dao = $dao->connect_schema($slug);   # tenant-scoped DAO
my $t_db  = $t_dao->db;

# Copy the student into the tenant schema so FK constraints are satisfied.
$dao->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $student->id);

# ---- minimal tenant-schema test data ----------------------------------------

my $location = Registry::DAO::Location->create( $t_db, {
    name         => 'WL Test Location',
    slug         => 'wl-test-loc-' . $$,
    address_info => { street => '1 Test St' },
});

my $session = Registry::DAO::Session->create( $t_db, {
    name => 'WL Test Session',
    slug => 'wl-test-session-' . $$,
});

# Create a cancelled enrollment with updated_at = NOW() (within the last hour).
# This enrollment lives in the tenant schema, not in registry.
my $enrollment = Registry::DAO::Enrollment->create( $t_db, {
    session_id  => $session->id,
    student_id  => $student->id,
    parent_id   => $parent->id,
    status      => 'cancelled',
});

ok $enrollment, 'cancelled enrollment created in tenant schema';

# Create a waitlist entry for the same session in the tenant schema.
my $wl_entry = Registry::DAO::Waitlist->create( $t_db, {
    session_id  => $session->id,
    location_id => $location->id,
    student_id  => $student->id,
    parent_id   => $parent->id,
    position    => 1,
    status      => 'waiting',
});

ok $wl_entry, 'waitlist entry created in tenant schema';

# ---- minimal mock infrastructure -------------------------------------------

{
    package MockLogger;
    sub new   { bless {}, shift }
    sub info  { }
    sub debug { }
    sub warn  { }
    sub error { }
}

{
    package MockJob;
    sub new    { bless { app => $_[1] }, $_[0] }
    sub app    { $_[0]->{app} }
    sub finish { }
    sub fail   { }
}

{
    package MockApp;
    sub new { bless { dao => $_[1], log => $_[2] }, $_[0] }
    sub dao { $_[0]->{dao} }
    sub log { $_[0]->{log} }
}

my $log = MockLogger->new;
my $app = MockApp->new( $dao, $log );
my $job = MockJob->new( $app );

# ---- Unit test: process_recent_cancellations is schema-aware ----------------
#
# The core of F-2: unqualified SQL in process_recent_cancellations resolves
# against the current search_path.  With a registry-scoped DAO the tenant's
# enrollments table is invisible; with a tenant-scoped DAO it is found.

subtest 'process_recent_cancellations: registry-scoped dao finds no sessions (F-2)' => sub {
    # Capture sessions by subclassing process_session_waitlist to collect args
    my @found_sessions;
    {
        no warnings 'redefine';
        local *Registry::Job::ProcessWaitlist::process_session_waitlist = sub {
            my ($class, $dao, $session_id, $log) = @_;
            push @found_sessions, $session_id;
        };

        Registry::Job::ProcessWaitlist->process_recent_cancellations( $dao, $log );
    }

    is scalar(@found_sessions), 0,
        'registry-scoped sweep finds 0 sessions - tenant enrollments invisible (F-2 confirmed)';
};

subtest 'process_recent_cancellations: tenant-scoped dao finds the cancelled session' => sub {
    my @found_sessions;
    {
        no warnings 'redefine';
        local *Registry::Job::ProcessWaitlist::process_session_waitlist = sub {
            my ($class, $dao, $session_id, $log) = @_;
            push @found_sessions, $session_id;
        };

        Registry::Job::ProcessWaitlist->process_recent_cancellations( $t_dao, $log );
    }

    is scalar(@found_sessions), 1,
        'tenant-scoped sweep finds 1 session with recent cancellation';
    is $found_sessions[0], $session->id,
        'found the correct session id in the tenant schema';
};

# ---- Integration test: perform() with no args routes through all tenants ----

subtest 'perform: global sweep calls process_recent_cancellations per tenant' => sub {
    my @called_schemas;
    {
        no warnings 'redefine';
        local *Registry::Job::ProcessWaitlist::process_recent_cancellations = sub {
            my ($class, $tenant_dao, $log) = @_;
            push @called_schemas, $tenant_dao->current_tenant;
        };

        Registry::Job::ProcessWaitlist->perform( $job );
    }

    ok scalar(@called_schemas) > 0,
        'perform called process_recent_cancellations at least once';

    my @tenant_calls = grep { $_ eq $slug } @called_schemas;
    is scalar(@tenant_calls), 1,
        "process_recent_cancellations was called for tenant schema '$slug'";

    my @registry_calls = grep { $_ eq 'registry' } @called_schemas;
    is scalar(@registry_calls), 0,
        'registry schema is not included in the sweep (tenant data is not there)';
};

$t->cleanup_test_database;
done_testing;
