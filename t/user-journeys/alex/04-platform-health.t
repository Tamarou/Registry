#!/usr/bin/env perl
# ABOUTME: Alex (platform owner) journey: the automation runs without him.
# ABOUTME: Tenant-aware sweeps process every tenant, isolate bad rows, and /health probes the DB.
use 5.42.0;

BEGIN { $ENV{EMAIL_SENDER_TRANSPORT} = 'Test' }

use lib qw(lib t/lib);
use experimental qw(defer);
use Test::More import => [qw( done_testing is like ok subtest )];
defer { done_testing };

use Test::Registry::Mojo;
use Test::Registry::DB;
use Test::Registry::Fixtures;
use Registry::DAO;
use Registry::DAO::Tenant;
use Registry::DAO::Waitlist;
use Registry::DAO::Location;
use Registry::DAO::Session;
use Registry::DAO::Enrollment;
use Registry::Job::ProcessWaitlist;
use Registry::Job::WaitlistExpiration;

# ---- database setup --------------------------------------------------------

my $test_db = Test::Registry::DB->new;
my $dao     = $test_db->db;    # registry-schema DAO
$ENV{DB_URL} = $test_db->uri;

# ---- fixture: Tenant A - has sweepable state for both sweeps ---------------
#
# WaitlistExpiration material: an 'offered' entry with expires_at in the past.
# ProcessWaitlist material: a recently-cancelled enrollment + a 'waiting' entry.

my $parent_a = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'ph_parent_a_' . $$,
    password  => 'pw',
    user_type => 'parent',
});

my $student_a = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'ph_student_a_' . $$,
    password  => 'pw',
    user_type => 'student',
});

# Second student for the 'waiting' waitlist entry (session/student unique constraint).
my $student_a2 = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'ph_student_a2_' . $$,
    password  => 'pw',
    user_type => 'student',
});

my $tenant_a = Registry::DAO::Tenant->provision( $dao->db, {
    name  => 'PlatformHealthTenantA_' . $$,
    slug  => 'ph_tenant_a_' . $$,
    users => [ $parent_a ],
});

my $slug_a  = $tenant_a->slug;
my $dao_a   = $dao->connect_schema($slug_a);
my $db_a    = $dao_a->db;

# Copy students into the tenant schema so FK constraints are satisfied.
$dao->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $slug_a, $student_a->id);
$dao->db->query('SELECT copy_user(dest_schema => ?, user_id => ?)', $slug_a, $student_a2->id);

my $location_a = Registry::DAO::Location->create( $db_a, {
    name         => 'PH Test Location A',
    slug         => 'ph-loc-a-' . $$,
    address_info => { street => '1 Test St' },
});

my $session_a = Registry::DAO::Session->create( $db_a, {
    name => 'PH Test Session A',
    slug => 'ph-session-a-' . $$,
});

# WaitlistExpiration material: offered entry with expires_at in the past.
$db_a->query(q{
    INSERT INTO waitlist
        (session_id, location_id, student_id, parent_id, position, status,
         offered_at, expires_at)
    VALUES (?, ?, ?, ?, 1, 'offered', NOW() - INTERVAL '49 hours', NOW() - INTERVAL '1 hour')
}, $session_a->id, $location_a->id, $student_a->id, $parent_a->id);

# ProcessWaitlist material: a recently-cancelled enrollment + a waiting entry.
Registry::DAO::Enrollment->create( $db_a, {
    session_id => $session_a->id,
    student_id => $student_a->id,
    parent_id  => $parent_a->id,
    status     => 'cancelled',
});

# student_a2 is distinct from student_a to satisfy the (session_id, student_id)
# unique constraint on the waitlist table -- each student can appear at most
# once per session on the waitlist.
Registry::DAO::Waitlist->create( $db_a, {
    session_id  => $session_a->id,
    location_id => $location_a->id,
    student_id  => $student_a2->id,
    parent_id   => $parent_a->id,
    position    => 2,
    status      => 'waiting',
});

# ---- fixture: Tenant B - provisioned with NO waitlist state ----------------

my $parent_b = Test::Registry::Fixtures::create_user( $dao, {
    username  => 'ph_parent_b_' . $$,
    password  => 'pw',
    user_type => 'parent',
});

my $tenant_b = Registry::DAO::Tenant->provision( $dao->db, {
    name  => 'PlatformHealthTenantB_' . $$,
    slug  => 'ph_tenant_b_' . $$,
    users => [ $parent_b ],
});

my $slug_b = $tenant_b->slug;

# ---- fixture: bad row - slug with no Postgres schema (#265 shape) ----------
#
# Defense-in-depth: the sweep must never let one bad row break other tenants
# regardless of whether such rows turn out to be legal (issue #265).
# This assertion survives any #265 resolution, including deleting the row
# and forbidding the state.

my $bad_slug = 'ph_no_schema_' . $$;
$dao->db->query(
    'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)',
    'PH Bad Row ' . $$,
    $bad_slug,
);

# ---- mock infrastructure (extended shims) -----------------------------------
#
# MockLogger captures error() calls to an array for assertion; other levels
# are silenced so test output stays pristine.
# MockJob records whether finish() or fail() was called so we can assert
# the bad row did not abort the sweep.

{
    package MockLogger;
    sub new   { bless { errors => [] }, shift }
    sub info  { }
    sub debug { }
    sub warn  { }
    sub error {
        my ($self, $msg) = @_;
        push @{ $self->{errors} }, $msg;
    }
    sub errors { @{ $_[0]->{errors} } }
}

{
    package MockJob;
    sub new    { bless { app => $_[1], finished => 0, failed => 0 }, $_[0] }
    sub app    { $_[0]->{app} }
    sub finish { $_[0]->{finished}++ }
    sub fail   { $_[0]->{failed}++  }
}

