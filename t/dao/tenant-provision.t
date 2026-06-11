# ABOUTME: Tests for Registry::DAO::Tenant->provision class method.
# ABOUTME: Verifies tenant creation copies all workflows (except tenant-signup) and users.
use 5.42.0;
use lib qw(lib t/lib);
use experimental qw(defer keyword_any);
use Test::More import => [qw(done_testing is ok subtest)];
defer { done_testing };

use Mojo::Home;
use Registry::DAO;
use Registry::DAO::OutcomeDefinition;
use Registry::DAO::Tenant;
use Registry::DAO::User;
use Test::Registry::DB;
use Test::Registry::Helpers qw(import_all_workflows);

my $t_db = Test::Registry::DB->new;
my $dao  = $t_db->db;            # keep $dao alive
$ENV{DB_URL} = $t_db->uri;
my $db = $dao->db;

import_all_workflows($dao);

my $admin = Registry::DAO::User->create($db, {
    username => 'prov_admin', user_type => 'admin',
    email => 'prov_admin@test.com', name => 'Prov Admin',
});

my $tenant = Registry::DAO::Tenant->provision($db, {
    name  => 'Provision Test',
    slug  => 'provision1',
    users => [ $admin ],
});
ok $tenant, 'provision returned a tenant';
is $tenant->slug, 'provision1', 'tenant slug as requested';

my $tenant_dao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $tenant->slug);
my @slugs = map { $_->{slug} } $tenant_dao->db->select('workflows', ['slug'])->hashes->each;
for my $need (qw(program-creation program-location-assignment tenant-storefront session-creation event-creation user-creation)) {
    ok( (any { $_ eq $need } @slugs), "tenant has '$need' workflow" );
}
ok( !(any { $_ eq 'tenant-signup' } @slugs), 'tenant does NOT have tenant-signup' );

my $copied = $tenant_dao->find(User => { username => 'prov_admin' });
ok $copied, 'admin user copied into tenant schema';

# Regression pin for the outcome-definition FK ordering bug fixed in 3652f34.
#
# Background: copy_workflow inserts workflow_steps rows that carry an
# outcome_definition_id FK.  That FK references the TENANT schema's own
# outcome_definitions table (clone_schema strips the registry. qualifier).
# If outcome definitions are not copied into the tenant schema BEFORE
# copy_workflow runs, the FK insert fails with a constraint violation.
#
# The app's before_server_start hook (lib/Registry.pm) calls import_schemas
# first, then import_workflows, so the registry schema always has outcome
# definitions in place when provision is called in production.  A test that
# imports workflows without outcome definitions exercises only the NULL-FK
# path and cannot detect a broken copy ordering.
#
# This subtest mirrors the production boot order (schemas before workflows,
# via the shared helper), provisions a tenant, and verifies that:
#   1. summer-camp-registration (the canonical workflow with a linked outcome
#      definition on its camper-info step) was copied into the tenant schema.
#   2. No step in the tenant schema has a dangling outcome_definition_id FK
#      (join count of unresolvable IDs == 0).
#   3. At least one step has a non-NULL outcome_definition_id so the pin
#      cannot pass vacuously on a database where the FK column is always NULL.
subtest 'provision copies outcome definitions before workflows (FK ordering pin)' => sub {
    my $pin_db_obj = Test::Registry::DB->new;
    my $pin_dao    = $pin_db_obj->db;
    $ENV{DB_URL}   = $pin_db_obj->uri;
    my $pin_db     = $pin_dao->db;

    # Import outcome definitions then workflows via the shared helper, which
    # mirrors the production import_schemas-then-import_workflows boot order.
    # Sharing the helper keeps this pin on the exact code path every other
    # provisioning test uses.
    import_all_workflows($pin_dao);

    my $pin_admin = Registry::DAO::User->create($pin_db, {
        username => 'pin_admin', user_type => 'admin',
        email => 'pin_admin@test.com', name => 'Pin Admin',
    });

    my $pin_tenant = Registry::DAO::Tenant->provision($pin_db, {
        name  => 'FK Pin Test',
        slug  => 'fkpin1',
        users => [ $pin_admin ],
    });
    ok $pin_tenant, 'provision succeeded with outcome definitions pre-loaded';

    my $pin_tdao = Registry::DAO->new(url => $ENV{DB_URL}, schema => $pin_tenant->slug);
    my $pin_tdb  = $pin_tdao->db;

    # Assert summer-camp-registration was copied into the tenant schema.
    my @tenant_wf_slugs =
      map { $_->{slug} } $pin_tdb->select('workflows', ['slug'])->hashes->each;
    ok( (any { $_ eq 'summer-camp-registration' } @tenant_wf_slugs),
        'tenant schema contains summer-camp-registration workflow' );

    # Assert no dangling outcome_definition_id FK in the tenant schema.
    # A dangling FK would mean copy_workflow ran before outcome defs existed
    # (the pre-fix bug: workflow_steps rows with outcome_definition_id values
    # that do not resolve to any row in the tenant's outcome_definitions table).
    my $dangling = $pin_tdb->query(qq{
        SELECT COUNT(*) AS n
          FROM workflow_steps ws
         WHERE ws.outcome_definition_id IS NOT NULL
           AND NOT EXISTS (
               SELECT 1 FROM outcome_definitions od
                WHERE od.id = ws.outcome_definition_id
           )
    })->hash->{n};
    is $dangling + 0, 0,
      'no workflow_steps rows have a dangling outcome_definition_id FK';

    # Assert at least one step has a non-NULL outcome_definition_id so the
    # above check cannot pass vacuously on a fully-NULL dataset.
    my $linked = $pin_tdb->query(q{
        SELECT COUNT(*) AS n
          FROM workflow_steps
         WHERE outcome_definition_id IS NOT NULL
    })->hash->{n};
    ok $linked > 0,
      'at least one workflow_step has a non-NULL outcome_definition_id (pin is non-vacuous)';
};
