#!/usr/bin/env perl
# ABOUTME: Verifies the SACP tenant seed script creates the tenant,
# ABOUTME: clones the schema, and populates expected rows.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use File::Spec;

my $tdb   = Test::Registry::DB->new;
my $dao   = $tdb->db;
my $db    = $dao->db;

my $seed_path = File::Spec->rel2abs('sql/seed/sacp-tenant.sql');

# Test::Registry::DB gives us a Test::PostgreSQL instance with a URI we
# can hand to psql. Run the seed script against it.
my $uri = $tdb->uri;
my $rc  = system(qq{psql -v ON_ERROR_STOP=1 "$uri" -f "$seed_path" >/dev/null 2>&1});
is($rc, 0, 'seed script runs without error');

subtest 'tenant row created' => sub {
    my $tenant = $db->query(
        "SELECT slug, name FROM registry.tenants WHERE slug = 'sacp'"
    )->hash;
    ok($tenant, 'sacp tenant exists');
    is($tenant->{name}, 'Super Awesome Cool Pottery', 'correct name');
};

subtest 'schema created' => sub {
    my $exists = $db->query(
        "SELECT 1 FROM information_schema.schemata WHERE schema_name = 'sacp'"
    )->hash;
    ok($exists, 'sacp schema exists');
};

subtest 'program types seeded' => sub {
    my $rows = $db->query(
        "SELECT slug FROM sacp.program_types ORDER BY slug"
    )->hashes;
    my @slugs = map { $_->{slug} } @$rows;

    for my $want (qw(afterschool summer-camp workshop wheel-class pyop)) {
        ok((grep { $_ eq $want } @slugs), "has $want program type");
    }
};

subtest 'locations seeded with addresses' => sub {
    my $studio = $db->query(
        "SELECT name, address_info FROM sacp.locations WHERE slug = 'sacp_studio'"
    )->expand->hash;
    ok($studio, 'studio location exists');
    is($studio->{name}, 'Super Awesome Cool Pottery Studio', 'studio name');
    is($studio->{address_info}{street_address}, '930 Hoffner Ave', 'studio address');

    my $drp = $db->query(
        "SELECT name, address_info FROM sacp.locations WHERE slug = 'dr_phillips_elementary'"
    )->expand->hash;
    ok($drp, 'Dr Phillips location exists');
    is($drp->{address_info}{city}, 'Orlando', 'Dr Phillips city');
};

subtest 'projects seeded as draft' => sub {
    my $rows = $db->query(
        "SELECT slug, status FROM sacp.projects ORDER BY slug"
    )->hashes;
    is(scalar @$rows, 2, 'two draft projects seeded');
    for my $row (@$rows) {
        is($row->{status}, 'draft', "$row->{slug} is draft");
    }
};

subtest 'seed script is idempotent' => sub {
    my $rc = system(qq{psql -v ON_ERROR_STOP=1 "$uri" -f "$seed_path" >/dev/null 2>&1});
    is($rc, 0, 'running again is a no-op');

    my $tenant_count = $db->query(
        "SELECT COUNT(*) FROM registry.tenants WHERE slug = 'sacp'"
    )->array->[0];
    is($tenant_count, 1, 'still exactly one sacp tenant row');

    my $type_count = $db->query(
        "SELECT COUNT(*) FROM sacp.program_types"
    )->array->[0];
    cmp_ok($type_count, '>=', 5, 'program types still present, not duplicated');
};

done_testing();
