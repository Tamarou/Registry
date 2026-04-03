# ABOUTME: Validates that setup_registration_test_data.pl creates correct test data
# ABOUTME: Ensures tenant, location, program, sessions, events, pricing, users exist
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use JSON::PP qw(decode_json);

my $test_db = Test::Registry::DB->new;
my $dao = $test_db->db;
my $db  = $dao->db;

# Run the setup script and capture output
my $script = 't/playwright/setup_registration_test_data.pl';
my $db_url = $test_db->uri;

ok(-f $script, 'setup script exists');

my $output = `DB_URL=$db_url perl -Ilib -It/lib $script 2>&1`;
my $exit_code = $? >> 8;

is($exit_code, 0, 'setup script exits successfully');

# Parse JSON output
my $data = eval { decode_json($output) };
ok($data, 'output is valid JSON') or diag "Parse error: $@\nOutput: $output";

# Validate top-level keys
for my $key (qw(tenant_slug tenant_id location_id program_id sessions returning_parent admin)) {
    ok(exists $data->{$key}, "output contains '$key'");
}

# Validate tenant
is($data->{tenant_slug}, 'super-awesome-cool-pottery', 'correct tenant slug');
ok($data->{tenant_id}, 'tenant_id is set');

# Validate location
ok($data->{location_id}, 'location_id is set');

# Validate program
ok($data->{program_id}, 'program_id is set');

# Validate sessions
is(ref $data->{sessions}, 'HASH', 'sessions is a hash');
for my $key (qw(week1 week2 week3_full)) {
    ok(exists $data->{sessions}{$key}, "sessions contains '$key'");
    ok($data->{sessions}{$key}{id}, "session $key has id");
    ok($data->{sessions}{$key}{name}, "session $key has name");
}

# Validate returning parent
ok($data->{returning_parent}{token}, 'returning parent has magic link token');
ok($data->{returning_parent}{user_id}, 'returning parent has user_id');
ok($data->{returning_parent}{email}, 'returning parent has email');
ok($data->{returning_parent}{child_id}, 'returning parent has child_id');
is($data->{returning_parent}{child_name}, 'Emma Johnson', 'returning parent child is Emma Johnson');

# Validate admin
ok($data->{admin}{token}, 'admin has magic link token');
ok($data->{admin}{user_id}, 'admin has user_id');

# Validate data in database
subtest 'database records exist' => sub {
    # Tenant
    my $tenant = $db->select('tenants', '*', { id => $data->{tenant_id} })->hash;
    ok($tenant, 'tenant exists in DB');

    # Location
    my $location = $db->select('locations', '*', { id => $data->{location_id} })->hash;
    ok($location, 'location exists in DB');

    # Program (project)
    my $project = $db->select('projects', '*', { id => $data->{program_id} })->hash;
    ok($project, 'project exists in DB');

    # Sessions
    for my $key (qw(week1 week2 week3_full)) {
        my $session = $db->select('sessions', '*', { id => $data->{sessions}{$key}{id} })->hash;
        ok($session, "session $key exists in DB");
        is($session->{status}, 'published', "session $key is published");
    }

    # Week 3 should be at capacity (2 enrollments filling capacity of 2)
    my $week3_id = $data->{sessions}{week3_full}{id};
    my $week3 = $db->select('sessions', '*', { id => $week3_id })->hash;
    my $enrollment_count = $db->select('enrollments', 'count(*) as cnt',
        { session_id => $week3_id, status => 'active' })->hash->{cnt};
    my $capacity = $week3->{capacity} // 0;
    is($enrollment_count, $capacity, "week3_full is at capacity ($capacity enrolled)");

    # Returning parent user
    my $parent = $db->select('users', '*', { id => $data->{returning_parent}{user_id} })->hash;
    ok($parent, 'returning parent exists in DB');
    is($parent->{user_type}, 'parent', 'returning parent has user_type=parent');

    # Child (family member)
    my $child = $db->select('family_members', '*', { id => $data->{returning_parent}{child_id} })->hash;
    ok($child, 'child exists in DB');
    is($child->{child_name}, 'Emma Johnson', 'child name is Emma Johnson');

    # Admin user
    my $admin = $db->select('users', '*', { id => $data->{admin}{user_id} })->hash;
    ok($admin, 'admin exists in DB');
    is($admin->{user_type}, 'admin', 'admin has user_type=admin');

    # Events exist for sessions (linked via session_events junction table)
    for my $key (qw(week1 week2)) {
        my $event_count = $db->select('session_events', 'count(*) as cnt',
            { session_id => $data->{sessions}{$key}{id} })->hash->{cnt};
        is($event_count, 5, "session $key has 5 events (Mon-Fri)");
    }
};

done_testing;