{
    package MockApp;
    sub new { bless { dao => $_[1], log => $_[2] }, $_[0] }
    sub dao { $_[0]->{dao} }
    sub log { $_[0]->{log} }
}

# ---- subtest 1: ProcessWaitlist dispatch reaches every tenant, skips registry ----

subtest 'ProcessWaitlist: sweep reaches tenant A and B, skips registry' => sub {
    my $log = MockLogger->new;
    my $app = MockApp->new( $dao, $log );
    my $job = MockJob->new( $app );

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

    my @a_calls = grep { $_ eq $slug_a } @called_schemas;
    is scalar(@a_calls), 1,
        "process_recent_cancellations dispatched for tenant A ($slug_a)";

    my @b_calls = grep { $_ eq $slug_b } @called_schemas;
    is scalar(@b_calls), 1,
        "process_recent_cancellations dispatched for tenant B ($slug_b)";

    my @reg_calls = grep { $_ eq 'registry' } @called_schemas;
    is scalar(@reg_calls), 0,
        'registry schema is not included in the ProcessWaitlist sweep';

    is $job->{finished}, 1, 'MockJob->finish was called (not fail)';
    is $job->{failed},   0, 'MockJob->fail was NOT called';
};

# ---- subtest 2: WaitlistExpiration dispatch reaches every tenant, skips registry ----

subtest 'WaitlistExpiration: sweep reaches tenant A and B, skips registry' => sub {
    my $log = MockLogger->new;
    my $app = MockApp->new( $dao, $log );
    my $job = MockJob->new( $app );

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

    my @a_calls = grep { $_ eq $slug_a } @called_schemas;
    is scalar(@a_calls), 1,
        "expire_all_old_offers dispatched for tenant A ($slug_a)";

    my @b_calls = grep { $_ eq $slug_b } @called_schemas;
    is scalar(@b_calls), 1,
        "expire_all_old_offers dispatched for tenant B ($slug_b)";

    my @reg_calls = grep { $_ eq 'registry' } @called_schemas;
    is scalar(@reg_calls), 0,
        'registry schema is not included in the WaitlistExpiration sweep';

    is $job->{finished}, 1, 'MockJob->finish was called (not fail)';
    is $job->{failed},   0, 'MockJob->fail was NOT called';
};

# ---- subtest 3: bad-row isolation (defense-in-depth, links issue #265) ------
#
# Run both performs WITHOUT dispatch interception so the real per-tenant
# try/catch exercises against the bad row whose schema does not exist.
# The sweep must: call finish (not fail), and the error must be logged
# (captured in MockLogger, never to raw STDERR) mentioning the bad slug.
# This assertion is intentionally schema-resolution-neutral - it survives
# any resolution of #265, including making such rows illegal and deleting them.

subtest 'ProcessWaitlist: bad row (no schema, #265) is isolated, sweep finishes' => sub {
    my $log = MockLogger->new;
    my $app = MockApp->new( $dao, $log );
    my $job = MockJob->new( $app );

    Registry::Job::ProcessWaitlist->perform( $job );

    is $job->{finished}, 1, 'ProcessWaitlist->finish called despite bad row';
    is $job->{failed},   0, 'ProcessWaitlist->fail NOT called';

    my @errors = $log->errors;
    my @bad_slug_errors = grep { /\Q$bad_slug\E/ } @errors;
    ok scalar(@bad_slug_errors) > 0,
        'bad-slug error was captured in the logger (not lost to STDERR)';
    like $bad_slug_errors[0], qr/\Q$bad_slug\E/,
        'captured error message mentions the bad slug';
};

subtest 'WaitlistExpiration: bad row (no schema, #265) is isolated, sweep finishes' => sub {
    my $log = MockLogger->new;
    my $app = MockApp->new( $dao, $log );
    my $job = MockJob->new( $app );

    Registry::Job::WaitlistExpiration->perform( $job );

    is $job->{finished}, 1, 'WaitlistExpiration->finish called despite bad row';
    is $job->{failed},   0, 'WaitlistExpiration->fail NOT called';

    my @errors = $log->errors;
    my @bad_slug_errors = grep { /\Q$bad_slug\E/ } @errors;
    ok scalar(@bad_slug_errors) > 0,
        'bad-slug error was captured in the logger (not lost to STDERR)';
    like $bad_slug_errors[0], qr/\Q$bad_slug\E/,
        'captured error message mentions the bad slug';
};

# ---- subtest 4: real effect in tenant A - WaitlistExpiration flips offer ----
#
# After the real WaitlistExpiration run above (subtest 3), the offered entry
# in tenant A should have flipped to 'expired'.  Assert on the tenant connection.

subtest 'WaitlistExpiration: offered entry in tenant A flipped to expired' => sub {
    # expire_old_offers sets position = 0 for expired entries, so we must NOT
    # filter on position here -- the row moved from position=1 to position=0.
    my $wl = $db_a->query(q{
        SELECT status FROM waitlist
        WHERE session_id = ? AND student_id = ?
    }, $session_a->id, $student_a->id)->hash;

    ok $wl, 'waitlist row still exists in tenant A';
    is $wl->{status}, 'expired',
        'the offered entry with past expires_at was flipped to expired by the sweep';
};

# ---- subtest 5: /health returns 200 with db:ok ------------------------------

subtest '/health: probes DB and returns ok' => sub {
    my $t = Test::Registry::Mojo->new('Registry');
    $t->get_ok('/health')
      ->status_is(200)
      ->json_is('/status', 'ok')
      ->json_is('/db',     'ok');
};

$test_db->cleanup_test_database;
