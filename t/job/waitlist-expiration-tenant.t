#!/usr/bin/env perl
# ABOUTME: Tests that the WaitlistExpiration job's global sweep iterates all tenant schemas.
# ABOUTME: Verifies fix for #246: the sweep was blind to every tenant schema.
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
use Registry::Job::WaitlistExpiration;

# ---- database setup --------------------------------------------------------

my $t   = Test::Registry::DB->new;
my $dao = $t->db;    # registry-schema DAO

# Provision a real tenant so get_all_tenant_schemas returns it.
my $parent = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'we_parent_' . $$,
    password  => 'pw',
    user_type => 'parent',
});

my $student = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'we_student_' . $$,
    password  => 'pw',
    user_type => 'student',
});

my $tenant = Registry::DAO::Tenant->provision( $dao->db, {
    name  => 'WaitlistExpirationTestTenant_' . $$,
    slug  => 'we_test_' . $$,
    users => [ $parent ],
});

my $slug    = $tenant->slug;
my $t_dao   = $dao->connect_schema($slug);   # tenant-scoped DAO
my $t_db    = $t_dao->db;

# Copy the student into the tenant schema so FK constraints are satisfied.
$dao->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $student->id);

# ---- minimal tenant-schema test data ----------------------------------------

my $location = Registry::DAO::Location->create( $t_db, {
    name         => 'WE Test Location',
    slug         => 'we-test-loc-' . $$,
    address_info => { street => '1 Test St' },
});

my $session = Registry::DAO::Session->create( $t_db, {
    name => 'WE Test Session',
    slug => 'we-test-session-' . $$,
});

# Create a waitlist entry in the tenant schema with status 'offered' and
# expires_at in the past so expire_old_offers will pick it up.
# We bypass create()'s default status validation by using the parent create
# directly with pre-set values - we use the DB directly for the INSERT so we
# can set offered_at and expires_at to past timestamps.
$t_db->query(q{
    INSERT INTO waitlist
        (session_id, location_id, student_id, parent_id, position, status,
         offered_at, expires_at)
    VALUES (?, ?, ?, ?, 1, 'offered', NOW() - INTERVAL '49 hours', NOW() - INTERVAL '1 hour')
}, $session->id, $location->id, $student->id, $parent->id);

# Confirm the entry was created
my $wl_raw = $t_db->query(q{
    SELECT id, status, expires_at FROM waitlist
    WHERE session_id = ? AND status = 'offered'
}, $session->id)->hash;

ok $wl_raw, 'offered waitlist entry created in tenant schema with past expires_at';

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

# ---- Subtest A: schema-awareness proof -------------------------------------
#
# expire_old_offers uses unqualified SQL ("UPDATE waitlist ...") which resolves
# against the current search_path.  With a registry-scoped DB handle the
# tenant's waitlist table is invisible; with a tenant-scoped handle it is found.
# Run the registry-scoped call first - it finds nothing and mutates nothing,
# so the tenant-scoped call in the next subtest still has a row to expire.

subtest 'expire_old_offers: registry-scoped db finds 0 expired entries' => sub {
    my $expired = Registry::DAO::Waitlist->expire_old_offers($dao->db);
    is scalar(@$expired), 0,
        'registry-scoped expire_old_offers finds 0 entries - tenant waitlist invisible';
};

subtest 'expire_old_offers: tenant-scoped db finds the expired entry' => sub {
    my $expired = Registry::DAO::Waitlist->expire_old_offers($t_dao->db);
    is scalar(@$expired), 1,
        'tenant-scoped expire_old_offers finds the 1 expired offered entry';
    is $expired->[0]->session_id, $session->id,
        'found the correct session id in the tenant schema';
};

# ---- Subtest B: perform() global sweep dispatches per tenant ----------------
#
# Re-insert the offered row so there is something to expire when perform()
# is exercised (subtest A's tenant call mutated it to 'expired').
$t_db->query(q{
    UPDATE waitlist
    SET status = 'offered', expires_at = NOW() - INTERVAL '1 hour'
    WHERE session_id = ? AND student_id = ?
}, $session->id, $student->id);

subtest 'perform: global sweep calls expire_all_old_offers per tenant, not for registry' => sub {
    my @called_schemas;
    {
        no warnings 'redefine';
        local *Registry::Job::WaitlistExpiration::expire_all_old_offers = sub {
            my ($class, $tenant_dao, $log) = @_;
            push @called_schemas, $tenant_dao->current_tenant;
        };

        Registry::Job::WaitlistExpiration->perform( $job );
    }

    ok scalar(@called_schemas) > 0,
        'perform called expire_all_old_offers at least once';

    my @tenant_calls = grep { $_ eq $slug } @called_schemas;
    is scalar(@tenant_calls), 1,
        "expire_all_old_offers was called for tenant schema '$slug'";

    my @registry_calls = grep { $_ eq 'registry' } @called_schemas;
    is scalar(@registry_calls), 0,
        'registry schema is not included in the sweep (tenant data is not there)';
};

$t->cleanup_test_database;
done_testing;
