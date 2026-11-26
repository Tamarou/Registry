#!/usr/bin/env perl
# ABOUTME: Verifies the SACP seed refuses without a signed-up sacp tenant, and
# ABOUTME: adds program data to the one tenant signup created, which holds Solo.
use 5.42.0;
use warnings;
use lib qw(lib t/lib);
use Test::More;
use Test::Registry::DB;
use File::Spec;
use Registry::DAO::Workflow;
use Registry::Utility::WorkflowProcessor;
use Registry::PriceOps::PlatformTerms qw( platform_terms_for_tenant );

my $tdb   = Test::Registry::DB->new;
my $dao   = $tdb->db;
my $db    = $dao->db;

my $seed_path = File::Spec->rel2abs('sql/seed/sacp-tenant.sql');

# Test::Registry::DB gives us a Test::PostgreSQL instance with a URI we
# can hand to psql.
my $uri = $tdb->uri;
sub run_seed { system(qq{psql -v ON_ERROR_STOP=1 "$uri" -f "$seed_path" >/dev/null 2>&1}) }

# Tenant rows plus the sacp schema: what creating a tenant would write.
sub written {
    return $db->query(q{
        SELECT (SELECT count(*) FROM registry.tenants)
             + (SELECT count(*) FROM pg_namespace WHERE nspname = 'sacp')
    })->array->[0];
}

subtest 'seed refuses without a signed-up sacp tenant' => sub {
    my $before = written();
    my $out = `psql -v ON_ERROR_STOP=1 "$uri" -f "$seed_path" 2>&1`;
    isnt($? >> 8, 0, 'exits non-zero');
    like($out, qr/sign up 'sacp' through tenant signup/, 'saying to sign up through tenant signup');
    is(written(), $before, 'creates no tenant and no schema');
};

# SACP signs up as any studio does: the tenant-signup workflow, accepting Solo.
$dao->import_workflows( ['workflows/tenant-signup.yml'] );
my ($workflow) = Registry::DAO::Workflow->find( $db, { slug => 'tenant-signup' } );
my $processor  = Registry::WorkflowProcessor->new( dao => $db );
my $run        = $processor->new_run( $workflow, {
    name            => 'Super Awesome Cool Pottery',
    subdomain       => 'sacp',
    admin_name      => 'Victoria',
    admin_email     => 'sacp_admin@test.example',
    admin_username  => 'sacp_admin',
    admin_user_type => 'admin',
    profile         => { name => 'Super Awesome Cool Pottery', slug => 'sacp' },
} );
$processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => $_ } ), {} )
    for qw( profile users );
$processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => 'review' } ),
    { offer_version => '9bc4069a-f0a7-0026-3a84-aeb0d0732995' } );    # Solo v2
$processor->process_workflow_run_step( $run, $workflow->get_step( $db, { slug => 'complete' } ), {} );
$db->query('SET search_path = registry, public');

is(run_seed(), 0, 'seed script runs without error after signup');

subtest 'signup tenant holds solo' => sub {
    my $tenant = $db->query(
        "SELECT slug, name FROM registry.tenants WHERE slug = 'sacp'"
    )->hash;
    ok($tenant, 'sacp tenant exists');
    is($tenant->{name}, 'Super Awesome Cool Pottery', 'correct name');
    is(platform_terms_for_tenant( $db, 'sacp' )->{fraction}, '0.025', 'holds Solo at 2.5%');
};

subtest 'program types seeded' => sub {
    my $rows = $db->query(
        "SELECT slug FROM sacp.program_types ORDER BY slug"
    )->hashes;
    my @slugs = map { $_->{slug} } @$rows;

    for my $want (qw(afterschool summer-camp workshop wheel-class pyop field-trip birthday-party)) {
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
    my $types = $db->query("SELECT COUNT(*) FROM sacp.program_types")->array->[0];
    is(run_seed(), 0, 'running again is a no-op');

    my $tenant_count = $db->query(
        "SELECT COUNT(*) FROM registry.tenants WHERE slug = 'sacp'"
    )->array->[0];
    is($tenant_count, 1, 'still exactly one sacp tenant row');

    is($db->query("SELECT COUNT(*) FROM sacp.program_types")->array->[0], $types,
        'program types still present, not duplicated');
};

done_testing();
