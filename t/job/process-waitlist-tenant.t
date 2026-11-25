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

my $location = Registry::DAO::Location->create( $t_db, { time_zone => 'America/New_York',
    name         => 'WL Test Location',
    slug         => 'wl-test-loc-' . $$,
    address_info => { street => '1 Test St' },
});

# Capacity matters: process_session_waitlist computes capacity minus enrolled
# and returns early when that is not positive, so a session without one can
# never promote anybody.
my $session = Registry::DAO::Session->create( $t_db, {
    name     => 'WL Test Session',
    slug     => 'wl-test-session-' . $$,
    capacity => 10,
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
    is scalar(@registry_calls), 1,
        'registry schema is included in the sweep once (it is the platform tenant)';
};

# The two halves of the chain were each proven and the join between them was
# not: the subtest above stubs process_recent_cancellations to count dispatch,
# and t/dao/waitlist-stress-test.t proves the DAO promotes. Nothing ran the
# scheduled job and looked at whether anybody was actually offered a seat.
#
# This must stay AFTER the dispatch subtest: that one replaces the method, so
# running it first would leave nothing for this to observe.
subtest 'perform: the sweep really does offer the freed seat' => sub {
    my $before = $t_db->query(
        'SELECT status FROM waitlist WHERE id = ?', $wl_entry->id )->hash;
    is $before->{status}, 'waiting', 'the family is waiting before the sweep runs';

    Registry::Job::ProcessWaitlist->perform($job);

    my $after = $t_db->query(
        'SELECT status, offered_at, expires_at FROM waitlist WHERE id = ?',
        $wl_entry->id )->hash;

    is $after->{status}, 'offered',
        'the scheduled sweep promoted them without anyone pressing anything';
    ok $after->{offered_at}, 'and recorded when the offer went out';
    ok $after->{expires_at}, 'and when it lapses, so the seat is not held forever';
};

# ---- The platform tenant is a tenant ----------------------------------------
#
# The platform is the tenant row whose slug is `registry`, and its schema is
# the registry schema. Its sessions, enrollments and waitlist live there, so the
# sweep reaches them through connect_schema('registry') like any other slug.

# Plant a session in the registry schema with one cancelled enrollment and the
# given number of waiting families. Returns the session and the waitlist ids in
# position order.
sub plant_platform_session ( $label, $capacity, $waiting ) {
    my $db = $dao->db;

    my $loc = Registry::DAO::Location->create( $db, { time_zone => 'America/New_York',
        name         => "Platform $label Location",
        slug         => "platform-$label-loc-$$",
        address_info => { street => '1 Platform St' },
    });

    my $sess = Registry::DAO::Session->create( $db, {
        name     => "Platform $label Session",
        slug     => "platform-$label-session-$$",
        capacity => $capacity,
    });

    my $leaver = Test::Registry::Fixtures::create_user( $dao, {
        username  => "pf_${label}_leaver_$$",
        password  => 'pw',
        user_type => 'student',
    });
    Registry::DAO::Enrollment->create( $db, {
        session_id => $sess->id,
        student_id => $leaver->id,
        parent_id  => $parent->id,
        status     => 'cancelled',
    });

    my @wl_ids;
    for my $n ( 1 .. $waiting ) {
        my $kid = Test::Registry::Fixtures::create_user( $dao, {
            username  => "pf_${label}_kid${n}_$$",
            password  => 'pw',
            user_type => 'student',
        });
        push @wl_ids, Registry::DAO::Waitlist->create( $db, {
            session_id  => $sess->id,
            location_id => $loc->id,
            student_id  => $kid->id,
            parent_id   => $parent->id,
            position    => $n,
            status      => 'waiting',
        })->id;
    }

    return ( $sess, @wl_ids );
}

subtest 'the cancellation sweep covers the platform tenant and offers its freed seat' => sub {
    ok Registry::DAO::Tenant->platform( $dao->db ), 'the platform tenant row exists';

    my ( $pf_session, $pf_wl_id ) = plant_platform_session( 'cover', 1, 1 );

    my $result = Registry::Job::ProcessWaitlist->process_all_tenant_cancellations( $dao, $log );

    my @registry = grep { $_ eq 'registry' } $result->{tenants_covered}->@*;
    is scalar(@registry), 1, 'registry is reported in tenants_covered once';
    is_deeply $result->{tenants_skipped}, [],
        'and no tenant was skipped (the offer notification no longer dies after the offer)';

    my $row = $dao->db->query(
        'SELECT status, offered_at FROM registry.waitlist WHERE id = ?', $pf_wl_id )->hash;
    is $row->{status}, 'offered', 'the waitlisted platform family is offered the freed seat';
    ok $row->{offered_at}, 'and the offer is dated';
};

subtest 'sweeping twice offers one freed platform seat to one family once' => sub {
    my ( $pf_session, $first_id, $second_id ) = plant_platform_session( 'twice', 1, 2 );

    my $offers_for = sub {
        return $dao->db->query(q{
            SELECT id, status, offered_at FROM registry.waitlist
             WHERE session_id = ? ORDER BY position, created_at
        }, $pf_session->id )->hashes->to_array;
    };

    Registry::Job::ProcessWaitlist->process_all_tenant_cancellations( $dao, $log );
    my %after_one = map { $_->{id} => $_ } $offers_for->()->@*;

    Registry::Job::ProcessWaitlist->process_all_tenant_cancellations( $dao, $log );
    my %after_two = map { $_->{id} => $_ } $offers_for->()->@*;

    is $after_two{$first_id}{status},  'offered', 'the first family in line holds the offer';
    is $after_two{$second_id}{status}, 'waiting', 'the second family is still waiting';
    is scalar( grep { $_->{status} eq 'offered' } values %after_two ), 1,
        'exactly one family holds an offer for the one freed seat';
    is $after_two{$first_id}{offered_at}, $after_one{$first_id}{offered_at},
        'the second pass did not re-offer the seat';
};

subtest 'a tenant row with no schema does not stop the sweep' => sub {
    my $ghost = 'ghost_' . $$;
    $dao->db->query(
        'INSERT INTO registry.tenants (name, slug) VALUES (?, ?)', "Ghost $$", $ghost );
    ok !$dao->db->query(
        'SELECT 1 FROM information_schema.schemata WHERE schema_name = ?', $ghost )->array,
        'the ghost tenant has no schema';

    my $result = Registry::Job::ProcessWaitlist->process_all_tenant_cancellations( $dao, $log );
    my %covered = map { $_ => 1 } $result->{tenants_covered}->@*;
    my %skipped = map { $_->{slug} => $_->{error} } $result->{tenants_skipped}->@*;

    ok $covered{registry}, 'the sweep still covers registry';
    ok $covered{$slug},    'and the provisioned tenant';
    ok !$covered{$ghost},  'the schema-less tenant is not reported covered';
    ok $skipped{$ghost},   'it is reported skipped, with a reason';

    $dao->db->query( 'DELETE FROM registry.tenants WHERE slug = ?', $ghost );
};

$t->cleanup_test_database;
done_testing;
