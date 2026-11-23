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

subtest 'perform: global sweep calls expire_all_old_offers per tenant, registry included' => sub {
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
    is scalar(@registry_calls), 1,
        'registry schema is included in the sweep once (it is the platform tenant)';
};

# ---- The platform tenant is a tenant ----------------------------------------
#
# The platform is the tenant row whose slug is `registry`, and its schema is
# the registry schema, so its waitlist is registry.waitlist and the sweep
# reaches it through connect_schema('registry') like any other slug.

# Plant an offered waitlist entry in the registry schema, on its own session,
# whose expires_at is NOW() plus the given interval. Returns its id.
sub plant_platform_offer ( $label, $expires_in ) {
    my $db = $dao->db;

    my $loc = Registry::DAO::Location->create( $db, {
        name         => "Platform $label Location",
        slug         => "platform-$label-loc-$$",
        address_info => { street => '1 Platform St' },
    });
    my $sess = Registry::DAO::Session->create( $db, {
        name => "Platform $label Session",
        slug => "platform-$label-session-$$",
    });
    my $kid = Test::Registry::Fixtures::create_user( $dao, {
        username  => "pf_${label}_kid_$$",
        password  => 'pw',
        user_type => 'student',
    });

    return $db->query(q{
        INSERT INTO registry.waitlist
            (session_id, location_id, student_id, parent_id, position, status,
             offered_at, expires_at)
        VALUES (?, ?, ?, ?, 1, 'offered', NOW() - INTERVAL '1 hour', NOW() + ?::interval)
        RETURNING id
    }, $sess->id, $loc->id, $kid->id, $parent->id, $expires_in)->array->[0];
}

sub platform_status ($id) {
    return $dao->db->query(
        'SELECT status FROM registry.waitlist WHERE id = ?', $id )->array->[0];
}

subtest 'the expiration sweep covers the platform tenant and expires its old offer' => sub {
    ok Registry::DAO::Tenant->platform( $dao->db ), 'the platform tenant row exists';

    my $pf_id = plant_platform_offer( 'old', '-1 hour' );
    is platform_status($pf_id), 'offered', 'the platform offer is outstanding before the sweep';

    my $result = Registry::Job::WaitlistExpiration->expire_all_tenant_offers( $dao, $log );

    my @registry = grep { $_ eq 'registry' } $result->{tenants_covered}->@*;
    is scalar(@registry), 1, 'registry is reported in tenants_covered once';
    is_deeply $result->{tenants_skipped}, [], 'and no tenant was skipped';

    is platform_status($pf_id), 'expired', 'the lapsed platform offer is expired';
};

subtest 'a platform offer not yet expired is left alone' => sub {
    my $pf_id = plant_platform_offer( 'fresh', '1 minute' );

    my $result = Registry::Job::WaitlistExpiration->expire_all_tenant_offers( $dao, $log );

    ok( ( grep { $_ eq 'registry' } $result->{tenants_covered}->@* ),
        'the sweep covered registry' );
    is platform_status($pf_id), 'offered',
        'an offer with a minute left is still offered';
};

subtest 'expiring platform offers touches no other tenant schema' => sub {
    # Two offers in the provisioned tenant's own schema: one lapsed, one live.
    my $t_session = Registry::DAO::Session->create( $t_db, {
        name => 'WE Isolation Session',
        slug => 'we-isolation-session-' . $$,
    });
    my %t_offer;
    for my $case ( [ lapsed => '-1 hour' ], [ live => '1 hour' ] ) {
        my ( $name, $expires_in ) = @$case;
        my $kid = Test::Registry::Fixtures::create_user( $dao, {
            username  => "we_iso_${name}_$$",
            password  => 'pw',
            user_type => 'student',
        });
        $dao->db->query( 'SELECT copy_user(dest_schema => ?, user_id => ?)', $slug, $kid->id );
        $t_offer{$name} = $t_db->query(q{
            INSERT INTO waitlist
                (session_id, location_id, student_id, parent_id, position, status,
                 offered_at, expires_at)
            VALUES (?, ?, ?, ?, 1, 'offered', NOW() - INTERVAL '2 hours', NOW() + ?::interval)
            RETURNING id
        }, $t_session->id, $location->id, $kid->id, $parent->id, $expires_in )->array->[0];
    }
    my $t_status = sub ($id) {
        $t_db->query( 'SELECT status FROM waitlist WHERE id = ?', $id )->array->[0];
    };

    my $pf_id = plant_platform_offer( 'isolation', '-1 hour' );

    # Expire the registry schema's offers alone.
    Registry::Job::WaitlistExpiration->expire_all_old_offers(
        $dao->connect_schema('registry'), $log );

    is platform_status($pf_id), 'expired', "the platform's lapsed offer is expired";
    is $t_status->( $t_offer{lapsed} ), 'offered',
        "the tenant's lapsed offer is not touched by the platform's expiry";
    is $t_status->( $t_offer{live} ), 'offered',
        "the tenant's live offer is not touched either";

    # Now the whole sweep: the tenant's lapsed offer expires in its own schema.
    Registry::Job::WaitlistExpiration->expire_all_tenant_offers( $dao, $log );

    is $t_status->( $t_offer{lapsed} ), 'expired',
        "the tenant's lapsed offer is expired in its own schema";
    is $t_status->( $t_offer{live} ), 'offered', "its live offer is still offered";
    is $dao->db->query(
        'SELECT COUNT(*) FROM registry.waitlist WHERE id IN (?, ?)',
        $t_offer{lapsed}, $t_offer{live} )->array->[0], 0,
        'no tenant offer has a row in the registry schema';
};

$t->cleanup_test_database;
done_testing;
